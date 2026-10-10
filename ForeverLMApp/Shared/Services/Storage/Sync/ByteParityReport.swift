import Foundation
import SQLite3

/// The old container's four asset fields whose bytes the new container must hold before "Remove old
/// iCloud data" may run (docs/cloudkit-schema-design.md §13.4 P4b, §13.8): `sync_asset_digests` names
/// each one the old engine uploaded.
enum OldAssetField: String, CaseIterable, Sendable {
    case pdf = "sourcePDFAsset"
    case readerHTML = "sourceReaderHTMLAsset"
    case content = "sourceContentAsset"
    case rawTTML = "podcastRawTTMLAsset"

    /// The `Content` roles (`Source.files`) that carry the same bytes in the new container. A book's
    /// original travels as `epub`.
    var satelliteRoles: [String] {
        switch self {
        case .pdf: return ["pdf", "epub"]
        case .readerHTML: return ["readerHTML"]
        case .content: return ["text"]
        case .rawTTML: return ["raw"]
        }
    }
}

/// One old asset digest, with the source it belongs to.
struct OldAssetDigest: Equatable, Sendable {
    let sourceID: String
    let title: String
    let field: OldAssetField
}

/// The byte parity report (§13.8): every old asset digest has either a new satellite, or a local file
/// on one of the learner's Macs (this one, or the Mac the Source's FileRef says holds it). What
/// neither covers is listed by source title, so the learner sees what the removal would lose.
struct ByteParityReport: Equatable, Sendable {
    enum Coverage: Equatable, Sendable {
        /// An acknowledged satellite of the new container carries the bytes.
        case newSatellite
        /// The file is on this Mac.
        case localFile
        /// The Source's FileRef says another Mac holds the file (`heldBy`, D38).
        case heldByMac(String)
        case missing
    }

    struct Missing: Equatable, Sendable {
        let sourceID: String
        let title: String
        let field: OldAssetField
    }

    var checked = 0
    var newSatellites = 0
    var localFiles = 0
    var heldByOtherMacs = 0
    /// Sorted by title, then field.
    var missing: [Missing] = []

    var isClean: Bool { missing.isEmpty }

    /// `coverage` decides each digest; the order of `digests` does not matter.
    static func build(digests: [OldAssetDigest], coverage: (OldAssetDigest) -> Coverage) -> ByteParityReport {
        var report = ByteParityReport()
        for digest in digests {
            report.checked += 1
            switch coverage(digest) {
            case .newSatellite: report.newSatellites += 1
            case .localFile: report.localFiles += 1
            case .heldByMac: report.heldByOtherMacs += 1
            case .missing: report.missing.append(Missing(sourceID: digest.sourceID, title: digest.title, field: digest.field))
            }
        }
        report.missing.sort {
            ($0.title.localizedLowercase, $0.field.rawValue, $0.sourceID) < ($1.title.localizedLowercase, $1.field.rawValue, $1.sourceID)
        }
        return report
    }

    /// The titles a Settings line lists, at most `limit`, with how many more there are.
    func titles(limit: Int = 5) -> (shown: [String], more: Int) {
        var seen = Set<String>()
        let unique = missing.map(\.title).filter { seen.insert($0).inserted }
        return (Array(unique.prefix(limit)), max(0, unique.count - limit))
    }
}

// MARK: - From the store

/// What the store knows: which old assets exist, which satellites the new container acknowledged, where
/// each Source's bytes are on this Mac and which Mac a FileRef says holds one. Evaluated inside one
/// storage-actor job (`ByteParityReport.compute(in:)`), never on the main actor.
struct ByteParityInputs {
    var digests: [OldAssetDigest]
    /// `(owner id, role)` of every acknowledged satellite.
    var satellites: Set<SatelliteKey>
    /// Whether this Mac holds the bytes of an old asset.
    var localFile: (OldAssetDigest) -> Bool
    /// The Mac a Source's FileRef of that role names in `heldBy`.
    var heldBy: (SatelliteKey) -> String?

    struct SatelliteKey: Hashable, Sendable {
        let owner: String
        let role: String
    }

    func report() -> ByteParityReport {
        ByteParityReport.build(digests: digests) { digest in
            let roles = digest.field.satelliteRoles
            if roles.contains(where: { satellites.contains(SatelliteKey(owner: digest.sourceID, role: $0)) }) { return .newSatellite }
            if localFile(digest) { return .localFile }
            for role in roles {
                if let mac = heldBy(SatelliteKey(owner: digest.sourceID, role: role)) { return .heldByMac(mac) }
            }
            return .missing
        }
    }
}

extension ByteParityReport {
    /// The report for this store: `sync_asset_digests` against `ck_blobs`, this Mac's files and the
    /// Catalog's FileRefs.
    static func compute(in store: KnowledgeStore) throws -> ByteParityReport {
        let digests = try store.oldAssetDigests()
        let facts = try store.byteParityLocalFacts(for: digests)
        let replica = store.replica
        let inputs = ByteParityInputs(
            digests: digests,
            satellites: try store.acknowledgedSatellites(),
            localFile: { facts.holds($0) },
            heldBy: { key in
                guard let record = try? replica.record(zoneKey: PrivateSyncZones.key(PrivateSyncZones.catalog), recordType: SyncRecordType.source.rawValue, wireID: key.owner),
                      let envelope = try? SyncEnvelope(storedPayload: record.payload),
                      let file = envelope.fields["files"]?.objectValue?[key.role].flatMap(FileRef.init(json:))
                else { return nil }
                return file.heldBy
            }
        )
        return inputs.report()
    }
}

extension KnowledgeStore {
    /// The old asset digests the old engine acknowledged (`sync_asset_digests`, a digest that is not the
    /// "absent" marker), with their sources' titles. A source the old world deleted has no
    /// `sync_metadata` row to join and is not listed.
    func oldAssetDigests() throws -> [OldAssetDigest] {
        let fields = OldAssetField.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        var digests: [OldAssetDigest] = []
        try query("""
            SELECT m.logical_key, COALESCE(s.title, m.logical_key), d.field
            FROM sync_asset_digests d
            JOIN sync_metadata m ON m.record_name = d.record_name AND m.entity_type = 'source' AND m.is_deleted = 0
            LEFT JOIN sources s ON s.id = m.logical_key
            WHERE d.digest IS NOT NULL AND d.digest <> '-' AND d.field IN (\(fields))
            ORDER BY m.logical_key, d.field
        """) { statement in
            guard let id = self.string(statement, 0), let title = self.string(statement, 1),
                  let field = self.string(statement, 2).flatMap(OldAssetField.init(rawValue:)) else { return }
            digests.append(OldAssetDigest(sourceID: id, title: title, field: field))
        }
        return digests
    }

    /// `(owner, role)` of every satellite this account uploaded and CloudKit acknowledged (`ck_blobs`).
    func acknowledgedSatellites() throws -> Set<ByteParityInputs.SatelliteKey> {
        var keys = Set<ByteParityInputs.SatelliteKey>()
        try query("SELECT DISTINCT owner_id, role FROM ck_blobs WHERE acked_at IS NOT NULL") { statement in
            if let owner = self.string(statement, 0), let role = self.string(statement, 1) {
                keys.insert(ByteParityInputs.SatelliteKey(owner: owner, role: role))
            }
        }
        return keys
    }

    /// The old assets' paths on this Mac, per source: the stored paths of its original, and which
    /// sources hold canonical text or raw TTML in the store.
    func byteParityLocalFacts(for digests: [OldAssetDigest]) throws -> ByteParityLocalFacts {
        var paths: [String: [String]] = [:]
        var withContent = Set<String>()
        var withTTML = Set<String>()
        try query("""
            SELECT sp.id, sp.local_file_path, sp.url FROM source_projection sp
        """) { statement in
            let id = self.string(statement, 0) ?? ""
            paths[id] = [self.string(statement, 1), self.string(statement, 2)].compactMap { $0 }.filter { !$0.isEmpty }
        }
        try query("SELECT source_id FROM source_content WHERE octet_length(content) > 0") { statement in
            if let id = self.string(statement, 0) { withContent.insert(id) }
        }
        try query("SELECT source_id FROM podcasts WHERE octet_length(raw_ttml) > 0") { statement in
            if let id = self.string(statement, 0) { withTTML.insert(id) }
        }
        return ByteParityLocalFacts(paths: paths, sourcesWithContent: withContent, sourcesWithRawTTML: withTTML)
    }
}

/// What this Mac holds of the old assets, as the old engine's record mapper found it
/// (`CloudKitRecordMapper`, `sourcePDFAsset`, `sourceReaderHTMLAsset`): a stored path that resolves to a
/// file, an archived article's `article.html`, canonical text in `source_content`, raw TTML in
/// `podcasts`.
struct ByteParityLocalFacts: Sendable {
    var paths: [String: [String]]
    var sourcesWithContent: Set<String>
    var sourcesWithRawTTML: Set<String>

    func holds(_ digest: OldAssetDigest, fileExists: (String) -> Bool = ByteParityLocalFacts.fileOnThisMac) -> Bool {
        switch digest.field {
        case .content: return sourcesWithContent.contains(digest.sourceID)
        case .rawTTML: return sourcesWithRawTTML.contains(digest.sourceID)
        case .pdf, .readerHTML:
            for stored in paths[digest.sourceID] ?? [] where fileExists(stored) { return true }
            if digest.field == .readerHTML, let archive = Self.archivedArticlePath(sourceID: digest.sourceID), fileExists(archive) {
                return true
            }
            return false
        }
    }

    /// A stored path as the old mapper resolved it: relative to the library, or absolute, found even
    /// when the volume or folder moved.
    static func fileOnThisMac(_ stored: String) -> Bool {
        let absolute = StorageService.absoluteSourcePath(stored)
        guard absolute.hasPrefix("/") else { return false }
        return StorageService.locateSourceFile(absolute) != nil
    }

    static func archivedArticlePath(sourceID: String) -> String? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("\(ForeverLMRuntimeIdentity.productFolderName)/ArticleArchives", isDirectory: true)
            .appendingPathComponent(sourceID, isDirectory: true)
            .appendingPathComponent("article.html").path
    }
}
