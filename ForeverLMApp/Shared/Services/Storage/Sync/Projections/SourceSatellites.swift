import Foundation
import OSLog

// MARK: - A Source's satellites on this Mac (docs/cloudkit-schema-design.md §3.5.30, §7.2, §13.3 step 4)

/// One body of a source this Mac holds, as the satellite a role of `Source.files` or `Source.derived`
/// names: where it comes from, how it is stored, and what it was made from.
struct SourceLocalSatellite: Equatable, Sendable {
    enum Map: String, Sendable { case files, derived }

    let map: Map
    let role: String
    let mime: String
    let encoding: BlobStore.Encoding
    let body: Data
    /// The file it was read from, relative to the content roots, when it is a file on disk.
    let localPath: String?
    /// The text a machine output was made from, as `gen.input` (§5.4: stale when it differs).
    let input: String?
    /// The record the bytes are uploaded under when it is not the source: a book chapter's `pdf` is its
    /// book's whole file, shared by every chapter, so it goes up once under the book (D41).
    var owner: (id: String, type: SyncRecordType)? = nil

    static func == (lhs: SourceLocalSatellite, rhs: SourceLocalSatellite) -> Bool {
        lhs.map == rhs.map && lhs.role == rhs.role && lhs.mime == rhs.mime && lhs.encoding == rhs.encoding
            && lhs.body == rhs.body && lhs.localPath == rhs.localPath && lhs.input == rhs.input
            && lhs.owner?.id == rhs.owner?.id && lhs.owner?.type == rhs.owner?.type
    }
}

/// Where each role comes from today, and which this package builds (§3.5.30). Built here: `pdf` and
/// `epub` (the source's own file), `text`, `listenText` and `raw` (the canonical text, the Listen text
/// and a podcast's TTML, gzip), `reviewGuide`, `walkthrough`, `figures` and `references` (gzip). Left to later packages,
/// which own their makers: `timing` (built from the TTML), `thumbnail`, `cover`, `icon`, `slides`,
/// `readerHTML`, `audio.*` (narration, `NarrationSatellites`), `attachment.*` (meeting files), `vectors.*`
///, `ideas` (packed from `source_ideas`), `citedPapers` and `explainer`. A pointer the publisher
/// wrote keeps no path; the seed builds its body here again (`SeedSatellite.Origin.table`).
enum SourceSatelliteRoles {
    static func localSatellites(sourceID: String, connection: SQLiteConnection, resolve: (String) -> URL) throws -> [SourceLocalSatellite] {
        var satellites: [SourceLocalSatellite] = []
        var filePath: String?
        try connection.query(
            "SELECT \(KnowledgeStore.subtypeCoalesce("local_file_path")) FROM sources s \(KnowledgeStore.subtypeJoins) WHERE s.id = ?",
            [.text(sourceID)]
        ) { filePath = $0.text(0) }
        // A chapter of a book kept as one file: the file is the book's, uploaded under the book.
        let bookOwner = try connection.scalarText("""
            SELECT gm.group_id FROM book_sources bs
            JOIN group_members gm ON gm.source_id = bs.source_id
            JOIN books b ON b.id = gm.group_id
            WHERE bs.source_id = ? AND bs.page_start IS NOT NULL
            LIMIT 1
        """, [.text(sourceID)])
        let isPageRangeChapter = try connection.scalarInteger(
            "SELECT COUNT(*) FROM book_sources WHERE source_id = ? AND page_start IS NOT NULL", [.text(sourceID)]
        ) == 1
        if let filePath, !filePath.isEmpty, !filePath.contains("://"), !isPageRangeChapter || bookOwner != nil {
            let lowered = filePath.lowercased()
            let kind: (role: String, mime: String)? = lowered.hasSuffix(".pdf")
                ? ("pdf", "application/pdf")
                : lowered.hasSuffix(".epub") ? ("epub", "application/epub+zip") : nil
            if let kind, let body = try? Data(contentsOf: resolve(filePath), options: .mappedIfSafe) {
                satellites.append(SourceLocalSatellite(
                    map: .files, role: kind.role, mime: kind.mime, encoding: .identity, body: body, localPath: filePath, input: nil,
                    owner: bookOwner.map { (id: $0, type: SyncRecordType.collection) }
                ))
            }
        }
        func text(_ sql: String, map: SourceLocalSatellite.Map, role: String, mime: String) throws {
            try connection.query(sql, [.text(sourceID)]) { row in
                guard let body = row.text(0), !body.isEmpty else { return }
                satellites.append(SourceLocalSatellite(
                    map: map, role: role, mime: mime, encoding: .gzip, body: Data(body.utf8), localPath: nil, input: row.text(1)
                ))
            }
        }
        try text("SELECT content, NULL FROM source_content WHERE source_id = ?", map: .files, role: "text", mime: "text/plain")
        try text("SELECT content, source_sha256 FROM source_listenable_content WHERE source_id = ?", map: .files, role: "listenText", mime: "text/plain")
        try text("SELECT raw_ttml, NULL FROM podcasts WHERE source_id = ?", map: .files, role: "raw", mime: "application/ttml+xml")
        try text("SELECT guide, source_sha256 FROM source_review_guides WHERE source_id = ?", map: .derived, role: "reviewGuide", mime: "text/markdown")
        try text("SELECT walkthrough_json, source_sha256 FROM source_walkthroughs WHERE source_id = ?", map: .derived, role: "walkthrough", mime: "application/json")
        if let figures = try figuresBody(sourceID: sourceID, connection: connection) {
            satellites.append(SourceLocalSatellite(
                map: .derived, role: "figures", mime: "application/json", encoding: .gzip, body: figures, localPath: nil, input: nil
            ))
        }
        if let references = try referencesBody(sourceID: sourceID, connection: connection) {
            satellites.append(SourceLocalSatellite(
                map: .derived, role: "references", mime: "application/json", encoding: .gzip, body: references, localPath: nil, input: nil
            ))
        }
        return satellites
    }

    /// A paper's reference list as the `references` satellite: one `SyncedPaperReference` an entry (its words, the
    /// link it resolved to and how it came by it), in list order and with dates to the second, so an unchanged list
    /// is the same bytes and is uploaded once. Nil when the paper has none. This is what lets a link an assistant
    /// found by hand reach every other Mac, which the free read of the PDF could not remake.
    static func referencesBody(sourceID: String, connection: SQLiteConnection) throws -> Data? {
        var entries: [SyncedPaperReference] = []
        try connection.query("""
            SELECT ordinal, label, entry_text, title, authors, journal, year, doi, url, link_origin, catalog_checked_at
            FROM paper_references WHERE source_id = ? ORDER BY ordinal ASC
        """, [.text(sourceID)]) { row in
            guard let ordinal = row.integer(0), let label = row.text(1), let text = row.text(2) else { return }
            entries.append(SyncedPaperReference(
                ordinal: Int(ordinal), label: label, text: text, title: row.text(3), authors: row.text(4), journal: row.text(5),
                year: row.text(6), doi: row.text(7), url: row.text(8), origin: row.text(9) ?? PaperReference.LinkOrigin.none.rawValue,
                catalogCheckedAt: row.real(10).map(Date.init(timeIntervalSinceReferenceDate:))
            ))
        }
        guard !entries.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(entries)
    }

    /// A paper's figure index as the `figures` satellite: one `SyncedPaperFigure` a figure (label, page, caption and
    /// the vision pass's analysis; the pixels render from the PDF), in a fixed order and with dates to the second,
    /// so an unchanged index is the same bytes and is uploaded once. Nil when the source has none.
    static func figuresBody(sourceID: String, connection: SQLiteConnection) throws -> Data? {
        var figures: [SyncedPaperFigure] = []
        try connection.query("""
            SELECT figure_id, figure_label, page_index, caption, analysis_json FROM paper_figures
            WHERE source_id = ? ORDER BY page_index ASC, figure_label COLLATE NOCASE ASC, figure_id ASC
        """, [.text(sourceID)]) { row in
            guard let id = row.text(0), let label = row.text(1), let caption = row.text(3) else { return }
            let analysis = row.text(4).flatMap { try? JSONDecoder().decode(PaperFigureAnalysis.self, from: Data($0.utf8)) }
            figures.append(SyncedPaperFigure(
                id: id, sourceID: sourceID, figureLabel: label, pageIndex: Int(row.integer(2) ?? 0), caption: caption, analysis: analysis
            ))
        }
        guard !figures.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(figures)
    }
}

/// A body's FileRef exactly as `BlobStore.upload` lays it out on a native client (one inline part up to
/// 256 KiB stored, else 48 MiB parts), so the seed's upload keeps it (§3.5.30 rule 8) and nothing is
/// uploaded twice.
enum SourceSatelliteLayout {
    static func layout(_ satellite: SourceLocalSatellite, owner: String) throws -> (file: FileRef, stored: Data) {
        let stored = satellite.encoding == .gzip ? try SyncGzip.compress(satellite.body) : satellite.body
        let configuration = BlobStore.Configuration.native
        let parts = stored.count <= configuration.inlineMaxBytes ? [stored] : FileRef.split(stored, partSize: configuration.partBytes)
        var file = FileRef(
            owner: owner, role: satellite.role, hash: SyncIdentity.sha256Hex(satellite.body), size: Int64(satellite.body.count),
            mime: satellite.mime, encoding: satellite.encoding.rawValue, storedParts: parts
        )
        if let input = satellite.input, var object = file.value.objectValue {
            object["gen"] = .object(["input": .string(input)])
            file = FileRef(json: .object(object)) ?? file
        }
        return (file, stored)
    }
}

// MARK: - The backfill that lays out every source's satellites (§13.3 step 4)

extension KnowledgeStore {
    static let sourceFilesBackfillKind = "sourceFiles"

    /// Where the backfill reads a source's stored file path from: the content roots, unless a task stands
    /// in for them. The cutover rehearsal (`ProductionCloneRehearsalTests`) reads a copy of a library this
    /// way, never the Mac's own folders.
    @TaskLocal static var sourceFileLocationOverride: (@Sendable (String) -> URL)?

    /// Queues every source for the satellite backfill: the activation's last source step. Set-based and
    /// derived from the library alone (each queued as of when it was added), so it gives one result
    /// however often it runs; the queue's `(kind, target)` key queues nothing twice.
    func queueSourceFilesBackfill() throws {
        try execute("""
            INSERT INTO ck_backfill_queue (kind, target, enqueued_at)
            SELECT ?, id, date_added FROM sources WHERE true
            ON CONFLICT(kind, target) DO NOTHING
        """, [.text(Self.sourceFilesBackfillKind)])
    }

    /// The folder beside the store where a body held in a table is staged, gzip as it will be stored,
    /// until its upload is acknowledged (§13.3 step 4).
    var satelliteStagingFolder: URL {
        URL(fileURLWithPath: dbPath).deletingLastPathComponent().appendingPathComponent("ck-staging", isDirectory: true)
    }

    /// Lays out up to `limit` queued sources' satellites: hashes each file once, gzips each text into the
    /// staging folder, and writes the FileRefs into `source_files` and `source_derived` with the `file:`
    /// work key of a source's own file. Off main, at `.utility`, in bounded batches the caller repeats
    /// until it returns 0; resumable, since each source leaves the queue with its rows. The rows are
    /// written without an outbox row, like a derivation: what they point at is not uploaded yet, and the
    /// cutover seed sends the pointers and then the bytes (§3.5.30 rule 2's one exception). Generation 2
    /// only. Returns the sources it handled.
    @discardableResult
    func runSourceFilesBackfill(limit: Int = 50) throws -> Int {
        var queued: [(id: Int64, source: String)] = []
        // A source that failed five times waits for a later build rather than holding the queue up.
        try query("SELECT id, target FROM ck_backfill_queue WHERE kind = ? AND attempts < 5 ORDER BY attempts, id LIMIT ?", [
            .text(Self.sourceFilesBackfillKind), .integer(Int64(limit)),
        ]) { row in
            if let id = row.integer(0), let source = row.text(1) { queued.append((id, source)) }
        }
        guard !queued.isEmpty else { return 0 }

        struct Laid { let queueID: Int64; let source: String; let rows: [(map: SourceLocalSatellite.Map, role: String, file: FileRef, localPath: String?)]; let fileHash: String? }
        var laid: [Laid] = []
        var failed: [(Int64, String)] = []
        let staging = satelliteStagingFolder
        for item in queued {
            do {
                let owner = try scalarText("SELECT wire_key FROM sources WHERE id = ?", [.text(item.source)]) ?? item.source
                var rows: [(map: SourceLocalSatellite.Map, role: String, file: FileRef, localPath: String?)] = []
                var fileHash: String?
                for satellite in try SourceSatelliteRoles.localSatellites(sourceID: item.source, connection: self, resolve: {
                    Self.sourceFileLocationOverride?($0) ?? URL(fileURLWithPath: StorageService.absoluteSourcePath($0))
                }) {
                    let (file, stored) = try SourceSatelliteLayout.layout(satellite, owner: owner)
                    var localPath = satellite.localPath
                    if localPath == nil {
                        let folder = staging.appendingPathComponent(SyncIdentity.sha256Hex(Data(owner.utf8)), isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let name = "\(satellite.map.rawValue).\(satellite.role).gz"
                        try stored.write(to: folder.appendingPathComponent(name), options: .atomic)
                        localPath = "ck-staging/\(folder.lastPathComponent)/\(name)"
                    }
                    if satellite.map == .files, ["pdf", "epub"].contains(satellite.role) { fileHash = file.hash }
                    rows.append((satellite.map, satellite.role, file, localPath))
                }
                laid.append(Laid(queueID: item.id, source: item.source, rows: rows, fileHash: fileHash))
            } catch {
                failed.append((item.id, error.localizedDescription))
            }
        }

        try replica.apply { _ in
            for item in laid {
                // A source deleted since it was queued has nothing to lay out.
                guard try scalarInteger("SELECT EXISTS(SELECT 1 FROM sources WHERE id = ?)", [.text(item.source)]) == 1 else {
                    try execute("DELETE FROM ck_backfill_queue WHERE id = ?", [.integer(item.queueID)])
                    continue
                }
                for row in item.rows {
                    let table = row.map == .files ? "source_files" : "source_derived"
                    let element = row.map == .files ? "role" : "kind"
                    try execute("""
                        INSERT INTO \(table) (source_id, \(element), file_ref, local_path) VALUES (?, ?, ?, ?)
                        ON CONFLICT(source_id, \(element)) DO UPDATE SET file_ref = excluded.file_ref, local_path = excluded.local_path
                    """, [.text(item.source), .text(row.role), .text(String(decoding: row.file.value.serialized(), as: UTF8.self)), .text(row.localPath)])
                }
                if let hash = item.fileHash {
                    try execute(
                        "INSERT INTO source_work_keys (source_id, work_key) VALUES (?, ?) ON CONFLICT(source_id, work_key) DO NOTHING",
                        [.text(item.source), .text("file:" + hash)]
                    )
                }
                try execute("DELETE FROM ck_backfill_queue WHERE id = ?", [.integer(item.queueID)])
            }
            for (id, message) in failed {
                try execute("UPDATE ck_backfill_queue SET attempts = attempts + 1, last_error = ? WHERE id = ?", [.text(message), .integer(id)])
            }
        }
        return laid.count
    }
}

// MARK: - What this Mac takes from the work another device already did

/// A Source another of the learner's devices finished ingesting arrives `ready`. The record carries only the
/// state; the work itself is in the satellites it names: the canonical `text` (cleaned, with the metadata
/// attested) and a paper's `pdf`. Before this existed a second Mac held that record as a `ready` source with
/// no text, no PDF and no attestation, so every sweep that looks for unprocessed sources picked it up and
/// did the whole ingestion again — the PDF search (with the AI browser agent), the Paper Metadata model, the
/// clean-up model — and paid for each step a second time.
///
/// What a Mac takes now, in the order it matters:
/// 1. The attestation. A paper whose record arrives `ready` is marked `synced` (`PaperIngestionMethod`): the
///    device that wrote `ingest: ready` passed the metadata gate, and this Mac neither calls the model nor
///    lists the paper as needing attention.
/// 2. The text. An inbound `files.text` this Mac cannot match to its own `source_content` is remembered in
///    `ck_backfill_queue` (kind `sourceSatellites`, the source's local id, the wanted FileRefs by role) for
///    the satellite reader, which installs it as `source_content`, and, for a paper or article, records the
///    clean-up as done at this build's version so the versioned re-clean never queues it a second time. The
///    Mac that made the text owns any later re-clean; its newer satellite replaces this copy.
/// 3. A paper's PDF. The same queue, role `pdf`: the reader writes the file under the content root and sets
///    `papers.local_file_path`, so the PDF search never runs for a paper another Mac already holds.
///
/// A local text is never overwritten with another one unless it is exactly the text the previous pointer
/// named (an untouched copy of the old satellite): a Mac that made its own text since keeps it.
enum InboundSourceFiles {
    static let queueKind = "sourceSatellites"
    static let textRole = "text"
    static let pdfRole = "pdf"
    /// `Source.derived.figures`: a paper's figure index with the vision pass's analysis.
    static let figuresRole = "figures"
    /// `Source.derived.references`: a paper's reference list with the link each entry resolved to.
    static let referencesRole = "references"
    /// Entries of the queue payload that are not FileRefs: the zone a space source's bytes live in (absent for
    /// the learner's own `Content` zone) and the hash of the text this Mac holds and may replace.
    static let zoneField = "zone"
    static let replacesField = "replaces"
    static let fileRoles = [textRole, pdfRole, figuresRole, referencesRole]

    // MARK: The queue

    static func waiting(sourceID: String, connection: SQLiteConnection) throws -> [String: SyncJSON] {
        let json = try connection.scalarText(
            "SELECT payload_json FROM ck_backfill_queue WHERE kind = ? AND target = ?", [.text(queueKind), .text(sourceID)]
        )
        return json.flatMap { try? SyncJSON(parsing: Data($0.utf8)) }?.objectValue ?? [:]
    }

    /// Saves what is wanted. A payload that changed starts the attempts over; one that did not keeps what
    /// the failures already spent, so a record that changes again does not give a broken satellite fresh tries.
    static func save(_ waiting: [String: SyncJSON], sourceID: String, connection: SQLiteConnection) throws {
        guard fileRoles.contains(where: { waiting[$0] != nil }) else { return try forget(sourceID: sourceID, connection: connection) }
        try connection.queueBackfillKeepingAttempts(
            kind: queueKind, target: sourceID, payload: String(decoding: SyncJSON.object(waiting).serialized(), as: UTF8.self)
        )
    }

    static func forget(sourceID: String, connection: SQLiteConnection) throws {
        try connection.execute("DELETE FROM ck_backfill_queue WHERE kind = ? AND target = ?", [.text(queueKind), .text(sourceID)])
    }

    // MARK: What this Mac holds

    /// The hash of the text this Mac stores for the source, nil when it stores none (or only blanks).
    static func localTextHash(sourceID: String, connection: SQLiteConnection) throws -> String? {
        guard let content = try connection.scalarText("SELECT content FROM source_content WHERE source_id = ?", [.text(sourceID)]),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return SyncIdentity.sha256Hex(Data(content.utf8))
    }

    static func pointer(_ role: String, sourceID: String, connection: SQLiteConnection) throws -> FileRef? {
        ArtifactBody.fileRef(try connection.scalarText(
            "SELECT file_ref FROM source_files WHERE source_id = ? AND role = ?", [.text(sourceID), .text(role)]
        ))
    }

    static func derivedPointer(_ kind: String, sourceID: String, connection: SQLiteConnection) throws -> FileRef? {
        ArtifactBody.fileRef(try connection.scalarText(
            "SELECT file_ref FROM source_derived WHERE source_id = ? AND kind = ?", [.text(sourceID), .text(kind)]
        ))
    }

    private static func figureCount(sourceID: String, connection: SQLiteConnection) throws -> Int64 {
        try connection.scalarInteger("SELECT COUNT(*) FROM paper_figures WHERE source_id = ?", [.text(sourceID)]) ?? 0
    }

    private static func localFilePath(table: String, sourceID: String, connection: SQLiteConnection) throws -> String? {
        try connection.scalarText("SELECT local_file_path FROM \(table) WHERE source_id = ?", [.text(sourceID)])
    }

    /// The per-type table that keeps a source's cleaned-text proof, nil for the types that have none.
    static func preparationTable(localType: String) -> String? {
        switch localType {
        case "paper": return "paper_content_preparations"
        case "article", "manual", "unclassified": return "article_content_preparations"
        default: return nil
        }
    }

    // MARK: Inbound

    /// Works out what an applied Source record leaves this Mac to fetch, and remembers it. `previousText` is
    /// the hash the source's `files.text` named before this record. Runs inside the apply, under the guard:
    /// two small reads and one queue write per source, no file access.
    static func take(
        sourceID: String, localType: String, table: String, zone: SyncZoneName, zoneKey: String, previousText: String?,
        connection: SQLiteConnection
    ) throws {
        var waiting = try self.waiting(sourceID: sourceID, connection: connection)
        let before = waiting

        if let text = try pointer(textRole, sourceID: sourceID, connection: connection), text.heldBy == nil {
            let local = try localTextHash(sourceID: sourceID, connection: connection)
            if local == text.hash {
                waiting[textRole] = nil
                waiting[replacesField] = nil
            } else if local == nil {
                waiting[textRole] = text.value
                waiting[replacesField] = nil
            } else if let local, local == previousText {
                waiting[textRole] = text.value
                waiting[replacesField] = .string(local)
            } else {
                // This Mac's own text, made since: it stays, and its own pointer follows it.
                waiting[textRole] = nil
                waiting[replacesField] = nil
            }
        } else {
            waiting[textRole] = nil
            waiting[replacesField] = nil
        }

        if localType == "paper", let pdf = try pointer(pdfRole, sourceID: sourceID, connection: connection), pdf.heldBy == nil,
           (try localFilePath(table: table, sourceID: sourceID, connection: connection) ?? "").isEmpty {
            waiting[pdfRole] = pdf.value
        } else if localType == "book", try isPageRangeChapter(sourceID: sourceID, connection: connection),
                  let pdf = try pointer(pdfRole, sourceID: sourceID, connection: connection), pdf.heldBy == nil {
            // A chapter of a book kept as one file: the book's file, which the first of its chapters to
            // arrive brings and the others then point at with nothing fetched.
            if let installed = try installedBookFile(hash: pdf.hash, connection: connection) {
                try pointChapter(sourceID: sourceID, at: installed, connection: connection)
                waiting[pdfRole] = nil
            } else if (try localFilePath(table: table, sourceID: sourceID, connection: connection) ?? "").isEmpty {
                waiting[pdfRole] = pdf.value
            } else {
                waiting[pdfRole] = nil
            }
        } else {
            waiting[pdfRole] = nil
        }

        // A paper's figure index, with the analysis a vision pass was paid for, unless this Mac has built its own.
        if localType == "paper", let figures = try derivedPointer(figuresRole, sourceID: sourceID, connection: connection), figures.heldBy == nil,
           try figureCount(sourceID: sourceID, connection: connection) == 0 {
            waiting[figuresRole] = figures.value
        } else {
            waiting[figuresRole] = nil
        }

        // A paper's reference list, with the links another Mac found: taken whole when this Mac has read none,
        // otherwise only to give a link to an entry this Mac's own read left without one.
        if localType == "paper", let references = try derivedPointer(referencesRole, sourceID: sourceID, connection: connection),
           references.heldBy == nil, try referencesWorthTaking(references, sourceID: sourceID, connection: connection) {
            waiting[referencesRole] = references.value
        } else {
            waiting[referencesRole] = nil
        }

        waiting[zoneField] = zone.isSpace && fileRoles.contains(where: { waiting[$0] != nil }) ? .string(zoneKey) : nil
        if waiting != before { try save(waiting, sourceID: sourceID, connection: connection) }
    }

    /// A paper another device finished is attested (`PaperIngestionMethod.synced`): `ingest: ready` is written
    /// only after that device passed the metadata gate. Never over an attestation this Mac holds. The caller
    /// checks that the record said `ready`.
    static func attestFromRecord(sourceID: String, connection: SQLiteConnection) throws {
        try connection.execute(
            "UPDATE papers SET paper_ingestion_method = ? WHERE source_id = ? AND paper_ingestion_method IS NULL",
            [.text(PaperIngestionMethod.synced.rawValue), .text(sourceID)]
        )
    }

    /// Records that `text` is the canonical, cleaned text of the source at this build's cleaner version, as the
    /// Mac that made it had it: the proof `paperContentSHA256` and the versioned re-clean read. The text is
    /// both the raw and the clean text, since the raw extraction stayed on the Mac that made it. `replacing`
    /// is true when the text itself was just replaced, false when a Mac adopts text it already held.
    static func recordCleanedText(sourceID: String, localType: String, text: String, replacing: Bool, connection: SQLiteConnection) throws {
        guard let table = preparationTable(localType: localType) else { return }
        let hash = PaperContentPreparationService.sha256(text)
        let conflict = replacing
            ? """
              DO UPDATE SET raw_content = excluded.raw_content, raw_sha256 = excluded.raw_sha256,
                  clean_sha256 = excluded.clean_sha256, cleaner_version = excluded.cleaner_version, prepared_at = excluded.prepared_at
              """
            : "DO NOTHING"
        try connection.execute("""
            INSERT INTO \(table) (source_id, raw_content, raw_sha256, clean_sha256, cleaner_version, prepared_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_id) \(conflict)
        """, [
            .text(sourceID), .text(text), .text(hash), .text(hash), .integer(Int64(PaperContentPreparationMetadata.currentVersion)),
            .real(Date().timeIntervalSinceReferenceDate),
        ])
    }

    /// The satellite reader's half for `text`: the fetched body written as the source's text, the clean-up
    /// recorded, the wish forgotten. False when the bytes are not the ones wanted. Runs under the apply guard.
    static func receivedText(_ body: Data, sourceID: String, connection: SQLiteConnection) throws -> Bool {
        var waiting = try self.waiting(sourceID: sourceID, connection: connection)
        guard let wanted = waiting[textRole].flatMap(FileRef.init(json:)), wanted.hash == SyncIdentity.sha256Hex(body) else { return false }
        let local = try localTextHash(sourceID: sourceID, connection: connection)
        let replaces = waiting[replacesField]?.stringValue
        if local == nil || local == wanted.hash || (replaces != nil && local == replaces) {
            let text = String(decoding: body, as: UTF8.self)
            let type = try connection.scalarText("SELECT source_type FROM sources WHERE id = ?", [.text(sourceID)])
            if let type {
                try connection.execute("""
                    INSERT INTO source_content (source_id, content) VALUES (?, ?)
                    ON CONFLICT(source_id) DO UPDATE SET content = excluded.content
                """, [.text(sourceID), .text(text)])
                try recordCleanedText(sourceID: sourceID, localType: type, text: text, replacing: true, connection: connection)
                // The bytes the pointer names are installed as they are. A Mac on a build
                // before 166 can still publish text with soft hyphens; staged here, the
                // next repair drain drops them and republishes (schema 166).
                try StoredSoftHyphens.stage(sourceID: sourceID, holding: text, connection: connection)
            }
        }
        waiting[textRole] = nil
        waiting[replacesField] = nil
        try save(waiting, sourceID: sourceID, connection: connection)
        return true
    }

    /// The satellite reader's half for `figures`: the rows the index holds, under the ids this Mac's own indexer
    /// gives the same figures, so the next review reuses the analysis (`PaperFigureIndexer` keeps an existing
    /// analysis by figure id) and calls the vision model for none of them. Rows this Mac made in the meantime stay.
    static func receivedFigures(_ body: Data, sourceID: String, connection: SQLiteConnection) throws -> Bool {
        var waiting = try self.waiting(sourceID: sourceID, connection: connection)
        guard let wanted = waiting[figuresRole].flatMap(FileRef.init(json:)), wanted.hash == SyncIdentity.sha256Hex(body) else { return false }
        if try figureCount(sourceID: sourceID, connection: connection) == 0 {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for figure in (try? decoder.decode([SyncedPaperFigure].self, from: body)) ?? [] where figure.pageIndex >= 0 {
                let analysis = try figure.analysis.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
                try connection.execute("""
                    INSERT INTO paper_figures (figure_id, source_id, figure_label, page_index, caption, analysis_json)
                    VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(figure_id) DO NOTHING
                """, [
                    .text(PaperFigureIndexContract.figureID(sourceID: sourceID, figureLabel: figure.figureLabel, pageIndex: figure.pageIndex)),
                    .text(sourceID), .text(figure.figureLabel), .integer(Int64(figure.pageIndex)), .text(figure.caption), .text(analysis),
                ])
            }
        }
        waiting[figuresRole] = nil
        try save(waiting, sourceID: sourceID, connection: connection)
        return true
    }

    /// Whether the list a pointer names can add anything here: this Mac holds no list for the paper, or holds one
    /// with an entry still without a link and not the very bytes the pointer names. A list this Mac already
    /// links in full is left alone, so the common case costs two small reads and fetches nothing.
    static func referencesWorthTaking(_ pointer: FileRef, sourceID: String, connection: SQLiteConnection) throws -> Bool {
        let held = try connection.scalarInteger("SELECT COUNT(*) FROM paper_references WHERE source_id = ?", [.text(sourceID)]) ?? 0
        if held == 0 { return true }
        let open = try connection.scalarInteger(
            "SELECT COUNT(*) FROM paper_references WHERE source_id = ? AND url IS NULL", [.text(sourceID)]
        ) ?? 0
        guard open > 0 else { return false }
        let local = try SourceSatelliteRoles.referencesBody(sourceID: sourceID, connection: connection)
        return local.map { SyncIdentity.sha256Hex($0) != pointer.hash } ?? true
    }

    /// The satellite reader's half for `references`: the list merged into this Mac's own (`mergeReferences`).
    /// Not sent back out: what the pointer names is already on the server, and this Mac's own reads and saves
    /// are what publish a list.
    static func receivedReferences(_ body: Data, sourceID: String, connection: SQLiteConnection) throws -> Bool {
        var waiting = try self.waiting(sourceID: sourceID, connection: connection)
        guard let wanted = waiting[referencesRole].flatMap(FileRef.init(json:)), wanted.hash == SyncIdentity.sha256Hex(body) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let entries = try? decoder.decode([SyncedPaperReference].self, from: body) {
            try mergeReferences(entries, sourceID: sourceID, connection: connection)
        }
        waiting[referencesRole] = nil
        try save(waiting, sourceID: sourceID, connection: connection)
        return true
    }

    /// Merges a list another Mac published into the one this Mac holds. Entries are matched by what they say,
    /// never by number: two Macs may split the same PDF's list differently, and a number that names another
    /// entry would hang a link on the wrong paper.
    /// - No list here: the published one is kept whole, and the paper counts as read, so this Mac does not ask
    ///   the catalogs again for what is already answered.
    /// - A list here: an entry with no link takes the link of the published entry that has the same words (only
    ///   when exactly one entry here has them). A link this Mac already holds is never replaced.
    static func mergeReferences(_ incoming: [SyncedPaperReference], sourceID: String, connection: SQLiteConnection) throws {
        let now = Date().timeIntervalSinceReferenceDate
        var held: [(ordinal: Int, text: String, url: String?)] = []
        try connection.query(
            "SELECT ordinal, entry_text, url FROM paper_references WHERE source_id = ? ORDER BY ordinal", [.text(sourceID)]
        ) { row in
            if let ordinal = row.integer(0), let text = row.text(1) { held.append((Int(ordinal), text, row.text(2))) }
        }
        let linked: (SyncedPaperReference) -> Bool = { entry in
            guard let url = entry.url, let parsed = URL(string: url) else { return false }
            return ["http", "https"].contains(parsed.scheme?.lowercased() ?? "")
        }
        if held.isEmpty {
            for entry in incoming where entry.ordinal >= 1 {
                try connection.execute("""
                    INSERT INTO paper_references
                        (source_id, ordinal, label, entry_text, title, authors, journal, year, doi, url, link_origin, catalog_checked_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(source_id, ordinal) DO NOTHING
                """, [
                    .text(sourceID), .integer(Int64(entry.ordinal)), .text(entry.label), .text(entry.text), .text(entry.title),
                    .text(entry.authors), .text(entry.journal), .text(entry.year), .text(entry.doi), .text(entry.url),
                    .text(entry.origin), .real(entry.catalogCheckedAt?.timeIntervalSinceReferenceDate), .real(now),
                ])
            }
            guard !incoming.isEmpty else { return }
            let authored = incoming.contains { $0.origin == PaperReference.LinkOrigin.agent.rawValue } ? "agent" : "app"
            try connection.execute("""
                INSERT INTO paper_reference_reads (source_id, state, enqueued_at, parser_version, read_at, authored_by)
                VALUES (?, 'read', ?, ?, ?, ?)
                ON CONFLICT(source_id) DO UPDATE SET state = 'read', attempt_count = 0, last_error = NULL,
                    parser_version = excluded.parser_version, read_at = excluded.read_at, authored_by = excluded.authored_by
            """, [.text(sourceID), .real(now), .integer(Int64(PaperReferenceParser.version)), .real(now), .text(authored)])
        } else {
            var byKey: [String: [Int]] = [:]
            for entry in held { byKey[PaperReferenceIdentity.leadKey(of: entry.text), default: []].append(entry.ordinal) }
            for entry in incoming where linked(entry) {
                guard let ordinals = byKey[PaperReferenceIdentity.leadKey(of: entry.text)], ordinals.count == 1,
                      let mine = held.first(where: { $0.ordinal == ordinals[0] }), mine.url == nil else { continue }
                try connection.execute("""
                    UPDATE paper_references SET title = COALESCE(?, title), authors = COALESCE(?, authors),
                        journal = COALESCE(?, journal), year = COALESCE(?, year), doi = ?, url = ?, link_origin = ?,
                        catalog_checked_at = COALESCE(?, catalog_checked_at), updated_at = ?
                    WHERE source_id = ? AND ordinal = ? AND url IS NULL
                """, [
                    .text(entry.title), .text(entry.authors), .text(entry.journal), .text(entry.year), .text(entry.doi), .text(entry.url),
                    .text(entry.origin), .real(entry.catalogCheckedAt?.timeIntervalSinceReferenceDate), .real(now),
                    .text(sourceID), .integer(Int64(mine.ordinal)),
                ])
            }
        }
        try connection.execute("""
            UPDATE paper_reference_reads SET
                entry_count = (SELECT COUNT(*) FROM paper_references WHERE source_id = ?),
                linked_count = (SELECT COUNT(*) FROM paper_references WHERE source_id = ? AND url IS NOT NULL)
            WHERE source_id = ?
        """, [.text(sourceID), .text(sourceID), .text(sourceID)])
    }

    /// A chapter whose record names its pages of its book's file (`book_sources.page_start`).
    static func isPageRangeChapter(sourceID: String, connection: SQLiteConnection) throws -> Bool {
        try connection.scalarInteger(
            "SELECT COUNT(*) FROM book_sources WHERE source_id = ? AND page_start IS NOT NULL", [.text(sourceID)]
        ) == 1
    }

    /// Where this Mac already keeps the book file `hash` names: a chapter that reads it, with the bytes
    /// checked when they were installed or published. Nil when no chapter here has it yet.
    static func installedBookFile(hash: String, connection: SQLiteConnection) throws -> String? {
        try connection.scalarText("""
            SELECT f.local_path FROM source_files f
            JOIN book_sources bs ON bs.source_id = f.source_id
            WHERE f.role = ? AND json_extract(f.file_ref, '$.hash') = ?
              AND COALESCE(f.local_path, '') != '' AND bs.page_start IS NOT NULL AND bs.local_file_path = f.local_path
            LIMIT 1
        """, [.text(pdfRole), .text(hash)])
    }

    /// Points a chapter of a book kept as one file at the book's file on this Mac.
    static func pointChapter(sourceID: String, at path: String, connection: SQLiteConnection) throws {
        try connection.execute(
            "UPDATE book_sources SET local_file_path = ? WHERE source_id = ? AND page_start IS NOT NULL",
            [.text(path), .text(sourceID)]
        )
        try connection.execute(
            "UPDATE source_files SET local_path = ? WHERE source_id = ? AND role = ?", [.text(path), .text(sourceID), .text(pdfRole)]
        )
    }

    /// The satellite reader's half for `pdf`: the file the reader wrote is the paper's file, unless this Mac
    /// has one by now, or the book's file a chapter is pages of. `installedPath` is relative to the content
    /// roots.
    static func receivedPDF(_ body: Data, installedPath: String, sourceID: String, connection: SQLiteConnection) throws -> Bool {
        var waiting = try self.waiting(sourceID: sourceID, connection: connection)
        guard let wanted = waiting[pdfRole].flatMap(FileRef.init(json:)), wanted.hash == SyncIdentity.sha256Hex(body) else { return false }
        if try isPageRangeChapter(sourceID: sourceID, connection: connection) {
            try pointChapter(sourceID: sourceID, at: installedPath, connection: connection)
            waiting[pdfRole] = nil
            try save(waiting, sourceID: sourceID, connection: connection)
            return true
        }
        try connection.execute(
            "UPDATE papers SET local_file_path = ? WHERE source_id = ? AND COALESCE(local_file_path, '') = ''",
            [.text(installedPath), .text(sourceID)]
        )
        try connection.execute(
            "UPDATE source_files SET local_path = ? WHERE source_id = ? AND role = ?", [.text(installedPath), .text(sourceID), .text(pdfRole)]
        )
        // The paper's reference list is read from the file it now has, as a paper saved with a
        // file is (`enqueuePaperReferenceRead`): without this a paper whose PDF came from another
        // Mac had no citations to hover. A list another Mac published already counts as read,
        // and is left as it is.
        try connection.execute("""
            INSERT INTO paper_reference_reads (source_id, state, pdf_path, enqueued_at)
            SELECT source_id, 'queued', local_file_path, ? FROM papers
            WHERE source_id = ? AND local_file_path = ?
            ON CONFLICT(source_id) DO NOTHING
        """, [.real(Date().timeIntervalSinceReferenceDate), .text(sourceID), .text(installedPath)])
        waiting[pdfRole] = nil
        try save(waiting, sourceID: sourceID, connection: connection)
        return true
    }
}

extension KnowledgeStore {
    /// Where the reader writes a PDF it fetched, unless a test stands in for the content root.
    @TaskLocal static var installedSourceFileRootOverride: URL?

    /// The sources whose record says another device finished their ingestion (`Source.ingest` arrived `ready`,
    /// kept in `source_wire_fields.lossy_json`), and which are `ready` here. The automatic sweeps that look for
    /// unprocessed sources leave these alone: the work is done, and its satellites are on their way.
    func sourceIDsIngestedOnAnotherDevice() throws -> Set<String> {
        var ids = Set<String>()
        try query("""
            SELECT w.source_id FROM source_wire_fields w JOIN sources s ON s.id = w.source_id
            WHERE s.state = 'ready' AND json_extract(w.lossy_json, '$.ingest.wire.state') = 'ready'
        """, []) { row in
            if let id = row.text(0) { ids.insert(id) }
        }
        return ids
    }

    /// One bounded pass over the sources a Mac already holds as `ready` from another device (the records
    /// applied before this Mac knew how to take their work, and any whose satellite arrived after the
    /// record): attests the papers, queues the text and PDF the sources still lack, and records the clean-up
    /// of text this Mac already stores. Set-based and cheap once nothing is left; each source leaves the
    /// selection with the row it gets, so repeating the call until it returns less than `limit` drains it.
    /// Under the apply guard, so nothing is sent back. Generation 2 only. Returns the sources it handled.
    @discardableResult
    func adoptSyncedSources(limit: Int = 50) throws -> Int {
        return try replica.apply { _ in
            var handled = 0
            try execute("""
                UPDATE papers SET paper_ingestion_method = ?
                WHERE paper_ingestion_method IS NULL
                  AND EXISTS (
                      SELECT 1 FROM sources s JOIN source_wire_fields w ON w.source_id = s.id
                      WHERE s.id = papers.source_id AND s.state = 'ready'
                        AND json_extract(w.lossy_json, '$.ingest.wire.state') = 'ready'
                  )
            """, [.text(PaperIngestionMethod.synced.rawValue)])
            handled += changedRowCount

            // The text and PDF a ready source's pointers name and this Mac lacks.
            var wishes: [(id: String, text: String?, pdf: String?, figures: String?, references: String?)] = []
            try query("""
                SELECT s.id,
                       (SELECT f.file_ref FROM source_files f WHERE f.source_id = s.id AND f.role = 'text'),
                       (SELECT f.file_ref FROM source_files f WHERE f.source_id = s.id AND f.role = 'pdf'),
                       (SELECT d.file_ref FROM source_derived d WHERE d.source_id = s.id AND d.kind = 'figures'),
                       (SELECT d.file_ref FROM source_derived d WHERE d.source_id = s.id AND d.kind = 'references')
                FROM sources s
                WHERE s.team_id IS NULL AND s.status = 'active' AND s.state = 'ready'
                  AND NOT EXISTS (SELECT 1 FROM ck_backfill_queue q WHERE q.kind = ? AND q.target = s.id)
                  AND (
                      (EXISTS (SELECT 1 FROM source_files f WHERE f.source_id = s.id AND f.role = 'text'
                               AND json_extract(f.file_ref, '$.heldBy') IS NULL)
                       AND NOT EXISTS (SELECT 1 FROM source_content c WHERE c.source_id = s.id))
                   OR (s.source_type = 'paper'
                       AND EXISTS (SELECT 1 FROM source_files f WHERE f.source_id = s.id AND f.role = 'pdf'
                                   AND json_extract(f.file_ref, '$.heldBy') IS NULL)
                       AND COALESCE((SELECT p.local_file_path FROM papers p WHERE p.source_id = s.id), '') = '')
                   OR (s.source_type = 'paper'
                       AND EXISTS (SELECT 1 FROM source_derived d WHERE d.source_id = s.id AND d.kind = 'figures'
                                   AND json_extract(d.file_ref, '$.heldBy') IS NULL)
                       AND NOT EXISTS (SELECT 1 FROM paper_figures g WHERE g.source_id = s.id))
                   OR (s.source_type = 'paper'
                       AND EXISTS (SELECT 1 FROM source_derived d WHERE d.source_id = s.id AND d.kind = 'references'
                                   AND json_extract(d.file_ref, '$.heldBy') IS NULL)
                       AND NOT EXISTS (SELECT 1 FROM paper_references r WHERE r.source_id = s.id))
                  )
                LIMIT ?
            """, [.text(InboundSourceFiles.queueKind), .integer(Int64(limit))]) { row in
                if let id = row.text(0) { wishes.append((id, row.text(1), row.text(2), row.text(3), row.text(4))) }
            }
            for wish in wishes {
                var waiting: [String: SyncJSON] = [:]
                let isPaper = try scalarText("SELECT source_type FROM sources WHERE id = ?", [.text(wish.id)]) == "paper"
                if let text = ArtifactBody.fileRef(wish.text), text.heldBy == nil,
                   try InboundSourceFiles.localTextHash(sourceID: wish.id, connection: self) == nil {
                    waiting[InboundSourceFiles.textRole] = text.value
                }
                if isPaper, let pdf = ArtifactBody.fileRef(wish.pdf), pdf.heldBy == nil {
                    waiting[InboundSourceFiles.pdfRole] = pdf.value
                }
                if isPaper, let figures = ArtifactBody.fileRef(wish.figures), figures.heldBy == nil,
                   try scalarInteger("SELECT COUNT(*) FROM paper_figures WHERE source_id = ?", [.text(wish.id)]) == 0 {
                    waiting[InboundSourceFiles.figuresRole] = figures.value
                }
                if isPaper, let references = ArtifactBody.fileRef(wish.references), references.heldBy == nil,
                   try scalarInteger("SELECT COUNT(*) FROM paper_references WHERE source_id = ?", [.text(wish.id)]) == 0 {
                    waiting[InboundSourceFiles.referencesRole] = references.value
                }
                try InboundSourceFiles.save(waiting, sourceID: wish.id, connection: self)
                handled += 1
            }

            // Text this Mac already stores for a source another device finished: its clean-up is that
            // device's, so it is recorded rather than queued. A source this Mac owes a clean-up (its own
            // queue says so) keeps it.
            var adoptable: [(id: String, type: String)] = []
            try query("""
                SELECT s.id, s.source_type FROM sources s JOIN source_wire_fields w ON w.source_id = s.id
                WHERE s.state = 'ready' AND s.status = 'active' AND s.source_type IN ('paper', 'article', 'manual', 'unclassified')
                  AND json_extract(w.lossy_json, '$.ingest.wire.state') = 'ready'
                  AND EXISTS (SELECT 1 FROM source_content c WHERE c.source_id = s.id AND TRIM(c.content) != '')
                  AND NOT EXISTS (SELECT 1 FROM paper_content_preparations p WHERE p.source_id = s.id)
                  AND NOT EXISTS (SELECT 1 FROM article_content_preparations a WHERE a.source_id = s.id)
                  AND NOT EXISTS (SELECT 1 FROM canonical_content_cleanup_queue q WHERE q.source_id = s.id)
                LIMIT ?
            """, [.integer(Int64(limit))]) { row in
                if let id = row.text(0), let type = row.text(1) { adoptable.append((id, type)) }
            }
            for source in adoptable {
                if let text = try scalarText("SELECT content FROM source_content WHERE source_id = ?", [.text(source.id)]),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try InboundSourceFiles.recordCleanedText(sourceID: source.id, localType: source.type, text: text, replacing: false, connection: self)
                }
                handled += 1
            }
            return handled
        }
    }
}

// MARK: - Publishing what this Mac made

/// The satellites a source needs uploaded, read off the rows: the bodies, where each came from and the
/// pointer the replica holds for it (kept when it names the same bytes, so nothing is uploaded twice).
struct SourcePublishPlan: Sendable {
    struct Item: Sendable {
        let map: SourceLocalSatellite.Map
        let role: String
        let mime: String
        let encoding: BlobStore.Encoding
        let body: Data
        let input: String?
        let localPath: String?
        let keeping: FileRef?
        /// Who the bytes are uploaded under, when not the source (`SourceLocalSatellite.owner`).
        var owner: (id: String, type: SyncRecordType)? = nil
    }

    let sourceID: String
    let items: [Item]
    /// When the source was queued, as read before its rows: a change after that stamps the row again, and
    /// the pointing leaves a row stamped since on the queue (`pointPublishedSourceFiles`).
    var queuedAt: Double? = nil
}

extension KnowledgeStore {
    static let sourcePublishKind = "sourcePublish"

    /// Queues the learner's own `ready` sources that hold text, or a paper's PDF, that no pointer names yet
    /// and that owe no clean-up: everything ingested after the activation, whose satellites the activation's
    /// queue (`sourceFiles`) never covered. Without this a source ingested here reached another Mac as a `ready` record and
    /// nothing else, and that Mac ran the ingestion again. Set-based over primary keys; empty once every
    /// source has its pointers. Generation 2 only. Returns the sources it queued.
    @discardableResult
    func queueUnpublishedSourceFiles(limit: Int = 200) throws -> Int {
        var ids: [String] = []
        try query("""
            SELECT s.id FROM sources s
            WHERE s.team_id IS NULL AND s.wire_key = s.id AND s.status = 'active' AND s.state = 'ready'
              AND NOT EXISTS (SELECT 1 FROM ck_backfill_queue q WHERE q.kind IN (?, ?) AND q.target = s.id)
              -- A text still owed its clean-up is the raw extraction: another Mac would record it as the
              -- cleaned text. The clean-up's own write queues the source again (`invalidateCanonicalContentIndexes`).
              AND NOT EXISTS (SELECT 1 FROM canonical_content_cleanup_queue cq WHERE cq.source_id = s.id)
              AND (
                  (EXISTS (SELECT 1 FROM source_content c WHERE c.source_id = s.id)
                   AND NOT EXISTS (SELECT 1 FROM source_files f WHERE f.source_id = s.id AND f.role = 'text'))
               OR (s.source_type = 'paper'
                   AND LOWER(COALESCE((SELECT p.local_file_path FROM papers p WHERE p.source_id = s.id), '')) LIKE '%.pdf'
                   AND NOT EXISTS (SELECT 1 FROM source_files f WHERE f.source_id = s.id AND f.role = 'pdf'))
                  -- A paper whose reference list this Mac read, or an assistant filled, and no pointer names yet.
               OR (s.source_type = 'paper'
                   AND EXISTS (SELECT 1 FROM paper_references r WHERE r.source_id = s.id)
                   AND NOT EXISTS (SELECT 1 FROM source_derived d WHERE d.source_id = s.id AND d.kind = 'references'))
                  -- A chapter of a book kept as one file whose pointer does not yet name the book's file.
               OR (s.source_type = 'book'
                   AND EXISTS (SELECT 1 FROM book_sources bs WHERE bs.source_id = s.id AND bs.page_start IS NOT NULL
                               AND LOWER(COALESCE(bs.local_file_path, '')) LIKE '%.pdf')
                   AND NOT EXISTS (SELECT 1 FROM source_files f WHERE f.source_id = s.id AND f.role = 'pdf'
                                   AND json_extract(f.file_ref, '$.owner') != s.id))
              )
            ORDER BY s.date_added DESC
            LIMIT ?
        """, [.text(Self.sourcePublishKind), .text(Self.sourceFilesBackfillKind), .integer(Int64(limit))]) { row in
            if let id = row.text(0) { ids.append(id) }
        }
        for id in ids { try queueSourceFilesRefresh(sourceID: id) }
        return ids.count
    }

    /// Queues one source for publishing again: its text, PDF or a derived output changed. A source already
    /// queued is stamped again with its tries cleared, since what it holds is new: a publish whose upload
    /// was under way read the rows before this change, and the new stamp keeps the source on the queue when
    /// that publish points it (`pointPublishedSourceFiles`). Until 2026-10-13 a source already queued was
    /// left as it was, so a change made while its publish was in flight was dropped with the row, and its
    /// pointer named the text from before the change on every other device.
    func queueSourceFilesRefresh(sourceID: String) throws {
        try execute("""
            INSERT INTO ck_backfill_queue (kind, target, enqueued_at) VALUES (?, ?, ?)
            ON CONFLICT(kind, target) DO UPDATE SET enqueued_at = excluded.enqueued_at, attempts = 0, last_error = NULL
        """, [.text(Self.sourcePublishKind), .text(sourceID), .real(Date().timeIntervalSinceReferenceDate)])
    }

    /// Queues a source whose satellites are already up to be published again, after a body made from its
    /// text (its Listen text, review guide or walkthrough) was made again here. A source with no pointer yet
    /// is left to the sweep (`queueUnpublishedSourceFiles`), which publishes every body at once, and a text
    /// still owed its clean-up waits for the clean-up's write, which queues it.
    func queuePublishedSourceFilesRefresh(sourceID: String) throws {
        guard try scalarInteger("""
            SELECT EXISTS (SELECT 1 FROM source_files WHERE source_id = ?)
               AND NOT EXISTS (SELECT 1 FROM canonical_content_cleanup_queue WHERE source_id = ?)
        """, [.text(sourceID), .text(sourceID)]) == 1 else { return }
        try queueSourceFilesRefresh(sourceID: sourceID)
    }

    /// The queued sources still worth trying, oldest first; one that failed five times waits for a later build.
    func dueSourcePublishItems(limit: Int) throws -> [(id: Int64, source: String)] {
        var items: [(id: Int64, source: String)] = []
        try query(
            "SELECT id, target FROM ck_backfill_queue WHERE kind = ? AND attempts < 5 ORDER BY attempts, id LIMIT ?",
            [.text(Self.sourcePublishKind), .integer(Int64(limit))]
        ) { row in
            if let id = row.integer(0), let source = row.text(1) { items.append((id, source)) }
        }
        return items
    }

    /// What to upload for a source, nil when it is no longer the learner's own `ready` source. Reads the file
    /// bodies as mapped data, so a PDF is paged in where it is hashed and uploaded, not here.
    func sourcePublishPlan(sourceID: String) throws -> SourcePublishPlan? {
        guard try scalarInteger("""
            SELECT EXISTS(SELECT 1 FROM sources s WHERE s.id = ? AND s.team_id IS NULL AND s.wire_key = s.id AND s.state = 'ready')
        """, [.text(sourceID)]) == 1 else { return nil }
        // Read before the rows, so a change made from here on stamps the row after it.
        var queuedAt: Double?
        try query(
            "SELECT enqueued_at FROM ck_backfill_queue WHERE kind = ? AND target = ?", [.text(Self.sourcePublishKind), .text(sourceID)]
        ) { queuedAt = $0.real(0) }
        let satellites = try SourceSatelliteRoles.localSatellites(sourceID: sourceID, connection: self, resolve: {
            Self.sourceFileLocationOverride?($0) ?? URL(fileURLWithPath: StorageService.absoluteSourcePath($0))
        })
        var items: [SourcePublishPlan.Item] = []
        for satellite in satellites {
            let table = satellite.map == .files ? "source_files" : "source_derived"
            let element = satellite.map == .files ? "role" : "kind"
            var held = ArtifactBody.fileRef(try scalarText(
                "SELECT file_ref FROM \(table) WHERE source_id = ? AND \(element) = ?", [.text(sourceID), .text(satellite.role)]
            ))
            // A book's file another chapter already put up is kept as it is, not uploaded again.
            if let owner = satellite.owner, held?.owner != owner.id {
                held = ArtifactBody.fileRef(try scalarText("""
                    SELECT file_ref FROM \(table) WHERE \(element) = ? AND json_extract(file_ref, '$.owner') = ? LIMIT 1
                """, [.text(satellite.role), .text(owner.id)]))
            }
            items.append(SourcePublishPlan.Item(
                map: satellite.map, role: satellite.role, mime: satellite.mime, encoding: satellite.encoding, body: satellite.body,
                input: satellite.input, localPath: satellite.localPath, keeping: held, owner: satellite.owner
            ))
        }
        return SourcePublishPlan(sourceID: sourceID, items: items, queuedAt: queuedAt)
    }

    /// Points the source at the satellites that are now on the server, as ordinary writes the outbox sends
    /// (bytes before pointer: this runs after every upload was acknowledged), records the text's hash as
    /// `contentHash`, gives a PDF its `file:` work key, and takes the source off the queue, unless it was queued
    /// again after `queuedAt` (the plan's stamp): then what it points at is already behind the rows, and the
    /// source stays queued to be published again. Nil takes it off whatever its stamp.
    func pointPublishedSourceFiles(
        sourceID: String, files: [(map: SourceLocalSatellite.Map, file: FileRef, localPath: String?)], queuedAt: Double? = nil
    ) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            for item in files {
                let table = item.map == .files ? "source_files" : "source_derived"
                let element = item.map == .files ? "role" : "kind"
                try execute("""
                    INSERT INTO \(table) (source_id, \(element), file_ref, local_path) VALUES (?, ?, ?, ?)
                    ON CONFLICT(source_id, \(element)) DO UPDATE SET file_ref = excluded.file_ref, local_path = excluded.local_path
                """, [.text(sourceID), .text(item.file.role), .text(ArtifactBody.text(item.file)), .text(item.localPath)])
                if item.map == .files, item.file.role == InboundSourceFiles.textRole {
                    try execute("""
                        INSERT INTO source_wire_fields (source_id, content_hash) VALUES (?, ?)
                        ON CONFLICT(source_id) DO UPDATE SET content_hash = excluded.content_hash
                    """, [.text(sourceID), .text(item.file.hash)])
                }
                // A book's file names the book, never one chapter: a `file:` key every chapter held would
                // make them one source to duplicate resolution.
                if item.map == .files, item.file.role == InboundSourceFiles.pdfRole, item.file.owner == sourceID {
                    try execute(
                        "INSERT INTO source_work_keys (source_id, work_key) VALUES (?, ?) ON CONFLICT(source_id, work_key) DO NOTHING",
                        [.text(sourceID), .text("file:" + item.file.hash)]
                    )
                }
            }
            try execute(
                "DELETE FROM ck_backfill_queue WHERE kind = ? AND target = ? AND (? IS NULL OR enqueued_at = ?)",
                [.text(Self.sourcePublishKind), .text(sourceID), .real(queuedAt), .real(queuedAt)]
            )
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func failSourcePublish(queueID: Int64, message: String) throws {
        try execute("UPDATE ck_backfill_queue SET attempts = attempts + 1, last_error = ? WHERE id = ?", [.text(message), .integer(queueID)])
    }
}

/// Uploads what `queueUnpublishedSourceFiles` queued, a source at a time, off the main actor: every body
/// first, then the pointers (rule 2: bytes before pointer), then a nudge so the outbox sends them. Runs after
/// a round on the Mac whose sends are not held, and only while the engine's record backlog is under 200, so
/// satellites never hold small records back (D43). A failure that says nothing about the source (offline,
/// rate limited, the iCloud quota) stops the run without spending the source's attempts.
struct SourceFilePublisher: Sendable {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "SourceFilePublisher")

    let store: MacPrivateSyncStore
    let blobs: BlobStore
    let pendingCount: @Sendable () async -> Int
    let wrote: @Sendable () async -> Void
    var backlogLimit = 200
    var batch = 10
    var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }

    /// Returns the sources published.
    @discardableResult
    func run() async -> Int {
        var published = 0
        var tried = Set<Int64>()
        do {
            guard let zone = try await store.perform({ try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: $0) }) else { return 0 }
            _ = try await store.onStore { try $0.queueUnpublishedSourceFiles() }
            let batch = self.batch
            while true {
                let due = try await store.onStore { try $0.dueSourcePublishItems(limit: batch) }.filter { !tried.contains($0.id) }
                guard !due.isEmpty else { break }
                for item in due {
                    tried.insert(item.id)
                    for _ in 0..<60 where await pendingCount() >= backlogLimit { await sleep(1) }
                    if try await publish(item, zone: zone) { published += 1 }
                }
                await Task.yield()
            }
        } catch {
            Self.logger.notice("Publishing source files stopped for now: \(String(describing: error), privacy: .public)")
        }
        if published > 0 { await wrote() }
        return published
    }

    /// True when the source's satellites are up and its pointers written. Throws only for a failure that
    /// says nothing about the source.
    private func publish(_ item: (id: Int64, source: String), zone: BlobZone) async throws -> Bool {
        let source = item.source
        guard let plan = try await store.onStore({ try $0.sourcePublishPlan(sourceID: source) }) else {
            try await store.onStore { try $0.execute("DELETE FROM ck_backfill_queue WHERE id = ?", [.integer(item.id)]) }
            return false
        }
        do {
            var uploaded: [(map: SourceLocalSatellite.Map, file: FileRef, localPath: String?)] = []
            for satellite in plan.items {
                let file = try await blobs.upload(
                    satellite.body, owner: satellite.owner?.id ?? source, ownerType: satellite.owner?.type ?? .source,
                    role: satellite.role, mime: satellite.mime,
                    encoding: satellite.encoding, into: zone, keeping: satellite.keeping,
                    gen: satellite.input.map { SyncJSON.object(["input": .string($0)]) }
                )
                uploaded.append((satellite.map, file, satellite.localPath))
            }
            let finished = uploaded
            let queuedAt = plan.queuedAt
            try await store.onStore { try $0.pointPublishedSourceFiles(sourceID: source, files: finished, queuedAt: queuedAt) }
            return true
        } catch {
            if Self.isTransient(error) { throw error }
            let message = String(describing: error)
            try await store.onStore { try $0.failSourcePublish(queueID: item.id, message: message) }
            return false
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        var cloud = error as? CloudError
        if let blob = error as? BlobStoreError, case .failed(let inner) = blob { cloud = inner }
        guard let code = cloud?.code else { return false }
        switch code {
        case .networkUnavailable, .networkFailure, .notAuthenticated, .requestRateLimited, .serviceUnavailable, .zoneBusy, .quotaExceeded:
            return true
        default:
            return false
        }
    }
}
