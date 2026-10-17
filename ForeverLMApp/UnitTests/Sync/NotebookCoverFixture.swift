import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import ForeverLM

/// Macs on FakeCloudKit drawing notebook covers (WP31, docs/cloudkit-schema-design.md D53, §5.9): the
/// app's projections and triggers, a stand-in for the managed image route that records every request,
/// and the cover service over the device's engine, BlobStore and compare-and-set writer.
enum NotebookCoverFixture {
    typealias M = MaintenanceFixture

    /// A Mac that holds the library (`client`), bootstrapped and synced once.
    static func mac(_ server: FakeCloudKit, _ name: String, deviceID: String = "macaaaaa",
                    client: ZoneBootstrap.Client = .macHoldingLibrary) async throws -> EngineTestDevice {
        let mac = try EngineTestDevice(server, name: name, deviceID: deviceID, registry: KnowledgeStore.projectionRegistry)
        try await mac.bootstrap(client)
        try await mac.sync()
        return mac
    }

    /// A notebook made on `mac` and sent, as the New notebook flow leaves one once it is named.
    static func addNotebook(_ mac: EngineTestDevice, _ id: String, title: String = "🧬 Mitochondria", send: Bool = true) async throws {
        try NotebookSyncFixture.addNotebook(mac.store, id, title: title)
        if send {
            await EngineTestDriver.pause()
            try await mac.send()
        }
    }

    /// A small picture, as the image route hands one back: one colour, `side` pixels square, PNG.
    static func picture(side: Int = 64, red: CGFloat = 0.2) -> Data {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    /// The managed image route, standing in: every request is recorded, each drawing is a new picture,
    /// and `during` runs while the picture is being drawn (another writer's save, a switch turned off).
    final class Drawer: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [NotebookCoverDrawRequest] = []
        var during: (@Sendable () async throws -> Void)?
        var fails = false
        /// Notebooks whose drawing always fails.
        var failing: Set<String> = []

        var requests: [NotebookCoverDrawRequest] { lock.withLock { made } }
        var count: Int { requests.count }

        func draw(_ request: NotebookCoverDrawRequest) async throws -> NotebookCoverDrawing {
            let index = lock.withLock { () -> Int in
                made.append(request)
                return made.count
            }
            try await during?()
            if fails || failing.contains(request.source.id) { throw ManagedImageGeneration.Failure.providerRejected("the model could not draw the picture") }
            return NotebookCoverDrawing(data: NotebookCoverFixture.picture(red: CGFloat(index % 10) / 10), modelID: request.model?.id ?? "account-images-model")
        }
    }

    /// The Setting, as a switch a test turns.
    final class Gates: @unchecked Sendable {
        private let lock = NSLock()
        private var held: NotebookCoverGates

        init(automatic: Bool = true) {
            held = NotebookCoverGates(automatic: automatic)
        }

        var value: NotebookCoverGates {
            get { lock.withLock { held } }
            set { lock.withLock { held = newValue } }
        }
    }

    /// A clock a suite moves: the engine's, ahead of the wall clock, and the days or hours it jumps.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var offset = EngineTestDevice.ahead
        var now: Date { lock.withLock { Date().addingTimeInterval(offset) } }
        func advance(_ seconds: TimeInterval) { lock.withLock { offset += seconds } }
    }

    static func cache() -> NotebookCoverCache {
        NotebookCoverCache(folder: FileManager.default.temporaryDirectory.appendingPathComponent("WP31-covers-\(UUID().uuidString)", isDirectory: true))
    }

    static func maker(_ mac: EngineTestDevice, drawer: Drawer, cache: NotebookCoverCache = cache(),
                      clock: @escaping @Sendable () -> Date = { Date().addingTimeInterval(EngineTestDevice.ahead) }) -> NotebookCoverMaker {
        NotebookCoverMaker(
            store: mac.local, blobs: M.blobs(mac, clock: clock),
            writer: MaintenanceWriter(transport: mac.transport, store: mac.local, moveMaps: MoveMapIndex(), deviceID: mac.deviceID, clock: clock),
            deviceID: mac.deviceID, cache: cache, draw: { try await drawer.draw($0) }, clock: clock
        )
    }

    static func service(_ mac: EngineTestDevice, drawer: Drawer, gates: Gates = Gates(), cache: NotebookCoverCache = cache(),
                        clock: @escaping @Sendable () -> Date = { Date().addingTimeInterval(EngineTestDevice.ahead) }) -> NotebookCoverService {
        NotebookCoverService(maker: maker(mac, drawer: drawer, cache: cache, clock: clock), gates: { gates.value })
    }

    /// The root's seed state, as the seeder leaves it (`complete`) or while it is under way.
    static func setSeed(_ mac: EngineTestDevice, _ state: String) async throws {
        try M.patchRoot(mac.server, ["seed": .elements(["state": .string(state)])])
        try await mac.sync()
    }

    /// The backfill's marker of a zone as the server holds it.
    static func serverMarker(_ mac: EngineTestDevice, zone: String = "Library") throws -> NotebookCoverBackfillMarker.Value? {
        try NotebookCoverBackfillMarker.value(in: mac.serverEnvelope(.setting, NotebookCoverBackfillMarker.key(zoneName: zone)))
    }

    /// A marker another device wrote, straight into the server, `at` epoch milliseconds.
    static func putMarker(_ mac: EngineTestDevice, _ state: NotebookCoverBackfillMarker.State, by device: String, at: Int64, zone: String = "Library") throws {
        let key = NotebookCoverBackfillMarker.key(zoneName: zone)
        try M.put(mac, .setting, key, [
            "key": .value(.string(key)),
            "value": .value(NotebookCoverBackfillMarker.typed(.init(state: state, by: device, at: at))),
            "editedAt": .value(SyncJSON(at)),
        ], at: at)
    }

    /// The notebook's cover as the server holds it.
    static func serverCover(_ mac: EngineTestDevice, _ id: String) throws -> FileRef? {
        try mac.serverEnvelope(.notebook, id).flatMap(NotebookCoverSubject.cover(in:))
    }

    /// The notebook's cover as the replica holds it.
    static func replicaCover(_ mac: EngineTestDevice, _ id: String) throws -> FileRef? {
        try NotebookCoverSubject.load(.library(id), connection: mac.store)?.cover
    }

    static func queued(_ mac: EngineTestDevice, kind: String = NotebookCoverQueue.newKind) throws -> Int64 {
        try mac.count("SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = ?", [.text(kind)])
    }

    /// Changes fields of a record the server holds, as another device's save would.
    static func patchServer(_ mac: EngineTestDevice, _ type: SyncRecordType, _ id: String, _ changes: [String: RecordPatch.Change],
                            zone: String = "Library", device: String = "otheraaa") throws {
        let name = try mac.recordName(type, id)
        guard let held = mac.server.storedRecord(name, zone: zone, owner: M.user), let payload = held.payload else {
            throw CloudError(.unknownItem, message: "no \(type.rawValue) \(id)")
        }
        var envelope = try SyncEnvelope(storedPayload: payload)
        var counter = 0
        let milliseconds = SyncTime.milliseconds(mac.server.now) + 1_000
        try envelope.apply(RecordPatch(type, id: id, changes: changes)) { _, policy, _ in
            counter += 1
            return SyncStamp(policy: policy, milliseconds: milliseconds, counter: counter, deviceID: device)
        }
        var record = CloudRecord(id: held.id, recordType: held.recordType)
        record.payload = try envelope.storedPayload()
        mac.server.put([record], zone: zone, owner: M.user)
    }

    /// A FileRef another writer's cover would carry (its bytes need not exist for a pointer test).
    static func otherCover(_ owner: String) -> FileRef {
        let bytes = picture(red: 0.9)
        return FileRef(owner: owner, role: "cover", hash: SyncIdentity.sha256Hex(bytes), size: Int64(bytes.count), mime: "image/png",
                       encoding: "identity", storedParts: [bytes])
    }
}
