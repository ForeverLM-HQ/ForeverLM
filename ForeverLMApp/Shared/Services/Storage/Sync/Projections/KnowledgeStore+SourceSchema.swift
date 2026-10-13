import CryptoKit
import Foundation

// MARK: - Schema 155: what the Source and Collection records need beyond generation 1's tables (§12.7)

extension KnowledgeStore {
    /// The tables schema 155 adds (docs/cloudkit-schema-design.md §12.7), created empty: DDL only, like
    /// every step from 154 on. Generation 1 never reads or writes them; the generation-2 activation
    /// fills them from generation-1 truth (`sourceActivationDerivations`), and from then on the Source
    /// and Collection projections and the importer keep them.
    static let sourceSyncTables: [ReplicaSchemaTable] = [
        // Every identity key known for a source's work (§4.2), normalized by `WorkKey`, plus the
        // iPhone's historical `url:` form where it differs: the index lookup-before-mint reads. A key
        // names its source until the source goes; two sources may share one until the maintenance Mac
        // resolves the duplicate.
        ReplicaSchemaTable("source_work_keys", [
            ("source_id", "TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE"),
            ("work_key", "TEXT NOT NULL"),
        ], constraints: ["PRIMARY KEY (source_id, work_key)"], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_source_work_keys_key ON source_work_keys(work_key)",
        ]),
        // A source's content satellites by role (`Source.files`, §3.5.30): the FileRef as JSON, and
        // where this Mac holds the bytes, relative to its content roots, when it does.
        ReplicaSchemaTable("source_files", [
            ("source_id", "TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE"),
            ("role", "TEXT NOT NULL"),
            ("file_ref", "TEXT NOT NULL"),
            ("local_path", "TEXT"),
        ], constraints: ["PRIMARY KEY (source_id, role)"]),
        // Its machine outputs by kind (`Source.derived`): review guide, walkthrough, figures, ideas,
        // cited papers, explainer.
        ReplicaSchemaTable("source_derived", [
            ("source_id", "TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE"),
            ("kind", "TEXT NOT NULL"),
            ("file_ref", "TEXT NOT NULL"),
            ("local_path", "TEXT"),
        ], constraints: ["PRIMARY KEY (source_id, kind)"]),
        // The collections no generation-1 table holds (§3.5.5): podcast shows and YouTube channels,
        // derived from their episodes and videos, and a playlist that `group_members` names with no
        // `video_playlists` row. Books, meeting series and followed playlists keep their own tables.
        ReplicaSchemaTable("source_collections", [
            ("id", "TEXT PRIMARY KEY"),
            ("kind", "TEXT NOT NULL"),
            ("external_key", "TEXT NOT NULL"),
            ("title", "TEXT NOT NULL"),
            ("subtitle", "TEXT"),
            ("author", "TEXT"),
            ("feed_json", "TEXT"),
            ("status", "TEXT NOT NULL DEFAULT 'active'"),
            ("added_at", "REAL"),
        ], constraints: ["UNIQUE (kind, external_key)"]),
        // The Source fields no generation-1 column holds, one row per source (correction of §12.7, WP7):
        // set by the activation, an inbound record or a generation-2 write, so they survive a round
        // trip. `extra_meta_json` holds the `meta` keys no column holds; `lossy_json` the wire value of a
        // field a column holds only approximately (authors, publication date, type, ingest), beside the
        // column values it was written as, so an untouched row encodes the value it came with.
        ReplicaSchemaTable("source_wire_fields", [
            ("source_id", "TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE"),
            ("primary_key", "TEXT"),
            ("made_by_json", "TEXT"),
            ("type_locked", "INTEGER"),
            ("subtitle", "TEXT"),
            ("language", "TEXT"),
            ("summary", "TEXT"),
            ("content_hash", "TEXT"),
            ("metrics_json", "TEXT"),
            ("copied_from_json", "TEXT"),
            ("merged_into", "TEXT"),
            ("extra_meta_json", "TEXT"),
            ("lossy_json", "TEXT"),
        ]),
    ]

    /// Creates schema 155's tables where missing: empty, DDL only.
    func createSourceSyncTables() throws {
        for table in Self.sourceSyncTables {
            try exec(table.createStatement)
            for index in table.indexes {
                try exec(index)
            }
        }
    }

    /// Schema 155's proof before the stamp: every table has its shape, so a same-named table of
    /// another shape fails here and the migration rolls back.
    func probeSchema155() throws {
        for table in Self.sourceSyncTables {
            try query(table.probe) { _ in }
        }
    }
}

// MARK: - The activation's derivations for sources and collections (§13.3 step 3c)

extension KnowledgeStore {
    /// WP7's derivations, in order: wire ids and the team copies' `ck_identity` rows, then work keys,
    /// then the shows, channels and playlists no table holds, then the queue of the satellite layout. Each is idempotent, set-based or bounded
    /// by the library, in its own transaction, and reads generation-1 truth only, so it reflects every
    /// generation-1 write made before the activation.
    static let sourceActivationDerivations: [ActivationDerivation] = [
        ActivationDerivation(id: "wireIDs") { store in try store.inDerivationTransaction { try $0.deriveWireIDs() } },
        ActivationDerivation(id: "sourceWorkKeys") { store in try store.inDerivationTransaction { try $0.deriveSourceWorkKeys() } },
        ActivationDerivation(id: "sourceCollections") { store in try store.inDerivationTransaction { try $0.deriveSourceCollections() } },
        ActivationDerivation(id: "playlistCollections") { store in try store.inDerivationTransaction { try $0.derivePlaylistCollections() } },
        // The satellites' layout is bounded work for the durable queue (§13.3 step 4).
        ActivationDerivation(id: "queueSourceFiles") { store in try store.inDerivationTransaction { try $0.queueSourceFilesBackfill() } },
    ]

    func inDerivationTransaction(_ body: (KnowledgeStore) throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body(self)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// The zone a generation-1 team's copies will live in, as `ck_identity` names it until the space
    /// packages make the team a space (§13.7, WP15): `Space-<team id>` (lowercased when it is a UUID),
    /// in the private database for a team this Mac owns, else in its owner's shared one. No such zone
    /// has a root yet, so the feeder holds every change to a team copy, rows and all, until then. Once
    /// the team is a space (`TeamToSpace`, or a space `SpaceService` made or joined), its `teams` row
    /// names the space's zone and its owner as the library container knows them (WP15).
    func teamZoneKeys() throws -> [String: String] {
        try SpaceRows.teamZoneKeys(self)
    }

    /// `wire_id` on the five wire-keyed tables (§4.3): a row's own id, except a team's copy of a source,
    /// whose wire id is the canonical personal id (§13.7 step 3): the personal source with the same
    /// address, else the address's stable id. Every team row gets its `ck_identity` row.
    func deriveWireIDs() throws {
        let types: [(table: String, type: SyncRecordType)] = [
            ("learning_goals", .notebook), ("review_sessions", .chat), ("global_artifacts", .artifact), ("courses", .course),
        ]
        try execute("UPDATE sources SET wire_id = id WHERE team_id IS NULL AND wire_id IS NOT id", [])
        for (table, _) in types {
            try execute("UPDATE \(table) SET wire_id = id WHERE wire_id IS NOT id", [])
        }

        let zones = try teamZoneKeys()
        var teamSources: [(id: String, team: String, normalized: String?)] = []
        try query("""
            SELECT s.id, s.team_id, \(Self.subtypeCoalesce("normalized_url"))
            FROM sources s \(Self.subtypeJoins)
            WHERE s.team_id IS NOT NULL
        """, []) { row in
            if let id = row.text(0), let team = row.text(1) { teamSources.append((id, team, row.text(2))) }
        }
        for source in teamSources {
            var canonical: String?
            if let normalized = source.normalized, !normalized.isEmpty {
                canonical = try scalarText("""
                    SELECT s.id FROM sources s \(Self.subtypeJoins)
                    WHERE s.team_id IS NULL AND \(Self.subtypeCoalesce("normalized_url")) = ?
                    ORDER BY s.id LIMIT 1
                """, [.text(normalized)]) ?? SyncIdentity.sourceID(normalizedURL: normalized)
            }
            let wireID = canonical ?? source.id
            try execute("UPDATE sources SET wire_id = ? WHERE id = ?", [.text(wireID), .text(source.id)])
            if let zone = zones[source.team] {
                try recordIdentity(zoneKey: zone, recordType: SyncRecordType.source.rawValue, wireID: wireID, localID: source.id)
            }
        }
        for (table, type) in types {
            var rows: [(id: String, team: String)] = []
            try query("SELECT id, team_id FROM \(table) WHERE team_id IS NOT NULL", []) { row in
                if let id = row.text(0), let team = row.text(1) { rows.append((id, team)) }
            }
            for row in rows {
                guard let zone = zones[row.team] else { continue }
                try recordIdentity(zoneKey: zone, recordType: type.rawValue, wireID: row.id, localID: row.id)
            }
        }
    }

    /// Every source's work keys from its address and DOI columns (§4.2), the iPhone's historical form
    /// of its address included (§4.1); keys only ever add, so a run after more imports adds theirs.
    func deriveSourceWorkKeys() throws {
        var rows: [(id: String, url: String?, normalized: String?, doi: String?)] = []
        try query("""
            SELECT s.id, \(Self.subtypeCoalesce("url")), \(Self.subtypeCoalesce("normalized_url")), p.doi
            FROM sources s \(Self.subtypeJoins)
        """, []) { row in
            if let id = row.text(0) { rows.append((id, row.text(1), row.text(2), row.text(3))) }
        }
        for row in rows {
            for key in SourceWorkKeys.keys(url: row.url, normalizedURL: row.normalized, doi: row.doi) {
                try execute(
                    "INSERT INTO source_work_keys (source_id, work_key) VALUES (?, ?) ON CONFLICT(source_id, work_key) DO NOTHING",
                    [.text(row.id), .text(key)]
                )
            }
        }
    }

    /// A podcast show's and a YouTube channel's collection, once each, from their episodes' and
    /// videos' show and channel lines (R6-m3), added when their first member was.
    /// `onlySource` is the one-source form a save runs under generation 2, so a show or channel first met
    /// after the activation gets its Collection before its Source names it.
    func deriveSourceCollections(onlySource: String? = nil) throws {
        var found: [String: (kind: String, name: String, addedAt: Double)] = [:]
        func note(_ kind: String, _ name: String, _ addedAt: Double) {
            let id = SyncIdentity.collectionID(kind: kind, externalKey: name)
            if let held = found[id], held.addedAt <= addedAt { return }
            found[id] = (kind, name, addedAt)
        }
        try query("""
            SELECT COALESCE(NULLIF(TRIM(pod.show_name), ''), NULLIF(TRIM(pod.domain), '')), s.date_added
            FROM podcasts pod JOIN sources s ON s.id = pod.source_id
            WHERE ?1 IS NULL OR s.id = ?1
        """, [.text(onlySource)]) { row in
            if let name = row.text(0) { note("podcastShow", name, row.real(1) ?? 0) }
        }
        var videos: [(id: String, domain: String?, url: String?, addedAt: Double)] = []
        try query("""
            SELECT v.source_id, v.domain, v.url, s.date_added FROM videos v JOIN sources s ON s.id = v.source_id
            WHERE ?1 IS NULL OR s.id = ?1
        """, [.text(onlySource)]) { row in
            if let id = row.text(0) { videos.append((id, row.text(1), row.text(2), row.real(3) ?? 0)) }
        }
        for video in videos {
            var groups: [String] = []
            try query("""
                SELECT gm.group_id, vp.title FROM group_members gm LEFT JOIN video_playlists vp ON vp.id = gm.group_id
                WHERE gm.source_id = ?
            """, [.text(video.id)]) { row in groups += [row.text(0), row.text(1)].compactMap { $0 } }
            if let channel = SourceCollections.channelName(domain: video.domain, url: video.url, groupNames: groups) {
                note("youtubeChannel", channel, video.addedAt)
            }
        }
        for (id, collection) in found.sorted(by: { $0.key < $1.key }) {
            try execute("""
                INSERT INTO source_collections (id, kind, external_key, title, status, added_at)
                VALUES (?, ?, ?, ?, 'active', ?)
                ON CONFLICT(id) DO UPDATE SET added_at = MIN(COALESCE(source_collections.added_at, excluded.added_at), excluded.added_at)
                WHERE source_collections.added_at IS NULL OR excluded.added_at < source_collections.added_at
            """, [.text(id), .text(collection.kind), .text(collection.name), .text(collection.name), .real(collection.addedAt)])
        }
    }

    /// A `Collection(kind playlist)` for each `playlist_` group `group_members` names and no
    /// `video_playlists` row holds (R7-m5), so its members' Entries keep a container: the playlist
    /// address its id names as the external key, and the id itself as the title, as generation 1 names
    /// such a playlist (`videoPlaylistDisplayName`). A course's or a stray group gives nothing.
    func derivePlaylistCollections(onlySource: String? = nil) throws {
        try execute("""
            INSERT INTO source_collections (id, kind, external_key, title, status, added_at)
            SELECT gm.group_id, 'playlist', substr(gm.group_id, \(PlaylistEntryProjection.playlistPrefix.count + 1)), gm.group_id,
                   'active', MIN(s.date_added)
            FROM group_members gm JOIN sources s ON s.id = gm.source_id
            WHERE gm.group_id LIKE 'playlist\\_%' ESCAPE '\\'
              AND NOT EXISTS (SELECT 1 FROM video_playlists vp WHERE vp.id = gm.group_id)
              AND (?1 IS NULL OR gm.source_id = ?1)
            GROUP BY gm.group_id
            ON CONFLICT(id) DO NOTHING
        """, [.text(onlySource)])
    }

    /// The per-type tables joined to `sources s`, and a column of whichever holds the source.
    static let subtypeJoins = """
        LEFT JOIN articles a ON a.source_id = s.id LEFT JOIN papers p ON p.source_id = s.id
        LEFT JOIN podcasts pod ON pod.source_id = s.id LEFT JOIN book_sources bs ON bs.source_id = s.id
        LEFT JOIN course_sources cs ON cs.source_id = s.id LEFT JOIN meeting_sources ms ON ms.source_id = s.id
        LEFT JOIN videos v ON v.source_id = s.id LEFT JOIN x_posts xp ON xp.source_id = s.id
        """

    static func subtypeCoalesce(_ column: String) -> String {
        "COALESCE(" + ["a", "p", "pod", "bs", "cs", "ms", "v", "xp"].map { "\($0).\(column)" }.joined(separator: ", ") + ")"
    }
}

// MARK: - Lookup before mint (§4.2), generation 2 only

extension KnowledgeStore {
    /// The work keys an import knows for `article`: its address, the DOIs, and the `file:` hash of a
    /// local original when `hashingFile` (an import reads the file once; an ordinary save never does).
    /// A chapter of a PDF book has no `file:` key: its file is the book's, which every chapter shares,
    /// and a key they all held would find the first chapter for each of the others.
    func workKeys(for article: StudioArticle, hashingFile: Bool) -> [String] {
        var fileHash: String?
        if hashingFile, article.bookPages == nil, let path = article.localFilePath, !path.contains("://") {
            fileHash = try? SourceFileHash.sha256Hex(ofFileAt: URL(fileURLWithPath: StorageService.absoluteSourcePath(path)))
        }
        return SourceWorkKeys.keys(
            url: article.url, normalizedURL: URLNormalizer.normalize(article.url), doi: article.doi,
            fileHash: fileHash
        )
    }

    /// The source in the import's library (the learner's own when `teamID` is nil, else that team's)
    /// that holds any of `keys`: an active one before an archived one, then the smaller id. Nil under
    /// generation 1, which mints as build 177 does and never reads `source_work_keys` (D40).
    func sourceID(forWorkKeys keys: [String], teamID: String?) throws -> String? {
        guard syncGeneration == .two, !keys.isEmpty else { return nil }
        let marks = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        return try scalarText("""
            SELECT s.id FROM source_work_keys k JOIN sources s ON s.id = k.source_id
            WHERE k.work_key IN (\(marks)) AND s.team_id IS ?
            ORDER BY s.status = 'active' DESC, s.id
            LIMIT 1
        """, keys.map(SQLiteValue.text) + [.text(teamID)])
    }

    /// Adds `keys` to a source's work keys; keys are only ever added (§4.2). Generation 2 only.
    func addWorkKeys(_ keys: [String], to sourceID: String) throws {
        guard syncGeneration == .two else { return }
        for key in keys {
            try execute(
                "INSERT INTO source_work_keys (source_id, work_key) VALUES (?, ?) ON CONFLICT(source_id, work_key) DO NOTHING",
                [.text(sourceID), .text(key)]
            )
        }
    }
}

// MARK: - A preprint's published DOI is no work key

extension KnowledgeStore {
    /// Takes the published DOI of every preprint back out of its work keys. Until paper versions
    /// (docs/paper-versions.md) a preprint's resolved published DOI was one of its keys, so importing
    /// the journal version found the preprint by it, and duplicate resolution on the maintenance Mac
    /// folded the two sources into one. The removal is a normal tracked write, so the element leaves the
    /// source's `workKeys` on every device. A key the source's own address or DOI names stays. Returns
    /// how many keys it removed; generation 2 only, and idempotent.
    @discardableResult
    func removePublishedDOIWorkKeys() throws -> Int {
        guard syncGeneration == .two else { return 0 }
        var rows: [(id: String, url: String?, normalized: String?, doi: String?, published: String)] = []
        try query("""
            SELECT p.source_id, p.url, p.normalized_url, p.doi, p.published_doi
            FROM papers p
            WHERE p.published_doi IS NOT NULL AND p.published_doi <> ''
        """, []) { row in
            if let id = row.text(0), let published = row.text(4) {
                rows.append((id, row.text(1), row.text(2), row.text(3), published))
            }
        }
        var removed = 0
        for row in rows {
            guard let key = WorkKey.normalizeRemote("doi:" + row.published),
                  !SourceWorkKeys.keys(url: row.url, normalizedURL: row.normalized, doi: row.doi).contains(key),
                  try scalarText(
                      "SELECT work_key FROM source_work_keys WHERE source_id = ? AND work_key = ?",
                      [.text(row.id), .text(key)]
                  ) != nil
            else { continue }
            try execute("DELETE FROM source_work_keys WHERE source_id = ? AND work_key = ?", [.text(row.id), .text(key)])
            removed += 1
        }
        return removed
    }
}

// MARK: - A file's hash

/// The lowercase hex sha256 of a file's bytes, read in pieces so a 372 MB PDF never sits in memory: the
/// `file:` work key and a FileRef's `hash`.
enum SourceFileHash {
    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
