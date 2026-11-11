import Foundation
import OSLog

/// The iPhone's own search index (docs/cloudkit-schema-design.md D27, §7.1, §8a), in its replica file
/// beside the index tables: SQLite FTS5 over every held source's metadata (title, authors, venue,
/// DOI, summary), extracted inside the apply that writes the Source as the index columns are, and
/// over the canonical text of its text set: the sources in its notebooks, the sources opened in the
/// last 30 days, the sources saved offline, and the whole library when the learner opts in. Never
/// synced: each device builds its own from the `text` satellites.
///
/// The FTS rows are keyed through two plain tables, so a record's metadata row and a source's text
/// row are found by key, never by scanning the FTS tables: `m_text_keys` (one row per held copy of a
/// source, with the hash of the `text` satellite that copy names) and `m_text_bodies` (one row per
/// source whose text is indexed, with the hash it was indexed from and when it was last indexed or
/// opened). A Source the replica forgets takes its metadata row with it (a trigger on `m_sources`).
enum MobileTextIndex {
    /// `ck_engine_state` scope of the metadata's version; a build that changes what is extracted moves
    /// it and the next open fills the metadata again from the held Source records.
    static let versionScope = "mobile.text.version"
    static let version = "1"
    /// Source records indexed again per transaction when the metadata is filled.
    static let fillBatch = 500
    /// How long an opened source's text stays searchable after it was last opened.
    static let openedWindow: TimeInterval = 30 * MemoryTutorScheduler.secondsPerDay

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MobileTextIndex")
    private static let tokenizer = "tokenize = 'unicode61 remove_diacritics 2'"

    static let schema = """
        CREATE TABLE IF NOT EXISTS m_text_keys (
            rowid INTEGER PRIMARY KEY,
            zone_key TEXT NOT NULL,
            source_id TEXT NOT NULL,
            text_hash TEXT,
            UNIQUE (zone_key, source_id)
        );
        CREATE INDEX IF NOT EXISTS idx_m_text_keys_source ON m_text_keys(source_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS m_source_meta_fts USING fts5(title, authors, venue, doi, summary, \(tokenizer));
        CREATE TABLE IF NOT EXISTS m_text_bodies (
            rowid INTEGER PRIMARY KEY,
            source_id TEXT NOT NULL UNIQUE,
            hash TEXT NOT NULL,
            indexed_at INTEGER NOT NULL
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS m_source_text_fts USING fts5(body, \(tokenizer));
        CREATE TRIGGER IF NOT EXISTS mobile_text_forget AFTER DELETE ON m_sources BEGIN
            DELETE FROM m_source_meta_fts WHERE rowid IN (SELECT rowid FROM m_text_keys WHERE zone_key = OLD.zone_key AND source_id = OLD.id);
            DELETE FROM m_text_keys WHERE zone_key = OLD.zone_key AND source_id = OLD.id;
        END;
        """

    /// Creates the tables and the trigger (the trigger again whenever `m_sources` was built anew).
    static func install(in connection: SQLiteConnection) throws {
        try connection.executeScript(schema)
    }

    // MARK: - Metadata, inside the apply

    /// Indexes a Source's metadata and the hash of its `text` satellite, inside the apply (or the
    /// reindex) that wrote its index row.
    static func index(_ envelope: SyncEnvelope, zoneKey: String, in connection: SQLiteConnection) throws {
        let fields = envelope.fields
        let textHash = fields["files"]?["text"].flatMap(FileRef.init(json:))?.hash
        try connection.execute("""
            INSERT INTO m_text_keys (zone_key, source_id, text_hash) VALUES (?, ?, ?)
            ON CONFLICT(zone_key, source_id) DO UPDATE SET text_hash = excluded.text_hash
        """, [.text(zoneKey), .text(envelope.id), .text(textHash)])
        guard let rowid = try connection.scalarInteger("SELECT rowid FROM m_text_keys WHERE zone_key = ? AND source_id = ?",
                                                       [.text(zoneKey), .text(envelope.id)]) else { return }
        let authors = fields["authors"]?.arrayValue?.compactMap(\.stringValue).joined(separator: "; ")
        try connection.execute("DELETE FROM m_source_meta_fts WHERE rowid = ?", [.integer(rowid)])
        try connection.execute("INSERT INTO m_source_meta_fts (rowid, title, authors, venue, doi, summary) VALUES (?, ?, ?, ?, ?, ?)", [
            .integer(rowid), .text(fields["title"]?.stringValue), .text(authors), .text(fields["venue"]?.stringValue),
            .text(fields["doi"]?.stringValue), .text(fields["summary"]?.stringValue),
        ])
    }

    /// Fills the metadata from the held Source records once per version: a replica made before this
    /// index existed, or by a build that extracted less. Bounded batches, resumable (the version moves
    /// only at the end). Runs where the replica opens, off the main actor.
    static func fillIfNeeded(_ replica: MobileReplica) throws {
        let connection = replica.connection
        let held = try replica.replica.engineState(versionScope).map { String(decoding: $0, as: UTF8.self) }
        guard held != version else { return }
        var after: Int64 = 0
        var total = 0
        while true {
            var batch: [(rowid: Int64, zoneKey: String, payload: Data)] = []
            try connection.query("""
                SELECT rowid, zone_key, payload FROM ck_records WHERE rowid > ? AND record_type = ? ORDER BY rowid LIMIT ?
            """, [.integer(after), .text(SyncRecordType.source.rawValue), .integer(Int64(fillBatch))]) { row in
                batch.append((row.integer(0) ?? 0, row.text(1) ?? "", row.blob(2) ?? Data()))
            }
            guard let last = batch.last else { break }
            try transaction(connection) {
                for record in batch {
                    guard let envelope = replica.decode(record.payload) else { continue }
                    try index(envelope, zoneKey: record.zoneKey, in: connection)
                }
            }
            after = last.rowid
            total += batch.count
        }
        try transaction(connection) {
            try prune(in: connection)
            try replica.replica.setEngineState(versionScope, Data(version.utf8))
        }
        if total > 0 { logger.info("Indexed the metadata of \(total) sources for search") }
    }

    /// Drops metadata rows whose Source the index no longer holds (left by an index rebuilt from scratch).
    static func prune(in connection: SQLiteConnection) throws {
        try connection.execute("""
            DELETE FROM m_source_meta_fts WHERE rowid IN (
                SELECT k.rowid FROM m_text_keys k WHERE NOT EXISTS (SELECT 1 FROM m_sources s WHERE s.zone_key = k.zone_key AND s.id = k.source_id)
            )
        """, [])
        try connection.execute("""
            DELETE FROM m_text_keys WHERE NOT EXISTS (SELECT 1 FROM m_sources s WHERE s.zone_key = m_text_keys.zone_key AND s.id = m_text_keys.source_id)
        """, [])
    }

    // MARK: - Text

    /// Indexes a source's canonical text, fetched from the `text` satellite whose hash it carries, or
    /// marks it opened again when that text is indexed already.
    static func store(text: String, sourceID: String, hash: String, now: Date, in connection: SQLiteConnection) throws {
        let at = Int64(now.timeIntervalSince1970 * 1_000)
        if try connection.scalarText("SELECT hash FROM m_text_bodies WHERE source_id = ?", [.text(sourceID)]) == hash {
            try connection.execute("UPDATE m_text_bodies SET indexed_at = ? WHERE source_id = ?", [.integer(at), .text(sourceID)])
            return
        }
        try connection.execute("""
            INSERT INTO m_text_bodies (source_id, hash, indexed_at) VALUES (?, ?, ?)
            ON CONFLICT(source_id) DO UPDATE SET hash = excluded.hash, indexed_at = excluded.indexed_at
        """, [.text(sourceID), .text(hash), .integer(at)])
        guard let rowid = try connection.scalarInteger("SELECT rowid FROM m_text_bodies WHERE source_id = ?", [.text(sourceID)]) else { return }
        try connection.execute("DELETE FROM m_source_text_fts WHERE rowid = ?", [.integer(rowid)])
        try connection.execute("INSERT INTO m_source_text_fts (rowid, body) VALUES (?, ?)", [.integer(rowid), .text(text)])
    }

    /// One source of the text set and the `text` satellite hash its preferred copy names (the learner's
    /// own `Catalog` copy before a space's).
    struct Wanted: Equatable, Sendable {
        let sourceID: String
        let hash: String
    }

    /// The text set (§2.3, §8a): every held source in a notebook (an active Entry of a notebook, any
    /// zone), every source this member read in the last 30 days (`ReadingState.lastReadAt`), every
    /// source saved offline, and every held source when `wholeLibrary`; only those whose copy names a
    /// `text` satellite.
    static func textSet(pinned: Set<String>, wholeLibrary: Bool, now: Date, in connection: SQLiteConnection) throws -> [Wanted] {
        let since = Int64((now.timeIntervalSince1970 - openedWindow) * 1_000)
        let chosen = """
            SELECT k.source_id, k.text_hash FROM m_text_keys k
            JOIN m_sources s ON s.zone_key = k.zone_key AND s.id = k.source_id AND s.merged_into IS NULL
            WHERE k.text_hash IS NOT NULL
            ORDER BY k.source_id, CASE k.zone_key WHEN ? THEN 0 ELSE 1 END, k.zone_key
        """
        var bestHash: [String: String] = [:]
        try connection.query(chosen, [.text(MobileProjection.catalogKey)]) { row in
            guard let id = row.text(0), let hash = row.text(1), bestHash[id] == nil else { return }
            bestHash[id] = hash
        }
        var wanted = Set<String>()
        if wholeLibrary {
            wanted = Set(bestHash.keys)
        } else {
            try connection.query("""
                SELECT item_id FROM m_entries WHERE container_kind = 'notebook' AND item_kind = 'source' AND state = 'active'
            """, []) { if let id = $0.text(0) { wanted.insert(id) } }
            try connection.query("""
                SELECT target_id FROM m_reading_states WHERE zone_key = ? AND target_kind = 'source' AND last_read_at >= ?
            """, [.text(MobileProjection.libraryKey), .integer(since)]) { if let id = $0.text(0) { wanted.insert(id) } }
            wanted.formUnion(pinned)
        }
        return wanted.sorted().compactMap { id in bestHash[id].map { Wanted(sourceID: id, hash: $0) } }
    }

    /// The text set's sources whose text is not indexed from the hash wanted now.
    static func missing(_ wanted: [Wanted], in connection: SQLiteConnection) throws -> [Wanted] {
        var indexed: [String: String] = [:]
        try connection.query("SELECT source_id, hash FROM m_text_bodies", []) { row in
            if let id = row.text(0), let hash = row.text(1) { indexed[id] = hash }
        }
        return wanted.filter { indexed[$0.sourceID] != $0.hash }
    }

    /// Drops the text of sources that left the text set and were not opened in the last 30 days, and of
    /// sources the phone no longer holds at all. Returns the bodies dropped.
    @discardableResult
    static func pruneText(keeping wanted: Set<String>, now: Date, in connection: SQLiteConnection) throws -> Int {
        let since = Int64((now.timeIntervalSince1970 - openedWindow) * 1_000)
        var dropped: [(rowid: Int64, sourceID: String)] = []
        try connection.query("""
            SELECT b.rowid, b.source_id, b.indexed_at,
                   EXISTS (SELECT 1 FROM m_text_keys k WHERE k.source_id = b.source_id) AS held
            FROM m_text_bodies b
        """, []) { row in
            guard let rowid = row.integer(0), let id = row.text(1) else { return }
            let held = row.integer(3) == 1
            let recent = (row.integer(2) ?? 0) >= since
            if !held || (!wanted.contains(id) && !recent) { dropped.append((rowid, id)) }
        }
        for body in dropped {
            try connection.execute("DELETE FROM m_source_text_fts WHERE rowid = ?", [.integer(body.rowid)])
            try connection.execute("DELETE FROM m_text_bodies WHERE rowid = ?", [.integer(body.rowid)])
        }
        return dropped.count
    }

    // MARK: - Search

    /// One source a search found: whether its text matched (not only its metadata), and the passage.
    struct Hit: Equatable, Sendable {
        let sourceID: String
        let inText: Bool
        let snippet: String?
    }

    /// The FTS5 query for what the learner typed: every word must match, the last as a prefix (they
    /// may still be typing it); nil when nothing searchable is left.
    static func matchExpression(_ query: String) -> String? {
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.enumerated().map { index, word in
            "\"\(word)\"" + (index == words.count - 1 ? "*" : "")
        }.joined(separator: " ")
    }

    /// The sources whose metadata or indexed text match `query`, best first: metadata matches (a
    /// title weighs most) before text-only ones, each set by FTS5's rank; one hit per source, merged
    /// duplicates never.
    static func search(_ query: String, limit: Int, in connection: SQLiteConnection) throws -> [Hit] {
        guard let match = matchExpression(query) else { return [] }
        var hits: [Hit] = []
        var seen = Set<String>()
        try connection.query("""
            SELECT k.source_id FROM m_source_meta_fts f
            JOIN m_text_keys k ON k.rowid = f.rowid
            JOIN m_sources s ON s.zone_key = k.zone_key AND s.id = k.source_id AND s.merged_into IS NULL
            WHERE m_source_meta_fts MATCH ? ORDER BY bm25(m_source_meta_fts, 10.0, 5.0, 2.0, 5.0, 1.0) LIMIT ?
        """, [.text(match), .integer(Int64(limit * 2))]) { row in
            guard let id = row.text(0), seen.insert(id).inserted else { return }
            hits.append(Hit(sourceID: id, inText: false, snippet: nil))
        }
        var text: [String: String] = [:]
        var order: [String] = []
        try connection.query("""
            SELECT b.source_id, snippet(m_source_text_fts, 0, '', '', '…', 16) FROM m_source_text_fts f
            JOIN m_text_bodies b ON b.rowid = f.rowid
            WHERE m_source_text_fts MATCH ? ORDER BY rank LIMIT ?
        """, [.text(match), .integer(Int64(limit))]) { row in
            guard let id = row.text(0) else { return }
            text[id] = row.text(1)
            order.append(id)
        }
        hits = hits.map { hit in text[hit.sourceID].map { Hit(sourceID: hit.sourceID, inText: true, snippet: $0) } ?? hit }
        for id in order where seen.insert(id).inserted {
            hits.append(Hit(sourceID: id, inText: true, snippet: text[id]))
        }
        return Array(hits.prefix(limit))
    }

    private static func transaction(_ connection: SQLiteConnection, _ body: () throws -> Void) throws {
        try connection.executeScript("BEGIN IMMEDIATE")
        do {
            try body()
            try connection.executeScript("COMMIT")
        } catch {
            try? connection.executeScript("ROLLBACK")
            throw error
        }
    }
}

/// Whether this phone indexes the text of its whole library, not only its text set (§8a: "whole
/// library opt-in"): a device's own choice, per CloudKit environment, never synced.
struct MobileTextIndexChoice: @unchecked Sendable {
    let defaults: UserDefaults
    let environment: MobileCloudKitEnvironment

    init(defaults: UserDefaults = .standard, environment: MobileCloudKitEnvironment = .current) {
        self.defaults = defaults
        self.environment = environment
    }

    private var key: DeviceKey<Bool> { Prefs.Families.wholeLibraryText.key(environment.rawValue) }

    var wholeLibrary: Bool {
        get { Preferences.withStorage(defaults) { Preferences.value(key) } }
        nonmutating set { Preferences.withStorage(defaults) { Preferences.set(newValue, for: key) } }
    }
}

/// Keeps the text index's text set current: after each settled round, the text of up to `budget`
/// sources that joined the set (or whose text changed) is fetched by name and indexed, and the text of
/// sources that left it is dropped. One pass at a time; the next round carries on.
actor MobileTextIndexer {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MobileTextIndex")

    let satellites: MobileSatellites
    private var running = false

    init(satellites: MobileSatellites) {
        self.satellites = satellites
    }

    /// Returns the sources whose text it indexed.
    @discardableResult
    func refresh(pinned: Set<String>, wholeLibrary: Bool, budget: Int = 40, now: Date = Date()) async -> Int {
        guard !running else { return 0 }
        running = true
        defer { running = false }
        let replica = satellites.projection.replica
        let missing: [MobileTextIndex.Wanted]
        do {
            missing = try await replica.read { replica in
                let connection = replica.connection
                let wanted = try MobileTextIndex.textSet(pinned: pinned, wholeLibrary: wholeLibrary, now: now, in: connection)
                try connection.executeScript("BEGIN IMMEDIATE")
                do {
                    try MobileTextIndex.pruneText(keeping: Set(wanted.map(\.sourceID)), now: now, in: connection)
                    try connection.executeScript("COMMIT")
                } catch {
                    try? connection.executeScript("ROLLBACK")
                    throw error
                }
                return try MobileTextIndex.missing(wanted, in: connection)
            }
        } catch {
            Self.logger.error("The text set could not be read: \(String(describing: error), privacy: .public)")
            return 0
        }
        var indexed = 0
        for wanted in missing.prefix(budget) {
            do {
                guard let satellite = try await satellites.source(wanted.sourceID, matching: { $0 == "text" }),
                      satellite.file.hash == wanted.hash else { continue }
                let text = String(decoding: try await satellites.data(satellite), as: UTF8.self)
                try await index(text, sourceID: wanted.sourceID, hash: wanted.hash, now: now)
                indexed += 1
            } catch {
                Self.logger.error("A source's text was not indexed: \(String(describing: error), privacy: .public)")
            }
        }
        return indexed
    }

    /// Indexes text the phone holds (the Reader just loaded it, or the pass above fetched it).
    func index(_ text: String, sourceID: String, hash: String, now: Date = Date()) async throws {
        try await satellites.projection.replica.read { replica in
            let connection = replica.connection
            try connection.executeScript("BEGIN IMMEDIATE")
            do {
                try MobileTextIndex.store(text: text, sourceID: sourceID, hash: hash, now: now, in: connection)
                try connection.executeScript("COMMIT")
            } catch {
                try? connection.executeScript("ROLLBACK")
                throw error
            }
        }
    }

    func search(_ query: String, limit: Int = 50) async throws -> [MobileTextIndex.Hit] {
        try await satellites.projection.replica.read { try MobileTextIndex.search(query, limit: limit, in: $0.connection) }
    }
}
