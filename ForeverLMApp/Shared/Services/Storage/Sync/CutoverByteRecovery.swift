import Foundation
import OSLog

/// P4b, download only (docs/cloudkit-schema-design.md §13.4 step 2): a source whose file the old container
/// holds and this Mac does not (55 papers' PDFs on the product owner's Mac today) is fetched by record name and
/// desired key, checked against the size its digest recorded, and staged for P5 under `ck-staging/`; its
/// `files.pdf` pointer then rides the Source record like any other. What cannot be recovered is left to the
/// byte parity report (§13.8). Only a paper's or book's own file travels this way: every other satellite
/// is built from the database, which the catch-up has brought up to date.
struct CutoverByteRecovery: Sendable {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "CutoverSeed")
    static let pdfField = "sourcePDFAsset"
    private static let absentDigest = "-"

    /// The old container's transport (the walk's).
    let oldTransport: CloudTransport
    let store: MacPrivateSyncStore

    struct Candidate: Equatable, Sendable {
        let sourceID: String
        let recordName: String
        let size: Int64
    }

    /// Sources whose old record carries a PDF this Mac lacks: a digest row for the field, a local path that
    /// names a file, and no file at it.
    func candidates(in store: KnowledgeStore) throws -> [Candidate] {
        var found: [Candidate] = []
        try store.query("""
            SELECT m.logical_key, m.record_name, d.digest FROM sync_asset_digests d
            JOIN sync_metadata m ON m.record_name = d.record_name AND m.entity_type = 'source' AND m.is_deleted = 0
            WHERE d.field = ? AND d.digest IS NOT NULL AND d.digest <> ?
            ORDER BY m.logical_key
        """, [.text(Self.pdfField), .text(Self.absentDigest)]) { row in
            guard let id = row.text(0), let name = row.text(1), let digest = row.text(2) else { return }
            // `f:<variant>:<size>:<mtime>:<path>`
            let parts = digest.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5, parts[0] == "f", let size = Int64(parts[2]), size > 0 else { return }
            found.append(Candidate(sourceID: id, recordName: name, size: size))
        }
        return try found.filter { candidate in
            var path: String?
            try store.query(
                "SELECT \(KnowledgeStore.subtypeCoalesce("local_file_path")) FROM sources s \(KnowledgeStore.subtypeJoins) WHERE s.id = ? AND s.team_id IS NULL",
                [.text(candidate.sourceID)]
            ) { path = $0.text(0) }
            guard let path, !path.isEmpty, !path.contains("://"),
                  !FileManager.default.fileExists(atPath: StorageService.absoluteSourcePath(path)) else { return false }
            return try store.scalarInteger("SELECT EXISTS(SELECT 1 FROM source_files WHERE source_id = ? AND role = 'pdf')", [.text(candidate.sourceID)]) == 0
        }
    }

    /// Fetches and stages what it can. Returns how many files it recovered.
    @discardableResult
    func recover() async throws -> Int {
        let todo = try await store.onStore { try self.candidates(in: $0) }
        var recovered = 0
        for candidate in todo {
            let id = CloudRecordID(candidate.recordName, in: CloudZoneID(CloudKitZoneHome.knowledgeZoneName))
            guard case .success(let record)? = try await oldTransport.records([id], in: .private, desiredKeys: [Self.pdfField])[id],
                  case .asset(let url)? = record.fields[Self.pdfField],
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe), Int64(data.count) == candidate.size
            else {
                Self.logger.error("A PDF the old container holds could not be recovered")
                continue
            }
            try await store.onStore { try Self.stage(data, for: candidate, in: $0) }
            recovered += 1
        }
        return recovered
    }

    /// Writes the bytes under `ck-staging/recovered/` and gives the source a `files.pdf` pointer that reads
    /// them: the pointer goes out with the Source record (a trigger enqueues it), the bytes in P5.
    static func stage(_ data: Data, for candidate: Candidate, in store: KnowledgeStore) throws {
        let folder = store.satelliteStagingFolder.appendingPathComponent("recovered", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = SyncIdentity.sha256Hex(Data(candidate.sourceID.utf8)).prefix(24) + ".pdf"
        try data.write(to: folder.appendingPathComponent(String(name)), options: .atomic)
        let owner = try store.scalarText("SELECT wire_key FROM sources WHERE id = ?", [.text(candidate.sourceID)]) ?? candidate.sourceID
        let relative = "ck-staging/recovered/\(name)"
        let (file, _) = try SourceSatelliteLayout.layout(SourceLocalSatellite(
            map: .files, role: "pdf", mime: "application/pdf", encoding: .identity, body: data, localPath: relative, input: nil
        ), owner: owner)
        try store.execute("""
            INSERT INTO source_files (source_id, role, file_ref, local_path) VALUES (?, 'pdf', ?, ?)
            ON CONFLICT(source_id, role) DO UPDATE SET file_ref = excluded.file_ref, local_path = excluded.local_path
        """, [.text(candidate.sourceID), .text(ArtifactBody.text(file)), .text(relative)])
        try store.execute(
            "INSERT INTO source_work_keys (source_id, work_key) VALUES (?, ?) ON CONFLICT(source_id, work_key) DO NOTHING",
            [.text(candidate.sourceID), .text("file:" + file.hash)]
        )
    }
}
