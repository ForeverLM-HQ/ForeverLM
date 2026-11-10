import CoreGraphics
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

extension Notification.Name {
    /// A notebook cover this Mac holds changed: one was drawn here, or its bytes arrived. The cover
    /// images read the replica again (`NotebookCoverImages`).
    static let notebookCoversDidChange = Notification.Name("ForeverLM.notebookCoversDidChange")
}

// MARK: - Which notebook (docs/cloudkit-schema-design.md D53, §5.9)

/// A notebook as the cover code names it: its record's zone and wire id. A personal notebook is in
/// `Library`; one moved into a space is in that space's zone.
struct NotebookCoverTarget: Hashable, Sendable {
    let zoneKey: String
    let notebookID: String

    var zoneName: String { zoneKey.split(separator: "/").last.map(String.init) ?? zoneKey }

    static func library(_ notebookID: String) -> NotebookCoverTarget {
        NotebookCoverTarget(zoneKey: PrivateSyncZones.libraryKey, notebookID: notebookID)
    }

    /// Where `notebookID` leads now (`resolveNotebook()`, §5.2): a merged notebook's survivor, a
    /// moved one's space copy. Nil when it leads into a zone this Mac does not hold.
    static func resolved(_ notebookID: String, connection: SQLiteConnection) throws -> NotebookCoverTarget? {
        let location = try NotebookResolutionTable.resolve(notebookID, connection: connection)
        guard location.zone.isSpace else { return .library(location.id) }
        guard let zoneKey = try connection.scalarText(
            "SELECT zone_key FROM ck_zones WHERE zone_name = ? ORDER BY database = 'private' DESC, zone_key LIMIT 1",
            [.text(location.zone.name)]
        ) else { return nil }
        return NotebookCoverTarget(zoneKey: zoneKey, notebookID: location.id)
    }

    /// Where `notebookID` leads, when this Mac also holds its record: what a `makeDerived` cover Job needs
    /// before a Mac claims it.
    static func held(_ notebookID: String, connection: SQLiteConnection) throws -> NotebookCoverTarget? {
        guard let target = try resolved(notebookID, connection: connection),
              try NotebookCoverSubject.load(target, connection: connection) != nil else { return nil }
        return target
    }
}

/// A notebook's cover as the replica holds it: its FileRef, and the zone it is in.
struct NotebookCoverPointer: Sendable {
    let file: FileRef
    let target: NotebookCoverTarget
}

/// The cover work queued in `ck_backfill_queue` (§5.9, so no local table is added): a notebook made one
/// at a time (`new`), a cover the fold hands a survivor (`fold`, its FileRef in `payload_json`) and the
/// backfill's list (`backfill`). The target is `<zone name>/<notebook wire id>`.
enum NotebookCoverQueue {
    static let newKind = "notebookCoverNew"
    static let foldKind = "notebookCoverFold"
    static let backfillKind = "notebookCover"
    /// Each notebook gets at most two attempts at a drawing; one that fails both keeps its emoji (§5.9).
    static let attemptsMax = 2

    static func target(zoneName: String, notebookID: String) -> String {
        "\(zoneName)/\(notebookID)"
    }

    static func parse(_ target: String) -> (zoneName: String, notebookID: String)? {
        guard let slash = target.firstIndex(of: "/") else { return nil }
        let zone = String(target[..<slash])
        let id = String(target[target.index(after: slash)...])
        guard !zone.isEmpty, !id.isEmpty else { return nil }
        return (zone, id)
    }
}

// MARK: - What the drawing reads

/// A notebook's record as the replica holds it, for its cover: the words the prompt reads, its status
/// and its cover, if any.
struct NotebookCoverSubject: Equatable, Sendable {
    var title: String
    var instructions: String?
    var summary: String?
    var topic: String?
    var status: String
    var cover: FileRef?

    var isActive: Bool { status == "active" }

    init(title: String, instructions: String? = nil, summary: String? = nil, topic: String? = nil, status: String = "active", cover: FileRef? = nil) {
        self.title = title
        self.instructions = instructions
        self.summary = summary
        self.topic = topic
        self.status = status
        self.cover = cover
    }

    init(_ envelope: SyncEnvelope) {
        let fields = envelope.fields
        self.init(
            title: fields["title"]?.stringValue ?? "", instructions: fields["instructions"]?.stringValue,
            summary: fields["summary"]?.stringValue, topic: fields["topic"]?.stringValue,
            status: fields["status"]?.stringValue ?? "active", cover: Self.cover(in: envelope)
        )
    }

    static func cover(in envelope: SyncEnvelope) -> FileRef? {
        envelope.fields["files"]?["cover"].flatMap(FileRef.init(json:))
    }

    /// The notebook's record in the replica; nil until the replica holds it.
    static func load(_ target: NotebookCoverTarget, connection: SQLiteConnection) throws -> NotebookCoverSubject? {
        try ReplicaStore(connection: connection)
            .record(zoneKey: target.zoneKey, recordType: SyncRecordType.notebook.rawValue, wireID: target.notebookID)
            .flatMap { try? SyncEnvelope(storedPayload: $0.payload) }
            .map(NotebookCoverSubject.init)
    }

    var prompt: String {
        ImageGenerationCatalog.notebookCoverPrompt(title: title, instructions: instructions, summary: summary, topic: topic)
    }
}

/// One drawing as the managed image route takes it (`ManagedImageGeneration.generate`), the way
/// `MeetingIconService.generate` draws a meeting icon: square, low quality, billed as `notebook_cover`
/// with the notebook as its source.
struct NotebookCoverDrawRequest: Sendable {
    static let usageTask = "notebook_cover"

    let prompt: String
    let shape: ImageGenerationCatalog.Shape
    let quality: ImageGenerationCatalog.Quality
    let usageTask: String
    let source: AIUsageSource
    /// The model Redraw With picked; nil for the account's Images model (`MacImageGenerationSettings.model`,
    /// by default `ImageGenerationCatalog.defaultModelID`), so the cover code names no model (Q7).
    let model: ImageGenerationModel?

    init(prompt: String, notebookID: String, title: String, model: ImageGenerationModel? = nil) {
        self.prompt = prompt
        shape = .square
        quality = .low
        usageTask = Self.usageTask
        source = AIUsageSource(id: notebookID, type: "notebook", title: NotebookTitle(title).text)
        self.model = model
    }
}

/// What a drawing came back with: the picture's bytes and the model that drew it, by OpenRouter's id.
struct NotebookCoverDrawing: Sendable {
    let data: Data
    let modelID: String
}

/// A cover drawn and kept on this Mac, not pointed at yet: its stored bytes (in `NotebookCoverCache`,
/// by `hash`) and what made it, so an upload that failed is tried again without drawing again.
struct NotebookCoverStaged: Equatable, Sendable {
    let hash: String
    let model: String
    let prompt: String
    let at: Int64

    var json: SyncJSON {
        .object(["hash": .string(hash), "model": .string(model), "prompt": .string(prompt), "at": SyncJSON(at)])
    }

    init(hash: String, model: String, prompt: String, at: Int64) {
        self.hash = hash
        self.model = model
        self.prompt = prompt
        self.at = at
    }

    init?(json: SyncJSON?) {
        guard let object = json?.objectValue, let hash = object["hash"]?.stringValue, let model = object["model"]?.stringValue,
              let prompt = object["prompt"]?.stringValue, let at = object["at"]?.int64Value else { return nil }
        self.init(hash: hash, model: model, prompt: prompt, at: at)
    }
}

// MARK: - The picture

/// A drawn picture as a cover is stored: a square JPEG of 512 pixels, centre-cropped, which fits one
/// inline satellite (§5.9: "a square JPEG or PNG of about 512 px").
enum NotebookCoverImage {
    static let pixels = 512
    static let mime = "image/jpeg"

    static func normalized(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let side = min(image.width, image.height)
        guard side > 0 else { return nil }
        let cropped = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)) ?? image
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        // A picture drawn on a transparent ground keeps a white one, not black.
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let scaled = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// The covers this Mac holds, by the sha256 of their bytes (a FileRef's `hash`): drawn here, or fetched
/// once from the satellite. Regenerable, so it lives in Caches; content-addressed, so it is never stale.
struct NotebookCoverCache: Sendable {
    let folder: URL

    static let shared = NotebookCoverCache(folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "ForeverLM", isDirectory: true)
        .appendingPathComponent("NotebookCovers", isDirectory: true))

    func url(hash: String) -> URL {
        folder.appendingPathComponent(hash + ".jpg")
    }

    func data(hash: String) -> Data? {
        guard !hash.isEmpty else { return nil }
        return try? Data(contentsOf: url(hash: hash))
    }

    func store(_ data: Data) throws -> String {
        let hash = SyncIdentity.sha256Hex(data)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = url(hash: hash)
        if !FileManager.default.fileExists(atPath: target.path) { try data.write(to: target, options: .atomic) }
        return hash
    }
}

// MARK: - The drawing (§5.9)

/// Draws a notebook's cover and moves its pointer: the drawing shared by creation, Redraw With, a
/// claimed `makeDerived` Job and the backfill. It moves the notebook's `files.cover` pointer.
///
/// 1. The prompt is read from the notebook's record in the replica (`notebookCoverPrompt`), drawn through
///    the managed image route on the account's Images model, and kept as a 512-px JPEG.
/// 2. The bytes go up as the notebook's `cover` satellite (owner the notebook, in private `Content`, or a
///    space's own zone), with `gen = {model, prompt, device, at}`.
/// 3. Only once every part is acknowledged does the pointer move (§3.5.30 rule 2): `files.cover`, a
///    compare-and-set save beside the engine on the version the replica holds (`MaintenanceWriter`), so a
///    save that met another version re-reads it and never moves a pointer another writer set meanwhile.
///    Before drawing and again before the pointer moves, a notebook another writer gave a cover is left
///    alone, unless the learner asked for a redraw.
struct NotebookCoverMaker {
    enum Outcome: Equatable, Sendable {
        /// The pointer moved to this cover.
        case drawn(FileRef)
        /// The notebook has a cover already (another writer's, or one this queue drew before).
        case hasCover
        /// The notebook is archived, merged or moved: nothing is drawn for it.
        case notActive
        /// The replica holds no record of the notebook (deleted, or not sent yet).
        case notHeld
    }

    /// What a drawing left: a cover kept here to publish, or why none was drawn.
    enum Drawing: Equatable, Sendable {
        case kept(NotebookCoverStaged)
        case none(Outcome)
    }

    /// What waits rather than fails: tried again later, never counted as an attempt.
    enum Wait: Error, Equatable {
        /// The zone's root (its salt), or the device's server offset, is not here yet.
        case zoneNotReady
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "NotebookCovers")

    let store: PrivateSyncLocalStore
    let blobs: BlobStore
    let writer: MaintenanceWriter
    let deviceID: String
    let cache: NotebookCoverCache
    /// The managed image route in the app (`NotebookCoverMaker.managedDrawing`); a stand-in in the suites.
    let draw: @Sendable (NotebookCoverDrawRequest) async throws -> NotebookCoverDrawing
    let clock: @Sendable () -> Date

    func subject(_ target: NotebookCoverTarget) async throws -> NotebookCoverSubject? {
        try await store.perform { try NotebookCoverSubject.load(target, connection: $0.connection) }
    }

    /// Step 1: draws the cover of `target` and keeps it here, unless it needs none. `model` is Redraw
    /// With's pick, which also draws over a cover the notebook has.
    func drawIfNeeded(_ target: NotebookCoverTarget, model: ImageGenerationModel? = nil) async throws -> Drawing {
        guard let subject = try await subject(target) else { return .none(.notHeld) }
        guard subject.isActive else { return .none(.notActive) }
        if subject.cover != nil, model == nil { return .none(.hasCover) }
        let prompt = subject.prompt
        let drawing = try await draw(NotebookCoverDrawRequest(prompt: prompt, notebookID: target.notebookID, title: subject.title, model: model))
        guard let bytes = NotebookCoverImage.normalized(drawing.data) else { throw ManagedImageGeneration.Failure.noImageReturned }
        let hash = try cache.store(bytes)
        return .kept(NotebookCoverStaged(hash: hash, model: drawing.modelID, prompt: prompt, at: SyncTime.milliseconds(clock())))
    }

    /// Steps 2 and 3: uploads a kept drawing as the cover satellite and moves the pointer once it is
    /// acknowledged. `replacing` is the learner's redraw, which moves the pointer over another cover.
    func publish(_ staged: NotebookCoverStaged, to target: NotebookCoverTarget, replacing: Bool = false) async throws -> Outcome {
        guard let bytes = cache.data(hash: staged.hash) else { throw ManagedImageGeneration.Failure.noImageReturned }
        let zones = try await zones(of: target)
        let gen = SyncJSON.object([
            "model": .string(staged.model), "prompt": .string(staged.prompt), "device": .string(deviceID), "at": SyncJSON(staged.at),
        ])
        let uploaded = try await blobs.upload(bytes, owner: target.notebookID, ownerType: .notebook, role: "cover", mime: NotebookCoverImage.mime,
                                              encoding: .identity, into: zones.satellites, gen: gen)
        var json = uploaded.value.objectValue ?? [:]
        json["gen"] = gen
        let file = FileRef(json: .object(json)) ?? uploaded
        return try await movePointer(to: file, of: target, in: zones.record, replacing: replacing)
    }

    /// The fold's hand-over (§5.2): a survivor with no cover takes the folded notebook's, its FileRef
    /// verbatim (D41; the same zone, so its satellites' names stay valid).
    func adopt(_ file: FileRef, for target: NotebookCoverTarget) async throws -> Outcome {
        let zones = try await zones(of: target)
        return try await movePointer(to: file, of: target, in: zones.record, replacing: false)
    }

    /// Moves `files.cover` by compare-and-set; a save that met another version is tried again on it,
    /// unless that version has a cover (another writer's) and this is no redraw.
    private func movePointer(to file: FileRef, of target: NotebookCoverTarget, in zone: BlobZone, replacing: Bool) async throws -> Outcome {
        for _ in 0..<3 {
            guard let subject = try await subject(target) else { return .notHeld }
            guard subject.isActive else { return .notActive }
            if let held = subject.cover {
                if held.hash == file.hash, held.owner == file.owner { return .drawn(held) }
                if !replacing { return .hasCover }
            }
            var patch = RecordPatch(.notebook, id: target.notebookID)
            patch.changes["files"] = .elements(["cover": file.value])
            let outcome: MaintenanceWriter.Outcome?
            do {
                outcome = try await writer.save([MaintenanceWriter.Write(zone: zone, patch: patch, onlyIfHeld: true)]).first
            } catch MaintenanceWriter.WriterError.noServerOffset {
                throw Wait.zoneNotReady
            }
            switch outcome {
            case .saved?, .unchanged?:
                continue
            case .lost?:
                Self.logger.info("A notebook cover's pointer met another version; read again")
                continue
            case .failed(let code)?:
                throw CloudError(code, message: "the cover's pointer was not saved")
            case nil:
                throw CloudError(.internalError, message: "the cover's pointer was not saved")
            }
        }
        guard let subject = try await subject(target) else { return .notHeld }
        if let held = subject.cover, held.hash == file.hash, held.owner == file.owner { return .drawn(held) }
        return subject.cover == nil ? .notHeld : .hasCover
    }

    /// The cover's bytes, for the display: this Mac's cache, else the satellite, kept in the cache. The
    /// FileRef's `hash` is of the decoded bytes, which is what the cache is named by.
    func bytes(of file: FileRef, for target: NotebookCoverTarget) async throws -> Data {
        if let held = cache.data(hash: file.hash) { return held }
        let zones = try await zones(of: target)
        let data = try await blobs.fetch(file, from: zones.satellites)
        _ = try cache.store(data)
        return data
    }

    /// The zone the record is saved in, and the one its satellites go to: private `Content` for a
    /// personal notebook, the space's own zone for a space's.
    private func zones(of target: NotebookCoverTarget) async throws -> (record: BlobZone, satellites: BlobZone) {
        let resolved = try await store.perform { state -> (BlobZone, BlobZone)? in
            guard let record = try BlobZone.resolve(zoneKey: target.zoneKey, in: state) else { return nil }
            if record.isSpace { return (record, record) }
            guard let content = try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: state) else { return nil }
            return (record, content)
        }
        guard let resolved else { throw Wait.zoneNotReady }
        return (resolved.0, resolved.1)
    }
}

// MARK: - When covers are drawn without being asked

/// The Setting `images.drawNotebookCovers.automatic` (§3.5.3), read when a cover would be drawn: a cover
/// is drawn without being asked only while it is on.
struct NotebookCoverGates: Equatable, Sendable {
    var automatic: Bool

    #if os(macOS)
    static func current() async -> NotebookCoverGates {
        await MainActor.run { NotebookCoverGates(automatic: MacImageGenerationSettings.drawsNotebookCovers) }
    }
    #endif
}

/// A notebook made without a name waits for its name: its cover is drawn from what it is about, so one
/// still under the placeholder (`NotebookNaming`, its mark unnamed and its title still the mark's) is
/// drawn once ForeverLM or the learner names it.
enum NotebookCoverNaming {
    static func isUnnamed(_ notebookID: String, connection: SQLiteConnection) throws -> Bool {
        guard let xml = try connection.scalarText(
            "SELECT value FROM user_preferences WHERE key = ?", [.text(NotebookNaming.preferenceKey(notebookID: notebookID))]
        ), let mark = NotebookNaming.Mark.decoded(PreferenceStore.decodePlist(xml)), !mark.isNamed else { return false }
        var row: (title: String, summary: String?)?
        try connection.query("SELECT title, summary FROM learning_goals WHERE wire_key = ?", [.text(notebookID)]) { values in
            row = (values.text(0) ?? "", values.text(1))
        }
        guard let row else { return false }
        return NotebookNaming.carries(mark, title: row.title, summary: row.summary)
    }
}

extension KnowledgeStore {
    /// Queues the cover of a notebook the learner made one at a time (D53): the New notebook flow and MCP
    /// `create_notebook` on this Mac. Imports, a split's children and late import never call it. Generation
    /// 2 only, and only while covers are drawn without being asked; drawn by `NotebookCoverService`, which
    /// waits for the notebook's record to be sent and for its name. Returns whether it queued one.
    @discardableResult
    func queueNotebookCover(_ notebookID: String, gates: NotebookCoverGates, now: Date = Date()) throws -> Bool {
        guard gates.automatic,
              let wireID = try scalarText(
                  "SELECT wire_key FROM learning_goals WHERE id = ? AND COALESCE(entity_kind, ?) = ? AND team_id IS NULL",
                  [.text(notebookID), .text(LearningGoalEntityKind.notebook), .text(LearningGoalEntityKind.notebook)]
              )
        else { return false }
        try execute("""
            INSERT INTO ck_backfill_queue (kind, target, enqueued_at) VALUES (?, ?, ?)
            ON CONFLICT(kind, target) DO NOTHING
        """, [
            .text(NotebookCoverQueue.newKind), .text(NotebookCoverQueue.target(zoneName: SyncZone.library.rawValue, notebookID: wireID)),
            .real(now.timeIntervalSinceReferenceDate),
        ])
        return changedRowCount > 0
    }
}

// MARK: - The fold (§5.2)

/// A notebook folded into another (a merge's survivor, an emptying split's heir) that has no cover takes the
/// folded notebook's: its FileRef verbatim, adopted by compare-and-set beside the engine once the survivor's
/// record is sent (`NotebookCoverService`, kind `notebookCoverFold`). Queued inside the fold's own
/// transaction, so a quit never loses it. Personal notebooks only: a space's notebooks are the space
/// owner's Mac's, and a folded notebook not yet in the replica has no cover to hand over.
enum NotebookCoverFold {
    static func queue(into targetID: String, from foldedIDs: [String], connection: SQLiteConnection, now: Date) throws {
        guard let target = try personal(targetID, connection: connection) else { return }
        // A heir made a moment ago is not in the replica yet and has no cover; a held one may.
        if let held = try NotebookCoverSubject.load(.library(target), connection: connection), held.cover != nil { return }
        for foldedID in foldedIDs where foldedID != targetID {
            guard let folded = try personal(foldedID, connection: connection),
                  let cover = try NotebookCoverSubject.load(.library(folded), connection: connection)?.cover else { continue }
            try connection.execute("""
                INSERT INTO ck_backfill_queue (kind, target, payload_json, enqueued_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(kind, target) DO NOTHING
            """, [
                .text(NotebookCoverQueue.foldKind), .text(NotebookCoverQueue.target(zoneName: SyncZone.library.rawValue, notebookID: target)),
                .text(String(decoding: cover.value.serialized(), as: UTF8.self)), .real(now.timeIntervalSinceReferenceDate),
            ])
            NotebookCoverService.current?.wake()
            return
        }
    }

    /// The wire id of a personal notebook's row; nil for a team's, or no notebook.
    private static func personal(_ rowID: String, connection: SQLiteConnection) throws -> String? {
        try connection.scalarText(
            "SELECT wire_key FROM learning_goals WHERE id = ? AND COALESCE(entity_kind, ?) = ? AND team_id IS NULL",
            [.text(rowID), .text(LearningGoalEntityKind.notebook), .text(LearningGoalEntityKind.notebook)]
        )
    }
}

// MARK: - The queues, drained

/// Draws the covers this Mac was asked for (§5.9, D53), off the main actor and off the launch path:
/// the creation queue (a notebook made here one at a time, once it is sent and named), the fold's
/// hand-overs, a `makeDerived` Job's cover and Redraw With. The cover backfill runs here too, on the
/// maintenance-lease holder only (`NotebookCoverBackfill`). The sync coordinator builds it, and
/// `MaintenanceService` wakes it after each round.
actor NotebookCoverService {
    /// The service the app started, for the creation flows and the menus.
    nonisolated(unsafe) static weak var current: NotebookCoverService?

    enum Refusal: LocalizedError, Equatable {
        case settingOff

        var errorDescription: String? {
            switch self {
            case .settingOff: return "Draw notebook covers is off in Settings › Images, so no cover is drawn without being asked."
            }
        }
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "NotebookCovers")

    let maker: NotebookCoverMaker
    let gates: @Sendable () async -> NotebookCoverGates
    private var draining = false
    private var drainAgain = false
    /// The backfill's pass while one runs (`runBackfill`, `NotebookCoverBackfill.swift`).
    var backfill: Task<Void, Never>?
    /// The notebooks being drawn now, so the creation queue and the backfill never draw one twice at once.
    private var drawing: Set<NotebookCoverTarget> = []

    init(maker: NotebookCoverMaker, gates: @escaping @Sendable () async -> NotebookCoverGates) {
        self.maker = maker
        self.gates = gates
    }

    var store: PrivateSyncLocalStore { maker.store }

    /// Drains the queues soon, without holding up the caller.
    nonisolated func wake() {
        Task(priority: .utility) { await self.drainQueued() }
    }

    /// One pass over the creation and fold queues, at most `limit` rows. Passes never overlap; one asked
    /// for while another runs makes it look again. Returns how many rows it settled.
    @discardableResult
    func drainQueued(limit: Int = 8) async -> Int {
        guard !draining else {
            drainAgain = true
            return 0
        }
        draining = true
        defer { draining = false }
        var settled = 0
        repeat {
            drainAgain = false
            settled += await onePass(limit: limit)
        } while drainAgain
        return settled
    }

    struct Row: Sendable {
        let id: Int64
        let kind: String
        let target: String
        let payload: SyncJSON?
    }

    private func onePass(limit: Int) async -> Int {
        let rows: [Row]
        do {
            rows = try await store.perform { state in
                var rows: [Row] = []
                try state.connection.query("""
                    SELECT id, kind, target, payload_json FROM ck_backfill_queue
                    WHERE kind IN (?, ?) AND attempts < ? ORDER BY id LIMIT ?
                """, [
                    .text(NotebookCoverQueue.newKind), .text(NotebookCoverQueue.foldKind),
                    .integer(Int64(NotebookCoverQueue.attemptsMax)), .integer(Int64(limit)),
                ]) { row in
                    guard let id = row.integer(0), let kind = row.text(1), let target = row.text(2) else { return }
                    rows.append(Row(id: id, kind: kind, target: target, payload: row.text(3).flatMap { try? SyncJSON(parsing: Data($0.utf8)) }))
                }
                return rows
            }
        } catch {
            Self.logger.error("The cover queue could not be read: \(String(describing: error), privacy: .public)")
            return 0
        }
        var settled = 0
        for row in rows {
            if await settle(row) { settled += 1 }
        }
        return settled
    }

    /// One queued row: true when it left the queue.
    private func settle(_ row: Row) async -> Bool {
        do {
            switch row.kind {
            case NotebookCoverQueue.foldKind:
                guard let file = row.payload.flatMap(FileRef.init(json:)), let parsed = NotebookCoverQueue.parse(row.target),
                      let target = try await target(of: row.target, following: false) else { return try await finish(row) }
                let outcome = try await maker.adopt(file, for: target)
                // The survivor's record is not sent yet: the cover waits for it.
                if outcome == .notHeld, try await isUnsent(parsed.notebookID) { return false }
                if case .drawn = outcome { await MainActor.run { NotificationCenter.default.post(name: .notebookCoversDidChange, object: nil) } }
                return try await finish(row)
            default:
                guard await gates().automatic else { return false }
                guard let parsed = NotebookCoverQueue.parse(row.target),
                      let target = try await target(of: row.target, following: true) else { return try await finish(row) }
                if try await store.perform({ try NotebookCoverNaming.isUnnamed(parsed.notebookID, connection: $0.connection) }) { return false }
                let outcome = try await draw(target, staged: NotebookCoverStaged(json: row.payload), queueRow: row.id)
                if outcome == .notHeld, try await isUnsent(parsed.notebookID) { return false }
                return try await finish(row)
            }
        } catch is NotebookCoverMaker.Wait {
            return false
        } catch where AITransientErrorClassifier.isCancellation(error) {
            // Stopped (under Running in the background, or by quitting): not
            // an attempt, so the row waits whole for the next drain.
            return false
        } catch {
            Self.logger.error("A notebook cover failed: \(String(describing: error), privacy: .public)")
            let message = String(describing: error)
            do {
                try await store.perform { state in
                    try state.connection.execute(
                        "UPDATE ck_backfill_queue SET attempts = attempts + 1, last_error = ? WHERE id = ?", [.text(message), .integer(row.id)]
                    )
                }
            } catch {
                Self.logger.error("Could not record the failed cover attempt: \(error.localizedDescription, privacy: .public)")
            }
            return false
        }
    }

    /// Draws `target` unless it needs none, keeping the drawing in the queue row before its upload so a
    /// failed upload is tried again without drawing again.
    func draw(_ target: NotebookCoverTarget, staged: NotebookCoverStaged?, queueRow: Int64?, model: ImageGenerationModel? = nil) async throws -> NotebookCoverMaker.Outcome {
        // Another path is drawing it: it answers for the cover (and its queue row retries on a failure).
        guard drawing.insert(target).inserted else { return .hasCover }
        defer { drawing.remove(target) }
        var kept = staged.flatMap { maker.cache.data(hash: $0.hash) == nil ? nil : $0 }
        if kept == nil {
            switch try await maker.drawIfNeeded(target, model: model) {
            case .none(let outcome):
                return outcome
            case .kept(let drawn):
                kept = drawn
                if let queueRow {
                    let json = String(decoding: drawn.json.serialized(), as: UTF8.self)
                    try await store.perform { state in
                        try state.connection.execute("UPDATE ck_backfill_queue SET payload_json = ? WHERE id = ?", [.text(json), .integer(queueRow)])
                    }
                }
            }
        }
        guard let kept else { return .notHeld }
        let outcome = try await maker.publish(kept, to: target, replacing: model != nil)
        if case .drawn = outcome {
            await MainActor.run { NotificationCenter.default.post(name: .notebookCoversDidChange, object: nil) }
        }
        return outcome
    }

    /// A cover Redraw With asked for (`model`, which draws over the cover the notebook has).
    func drawNow(_ notebookID: String, model: ImageGenerationModel? = nil) async throws -> NotebookCoverMaker.Outcome {
        try await drawResolved(notebookID, model: model)
    }

    /// The cover a claimed `makeDerived` Job asks for (§3.5.28, D53): the creation of a notebook made on the
    /// iPhone or through the hosted MCP, so it follows the Setting as the creation does. A notebook that
    /// has a cover is left alone.
    func drawForJob(_ notebookID: String) async throws -> NotebookCoverMaker.Outcome {
        guard await gates().automatic else { throw Refusal.settingOff }
        return try await drawResolved(notebookID, model: nil)
    }

    /// The cover a notebook holds in the replica, by the id the Mac's rows use: what the display draws
    /// (`NotebookCoverImages`). Nil for none, and while the replica holds no record of the notebook.
    func pointer(ofRow rowID: String) async -> NotebookCoverPointer? {
        let found = try? await store.perform { state -> NotebookCoverPointer? in
            let connection = state.connection
            guard let wireKey = try connection.scalarText("SELECT wire_key FROM learning_goals WHERE id = ?", [.text(rowID)]),
                  let target = try NotebookCoverTarget.resolved(wireKey, connection: connection),
                  let file = try NotebookCoverSubject.load(target, connection: connection)?.cover else { return nil }
            return NotebookCoverPointer(file: file, target: target)
        }
        return found ?? nil
    }

    /// The bytes of a cover the replica names; nil while they cannot be fetched (offline, not arrived), and
    /// the display asks again.
    func bytes(of pointer: NotebookCoverPointer) async -> Data? {
        do {
            return try await maker.bytes(of: pointer.file, for: pointer.target)
        } catch {
            Self.logger.info("A notebook cover's bytes are not here yet: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func drawResolved(_ notebookID: String, model: ImageGenerationModel?) async throws -> NotebookCoverMaker.Outcome {
        // The id a menu holds is its row's; a Job's is the wire id, which a row's is too until an import gives
        // it another.
        guard let target = try await store.perform({ state -> NotebookCoverTarget? in
            let wireID = try state.connection.scalarText("SELECT wire_key FROM learning_goals WHERE id = ?", [.text(notebookID)]) ?? notebookID
            return try NotebookCoverTarget.resolved(wireID, connection: state.connection)
        }) else {
            return .notHeld
        }
        return try await draw(target, staged: nil, queueRow: nil, model: model)
    }

    /// The row's notebook: a creation row's follows its merges and moves; a fold row names its survivor.
    private func target(of text: String, following: Bool) async throws -> NotebookCoverTarget? {
        guard let parsed = NotebookCoverQueue.parse(text) else { return nil }
        return try await store.perform { state -> NotebookCoverTarget? in
            if following, parsed.zoneName == SyncZone.library.rawValue {
                return try NotebookCoverTarget.resolved(parsed.notebookID, connection: state.connection)
            }
            guard let zoneKey = try state.connection.scalarText(
                "SELECT zone_key FROM ck_zones WHERE zone_name = ? ORDER BY database = 'private' DESC, zone_key LIMIT 1", [.text(parsed.zoneName)]
            ) else { return nil }
            return NotebookCoverTarget(zoneKey: zoneKey, notebookID: parsed.notebookID)
        }
    }

    /// The notebook is here and its record is not sent yet: its cover waits for it.
    private func isUnsent(_ notebookID: String) async throws -> Bool {
        try await store.perform { state in
            try state.connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM learning_goals WHERE wire_key = ?)", [.text(notebookID)]) == 1
        }
    }

    private func finish(_ row: Row) async throws -> Bool {
        try await store.perform { try $0.connection.execute("DELETE FROM ck_backfill_queue WHERE id = ?", [.integer(row.id)]) }
        return true
    }
}

#if os(macOS)
extension NotebookCoverService {
    /// The service the Mac runs: the managed image route on the account's Images model, the
    /// Setting read when a cover would be drawn, and the covers cached in Caches. The sync coordinator builds it
    /// beside `MaintenanceService` (`attachCovers`), and keeps it, since `current` is
    /// weak.
    static func live(store: PrivateSyncLocalStore, blobs: BlobStore, writer: MaintenanceWriter, deviceID: String) -> NotebookCoverService {
        let maker = NotebookCoverMaker(
            store: store, blobs: blobs, writer: writer, deviceID: deviceID, cache: .shared,
            draw: { try await NotebookCoverMaker.managedDrawing($0) },
            clock: { Date() }
        )
        let service = NotebookCoverService(maker: maker, gates: { await NotebookCoverGates.current() })
        current = service
        return service
    }

    /// The New notebook flow and MCP `create_notebook` call this once a notebook the learner made one at a
    /// time exists, with its naming row written (D53). It queues the cover when covers are drawn without
    /// being asked, and wakes the service, which draws it once the notebook is sent and named. Imports, a
    /// split's children and late import never call it.
    static func notebookMadeOneAtATime(_ notebookID: String, storage: StorageService) async {
        let gates = await NotebookCoverGates.current()
        guard gates.automatic else { return }
        await PreferenceStore.flushPendingWrites()
        var queued = false
        do {
            try await storage.performSync { queued = try $0.queueNotebookCover(notebookID, gates: gates) }
        } catch {
            Self.logger.error("Could not queue the notebook cover: \(error.localizedDescription, privacy: .public)")
        }
        if queued { current?.wake() }
    }

    /// The same, for a caller that holds the store (MCP).
    static func notebookMadeOneAtATime(_ notebookID: String, store: KnowledgeStore) async {
        let gates = await NotebookCoverGates.current()
        guard gates.automatic else { return }
        await PreferenceStore.flushPendingWrites()
        if (try? store.queueNotebookCover(notebookID, gates: gates)) == true { current?.wake() }
    }
}

extension NotebookCoverMaker {
    /// The app's drawing: the managed image route, on the account's Images model unless Redraw With
    /// picked another, resolved against OpenRouter's directory so `gen` names the model that drew.
    static func managedDrawing(_ request: NotebookCoverDrawRequest) async throws -> NotebookCoverDrawing {
        let chosen: ImageGenerationModel
        if let model = request.model {
            chosen = model
        } else {
            chosen = await MainActor.run { MacImageGenerationSettings.model }
        }
        let resolved = try await ImageGenerationDirectory.resolve(chosen)
        let image = try await ManagedImageGeneration.generate(
            prompt: request.prompt, model: resolved, shape: request.shape, quality: request.quality,
            usageTask: request.usageTask, source: request.source
        )
        return NotebookCoverDrawing(data: image.data, modelID: resolved.id)
    }
}
#endif
