import CryptoKit
import Foundation
import OSLog

/// One satellite the phone can fetch (docs/cloudkit-schema-design.md §3.5.30): the FileRef a record
/// names and the zone its bytes live in.
struct MobileSatellite: Equatable, Sendable {
    let file: FileRef
    let zone: BlobZone

    /// The child satellites of `role` (a narration's `audioChunk`s, a walk's `walkthroughPicture`s),
    /// in the order the FileRef lists them; they live where their parent does.
    func children(role: String) -> [MobileSatellite] {
        file.children.filter { $0.role == role }.map { MobileSatellite(file: $0, zone: zone) }
    }

    /// The child the writer keyed `key` (a chunk's file name, a picture's image id), compared without case.
    func child(role: String, key: String) -> MobileSatellite? {
        children(role: role).first { $0.file.key?.caseInsensitiveCompare(key) == .orderedSame }
    }
}

/// Where the phone keeps satellite bytes (§2.3, §8b): a cache under Caches, keyed by the decoded
/// file's hash, which iOS may purge whenever it wants the space; and durable copies under Application
/// Support for what the learner asked to keep (a source saved offline, a space's "Download all files"),
/// filed per holder so taking a holder off removes exactly its copies. Nothing here is authoritative:
/// every byte can be fetched again by name. Each per CloudKit environment, like the replica.
struct MobileSatelliteDisk: Sendable {
    let cacheRoot: URL
    let durableRoot: URL

    static func current(environment: MobileCloudKitEnvironment = .current) -> MobileSatelliteDisk {
        let manager = FileManager.default
        return MobileSatelliteDisk(
            cacheRoot: manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ForeverLM", isDirectory: true)
                .appendingPathComponent(environment.scopedName("Satellites"), isDirectory: true),
            durableRoot: manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ForeverLM/Offline", isDirectory: true)
                .appendingPathComponent(environment.scopedName("Satellites"), isDirectory: true)
        )
    }

    /// A file's name on disk: its decoded hash, with an extension from its type so PDFKit, AVFoundation
    /// and UIImage read it as what it is.
    static func fileName(_ file: FileRef) -> String {
        "\(file.hash).\(fileExtension(mime: file.mime))"
    }

    static func fileExtension(mime: String?) -> String {
        switch mime?.lowercased() {
        case "application/pdf"?: return "pdf"
        case "application/epub+zip"?: return "epub"
        case "text/html"?: return "html"
        case "text/plain"?, "text/markdown"?: return "txt"
        case "application/json"?: return "json"
        case "image/jpeg"?: return "jpg"
        case "image/png"?: return "png"
        case "image/webp"?: return "webp"
        case "audio/mp4"?, "audio/x-m4a"?, "audio/m4a"?: return "m4a"
        case "audio/mpeg"?: return "mp3"
        case "application/zip"?: return "zip"
        default: return "bin"
        }
    }

    /// A holder's folder name: the hash of its key (a source id is a URL or free text).
    static func folderName(holder: String) -> String {
        String(SHA256.hash(data: Data(holder.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    func cacheURL(_ file: FileRef) -> URL {
        cacheRoot.appendingPathComponent(String(file.hash.prefix(2)), isDirectory: true).appendingPathComponent(Self.fileName(file))
    }

    func durableURL(_ file: FileRef, holder: String) -> URL {
        durableRoot.appendingPathComponent(Self.folderName(holder: holder), isDirectory: true).appendingPathComponent(Self.fileName(file))
    }

    func holderFolder(_ holder: String) -> URL {
        durableRoot.appendingPathComponent(Self.folderName(holder: holder), isDirectory: true)
    }
}

extension MobileBookChapterPages {
    /// The run a book Source's `meta` names. A key that is there but is not a whole number makes the
    /// run invalid, never absent: an absent run would show the whole book as the chapter.
    init(meta: SyncJSON?) {
        func key(_ name: String) -> (present: Bool, value: Int?) {
            guard let value = meta?[name], value != .null else { return (false, nil) }
            return (true, value.intValue)
        }
        let start = key("pageStart"), count = key("pageCount")
        if (start.present && start.value == nil) || (count.present && count.value == nil) {
            self = .invalid
        } else {
            self.init(pageStart: start.value, pageCount: count.value)
        }
    }
}

/// The holders the durable copies are filed under.
enum MobileSatelliteHolder {
    /// A source the learner saved offline (`MobileOfflinePins`).
    static func source(_ sourceID: String) -> String { "src:\(sourceID)" }
    /// A space whose files this phone downloads (`MobileSpaceDownloads`).
    static func space(_ zoneKey: String) -> String { "space:\(zoneKey)" }
}

/// The phone's satellites on demand, under generation 2 (docs/cloudkit-schema-design.md §2.3, §3.5.30,
/// §8b): a record's FileRef is found where the phone holds the record, the learner's own copy first,
/// and its bytes are fetched by name through `BlobStore` the first time something opens them, then
/// read from disk. Opening writes nothing synced (P9). Two screens asking for the same satellite share
/// one fetch. The text of notebook sources is fetched ahead by `MobileTextIndex`; a space's files only
/// after the learner's "Download all files" (`MobileSpaceDownloads`); everything else when opened.
actor MobileSatellites {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MobileSatellites")

    /// Roles never fetched ahead of an open, even for a space downloaded whole: the raw originals
    /// (fetched only on demand, D29) and the Mac's chunk vectors (Mac to Mac, D27).
    static func isOnDemandOnly(role: String) -> Bool {
        role == "raw" || role.hasPrefix("vectors.")
    }

    nonisolated let projection: MobileProjection
    nonisolated let blobs: BlobStore
    nonisolated let disk: MobileSatelliteDisk
    private var inFlight: [String: Task<URL, Error>] = [:]
    /// Durable copies by hash, read from disk once.
    private var durable: [String: URL]?
    /// What the last complete pass of each downloaded space saw, so a quiet space is not walked again.
    private var spacePasses: [String: String] = [:]
    /// Whether a pass over the downloaded spaces is running; a round that settles meanwhile starts none.
    private var downloading = false

    init(projection: MobileProjection, blobs: BlobStore, disk: MobileSatelliteDisk = .current()) {
        self.projection = projection
        self.blobs = blobs
        self.disk = disk
    }

    /// The running session's satellites; nil when the session cannot start.
    static func current() async -> MobileSatellites? {
        await MobileSyncSession.startIfEnabled()?.satellites
    }

    // MARK: - Finding a satellite

    /// Where a record's satellites live (§2.2, §3.5.30): the private `Content` zone for an owner in the
    /// learner's `Library` or `Catalog` and for every personal satellite, a space's own zone for an
    /// owner in that space.
    static func satelliteZoneKey(forOwnerIn zoneKey: String, personal: Bool = false) -> String {
        if personal || zoneKey == MobileProjection.libraryKey || zoneKey == MobileProjection.catalogKey {
            return PrivateSyncZones.key(PrivateSyncZones.content)
        }
        return zoneKey
    }

    /// The satellite `pick` chooses from the record `type`/`id`, from the first zone that holds the
    /// record and names one: the learner's `Library` or `Catalog` copy, then each space's. Nil when no
    /// held copy names one, or the zone's root (its salt) is not held yet.
    func locate(_ type: SyncRecordType, id: String, pick: @escaping @Sendable (SyncEnvelope) -> FileRef?) async throws -> MobileSatellite? {
        for zoneKey in try await zonesHolding(type, id: id) {
            guard let envelope = try await projection.envelope(type, id: id, zoneKey: zoneKey), let file = pick(envelope),
                  let satellite = try await satellite(file, ownerZoneKey: zoneKey) else { continue }
            return satellite
        }
        return nil
    }

    /// The zones that hold the record `type`/`id`, the learner's `Library` or `Catalog` first.
    private func zonesHolding(_ type: SyncRecordType, id: String) async throws -> [String] {
        guard let table = MobileReplica.indexTable(for: type) else { return [] }
        let own = [MobileProjection.catalogKey, MobileProjection.libraryKey]
        return try await projection.replica.read { replica -> [String] in
            var keys: [String] = []
            try replica.connection.query("""
                SELECT zone_key FROM \(table.name) WHERE id = ? ORDER BY CASE WHEN zone_key IN (?, ?) THEN 0 ELSE 1 END, zone_key
            """, [.text(id), .text(own[0]), .text(own[1])]) { keys.append($0.text(0) ?? "") }
            return keys
        }
    }

    /// An Artifact's body, from the first copy the phone holds: its `linkedURL`, and its `body`
    /// satellite's bytes with the FileRef's hash as the revision (§3.5.15). Nil when the phone holds
    /// no copy.
    func artifactBody(_ artifactID: String) async throws -> (linkedURL: String?, bodyRevision: String?, package: Data?)? {
        for zoneKey in try await zonesHolding(.artifact, id: artifactID) {
            guard let envelope = try await projection.envelope(.artifact, id: artifactID, zoneKey: zoneKey) else { continue }
            let linkedURL = envelope.fields["linkedURL"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            guard let file = envelope.fields["body"].flatMap(FileRef.init(json:)),
                  let body = try await satellite(file, ownerZoneKey: zoneKey) else { return (linkedURL, nil, nil) }
            return (linkedURL, file.hash, try await data(body))
        }
        return nil
    }

    /// A card picture a Mac rendered for the phone (`Card.pictures`, `CardPictureKey`): the JPEG of `target` on
    /// the first of `cardIDs` whose record points at one. A draft's record is its card id, a kept card's its
    /// item's. Nil while no Mac has published it.
    func cardPicture(cardIDs: [String], target: String) async -> Data? {
        let key = CardPictureKey.key(target)
        for id in cardIDs {
            guard let satellite = try? await locate(.card, id: id, pick: { $0.fields["pictures"]?[key].flatMap(FileRef.init(json:)) }) else { continue }
            if let bytes = try? await data(satellite) { return bytes }
        }
        return nil
    }

    /// The satellite `file` names for an owner held in `ownerZoneKey`; nil until that zone's root is held.
    func satellite(_ file: FileRef, ownerZoneKey: String) async throws -> MobileSatellite? {
        let satelliteZone = Self.satelliteZoneKey(forOwnerIn: ownerZoneKey, personal: file.isPersonal)
        guard let zone = try await projection.replica.perform({ try BlobZone.resolve(zoneKey: satelliteZone, in: $0) }) else { return nil }
        return MobileSatellite(file: file, zone: zone)
    }

    /// A source's satellite of a role in `files` (`pdf`, `text`, `thumbnail`, `audio.*`) or `derived`
    /// (`walkthrough`, `reviewGuide`), the first whose role `matches` by name.
    func source(_ sourceID: String, in map: String = "files", matching matches: @escaping @Sendable (String) -> Bool) async throws -> MobileSatellite? {
        try await locate(.source, id: sourceID) { Self.file(in: $0, map: map, matching: matches) }
    }

    /// A source's `pdf` satellite and the run of its pages the source is, read from the one copy of the
    /// record that names the file, so the run is the one written with that FileRef. A page-range book
    /// chapter's `files.pdf` is its whole book's file (`meta.pageStart`, `meta.pageCount` say which
    /// pages are the chapter); for any other source the file is the source. Nil when no held copy names
    /// a PDF.
    func sourcePDF(_ sourceID: String) async throws -> (satellite: MobileSatellite, pages: MobileBookChapterPages)? {
        for zoneKey in try await zonesHolding(.source, id: sourceID) {
            guard let envelope = try await projection.envelope(.source, id: sourceID, zoneKey: zoneKey),
                  let file = Self.file(in: envelope, map: "files", matching: { $0 == "pdf" }),
                  let satellite = try await satellite(file, ownerZoneKey: zoneKey) else { continue }
            let pages = envelope.fields["type"]?.stringValue == "book"
                ? MobileBookChapterPages(meta: envelope.fields["meta"])
                : .wholeFile
            return (satellite, pages)
        }
        return nil
    }

    /// The first live FileRef of an envelope's map whose role `matches`, by role name.
    static func file(in envelope: SyncEnvelope, map: String, matching matches: (String) -> Bool) -> FileRef? {
        guard let files = envelope.fields[map]?.objectValue else { return nil }
        return files.keys.filter(matches).sorted().lazy.compactMap { files[$0].flatMap(FileRef.init(json:)) }.first
    }

    // MARK: - Bytes

    /// The satellite's file on this phone without asking the server: a durable copy first, then the cache.
    func localURL(_ satellite: MobileSatellite) -> URL? {
        if let kept = durableCopies()[satellite.file.hash], FileManager.default.fileExists(atPath: kept.path) { return kept }
        let cached = disk.cacheURL(satellite.file)
        return FileManager.default.fileExists(atPath: cached.path) ? cached : nil
    }

    /// The satellite's file, fetched by name the first time (every part checked against its name, the
    /// whole against the FileRef's hash) and then read from disk. `holder` keeps a durable copy for it.
    func url(_ satellite: MobileSatellite, keepingFor holder: String? = nil) async throws -> URL {
        let local: URL
        if let held = localURL(satellite) {
            local = held
        } else {
            local = try await fetch(satellite)
        }
        guard let holder else { return local }
        return try keep(satellite, at: local, for: holder)
    }

    func data(_ satellite: MobileSatellite, keepingFor holder: String? = nil) async throws -> Data {
        try Data(contentsOf: try await url(satellite, keepingFor: holder), options: .mappedIfSafe)
    }

    /// One fetch per satellite however many screens ask for it at once.
    private func fetch(_ satellite: MobileSatellite) async throws -> URL {
        let hash = satellite.file.hash
        if let running = inFlight[hash] { return try await running.value }
        let blobs = self.blobs
        let destination = disk.cacheURL(satellite.file)
        let task = Task<URL, Error> {
            let bytes = try await blobs.fetch(satellite.file, from: satellite.zone)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: destination, options: .atomic)
            return destination
        }
        inFlight[hash] = task
        defer { inFlight[hash] = nil }
        return try await task.value
    }

    /// Copies a satellite's local file into `holder`'s durable folder (a hard link when the volume
    /// allows) and returns the durable copy.
    private func keep(_ satellite: MobileSatellite, at local: URL, for holder: String) throws -> URL {
        let target = disk.durableURL(satellite.file, holder: holder)
        let manager = FileManager.default
        if manager.fileExists(atPath: target.path) { return target }
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root = disk.durableRoot
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        do {
            try manager.linkItem(at: local, to: target)
        } catch {
            try manager.copyItem(at: local, to: target)
        }
        var index = durableCopies()
        index[satellite.file.hash] = target
        durable = index
        return target
    }

    /// Keeps a satellite for `holder`, fetching it first when the phone does not hold it.
    func keep(_ satellite: MobileSatellite, for holder: String) async throws {
        _ = try await url(satellite, keepingFor: holder)
    }

    /// Takes `holder`'s durable copies off this phone (a copy another holder also keeps stays theirs).
    func release(holder: String) {
        try? FileManager.default.removeItem(at: disk.holderFolder(holder))
        durable = nil
    }

    /// The bytes `holder` keeps on this phone.
    func byteCount(holder: String) -> Int64 {
        let folder = disk.holderFolder(holder)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return 0 }
        return names.reduce(into: Int64(0)) { total, name in
            let size = (try? folder.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
    }

    /// The bytes `holders` keep of one file more than once. A book kept as one file is kept for each of
    /// its chapters saved offline, as hard links to a single copy (`keep`), so a total over the holders
    /// takes this off to count the book once.
    func sharedByteCount(holders: [String]) -> Int64 {
        var seen = Set<String>()
        var shared: Int64 = 0
        for holder in Set(holders) {
            let folder = disk.holderFolder(holder)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            // A file's name is its hash: the same name in two holders is the same bytes.
            for name in names where !seen.insert(name).inserted {
                shared += Int64((try? folder.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return shared
    }

    /// Every holder's durable copies by hash, read from disk once per process and kept current here.
    private func durableCopies() -> [String: URL] {
        if let durable { return durable }
        var index: [String: URL] = [:]
        let manager = FileManager.default
        for folder in (try? manager.contentsOfDirectory(at: disk.durableRoot, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                index[file.deletingPathExtension().lastPathComponent] = file
            }
        }
        durable = index
        return index
    }

    // MARK: - A space's files

    /// The satellites of everything a space holds that a reader may open (§2.3, §9.7): its sources'
    /// files and derived outputs with their children, its Docs' bodies and files, its quizzes'
    /// questions and pictures, its books' and shows' covers and its notebooks' covers. The raw
    /// originals and chunk vectors stay on demand. Each satellite once, by hash.
    func spaceSatellites(zoneKey: String) async throws -> [MobileSatellite] {
        guard let zone = try await projection.replica.perform({ try BlobZone.resolve(zoneKey: zoneKey, in: $0) }) else { return [] }
        let maps: [SyncRecordType: [String]] = [
            .source: ["files", "derived"], .artifact: ["body", "files", "walkthrough"], .quiz: ["questions", "pictures"],
            .collection: ["files"], .notebook: ["files"],
        ]
        let files = try await projection.replica.read { replica -> [FileRef] in
            var found: [FileRef] = []
            let types = maps.keys.map(\.rawValue).sorted()
            try replica.connection.query("""
                SELECT record_type, payload FROM ck_records WHERE zone_key = ? AND record_type IN (\(types.map { _ in "?" }.joined(separator: ", ")))
            """, [.text(zoneKey)] + types.map { .text($0) }) { row in
                guard let type = SyncRecordType(rawValue: row.text(0) ?? ""), let payload = row.blob(1),
                      let envelope = replica.decode(payload) else { return }
                for map in maps[type] ?? [] {
                    switch envelope.fields[map] {
                    case .object(let elements)?:
                        // A map of roles, or a FileRef itself (`Artifact.body`, `Quiz.questions`).
                        if let file = FileRef(json: .object(elements)) {
                            found.append(file)
                        } else {
                            found += elements.keys.sorted().compactMap { elements[$0].flatMap(FileRef.init(json:)) }
                        }
                    default:
                        continue
                    }
                }
            }
            return found
        }
        var seen = Set<String>()
        var satellites: [MobileSatellite] = []
        func add(_ file: FileRef) {
            guard !Self.isOnDemandOnly(role: file.role), !file.isPersonal, file.heldBy == nil, seen.insert(file.hash).inserted else { return }
            satellites.append(MobileSatellite(file: file, zone: zone))
            file.children.forEach(add)
        }
        files.forEach(add)
        return satellites
    }

    /// What downloading a space whole would add to this phone, in decoded bytes (the "1.3 GB" of its
    /// toggle), and what it keeps already.
    func spaceSize(zoneKey: String) async throws -> (total: Int64, kept: Int64) {
        let satellites = try await spaceSatellites(zoneKey: zoneKey)
        let total = satellites.reduce(Int64(0)) { $0 + ($1.file.size ?? 0) }
        return (total, byteCount(holder: MobileSatelliteHolder.space(zoneKey)))
    }

    /// Fetches up to `budget` satellites of each downloaded space this phone does not keep yet, durable
    /// for the space; a space whose records have not moved since its last complete pass is not walked
    /// again. Bounded, so a round's pass never holds the phone for long; the next pass carries on.
    /// Returns how many it fetched.
    @discardableResult
    func downloadSpaces(_ zoneKeys: Set<String>, budget: Int = 25) async -> Int {
        guard !downloading else { return 0 }
        downloading = true
        defer { downloading = false }
        var fetched = 0
        for zoneKey in zoneKeys.sorted() {
            let holder = MobileSatelliteHolder.space(zoneKey)
            // A space that went (deleted, left, purged) takes its downloaded files with it (§9.6).
            let gone = (try? await projection.replica.read { try $0.replica.engineState(SpaceSync.StateScope.gonePrefix + zoneKey) }) ?? nil
            if gone != nil {
                stopDownloading(space: zoneKey)
                continue
            }
            guard let signature = try? await spaceSignature(zoneKey), spacePasses[zoneKey] != signature else { continue }
            var complete = true
            do {
                for satellite in try await spaceSatellites(zoneKey: zoneKey)
                where !FileManager.default.fileExists(atPath: disk.durableURL(satellite.file, holder: holder).path) {
                    guard fetched < budget else {
                        complete = false
                        break
                    }
                    do {
                        try await keep(satellite, for: holder)
                        fetched += 1
                    } catch {
                        complete = false
                        Self.logger.error("A space's satellite was not downloaded: \(String(describing: error), privacy: .public)")
                    }
                }
            } catch {
                complete = false
            }
            if complete { spacePasses[zoneKey] = signature }
        }
        return fetched
    }

    /// The learner stopped downloading a space: its durable copies go (the cache may keep what it read).
    func stopDownloading(space zoneKey: String) {
        release(holder: MobileSatelliteHolder.space(zoneKey))
        spacePasses[zoneKey] = nil
    }

    private func spaceSignature(_ zoneKey: String) async throws -> String {
        try await projection.replica.read { replica in
            var signature = ""
            try replica.connection.query("SELECT COUNT(*), MAX(rowid), SUM(length(payload)) FROM ck_records WHERE zone_key = ?", [.text(zoneKey)]) { row in
                signature = "\(row.integer(0) ?? 0):\(row.integer(1) ?? 0):\(row.integer(2) ?? 0)"
            }
            return signature
        }
    }
}

/// Which spaces this phone downloads whole (§2.3: "Download all files", bytes only, never visibility):
/// a device's own choice, kept in its defaults per CloudKit environment, never synced.
struct MobileSpaceDownloads: @unchecked Sendable {
    let defaults: UserDefaults
    let environment: MobileCloudKitEnvironment

    init(defaults: UserDefaults = .standard, environment: MobileCloudKitEnvironment = .current) {
        self.defaults = defaults
        self.environment = environment
    }

    private var key: String { "ios.spaces.downloadAll.\(environment.rawValue)" }

    var zoneKeys: Set<String> { Set(defaults.stringArray(forKey: key) ?? []) }

    func contains(_ zoneKey: String) -> Bool { zoneKeys.contains(zoneKey) }

    func set(_ zoneKey: String, downloaded: Bool) {
        var keys = zoneKeys
        if downloaded { keys.insert(zoneKey) } else { keys.remove(zoneKey) }
        defaults.set(keys.sorted(), forKey: key)
    }
}

/// A source's `listenText` satellite as the Listen path reads it (§3.5.30, §7.2): the narration text the
/// Mac prepared, with what it was made from in the FileRef's `gen`: `input`, the SHA-256 of the trimmed
/// canonical text; `prompt`, the preparation's signature; `version`, the generator's; `at`, when. It
/// is read only while it was made from the source's text as it is now and by this build's generator.
enum MobileListenText {
    static func content(narration: String, file: FileRef, canonicalText: String) -> StoredSourceListenableContent? {
        let made = file.value["gen"]
        guard !narration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let input = made?["input"]?.stringValue,
              SyncIdentity.sha256Hex(Data(canonicalText.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) == input
        else { return nil }
        let version = made?["version"]?.int64Value.map(Int.init) ?? SourceListenableContentMetadata.currentVersion
        guard version == SourceListenableContentMetadata.currentVersion else { return nil }
        let preparedAt = made?["at"]?.int64Value.map { Date(timeIntervalSince1970: Double($0) / 1_000) } ?? Date(timeIntervalSince1970: 0)
        return StoredSourceListenableContent(text: narration, metadata: SourceListenableContentMetadata(
            sourceSHA256: input, generatorVersion: version, preparationSignature: made?["prompt"]?.stringValue,
            characterCount: narration.count, preparedAt: preparedAt
        ))
    }
}

/// A narration's chunks as satellites (§3.5.30: `audio.<voiceKey>` with children `audioChunk`): each of
/// the manifest's chunks, in its order, is the child keyed by its file name, else the child at its
/// place. Nil where the FileRef lists none for a chunk.
enum MobileNarrationChunks {
    static func satellites(of narration: MobileSatellite, manifest: SyncedArticleAudioManifest) -> [MobileSatellite?] {
        let children = narration.children(role: "audioChunk")
        return manifest.chunks.enumerated().map { place, chunk in
            narration.child(role: "audioChunk", key: chunk.fileName)
                ?? (children.indices.contains(place) && children[place].file.key == nil ? children[place] : nil)
        }
    }
}

/// A course's quizzes under generation 2 (§3.5.11): each a Quiz record in the course's zone, its
/// questions (and its drawn picture) satellites the phone fetches when the course page opens, never at
/// launch. What a quiz covers is a set of lessons, put in the course's lesson order.
enum MobileCourseQuizzes {
    /// What a course page's quiz load depends on, for the `.task(id:)` that runs it: empty until the catalog
    /// holds the course, then the course and its lessons in order. A page opened before the course arrived
    /// loads its quizzes when it does, and again when its lessons change.
    static func loadKey(courseID: String, course: MobileCloudCourse?) -> [String] {
        course.map { [courseID] + $0.lectures.map(\.id) } ?? []
    }

    /// The quiz a Quiz record and its fetched satellites make.
    static func quiz(from envelope: SyncEnvelope, questions: Data, artwork: Data?, lessonOrder: [String]) -> CourseQuiz? {
        let fields = envelope.fields
        guard let courseID = fields["courseID"]?.stringValue,
              let kind = CourseQuiz.Kind(rawValue: fields["kind"]?.stringValue ?? ""),
              let decoded = try? JSONDecoder().decode([CourseQuizQuestion].self, from: questions) else { return nil }
        let covered = Set((fields["coversLessonIDs"]?.objectValue ?? [:]).compactMap { $0.value == .bool(true) ? $0.key : nil })
        let place = Dictionary(lessonOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let lectures = covered.sorted { (place[$0] ?? Int.max, $0) < (place[$1] ?? Int.max, $1) }
        let createdAt = Date(timeIntervalSince1970: Double(fields["createdAt"]?.int64Value ?? 0) / 1_000)
        return CourseQuiz(
            id: envelope.id, courseID: courseID, kind: kind, title: fields["title"]?.stringValue ?? "", lectureIDs: lectures,
            afterLectureID: fields["lessonID"]?.stringValue, questions: decoded,
            author: fields["author"]?.stringValue == "learner" ? .assistant : .foreverlm, createdAt: createdAt, updatedAt: createdAt,
            symbol: fields["symbol"]?.stringValue, artwork: artwork
        )
    }

    /// Every quiz of `courseID` the phone holds, with its questions fetched by name; a quiz whose
    /// questions cannot be read yet is left out.
    static func load(courseID: String, lessonOrder: [String], satellites: MobileSatellites) async -> [CourseQuiz] {
        let projection = satellites.projection
        let held = (try? await projection.replica.read { replica -> [(id: String, zoneKey: String)] in
            var rows: [(String, String)] = []
            try replica.connection.query("SELECT id, zone_key FROM m_quizzes WHERE course_id = ? ORDER BY id", [.text(courseID)]) {
                rows.append(($0.text(0) ?? "", $0.text(1) ?? ""))
            }
            return rows
        }) ?? []
        var quizzes: [CourseQuiz] = []
        for row in held {
            guard let envelope = try? await projection.envelope(.quiz, id: row.id, zoneKey: row.zoneKey),
                  let questionsFile = envelope.fields["questions"].flatMap(FileRef.init(json:)),
                  let questions = try? await satellites.satellite(questionsFile, ownerZoneKey: row.zoneKey),
                  let bytes = try? await satellites.data(questions) else { continue }
            var artwork: Data?
            if let pictures = envelope.fields["pictures"]?.objectValue,
               let file = pictures.keys.sorted().lazy.compactMap({ pictures[$0].flatMap(FileRef.init(json:)) }).first,
               let picture = try? await satellites.satellite(file, ownerZoneKey: row.zoneKey) {
                artwork = try? await satellites.data(picture)
            }
            if let quiz = quiz(from: envelope, questions: bytes, artwork: artwork, lessonOrder: lessonOrder) { quizzes.append(quiz) }
        }
        return quizzes
    }
}
