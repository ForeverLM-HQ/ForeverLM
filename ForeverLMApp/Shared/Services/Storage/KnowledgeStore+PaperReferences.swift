import Foundation
import SQLite3

/// Where a paper stands in having its reference list read (schema 174, `paper_reference_reads`).
struct PaperReferenceReadState: Equatable, Sendable {
    enum State: String, Sendable {
        /// Owed a read, or begun and not finished (a catalog that did not answer).
        case queued
        /// Read, whatever it found. An empty list is a read too: a scanned paper has none to find.
        case read
    }

    let sourceID: String
    let state: State
    /// The file the list was read from (or will be), as the source stores it.
    let pdfPath: String?
    let parserVersion: Int
    let attemptCount: Int
    let lastError: String?
    let readAt: Date?
    let entryCount: Int
    let linkedCount: Int
    /// "app" for a list the app read, "agent" for one an assistant saved.
    let authoredBy: String?
}

/// A paper whose list is owed a read.
struct PaperReferenceReadCandidate: Equatable, Sendable {
    let sourceID: String
    let attemptCount: Int
}

/// Persistence for papers' reference lists (schema 174).
///
/// Two local-only tables. `paper_references` holds each entry of a paper's list with the link
/// the entry resolved to; `paper_reference_reads` is both the durable queue of papers owed a
/// read and the record of what each read found. Neither syncs: a list is derived from the
/// paper's own PDF by rule and by free catalogs, so a Mac that opens the paper makes it for
/// itself, and an assistant's saved entries are the one thing a second Mac would lack until it
/// reads the paper. The iPhone, which does no ingestion, shows no list until a synced record
/// carries it (a follow-up that needs a CloudKit record type, not done here).
extension KnowledgeStore {

    static let paperReferencesSchemaVersion: Int32 = 174

    /// A paper whose catalogs did not answer this many reads in a row is left alone. Its row
    /// stays as the record of what was tried, and an assistant can still fill the list.
    static let maximumPaperReferenceReadAttempts = 5

    // MARK: Schema

    func createPaperReferenceTables() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS paper_references (
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL CHECK(ordinal >= 1),
                label TEXT NOT NULL,
                entry_text TEXT NOT NULL,
                title TEXT,
                authors TEXT,
                journal TEXT,
                year TEXT,
                doi TEXT,
                url TEXT,
                link_origin TEXT NOT NULL DEFAULT 'none',
                catalog_checked_at REAL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (source_id, ordinal)
            ) WITHOUT ROWID
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS paper_reference_reads (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                state TEXT NOT NULL,
                pdf_path TEXT,
                parser_version INTEGER NOT NULL DEFAULT 0,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                read_at REAL,
                entry_count INTEGER NOT NULL DEFAULT 0,
                linked_count INTEGER NOT NULL DEFAULT 0,
                authored_by TEXT
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_paper_reference_reads_queue
            ON paper_reference_reads(state, attempt_count, enqueued_at)
        """)
    }

    /// Fails when tables of another shape were there before, so the migration rolls back.
    func probePaperReferenceTables() throws {
        try query("""
            SELECT source_id, ordinal, label, entry_text, title, authors, journal, year, doi, url,
                   link_origin, catalog_checked_at, updated_at
            FROM paper_references LIMIT 0
        """) { _ in }
        try query("""
            SELECT source_id, state, pdf_path, parser_version, enqueued_at, attempt_count, last_error,
                   read_at, entry_count, linked_count, authored_by
            FROM paper_reference_reads LIMIT 0
        """) { _ in }
    }

    func holdsPaperReferenceTables() throws -> Bool {
        try scalarInteger("""
            SELECT COUNT(*) FROM sqlite_master
            WHERE type = 'table' AND name IN ('paper_references', 'paper_reference_reads')
        """) == 2
    }

    /// Schema 174: every paper with a file is queued once for the post-launch read of its
    /// reference list (`PaperReferenceLinkService`). One set-based INSERT over `papers`, ids
    /// only: the migration opens no PDF and asks no catalog.
    @discardableResult
    func enqueuePaperReferenceReadsForExistingPapers() throws -> Int {
        try execute("""
            INSERT INTO paper_reference_reads (source_id, state, enqueued_at)
            SELECT p.source_id, 'queued', ?
            FROM papers p
            JOIN sources s ON s.id = p.source_id
            WHERE COALESCE(p.local_file_path, '') <> ''
            ON CONFLICT(source_id) DO NOTHING
        """, [.real(Date().timeIntervalSinceReferenceDate)])
        return try paperReferenceReadQueueCount()
    }

    // MARK: Queue

    /// A paper saved with a file is owed a read when none was made from this file by this
    /// version of the parser. A row already read from the same file is left exactly as it is,
    /// so the save a reader makes on every page turn costs one indexed no-op.
    func enqueuePaperReferenceRead(sourceID: String, pdfPath: String) throws {
        try execute("""
            INSERT INTO paper_reference_reads (source_id, state, pdf_path, enqueued_at)
            VALUES (?, 'queued', ?, ?)
            ON CONFLICT(source_id) DO UPDATE SET
                state = 'queued',
                pdf_path = excluded.pdf_path,
                enqueued_at = excluded.enqueued_at,
                attempt_count = 0,
                last_error = NULL,
                entry_count = 0,
                linked_count = 0
            WHERE paper_reference_reads.pdf_path IS NOT excluded.pdf_path
               OR paper_reference_reads.parser_version < ?
        """, [
            .text(sourceID), .text(pdfPath), .real(Date().timeIntervalSinceReferenceDate),
            .integer(Int64(PaperReferenceParser.version)),
        ])
    }

    /// A source that is no longer a paper has no list.
    func dropPaperReferences(sourceID: String) throws {
        try execute("DELETE FROM paper_references WHERE source_id = ?", [.text(sourceID)])
        try execute("DELETE FROM paper_reference_reads WHERE source_id = ?", [.text(sourceID)])
    }

    /// The next papers to read, newest queued first (a paper just added before the backlog),
    /// least tried first.
    func paperReferenceReadCandidates(limit: Int) throws -> [PaperReferenceReadCandidate] {
        guard limit > 0 else { return [] }
        var candidates: [PaperReferenceReadCandidate] = []
        try query("""
            SELECT r.source_id, r.attempt_count
            FROM paper_reference_reads r
            JOIN papers p ON p.source_id = r.source_id
            JOIN sources s ON s.id = r.source_id
            WHERE r.state = 'queued' AND r.attempt_count < ? AND s.status = 'active'
            ORDER BY r.attempt_count ASC, r.enqueued_at DESC, r.source_id ASC
            LIMIT ?
        """, [.integer(Int64(Self.maximumPaperReferenceReadAttempts)), .integer(Int64(limit))]) { row in
            guard let sourceID = row.text(0) else { return }
            candidates.append(PaperReferenceReadCandidate(sourceID: sourceID, attemptCount: Int(row.integer(1) ?? 0)))
        }
        return candidates
    }

    func paperReferenceReadQueueCount() throws -> Int {
        Int(try scalarInteger(
            "SELECT COUNT(*) FROM paper_reference_reads WHERE state = 'queued' AND attempt_count < ?",
            [.integer(Int64(Self.maximumPaperReferenceReadAttempts))]
        ) ?? 0)
    }

    func paperReferenceReadState(sourceID: String) throws -> PaperReferenceReadState? {
        var found: PaperReferenceReadState?
        try query("""
            SELECT state, pdf_path, parser_version, attempt_count, last_error, read_at,
                   entry_count, linked_count, authored_by
            FROM paper_reference_reads WHERE source_id = ?
        """, [.text(sourceID)]) { row in
            guard let state = row.text(0).flatMap(PaperReferenceReadState.State.init(rawValue:)) else { return }
            found = PaperReferenceReadState(
                sourceID: sourceID,
                state: state,
                pdfPath: row.text(1),
                parserVersion: Int(row.integer(2) ?? 0),
                attemptCount: Int(row.integer(3) ?? 0),
                lastError: row.text(4),
                readAt: row.real(5).map(Date.init(timeIntervalSinceReferenceDate:)),
                entryCount: Int(row.integer(6) ?? 0),
                linkedCount: Int(row.integer(7) ?? 0),
                authoredBy: row.text(8)
            )
        }
        return found
    }

    /// Ends a read: `failure` nil finishes it; a failure (a catalog that did not answer) counts
    /// an attempt and leaves the paper queued until it has had its attempts. The counts are
    /// taken from the entries as stored.
    func finishPaperReferenceRead(sourceID: String, pdfPath: String?, failure: String?, authoredBy: String) throws {
        try execute("""
            INSERT INTO paper_reference_reads (source_id, state, enqueued_at)
            VALUES (?, 'queued', ?)
            ON CONFLICT(source_id) DO NOTHING
        """, [.text(sourceID), .real(Date().timeIntervalSinceReferenceDate)])
        let attempts = Int(try scalarInteger(
            "SELECT attempt_count FROM paper_reference_reads WHERE source_id = ?", [.text(sourceID)]
        ) ?? 0)
        let nextAttempts = failure == nil ? 0 : attempts + 1
        let finished = failure == nil || nextAttempts >= Self.maximumPaperReferenceReadAttempts
        try execute("""
            UPDATE paper_reference_reads SET
                state = ?,
                pdf_path = COALESCE(?, pdf_path),
                parser_version = ?,
                attempt_count = ?,
                last_error = ?,
                read_at = ?,
                entry_count = (SELECT COUNT(*) FROM paper_references WHERE source_id = ?),
                linked_count = (SELECT COUNT(*) FROM paper_references WHERE source_id = ? AND url IS NOT NULL),
                authored_by = ?
            WHERE source_id = ?
        """, [
            .text(finished ? PaperReferenceReadState.State.read.rawValue : PaperReferenceReadState.State.queued.rawValue),
            .text(pdfPath),
            .integer(Int64(PaperReferenceParser.version)),
            .integer(Int64(nextAttempts)),
            .text(failure.map { String($0.prefix(500)) }),
            .real(Date().timeIntervalSinceReferenceDate),
            .text(sourceID), .text(sourceID),
            .text(authoredBy),
            .text(sourceID),
        ])
    }

    // MARK: Entries

    func loadPaperReferences(sourceID: String) throws -> [PaperReference] {
        var references: [PaperReference] = []
        try query("""
            SELECT ordinal, label, entry_text, title, authors, journal, year, doi, url,
                   link_origin, catalog_checked_at, updated_at
            FROM paper_references WHERE source_id = ? ORDER BY ordinal
        """, [.text(sourceID)]) { row in
            references.append(PaperReference(
                sourceID: sourceID,
                ordinal: Int(row.integer(0) ?? 0),
                label: row.text(1) ?? "",
                text: row.text(2) ?? "",
                title: row.text(3),
                authors: row.text(4),
                journal: row.text(5),
                year: row.text(6),
                doi: row.text(7),
                url: row.text(8),
                origin: row.text(9).flatMap(PaperReference.LinkOrigin.init(rawValue:)) ?? .none,
                catalogCheckedAt: row.real(10).map(Date.init(timeIntervalSinceReferenceDate:)),
                updatedAt: Date(timeIntervalSinceReferenceDate: row.real(11) ?? 0)
            ))
        }
        return references
    }

    /// Stores the list a read made, keeping what an earlier read already learned. An entry the
    /// stored list has under the same number and the same words keeps its link, its record and
    /// the date a catalog answered about it; one an assistant authored (`.agent`) is never
    /// replaced by a read; an entry the new read no longer finds is removed. One transaction:
    /// a quit half-way leaves the list as it was.
    func replacePaperReferenceList(sourceID: String, entries: [PaperReference]) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            let existing = Dictionary(
                try loadPaperReferences(sourceID: sourceID).map { ($0.ordinal, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let incoming = Set(entries.map(\.ordinal))
            for (ordinal, stored) in existing where !incoming.contains(ordinal) && stored.origin != .agent {
                try execute(
                    "DELETE FROM paper_references WHERE source_id = ? AND ordinal = ?",
                    [.text(sourceID), .integer(Int64(ordinal))]
                )
            }
            for entry in entries {
                if let stored = existing[entry.ordinal] {
                    if stored.origin == .agent { continue }
                    if PaperReferenceIdentity.leadKey(of: stored.text) == PaperReferenceIdentity.leadKey(of: entry.text) {
                        continue
                    }
                }
                try upsertPaperReference(entry)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Saves one entry, replacing whatever the list held under its number.
    func savePaperReference(_ reference: PaperReference) throws {
        try upsertPaperReference(reference)
    }

    /// The entries an assistant authored: each replaces the entry under its number, and with
    /// `replacing` the whole stored list goes first (a list read wrongly, rewritten). One
    /// transaction; the read record is marked finished and agent-authored.
    func savePaperReferencesAuthoredByAgent(
        sourceID: String,
        references: [PaperReference],
        replacing: Bool
    ) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            if replacing {
                try execute("DELETE FROM paper_references WHERE source_id = ?", [.text(sourceID)])
            }
            for reference in references { try upsertPaperReference(reference) }
            try finishPaperReferenceRead(sourceID: sourceID, pdfPath: nil, failure: nil, authoredBy: "agent")
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func upsertPaperReference(_ reference: PaperReference) throws {
        try execute("""
            INSERT INTO paper_references
                (source_id, ordinal, label, entry_text, title, authors, journal, year, doi, url,
                 link_origin, catalog_checked_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_id, ordinal) DO UPDATE SET
                label = excluded.label,
                entry_text = excluded.entry_text,
                title = excluded.title,
                authors = excluded.authors,
                journal = excluded.journal,
                year = excluded.year,
                doi = excluded.doi,
                url = excluded.url,
                link_origin = excluded.link_origin,
                catalog_checked_at = excluded.catalog_checked_at,
                updated_at = excluded.updated_at
        """, [
            .text(reference.sourceID),
            .integer(Int64(reference.ordinal)),
            .text(reference.label),
            .text(reference.text),
            .text(reference.title),
            .text(reference.authors),
            .text(reference.journal),
            .text(reference.year),
            .text(reference.doi),
            .text(reference.url),
            .text(reference.origin.rawValue),
            .real(reference.catalogCheckedAt?.timeIntervalSinceReferenceDate),
            .real(reference.updatedAt.timeIntervalSinceReferenceDate),
        ])
    }
}
