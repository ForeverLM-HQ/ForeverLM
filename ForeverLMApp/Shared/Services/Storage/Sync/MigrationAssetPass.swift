import CloudKit
import Foundation
import OSLog

// MARK: - The old records' files (docs/cloudkit-schema-design.md §13.6 "Assets", §13.3 step 4, WP16b2)

/// The two queues a pass fills for `MigrationAssetPass` to drain, both in `ck_backfill_queue`.
enum MigrationAssetQueue {
    /// A changed old record's file assets, queued by the catch-up and by every import pass, refresh and
    /// deferred catch-up that met the record. Target `<old zone>/<record name>`; the payload names the
    /// record's database, zone, owner and entity and the asset fields it may carry.
    static let oldAssetsKind = MigrationCatchUpApplier.assetQueueKind
    /// An old iPhone's capture after T0, whose PDF sits in iCloud Drive `Mobile Imports/`. Target the Source's
    /// wire id; the payload holds the path the capture named.
    static let mobileImportKind = "mobileImportUpload"

    static func isMobileImport(_ path: String) -> Bool { path.hasPrefix("Mobile Imports/") || path.contains("/Mobile Imports/") }

    /// A try that waits (the record has not arrived yet, the file is still downloading) is not a failure.
    static let maxAttempts = 5
    /// How long a capture's file may take to appear before the job is dropped.
    static let mobileImportPatience: TimeInterval = 30 * 86_400
}

// MARK: - What the pass reaches

/// Where a record's `files.<role>` stands in the replica.
enum MigrationPointerState: Equatable, Sendable {
    /// The replica holds no copy of the record yet (the seed has not reached it, or it never will): nothing is
    /// pointed at, and nothing is uploaded for it.
    case notHeld
    case missing
    case held(FileRef)
}

/// Reads and moves a record's `files.<role>` pointer. The Mac's is `MaintenanceFilePointers`.
protocol MigrationFilePointers: Sendable {
    func pointer(type: SyncRecordType, id: String, role: String) async throws -> MigrationPointerState
    /// Sets the pointer by compare-and-set onto the version the replica holds. False when the save met another
    /// version: the caller tries again later.
    func setPointer(type: SyncRecordType, id: String, role: String, file: FileRef) async throws -> Bool
}

/// Uploads the bytes of a satellite of a Source or a Collection before its pointer goes out (D10).
protocol MigrationSatelliteUploader: Sendable {
    func upload(_ body: Data, owner: String, ownerType: SyncRecordType, role: String, mime: String, encoding: BlobStore.Encoding) async throws -> FileRef
}

/// Where a capture's file stands on this Mac.
enum MigrationMobileFile: Equatable, Sendable {
    /// Neither the file nor its iCloud placeholder is here yet.
    case missing
    /// Evicted or still arriving: its download has been asked for.
    case downloading
    case ready(URL)
}

// MARK: - The pass

/// Drains the queues a late import, a refresh and a deferred catch-up leave:
/// - **A changed record's file assets.** Each is fetched by name from the old container (the record by
///   payload first, so a Source the new world does not hold yet costs no bytes), uploaded as the satellite the
///   role names (`pdf`, `epub`, `readerHTML`, `text`, `listenText`, `raw`, `thumbnail` of a Source, `cover` and
///   `icon` of a Collection), and pointed at by `files.<role>` once the bytes are acknowledged, only where the
///   record holds no pointer for the role yet: what the new world holds stands. A paper's PDF is also written
///   at the path the source has on record when no root on this Mac holds it, as generation 1 installed it.
/// - **A `Mobile Imports` capture.** The file of a late-imported Source an old iPhone captured into iCloud
///   Drive is downloaded (it may be evicted), and uploaded from where it sits as the Source's `pdf`, never
///   moved or deleted.
/// A job whose record the replica does not hold yet waits; one that fails five times waits for a later build.
/// Not built: a course's quiz pictures and a walkthrough's pictures (`courseQuizPicturesAsset`,
/// `walkthroughPicturesAsset`, packages of many pictures) and a Source's `sourceRawContentAsset`, which have
/// no satellite role of their own here; a Team's assets, whose space copies this Mac holds under other ids.
struct MigrationAssetPass: Sendable {
    struct Report: Equatable, Sendable {
        /// Satellites uploaded and pointed at.
        var uploaded = 0
        /// Paper PDFs written at the path the source has on record.
        var installed = 0
        /// Roles that already held a pointer, and assets the record no longer carries.
        var skipped = 0
        /// Jobs that wait for a record, a download or a lost compare-and-set.
        var pending = 0
        var failed = 0
        /// Jobs that left the queue.
        var finished = 0
    }

    let oldContainer: any CloudTransport
    let store: PrivateSyncLocalStore
    let uploader: any MigrationSatelliteUploader
    let pointers: any MigrationFilePointers
    var clock: @Sendable () -> Date = { Date() }
    var assetsRoot: URL = FileManager.default.temporaryDirectory
    /// Writes a paper's PDF where the source's path says. A stand-in in the suites.
    var installFile: @Sendable (CKRecord, _ storedPath: String?, _ logicalKey: String) -> Bool = { record, path, key in
        CloudKitRecordMapper.installRecordedSourcePDFAsset(from: record, storedPath: path, sourceContentRoot: nil, logicalKey: key) != nil
    }
    /// Where a `Mobile Imports` capture's file stands; asks for its download when it is evicted.
    var locateCapture: @Sendable (String) -> MigrationMobileFile = { Self.locateOnThisMac($0) }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MigrationAssets")

    private struct Job {
        let id: Int64
        let kind: String
        let target: String
        let payload: [String: Any]
        let enqueuedAt: Date
    }

    /// Runs up to `limit` jobs, oldest first; a job that waits goes to the back of its queue.
    @discardableResult
    func run(limit: Int = 25) async throws -> Report {
        var report = Report()
        let jobs = try await nextJobs(limit: limit)
        for job in jobs {
            try Task.checkCancellation()
            do {
                let outcome = job.kind == MigrationAssetQueue.mobileImportKind ? try await uploadCapture(job, report: &report) : try await drain(job, report: &report)
                try await settle(job, outcome)
                switch outcome {
                case .done: report.finished += 1
                case .waiting, .waitingSince: report.pending += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                report.failed += 1
                Self.logger.error("An old asset job failed: \(job.kind, privacy: .public) \(error.localizedDescription, privacy: .public)")
                try await fail(job, error)
            }
        }
        return report
    }

    // MARK: The queue

    private enum Outcome {
        case done
        case waiting(String)
        case waitingSince(String, Date)
    }

    private func nextJobs(limit: Int) async throws -> [Job] {
        try await store.perform { state in
            var jobs: [Job] = []
            try state.connection.query("""
                SELECT id, kind, target, payload_json, enqueued_at FROM ck_backfill_queue
                WHERE kind IN (?, ?) AND attempts < ? ORDER BY enqueued_at, id LIMIT ?
            """, [
                .text(MigrationAssetQueue.oldAssetsKind), .text(MigrationAssetQueue.mobileImportKind),
                .integer(Int64(MigrationAssetQueue.maxAttempts)), .integer(Int64(limit)),
            ]) { row in
                guard let id = row.integer(0), let kind = row.text(1), let target = row.text(2) else { return }
                let payload = row.text(3).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                jobs.append(Job(id: id, kind: kind, target: target, payload: payload, enqueuedAt: Date(timeIntervalSinceReferenceDate: row.real(4) ?? 0)))
            }
            return jobs
        }
    }

    private func settle(_ job: Job, _ outcome: Outcome) async throws {
        let now = clock()
        try await store.perform { state in
            switch outcome {
            case .done:
                try state.connection.execute("DELETE FROM ck_backfill_queue WHERE id = ?", [.integer(job.id)])
            case .waiting(let why):
                try state.connection.execute(
                    "UPDATE ck_backfill_queue SET enqueued_at = ?, last_error = ? WHERE id = ?",
                    [.real(now.timeIntervalSinceReferenceDate), .text(why), .integer(job.id)]
                )
            case .waitingSince(let why, let since):
                var payload = job.payload
                payload["waitingSince"] = since.timeIntervalSinceReferenceDate
                let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
                try state.connection.execute(
                    "UPDATE ck_backfill_queue SET enqueued_at = ?, last_error = ?, payload_json = ? WHERE id = ?",
                    [.real(now.timeIntervalSinceReferenceDate), .text(why), json.map(SQLiteValue.text) ?? .null, .integer(job.id)]
                )
            }
        }
    }

    private func fail(_ job: Job, _ error: Error) async throws {
        let message = String(error.localizedDescription.prefix(200))
        try await store.perform { state in
            try state.connection.execute(
                "UPDATE ck_backfill_queue SET attempts = attempts + 1, last_error = ? WHERE id = ?", [.text(message), .integer(job.id)]
            )
        }
    }

    // MARK: A changed old record's assets

    /// One asset field of an old record, and the satellite it becomes.
    private struct Satellite {
        let field: String
        let type: SyncRecordType
        /// The roles whose pointer, held, says the field's bytes are already there.
        let roles: [String]
        let mime: String
        let encoding: BlobStore.Encoding
    }

    private static func satellite(for field: String, entity: CloudKitSyncEntity) -> Satellite? {
        switch (entity, field) {
        case (.source, CKRecord.FieldKey.sourcePDFAsset):
            return Satellite(field: field, type: .source, roles: ["pdf", "epub"], mime: "application/pdf", encoding: .identity)
        case (.source, CKRecord.FieldKey.sourceReaderHTMLAsset):
            return Satellite(field: field, type: .source, roles: ["readerHTML"], mime: "text/html", encoding: .gzip)
        case (.source, CKRecord.FieldKey.sourceContentAsset):
            return Satellite(field: field, type: .source, roles: ["text"], mime: "text/plain", encoding: .gzip)
        case (.source, CKRecord.FieldKey.sourceListenableContentAsset):
            return Satellite(field: field, type: .source, roles: ["listenText"], mime: "text/plain", encoding: .gzip)
        case (.source, CKRecord.FieldKey.podcastRawTTMLAsset):
            return Satellite(field: field, type: .source, roles: ["raw"], mime: "application/ttml+xml", encoding: .gzip)
        case (.source, CKRecord.FieldKey.paperThumbnailAsset):
            return Satellite(field: field, type: .source, roles: ["thumbnail"], mime: "image/jpeg", encoding: .identity)
        case (.book, CKRecord.FieldKey.bookCoverAsset):
            return Satellite(field: field, type: .collection, roles: ["cover"], mime: "image/jpeg", encoding: .identity)
        case (.meetingGroup, CKRecord.FieldKey.meetingIconAsset):
            return Satellite(field: field, type: .collection, roles: ["icon"], mime: "image/png", encoding: .identity)
        default:
            return nil
        }
    }

    private func drain(_ job: Job, report: inout Report) async throws -> Outcome {
        guard let entity = (job.payload["entity"] as? String).flatMap(CloudKitSyncEntity.init(rawValue:)),
              let zoneName = job.payload["zone"] as? String, let recordName = job.payload["recordName"] as? String,
              let database = (job.payload["database"] as? String).flatMap(CloudDatabaseScope.init(rawValue:))
        else { return .done }
        // A Team's records are held as space copies under other ids: the importer's, not this pass's.
        guard TeamRecord.teamID(fromZoneName: zoneName) == nil else { return .done }
        let owner = job.payload["owner"] as? String ?? CloudZoneID.currentUser
        let zoneID = owner == CloudZoneID.currentUser ? CloudZoneID(zoneName) : CloudZoneID(zoneName, ownerName: owner)
        let id = CloudRecordID(recordName, in: zoneID)
        let wanted = (job.payload["fields"] as? [String] ?? []).compactMap { Self.satellite(for: $0, entity: entity) }
        guard !wanted.isEmpty else { return .done }

        // The record by payload first: its logical key names the v2 record, and a record the replica does not
        // hold yet costs no bytes.
        let head = try await oldContainer.records([id], in: database, desiredKeys: OldContainerWalk.desiredKeys)
        guard case .success(let headRecord)? = head[id] else { return .done }
        let decoded = try MigrationLateImport.decode(headRecord)
        var pending: [Satellite] = []
        for satellite in wanted {
            var held = false
            for role in satellite.roles {
                switch try await pointers.pointer(type: satellite.type, id: decoded.logicalKey, role: role) {
                case .notHeld: return .waiting("the record is not in the new container yet")
                case .held: held = true
                case .missing: break
                }
            }
            if held { report.skipped += 1 } else { pending.append(satellite) }
        }
        guard !pending.isEmpty else { return .done }

        let fetched = try await oldContainer.records([id], in: database, desiredKeys: pending.map(\.field))
        guard case .success(let record)? = fetched[id] else { return .done }
        let storedPath: String? = if case .source(let payload) = decoded.payload { payload.article.localFilePath } else { nil }
        var retry = false
        for satellite in pending {
            guard case .asset(let url)? = record.fields[satellite.field], let bytes = try? Data(contentsOf: url, options: .mappedIfSafe), !bytes.isEmpty else {
                report.skipped += 1
                continue
            }
            if satellite.field == CKRecord.FieldKey.sourcePDFAsset, installFile(OldContainerWalk.ckRecord(record), storedPath, decoded.logicalKey) {
                report.installed += 1
            }
            let (role, mime) = Self.sniff(bytes, satellite)
            let file = try await uploader.upload(bytes, owner: decoded.logicalKey, ownerType: satellite.type, role: role, mime: mime, encoding: satellite.encoding)
            if try await pointers.setPointer(type: satellite.type, id: decoded.logicalKey, role: role, file: file) {
                report.uploaded += 1
            } else {
                retry = true
            }
        }
        return retry ? .waiting("the record changed while its pointer was saved") : .done
    }

    /// The role and MIME type the bytes say: an EPUB travels in the PDF asset's place for a book, and an image
    /// is a PNG or a JPEG.
    private static func sniff(_ bytes: Data, _ satellite: Satellite) -> (role: String, mime: String) {
        let head = [UInt8](bytes.prefix(4))
        switch satellite.roles.first {
        case "pdf":
            return head == [0x50, 0x4B, 0x03, 0x04] ? ("epub", "application/epub+zip") : ("pdf", "application/pdf")
        case "thumbnail", "cover", "icon":
            return (satellite.roles[0], head.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg")
        default:
            return (satellite.roles[0], satellite.mime)
        }
    }

    // MARK: A captured file in iCloud Drive

    private func uploadCapture(_ job: Job, report: inout Report) async throws -> Outcome {
        guard let path = job.payload["path"] as? String else { return .done }
        let sourceID = job.target
        let since = (job.payload["waitingSince"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:)) ?? clock()
        if clock().timeIntervalSince(since) > MigrationAssetQueue.mobileImportPatience {
            Self.logger.notice("A captured file never arrived; its upload job is dropped")
            return .done
        }
        switch try await pointers.pointer(type: .source, id: sourceID, role: "pdf") {
        case .notHeld: return .waiting("the record is not in the new container yet")
        case .held:
            report.skipped += 1
            return .done
        case .missing: break
        }
        switch locateCapture(path) {
        case .missing: return .waitingSince("the file has not arrived from iCloud Drive", since)
        case .downloading: return .waitingSince("the file is downloading from iCloud Drive", since)
        case .ready(let url):
            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !bytes.isEmpty else { return .waitingSince("the file is empty", since) }
            let file = try await uploader.upload(bytes, owner: sourceID, ownerType: .source, role: "pdf", mime: "application/pdf", encoding: .identity)
            guard try await pointers.setPointer(type: .source, id: sourceID, role: "pdf", file: file) else {
                return .waiting("the record changed while its pointer was saved")
            }
            report.uploaded += 1
            return .done
        }
    }

    /// Where a capture's file stands under this Mac's content roots (`StorageService.locateSourceFile`): the
    /// file itself, or its iCloud placeholder, whose download is asked for.
    static func locateOnThisMac(_ storedPath: String) -> MigrationMobileFile {
        guard let located = StorageService.locateSourceFile(storedPath) else { return .missing }
        let url = URL(fileURLWithPath: located)
        if FileManager.default.fileExists(atPath: located) {
            let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
            if status == nil || status == .current { return .ready(url) }
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return .downloading
        }
        let stub = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        try? FileManager.default.startDownloadingUbiquitousItem(at: stub)
        return .downloading
    }
}

// MARK: - The Mac's seams

/// `MigrationFilePointers` on the replica and the maintenance writer: the pointer moves by compare-and-set
/// onto the version the replica holds, only where the record is held, as a notebook cover's does.
struct MaintenanceFilePointers: MigrationFilePointers {
    let store: PrivateSyncLocalStore
    let writer: MaintenanceWriter

    func pointer(type: SyncRecordType, id: String, role: String) async throws -> MigrationPointerState {
        try await store.perform { state in
            guard let located = try MigrationImportStore.locate(MigrationRecordKey(type, id), state.connection), let held = located.replica,
                  let envelope = try? SyncEnvelope(storedPayload: held.payload)
            else { return .notHeld }
            guard let file = envelope.fields["files"]?.objectValue?[role].flatMap(FileRef.init(json:)) else { return .missing }
            return .held(file)
        }
    }

    func setPointer(type: SyncRecordType, id: String, role: String, file: FileRef) async throws -> Bool {
        let zone = try await store.perform { state -> BlobZone? in
            guard let located = try MigrationImportStore.locate(MigrationRecordKey(type, id), state.connection), located.replica != nil else { return nil }
            return try BlobZone.resolve(zoneKey: located.zoneKey, in: state)
        }
        guard let zone else { return false }
        var patch = RecordPatch(type, id: id)
        patch.changes["files"] = .elements([role: file.value])
        let outcome: MaintenanceWriter.Outcome?
        do {
            outcome = try await writer.save([MaintenanceWriter.Write(zone: zone, patch: patch, onlyIfHeld: true)]).first
        } catch MaintenanceWriter.WriterError.noServerOffset {
            // The device has not learnt its server offset yet: not a failure, the job waits.
            return false
        }
        switch outcome {
        case .saved?, .unchanged?: return true
        case .lost?, nil: return false
        case .failed(let code)?: throw CloudError(code, message: "a file pointer was not saved")
        }
    }
}

/// `MigrationSatelliteUploader` through `BlobStore`: a personal owner's satellites go to the private `Content`
/// zone (§3.5.30).
struct BlobMigrationSatelliteUploader: MigrationSatelliteUploader {
    let store: PrivateSyncLocalStore
    let blobs: BlobStore

    func upload(_ body: Data, owner: String, ownerType: SyncRecordType, role: String, mime: String, encoding: BlobStore.Encoding) async throws -> FileRef {
        let zone = try await store.perform { state in
            try BlobZone.resolve(zoneKey: PrivateSyncZones.libraryKey, in: state).map { BlobZone.personal(salt: $0.salt) }
        }
        guard let zone else { throw CloudError(.zoneNotFound, message: "no zone holds \(owner)") }
        return try await blobs.upload(body, owner: owner, ownerType: ownerType, role: role, mime: mime, encoding: encoding, into: zone)
    }
}
