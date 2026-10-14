import CloudKit
import Foundation
import OSLog

/// Where a body's satellites live: the private `Content` zone for every private owner and every
/// personal satellite, or a space's own zone for a space owner (§2.2, §3.5.30), named with that
/// zone's salt (the personal library's root names `Content`).
struct BlobZone: Equatable, Sendable {
    let zoneID: CloudZoneID
    let database: CloudDatabaseScope
    /// `ck_zones.zone_key`: `private/Content`, `private/Space-<id>` or `shared/<owner>/Space-<id>`.
    let zoneKey: String
    let salt: Data

    var isSpace: Bool { SyncZoneName(zoneID.zoneName)?.isSpace ?? false }

    /// The private `Content` zone, named with the personal library's salt.
    static func personal(salt: Data) -> BlobZone {
        BlobZone(zoneID: PrivateSyncZones.content, database: .private, zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), salt: salt)
    }

    /// The zone a replica zone key names, with the salt of the root that names it; nil until that
    /// root is held.
    static func resolve(zoneKey: String, in state: PrivateSyncLocalState) throws -> BlobZone? {
        let replica = state.replica
        guard let zone = try replica.zone(key: zoneKey) else { return nil }
        let rootKey = SyncZoneName(zone.zoneName)?.isSpace == true ? zoneKey : PrivateSyncZones.libraryKey
        guard let root = try replica.record(zoneKey: rootKey, recordName: SyncSchema.rootRecordName),
              let salt = (try? SyncEnvelope(storedPayload: root.payload))?.fields["salt"]?.stringValue.flatMap(RecordNaming.salt(base64:))
        else { return nil }
        let database: CloudDatabaseScope = zone.database == .shared ? .shared : .private
        let zoneID = database == .shared
            ? CloudZoneID(zone.zoneName, ownerName: zone.ownerRecordName ?? CloudZoneID.currentUser)
            : CloudZoneID(zone.zoneName)
        return BlobZone(zoneID: zoneID, database: database, zoneKey: zoneKey, salt: salt)
    }
}

enum BlobStoreError: Error, Equatable, Sendable {
    /// A create met a satellite of the same name whose part fields differ: a buggy writer. Logged
    /// and quarantined, never taken as success (§3.5.30 rule 1).
    case partMismatch(contentID: String)
    /// Satellites a FileRef names that the server does not hold (their content ids).
    case missingParts([String])
    /// A part whose bytes do not hash to the name it was fetched by.
    case corruptPart(contentID: String)
    /// The reassembled, decoded file is not the one the FileRef names.
    case hashMismatch
    /// The bytes were never uploaded (`sync.originals`); only that Mac holds them.
    case heldOnlyBy(String)
    /// A personal satellite is never written into a space (§3.5.30 rule 5).
    case personalSatelliteInSpace
    case failed(CloudError)
}

/// The satellites of `Content` (docs/cloudkit-schema-design.md §2.3, §3.5.30, D10, D11, D41): every
/// body is uploaded, fetched and copied by record name, never through a change feed.
///
/// - A body that stores in at most 256 KiB is one inline satellite (`data`); a larger one is cut into
///   parts of exactly 48 MiB from native clients (14 MiB from the web, the layout a test asks for),
///   the last smaller, each an `asset`. A satellite is named by its owner, role and the hash of that
///   part's stored bytes, after gzip when the body is gzip, so two writers that split or compress the
///   same file differently write different names, never different bytes under one name.
/// - Bytes before pointer: `upload` returns the FileRef only once every part is acknowledged; the
///   caller writes the owner's pointer after that (§3.5.30 rule 2). Nobody deletes on a pointer move.
/// - A create is a compare-and-set create. One that meets a satellite of its name counts as success
///   only once that satellite's `partHash`, `partBytes` and `enc` match what this writer meant to
///   store; otherwise it is quarantined and the upload fails (rule 1).
/// - `ck_blobs` is a hint, never proof: a part acknowledged more than 24 hours ago, or one this
///   device never acknowledged, is looked up by name (`desiredKeys = []`) before it is pointed at
///   again, and uploaded again when it is gone (rule 4, D11).
/// - A body whose decoded hash equals the replica FileRef's keeps that FileRef, parts and all (rule
///   8), so a web upload is never uploaded again by the Mac.
/// - A fetch checks every part against its name and the reassembled file against `hash` and `size`.
///
/// Every request goes through the pacer of its database as the `.blobs` stream (D43), so satellites
/// never hold small records back. Generation 2 only: nothing constructs a BlobStore under generation 1.
actor BlobStore {
    enum Encoding: String, Sendable {
        case identity
        case gzip
    }

    struct Configuration: Sendable {
        /// 48 MiB from native clients; the web's 14 MiB only where a test stands in for a web upload.
        var partBytes = SyncSchema.Limits.satellitePartBytesNative
        var inlineMaxBytes = SyncSchema.Limits.inlineSatelliteMaxBytes
        var assetsPerRequest = SyncSchema.Limits.assetsPerOperationMax
        /// What one request may carry in assets (§11.3).
        var requestAssetBytes = 200 * 1024 * 1024
        var requestInlineBytes = SyncSchema.Limits.batchMaxBytes
        /// A part acknowledged longer ago is looked up before it is pointed at again (rule 4).
        var reverifyAfter: TimeInterval = 24 * 3_600
        var retryRounds = 3

        static let native = Configuration()
        static var web: Configuration {
            var configuration = Configuration()
            configuration.partBytes = SyncSchema.Limits.satellitePartBytesWeb
            return configuration
        }
    }

    static let quarantineReason = "satelliteMismatch"
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "BlobStore")

    let transport: CloudTransport
    let store: PrivateSyncLocalStore
    let deviceID: String
    let configuration: Configuration
    private let pacer: @Sendable (CloudDatabaseScope) async -> SyncPacer
    private let clock: @Sendable () -> Date
    private let scratch: URL

    init(transport: CloudTransport, store: PrivateSyncLocalStore, deviceID: String, configuration: Configuration = .native,
         pacer: @escaping @Sendable (CloudDatabaseScope) async -> SyncPacer, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.store = store
        self.deviceID = deviceID
        self.configuration = configuration
        self.pacer = pacer
        self.clock = clock
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ForeverLMBlobStore-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Uploading

    /// Uploads `body` as the satellites of `owner`'s `role` in `zone` and returns their FileRef, once
    /// every part is acknowledged. `existing` is the FileRef the replica holds for the same owner and
    /// role: when it names the same decoded bytes it is kept as it is, and only parts the server lost
    /// are uploaded again, when this device can reproduce them.
    func upload(_ body: Data, owner: String, ownerType: SyncRecordType, role: String, mime: String, encoding: Encoding,
                into zone: BlobZone, keeping existing: FileRef? = nil, children: [FileRef] = [], gen: SyncJSON? = nil) async throws -> FileRef {
        let personal = SyncSchema.personalSatelliteRoles.contains(role)
        if personal, zone.isSpace { throw BlobStoreError.personalSatelliteInSpace }
        let hash = SyncIdentity.sha256Hex(body)
        let description = PartDescription(ownerType: ownerType, owner: owner, role: role, hash: hash, size: Int64(body.count), mime: mime,
                                          personal: personal, gen: gen)

        if let existing, existing.hash == hash, existing.owner == owner, existing.role == role, existing.heldBy == nil {
            if let parts = try reproduce(body, as: existing) {
                try await ensure(parts, of: existing, description: description, in: zone, lookUpFirst: true)
                return existing
            }
            // Bytes another writer laid out (a web upload's gzip) cannot be made again here: the
            // FileRef stays while its parts are on the server.
            if try await missing(existing, in: zone).isEmpty { return existing }
        }

        let stored = encoding == .gzip ? try SyncGzip.compress(body) : body
        let parts = stored.count <= configuration.inlineMaxBytes ? [stored] : FileRef.split(stored, partSize: configuration.partBytes)
        let file = FileRef(owner: owner, role: role, hash: hash, size: Int64(body.count), mime: mime, encoding: encoding.rawValue,
                           storedParts: parts, children: children)
        try await ensure(parts, of: file, description: description, in: zone, lookUpFirst: false)
        return file
    }

    /// The stored parts of `body` laid out as `file` says, when this device's encoding makes exactly
    /// those parts; nil otherwise.
    private func reproduce(_ body: Data, as file: FileRef) throws -> [Data]? {
        let stored: Data
        switch file.encoding {
        case Encoding.identity.rawValue: stored = body
        case Encoding.gzip.rawValue: stored = try SyncGzip.compress(body)
        default: return nil
        }
        let layouts = file.parts.count == 1
            ? [[stored]]
            : Set([configuration.partBytes, SyncSchema.Limits.satellitePartBytesNative, SyncSchema.Limits.satellitePartBytesWeb])
                .sorted().map { FileRef.split(stored, partSize: $0) }
        return layouts.first { $0.map(FileRef.partHash32) == file.parts }
    }

    /// What every part's payload says besides its own place.
    private struct PartDescription {
        let ownerType: SyncRecordType
        let owner: String
        let role: String
        let hash: String
        let size: Int64
        let mime: String
        let personal: Bool
        let gen: SyncJSON?
    }

    private struct Part {
        let index: Int
        let data: Data
        let contentID: String
        let id: CloudRecordID
        let inline: Bool
    }

    /// Makes sure every part of `file` is on the server: a part acknowledged here within the last 24
    /// hours is trusted, an older one is looked up first, and what is not there is created. A part this
    /// device never acknowledged is created at once (a collision is checked), or looked up first when
    /// the layout is someone else's (`lookUpFirst`), so a kept layout uploads no bytes the server holds.
    /// The parts that land are in the ledger even when another fails; the first failure is thrown.
    private func ensure(_ data: [Data], of file: FileRef, description: PartDescription, in zone: BlobZone, lookUpFirst: Bool) async throws {
        let parts = data.enumerated().map { index, bytes in
            let contentID = SyncIdentity.contentID(owner: file.owner, role: file.role, partHash32: FileRef.partHash32(bytes))
            return Part(index: index, data: bytes, contentID: contentID,
                        id: CloudRecordID(RecordNaming.recordName(type: .content, id: contentID, salt: zone.salt), in: zone.zoneID),
                        inline: file.isInline)
        }
        let now = clock()
        let acknowledged = try await acknowledgedAt(parts.map(\.id.recordName), zoneKey: zone.zoneKey)
        let trusted = Set(parts.filter { part in
            acknowledged[part.id.recordName].map { now.timeIntervalSince($0) <= configuration.reverifyAfter } ?? false
        }.map(\.id))
        var toCreate = parts.filter { !trusted.contains($0.id) && acknowledged[$0.id.recordName] == nil && !lookUpFirst }
        let toCheck = parts.filter { !trusted.contains($0.id) && (acknowledged[$0.id.recordName] != nil || lookUpFirst) }
        if !toCheck.isEmpty {
            let gone = Set(try await absent(toCheck.map(\.id), in: zone))
            let present = toCheck.filter { !gone.contains($0.id) }
            try await record(present, of: file, in: zone, createdAt: nil)
            toCreate += toCheck.filter { gone.contains($0.id) }
        }
        guard !toCreate.isEmpty else { return }
        let stamp = try await mintStamp()
        var failure: Error?
        for batch in batches(toCreate) {
            do {
                try await create(batch, of: file, description: description, in: zone, stamp: stamp)
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
    }

    /// Requests of at most 20 assets and 200 MB, or 800 KiB of inline bodies, and the pacer's batch.
    private func batches(_ parts: [Part]) -> [[Part]] {
        var batches: [[Part]] = []
        var current: [Part] = []
        var bytes = 0
        for part in parts {
            let limit = part.inline ? configuration.requestInlineBytes : configuration.requestAssetBytes
            if !current.isEmpty, current.count >= configuration.assetsPerRequest || bytes + part.data.count > limit {
                batches.append(current)
                current = []
                bytes = 0
            }
            current.append(part)
            bytes += part.data.count
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private func create(_ parts: [Part], of file: FileRef, description: PartDescription, in zone: BlobZone, stamp: SyncStamp) async throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var records: [CloudRecord] = []
        var files: [URL] = []
        defer { for url in files { try? FileManager.default.removeItem(at: url) } }
        for part in parts {
            var envelope = SyncEnvelope.new(.content, id: part.contentID, saltID: RecordNaming.saltID(zone.salt))
            var patch = RecordPatch(.content, id: part.contentID)
            var fields: [String: SyncJSON] = [
                "ownerType": .string(description.ownerType.rawValue), "ownerID": .string(description.owner), "role": .string(description.role),
                "hash": .string(description.hash), "size": SyncJSON(description.size), "mime": .string(description.mime),
                "enc": .string(file.encoding ?? Encoding.identity.rawValue), "part": SyncJSON(part.index), "parts": SyncJSON(file.parts.count),
                "partHash": .string(SyncIdentity.sha256Hex(part.data)), "partBytes": SyncJSON(part.data.count),
                "personal": .bool(description.personal), "createdAt": SyncJSON(SyncTime.milliseconds(clock())),
            ]
            if let gen = description.gen { fields["gen"] = gen }
            for (field, value) in fields { patch.changes[field] = .value(value) }
            try envelope.apply(patch) { _, _, _ in stamp }
            var record = CloudRecord(id: part.id, recordType: SyncRecordType.content.rawValue,
                                     encryptedFields: [CloudRecord.payloadKey: .bytes(try envelope.storedPayload())])
            if part.inline {
                record.encryptedFields[CloudRecord.dataKey] = .bytes(part.data)
            } else {
                let url = scratch.appendingPathComponent(UUID().uuidString)
                try part.data.write(to: url)
                files.append(url)
                record.fields[CloudRecord.assetKey] = .asset(url)
            }
            records.append(record)
        }

        let saving = records
        let results = try await perform(zone.database, writes: true) { [transport] in
            try await transport.modifyRecords(saving: saving, in: zone.database)
        }
        var saved: [Part] = []
        var collided: [Part] = []
        var created: [CloudRecordID: Date?] = [:]
        var failure: CloudError?
        for part in parts {
            switch results.saved[part.id] {
            case .success(let record)?:
                saved.append(part)
                created[part.id] = record.creationDate
            case .failure(let error)? where error.code == .serverRecordChanged:
                collided.append(part)
            case .failure(let error)?:
                failure = failure ?? error
            case nil:
                failure = failure ?? CloudError(.internalError, message: "no result for \(part.contentID)")
            }
        }
        try await record(saved, of: file, in: zone, createdAt: created)
        if !collided.isEmpty { try await acceptCollisions(collided, of: file, in: zone) }
        if let failure { throw BlobStoreError.failed(failure) }
    }

    /// A create that met a satellite of its name: success only when that satellite's part fields are
    /// the ones this writer meant to store (the name already fixes owner, role and part hash).
    private func acceptCollisions(_ parts: [Part], of file: FileRef, in zone: BlobZone) async throws {
        let fetched = try await perform(zone.database, writes: false) { [transport] in
            try await transport.records(parts.map(\.id), in: zone.database, desiredKeys: [CloudRecord.payloadKey])
        }
        var matched: [Part] = []
        var created: [CloudRecordID: Date?] = [:]
        for part in parts {
            let record: CloudRecord
            switch fetched[part.id] {
            case .success(let held)?: record = held
            case .failure(let error)?: throw BlobStoreError.failed(error)
            case nil: throw BlobStoreError.failed(CloudError(.unknownItem, message: "no satellite \(part.contentID)"))
            }
            let fields = record.payload.flatMap { try? SyncEnvelope(storedPayload: $0) }?.fields ?? [:]
            guard fields["partHash"]?.stringValue == SyncIdentity.sha256Hex(part.data),
                  fields["partBytes"]?.int64Value == Int64(part.data.count),
                  fields["enc"]?.stringValue == (file.encoding ?? Encoding.identity.rawValue)
            else {
                let now = clock()
                try await store.perform { state in
                    try state.connection.execute("""
                        INSERT INTO ck_quarantine (zone_key, record_name, record_type, reason, system_fields, payload, quarantined_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(zone_key, record_name) DO UPDATE SET reason = excluded.reason, system_fields = excluded.system_fields,
                            payload = excluded.payload, quarantined_at = excluded.quarantined_at
                    """, [
                        .text(zone.zoneKey), .text(part.id.recordName), .text(SyncRecordType.content.rawValue), .text(Self.quarantineReason),
                        .blob(record.systemFields), .blob(record.payload), .real(now.timeIntervalSinceReferenceDate),
                    ])
                }
                Self.logger.error("A satellite of \(file.role, privacy: .public) holds other part fields than its name promises")
                throw BlobStoreError.partMismatch(contentID: part.contentID)
            }
            matched.append(part)
            created[part.id] = record.creationDate
        }
        try await record(matched, of: file, in: zone, createdAt: created)
    }

    /// Writes the parts into `ck_blobs` as acknowledged now (the upload ledger GC lists, §5.8). A part
    /// acknowledged again (re-verified before a pointer names it) starts GC's sweeps over.
    private func record(_ parts: [Part], of file: FileRef, in zone: BlobZone, createdAt: [CloudRecordID: Date?]?) async throws {
        guard !parts.isEmpty else { return }
        let now = clock().timeIntervalSinceReferenceDate
        let encoding = file.encoding ?? Encoding.identity.rawValue
        try await store.perform { state in
            for part in parts {
                let created = createdAt?[part.id] ?? nil
                try state.connection.execute("""
                    INSERT INTO ck_blobs (zone_key, record_name, content_id, owner_id, role, part_hash, part_bytes, enc, server_created_at, acked_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(zone_key, record_name) DO UPDATE SET acked_at = excluded.acked_at,
                        server_created_at = COALESCE(excluded.server_created_at, ck_blobs.server_created_at),
                        content_id = excluded.content_id, owner_id = excluded.owner_id, role = excluded.role,
                        part_hash = excluded.part_hash, part_bytes = excluded.part_bytes, enc = excluded.enc,
                        unreachable_since = NULL
                """, [
                    .text(zone.zoneKey), .text(part.id.recordName), .text(part.contentID), .text(file.owner), .text(file.role),
                    .text(SyncIdentity.sha256Hex(part.data)), .integer(Int64(part.data.count)), .text(encoding),
                    .real(created?.timeIntervalSinceReferenceDate), .real(now),
                ])
            }
        }
    }

    private func acknowledgedAt(_ recordNames: [String], zoneKey: String) async throws -> [String: Date] {
        try await store.perform { state in
            var found: [String: Date] = [:]
            for name in recordNames {
                try state.connection.query(
                    "SELECT acked_at FROM ck_blobs WHERE zone_key = ? AND record_name = ? AND acked_at IS NOT NULL",
                    [.text(zoneKey), .text(name)]
                ) { row in
                    if let seconds = row.real(0) { found[name] = Date(timeIntervalSinceReferenceDate: seconds) }
                }
            }
            return found
        }
    }

    /// One stamp for every field of an upload's satellites (all S, and immutable): from the device's
    /// clock once it knows its server offset, else provisional, as a root made before one is (§6.3).
    private func mintStamp() async throws -> SyncStamp {
        let now = clock()
        let deviceID = deviceID
        return try await store.perform { state -> SyncStamp in
            let replica = state.replica
            guard var clock = try replica.loadClock(),
                  let stamp = clock.mint(.serverFirst, eventTime: SyncTime.milliseconds(now), seen: nil, now: SyncTime.milliseconds(now))
            else { return SyncStamp.provisional(.serverFirst, deviceID: deviceID) }
            try replica.saveClock(clock, now: now)
            return stamp
        }
    }

    // MARK: - Reading

    /// The decoded bytes of `file`, fetched part by part by name from `zone`: every part must hash to
    /// its name, and the whole to the FileRef's `hash` and `size`.
    func fetch(_ file: FileRef, from zone: BlobZone) async throws -> Data {
        if let heldBy = file.heldBy { throw BlobStoreError.heldOnlyBy(heldBy) }
        let stored = try await storedParts(file, from: zone).reduce(into: Data()) { $0.append($1) }
        let decoded: Data
        if file.encoding == Encoding.gzip.rawValue {
            guard let size = file.size, let inflated = try? SyncGzip.decompress(stored, maxBytes: Int(size)) else { throw BlobStoreError.hashMismatch }
            decoded = inflated
        } else {
            decoded = stored
        }
        guard SyncIdentity.sha256Hex(decoded) == file.hash, file.size.map({ $0 == Int64(decoded.count) }) ?? true else {
            throw BlobStoreError.hashMismatch
        }
        return decoded
    }

    /// Each part's stored bytes, fetched by name in requests of at most 20 assets and 200 MB, each
    /// checked against the hash its name carries.
    private func storedParts(_ file: FileRef, from zone: BlobZone) async throws -> [Data] {
        let ids = partIDs(file, in: zone)
        let partBytes = max(1, Int((file.stored ?? 0) / Int64(max(1, ids.count))))
        let perRequest = max(1, min(configuration.assetsPerRequest, configuration.requestAssetBytes / partBytes))
        var parts: [Data] = []
        var missing: [String] = []
        for start in stride(from: 0, to: ids.count, by: perRequest) {
            let slice = Array(ids[start..<min(start + perRequest, ids.count)])
            let fetched = try await perform(zone.database, writes: false) { [transport] in
                try await transport.records(slice.map(\.id), in: zone.database, desiredKeys: [CloudRecord.dataKey, CloudRecord.assetKey])
            }
            for part in slice {
                switch fetched[part.id] {
                case .success(let record)?:
                    let bytes: Data
                    switch (record.encryptedFields[CloudRecord.dataKey], record.fields[CloudRecord.assetKey]) {
                    case (.bytes(let data)?, _): bytes = data
                    case (_, .asset(let url)?): bytes = try Data(contentsOf: url)
                    default: throw BlobStoreError.corruptPart(contentID: part.contentID)
                    }
                    guard FileRef.partHash32(bytes) == part.partHash else { throw BlobStoreError.corruptPart(contentID: part.contentID) }
                    parts.append(bytes)
                case .failure(let error)? where error.code == .unknownItem:
                    missing.append(part.contentID)
                case .failure(let error)?:
                    throw BlobStoreError.failed(error)
                case nil:
                    missing.append(part.contentID)
                }
            }
        }
        guard missing.isEmpty else { throw BlobStoreError.missingParts(missing) }
        return parts
    }

    /// The content ids of `file`'s parts the server does not hold (a names-only lookup).
    func missing(_ file: FileRef, in zone: BlobZone) async throws -> [String] {
        let ids = partIDs(file, in: zone)
        let gone = Set(try await absent(ids.map(\.id), in: zone))
        return ids.filter { gone.contains($0.id) }.map(\.contentID)
    }

    /// The indices of `files` the server lacks a part of, its own or a child's: names-only lookups, as many to a
    /// request as a batch holds, so a whole library's pointers are checked in a few dozen requests. A file held
    /// only by a named Mac (`heldBy`) has nothing on the server to look for.
    func filesMissingParts(_ files: [FileRef], in zone: BlobZone) async throws -> Set<Int> {
        var owners: [CloudRecordID: [Int]] = [:]
        var ids: [CloudRecordID] = []
        func add(_ file: FileRef, index: Int) {
            guard file.heldBy == nil else { return }
            for child in file.children { add(child, index: index) }
            for part in partIDs(file, in: zone) {
                if owners[part.id] == nil { ids.append(part.id) }
                owners[part.id, default: []].append(index)
            }
        }
        for (index, file) in files.enumerated() { add(file, index: index) }
        return Set(try await absent(ids, in: zone).flatMap { owners[$0] ?? [] })
    }

    private struct PartID {
        let id: CloudRecordID
        let contentID: String
        let partHash: String
    }

    private func partIDs(_ file: FileRef, in zone: BlobZone) -> [PartID] {
        file.parts.map { partHash in
            let contentID = SyncIdentity.contentID(owner: file.owner, role: file.role, partHash32: partHash)
            return PartID(id: CloudRecordID(RecordNaming.recordName(type: .content, id: contentID, salt: zone.salt), in: zone.zoneID),
                          contentID: contentID, partHash: partHash)
        }
    }

    /// Which of `ids` the server does not hold, looked up by name with no field (`desiredKeys = []`).
    private func absent(_ ids: [CloudRecordID], in zone: BlobZone) async throws -> [CloudRecordID] {
        var gone: [CloudRecordID] = []
        for start in stride(from: 0, to: ids.count, by: SyncSchema.Limits.batchMaxRecords) {
            let slice = Array(ids[start..<min(start + SyncSchema.Limits.batchMaxRecords, ids.count)])
            let fetched = try await perform(zone.database, writes: false) { [transport] in
                try await transport.records(slice, in: zone.database, desiredKeys: [])
            }
            for id in slice {
                switch fetched[id] {
                case .success?: continue
                case .failure(let error)? where error.code == .unknownItem: gone.append(id)
                case .failure(let error)?: throw BlobStoreError.failed(error)
                case nil: gone.append(id)
                }
            }
        }
        return gone
    }

    // MARK: - Copying into another zone (D41)

    /// Puts the satellites `file` names into `target` under the same logical ids (named with the
    /// target zone's salt), for a record copied into another zone: the FileRef stays verbatim, owner
    /// included. Each part goes as it is stored, so its part hash holds whoever laid it out; parts the
    /// target already holds are not sent again, and children go too.
    func copy(_ file: FileRef, ownerType: SyncRecordType, from source: BlobZone, to target: BlobZone) async throws {
        for child in file.children { try await copy(child, ownerType: ownerType, from: source, to: target) }
        guard !(file.isPersonal && target.isSpace) else { throw BlobStoreError.personalSatelliteInSpace }
        if let heldBy = file.heldBy { throw BlobStoreError.heldOnlyBy(heldBy) }
        guard try await !missing(file, in: target).isEmpty else { return }
        let parts = try await storedParts(file, from: source)
        let description = PartDescription(ownerType: ownerType, owner: file.owner, role: file.role, hash: file.hash, size: file.size ?? 0,
                                          mime: file.mime ?? "application/octet-stream", personal: file.isPersonal, gen: nil)
        try await ensure(parts, of: file, description: description, in: target, lookUpFirst: true)
    }

    // MARK: - Pacing

    /// One request through the `.blobs` stream of `database`'s pacer, tried again while CloudKit asks
    /// the client to wait; any other refusal is the caller's.
    private func perform<T: Sendable>(_ database: CloudDatabaseScope, writes: Bool, _ request: @Sendable () async throws -> T) async throws -> T {
        let pacer = await pacer(database)
        var round = 0
        while true {
            round += 1
            _ = try await pacer.acquire(.blobs, writes: writes)
            do {
                let result = try await request()
                await pacer.succeeded(.blobs)
                return result
            } catch let error as CloudError {
                await pacer.refused(.blobs, with: error)
                let waits: [CKError.Code] = [.requestRateLimited, .zoneBusy, .serviceUnavailable]
                guard waits.contains(error.code), round < configuration.retryRounds else { throw BlobStoreError.failed(error) }
            }
        }
    }
}
