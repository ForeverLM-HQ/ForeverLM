import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The old records' files (docs/cloudkit-schema-design.md §13.6 "Assets", §13.3 step 4, WP16b2): the queue a late
/// import leaves for the file assets of the records it met and for an old iPhone's `Mobile Imports` capture is
/// drained by uploading each as a satellite and pointing at it once the bytes are acknowledged, only where the
/// record holds no pointer for the role yet. The old container is a `FakeCloudKit`; the satellites and pointers
/// are in memory (`BlobStore` and `MaintenanceWriter` have their own suites).
@Suite("Migration asset pass")
struct MigrationAssetPassTests {
    private typealias Rig = MigrationImportRig

    private static let pdf = Data("%PDF-1.7 the paper".utf8)
    private static let epub = Data([0x50, 0x4B, 0x03, 0x04]) + Data("an epub".utf8)

    private func file(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("asset-\(UUID().uuidString)")
        try bytes.write(to: url)
        return url
    }

    /// Puts `field` of the old Source in the old container as an asset.
    private func giveAsset(_ rig: Rig, _ sourceID: String, field: String = CKRecord.FieldKey.sourcePDFAsset, bytes: Data = MigrationAssetPassTests.pdf) throws {
        var record = try rig.oldRecord(.source, sourceID)
        record.fields[field] = .asset(try file(bytes))
        rig.server.put([record], zone: Rig.zoneName, owner: Rig.learner, container: FakeCloudKit.legacyContainer)
    }

    private func makePass(_ rig: Rig, uploader: FakeSatelliteUploader, pointers: FakeFilePointers) -> MigrationAssetPass {
        var pass = MigrationAssetPass(oldContainer: rig.oldContainer, store: rig.local, uploader: uploader, pointers: pointers)
        pass.clock = { [clock = rig.clock] in clock.now }
        pass.installFile = { _, _, _ in false }
        return pass
    }

    private func queued(_ rig: Rig, _ kind: String) throws -> Int {
        try rig.rowCount("SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = ?", [.text(kind)])
    }

    /// A seeded Source whose old record then carries `field` as an asset, met by an import pass.
    private func queuedSource(_ rig: Rig, bytes: Data = MigrationAssetPassTests.pdf) async throws {
        try rig.source("src-1")
        try await rig.seed()
        try await Task.sleep(nanoseconds: 30_000_000)
        try giveAsset(rig, "src-1", bytes: bytes)
        try await rig.imported()
    }

    // MARK: A changed record's assets

    @Test("An import pass queues a changed Source's file assets, and the pass uploads the PDF as a satellite and points at it")
    func uploadsPDF() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try await queuedSource(rig)
        #expect(try queued(rig, MigrationAssetQueue.oldAssetsKind) == 1, "queued by the pass that met the changed record")

        let log = EventLog()
        let uploader = FakeSatelliteUploader(log: log), pointers = FakeFilePointers(log: log)
        let report = try await makePass(rig, uploader: uploader, pointers: pointers).run()
        #expect(report.uploaded == 1 && report.finished == 1 && report.failed == 0, "\(report)")
        let upload = try #require(uploader.uploads.first)
        #expect(uploader.uploads.count == 1 && upload.owner == "src-1" && upload.ownerType == .source && upload.role == "pdf")
        #expect(upload.mime == "application/pdf" && upload.bytes == Self.pdf && upload.encoding == .identity)
        #expect(pointers.set.map(\.role) == ["pdf"] && pointers.set.first?.file.owner == "src-1", "the pointer moves once the bytes are in")
        #expect(try queued(rig, MigrationAssetQueue.oldAssetsKind) == 0, "the job left the queue")
        #expect(log.events.suffix(2) == ["upload:pdf", "set:pdf"], "bytes before pointers: \(log.events)")
    }

    @Test("A book's EPUB travels in the PDF asset and is a satellite of its own role")
    func sniffsEPUB() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try await queuedSource(rig, bytes: Self.epub)
        let uploader = FakeSatelliteUploader()
        try await makePass(rig, uploader: uploader, pointers: FakeFilePointers()).run()
        #expect(uploader.uploads.map(\.role) == ["epub"] && uploader.uploads.first?.mime == "application/epub+zip")
    }

    @Test("A role the record already points at is left as it is: what the new world holds stands")
    func heldPointerStands() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try await queuedSource(rig)
        let held = FileRef(owner: "src-1", role: "pdf", hash: "feedbeef", size: 3, mime: "application/pdf", encoding: "identity", storedParts: [Data("new".utf8)])
        let uploader = FakeSatelliteUploader(), pointers = FakeFilePointers()
        pointers.states["source:src-1:pdf"] = .held(held)

        let report = try await makePass(rig, uploader: uploader, pointers: pointers).run()
        #expect(uploader.uploads.isEmpty && pointers.set.isEmpty && report.finished == 1, "\(report)")
    }

    @Test("A record the new container does not hold yet costs no bytes: the job waits, at the back of the queue")
    func waitsForTheRecord() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try await queuedSource(rig)
        let uploader = FakeSatelliteUploader(), pointers = FakeFilePointers()
        pointers.notHeld = ["source:src-1"]

        let report = try await makePass(rig, uploader: uploader, pointers: pointers).run()
        #expect(report.pending == 1 && report.finished == 0 && uploader.uploads.isEmpty, "\(report)")
        #expect(try queued(rig, MigrationAssetQueue.oldAssetsKind) == 1)
        #expect(try rig.store.scalarText("SELECT last_error FROM ck_backfill_queue WHERE kind = ?", [.text(MigrationAssetQueue.oldAssetsKind)])?.isEmpty == false)

        pointers.notHeld = []
        let later = try await makePass(rig, uploader: uploader, pointers: pointers).run()
        #expect(later.uploaded == 1 && later.finished == 1, "it goes through once the record is there: \(later)")
    }

    @Test("A pointer save that met another version waits for the next try")
    func lostPointer() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try await queuedSource(rig)
        let pointers = FakeFilePointers()
        pointers.losesNextSet = true
        let report = try await makePass(rig, uploader: FakeSatelliteUploader(), pointers: pointers).run()
        #expect(report.pending == 1 && report.finished == 0 && pointers.set.isEmpty, "\(report)")
        #expect(try queued(rig, MigrationAssetQueue.oldAssetsKind) == 1)
    }

    @Test("A job that fails five times waits for a later build instead of holding the queue up")
    func failuresStop() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try await queuedSource(rig)
        let uploader = FakeSatelliteUploader()
        uploader.fails = true
        for _ in 0..<MigrationAssetQueue.maxAttempts {
            let report = try await makePass(rig, uploader: uploader, pointers: FakeFilePointers()).run()
            #expect(report.failed == 1)
        }
        let report = try await makePass(rig, uploader: uploader, pointers: FakeFilePointers()).run()
        #expect(report.failed == 0 && report.finished == 0, "it is not tried a sixth time: \(report)")
        #expect(try queued(rig, MigrationAssetQueue.oldAssetsKind) == 1, "and stays for a later build")
    }

    @Test("A Team's assets are the space's: the pass leaves them to the importer and drops the job")
    func teamAssets() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let payload = #"{"database":"private","entity":"source","fields":["sourcePDFAsset"],"owner":"\#(CloudZoneID.currentUser)","recordName":"abc","zone":"Team-t1"}"#
        try rig.store.execute(
            "INSERT INTO ck_backfill_queue (kind, target, payload_json, enqueued_at) VALUES (?, 'Team-t1/abc', ?, 1)",
            [.text(MigrationAssetQueue.oldAssetsKind), .text(payload)]
        )
        let uploader = FakeSatelliteUploader()
        let report = try await makePass(rig, uploader: uploader, pointers: FakeFilePointers()).run()
        #expect(report.finished == 1 && uploader.uploads.isEmpty)
    }

    // MARK: A Mobile Imports capture

    private func queueCapture(_ rig: Rig, path: String = "Mobile Imports/seed/a.pdf") throws {
        try rig.store.execute(
            "INSERT INTO ck_backfill_queue (kind, target, payload_json, enqueued_at) VALUES (?, 'src-m', ?, ?)",
            [.text(MigrationAssetQueue.mobileImportKind), .text(#"{"path":"\#(path)"}"#), .real(rig.clock.now.timeIntervalSinceReferenceDate)]
        )
    }

    @Test("A late-imported capture's file is uploaded from where it sits as the Source's pdf, never moved")
    func uploadsCapture() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let url = try file(Self.pdf)
        try queueCapture(rig)
        let uploader = FakeSatelliteUploader(), pointers = FakeFilePointers()
        var pass = makePass(rig, uploader: uploader, pointers: pointers)
        pass.locateCapture = { path in path == "Mobile Imports/seed/a.pdf" ? .ready(url) : .missing }

        let report = try await pass.run()
        #expect(report.uploaded == 1 && report.finished == 1, "\(report)")
        #expect(uploader.uploads.first?.owner == "src-m" && uploader.uploads.first?.role == "pdf" && uploader.uploads.first?.bytes == Self.pdf)
        #expect(pointers.set.map(\.id) == ["src-m"] && FileManager.default.fileExists(atPath: url.path), "the file stays where it is")
        #expect(try queued(rig, MigrationAssetQueue.mobileImportKind) == 0)
    }

    @Test("A file still downloading from iCloud Drive waits, and one that never arrives is dropped after its patience")
    func captureWaits() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try queueCapture(rig)
        let uploader = FakeSatelliteUploader()
        var downloading = makePass(rig, uploader: uploader, pointers: FakeFilePointers())
        downloading.locateCapture = { _ in .downloading }

        let report = try await downloading.run()
        #expect(report.pending == 1 && uploader.uploads.isEmpty, "\(report)")
        #expect(try queued(rig, MigrationAssetQueue.mobileImportKind) == 1)
        let stored = try #require(try rig.store.scalarText("SELECT payload_json FROM ck_backfill_queue WHERE kind = ?", [.text(MigrationAssetQueue.mobileImportKind)]))
        #expect(stored.contains("waitingSince"), "the wait is dated")

        rig.clock.advance(MigrationAssetQueue.mobileImportPatience + 3_600)
        var missing = makePass(rig, uploader: uploader, pointers: FakeFilePointers())
        missing.locateCapture = { _ in .missing }
        let dropped = try await missing.run()
        #expect(try dropped.finished == 1 && queued(rig, MigrationAssetQueue.mobileImportKind) == 0, "\(dropped)")
    }

    @Test("A pass that met an old iPhone's capture queues its upload; any other Source queues none")
    func lateImportQueuesCapture() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.source("src-m")
        try rig.source("src-n")
        try await rig.seed()
        try await Task.sleep(nanoseconds: 30_000_000)
        try rig.sender.execute("UPDATE articles SET local_file_path = 'Mobile Imports/seed/a.pdf' WHERE source_id = 'src-m'")
        try rig.publish(.source, "src-m")
        try rig.sender.execute("UPDATE articles SET title = 'Another title' WHERE source_id = 'src-n'")
        try rig.publish(.source, "src-n")

        try await rig.imported()
        #expect(try queued(rig, MigrationAssetQueue.mobileImportKind) == 1)
        #expect(try rig.store.scalarText("SELECT target FROM ck_backfill_queue WHERE kind = ?", [.text(MigrationAssetQueue.mobileImportKind)]) == "src-m")
    }
}

// MARK: - Doubles

/// The order of what the doubles were asked.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var events: [String] { lock.withLock { recorded } }
    func add(_ event: String) { lock.withLock { recorded.append(event) } }
}

/// Remembers the bytes it was asked to upload.
final class FakeSatelliteUploader: MigrationSatelliteUploader, @unchecked Sendable {
    struct Upload {
        var owner: String
        var ownerType: SyncRecordType
        var role: String
        var mime: String
        var encoding: BlobStore.Encoding
        var bytes: Data
    }

    private let lock = NSLock()
    private var recorded: [Upload] = []
    private let log: EventLog?
    var fails = false

    init(log: EventLog? = nil) {
        self.log = log
    }

    var uploads: [Upload] { lock.withLock { recorded } }

    func upload(_ body: Data, owner: String, ownerType: SyncRecordType, role: String, mime: String, encoding: BlobStore.Encoding) async throws -> FileRef {
        if fails { throw CloudError(.networkUnavailable, message: "no network") }
        lock.withLock { recorded.append(Upload(owner: owner, ownerType: ownerType, role: role, mime: mime, encoding: encoding, bytes: body)) }
        log?.add("upload:\(role)")
        let stored = encoding == .gzip ? try SyncGzip.compress(body) : body
        return FileRef(owner: owner, role: role, hash: SyncIdentity.sha256Hex(body), size: Int64(body.count), mime: mime, encoding: encoding.rawValue, storedParts: [stored])
    }
}

/// Where each record's pointers stand, and what was set.
final class FakeFilePointers: MigrationFilePointers, @unchecked Sendable {
    struct PointerWrite {
        var type: SyncRecordType
        var id: String
        var role: String
        var file: FileRef
    }

    private let lock = NSLock()
    private var recorded: [PointerWrite] = []
    private let log: EventLog?
    /// `<type>:<id>:<role>`, held.
    var states: [String: MigrationPointerState] = [:]
    /// `<type>:<id>` the replica holds no copy of.
    var notHeld: [String] = []
    var losesNextSet = false

    var set: [PointerWrite] { lock.withLock { recorded } }

    init(log: EventLog? = nil) {
        self.log = log
    }

    func pointer(type: SyncRecordType, id: String, role: String) async throws -> MigrationPointerState {
        let record = "\(type.rawValue.lowercased()):\(id)"
        if notHeld.contains(record) { return .notHeld }
        return states["\(record):\(role)"] ?? .missing
    }

    func setPointer(type: SyncRecordType, id: String, role: String, file: FileRef) async throws -> Bool {
        let lost = lock.withLock { () -> Bool in
            let value = losesNextSet
            losesNextSet = false
            return value
        }
        if lost { return false }
        log?.add("set:\(role)")
        lock.withLock { recorded.append(PointerWrite(type: type, id: id, role: role, file: file)) }
        return true
    }
}
