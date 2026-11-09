import Foundation

// MARK: - The activation's derivations for reading state (docs/cloudkit-schema-design.md §12.7 v160, §13.3)

/// What this Mac's disk holds of a narration's `playback-position.json` (§13.3 step 3c and step 4).
enum ListenFileProbe: Equatable, Sendable {
    /// Downloaded: the position it holds.
    case present(ArticleSpeechPlaybackPosition)
    /// In iCloud Drive but not on this Mac (Optimize Mac Storage): read once downloaded, by the queue.
    case evicted
}

extension KnowledgeStore {
    static let understandingBackfillKind = "understanding"
    static let listenFileBackfillKind = "listenFile"

    /// Reads the `playback-position.json` files of these sources; a source with none is left out.
    /// Tests stand in for iCloud Drive here, per task.
    @TaskLocal static var listenFileProbeOverride: (@Sendable ([String]) -> [String: ListenFileProbe])?

    /// WP12's derivations, after WP7's wire ids: the team copies' per-member rows on wire ids, then each
    /// work's reading state from generation-1 truth, then the Understanding documents queued for their
    /// layout. Each is idempotent, bounded by the library, in its own transaction, and reads
    /// generation-1 truth only, so a run after generation-1 edits reflects them.
    static let readingActivationDerivations: [ActivationDerivation] = [
        ActivationDerivation(id: "perMemberWireKeys") { store in try store.inDerivationTransaction { try $0.rekeyTeamCopiesPerMemberRows() } },
        ActivationDerivation(id: "readingStates") { store in try store.inDerivationTransaction { try $0.deriveReadingStates() } },
        ActivationDerivation(id: "queueUnderstanding") { store in try store.inDerivationTransaction { try $0.queueUnderstandingBackfill() } },
    ]

    // MARK: Team copies' rows on wire ids (§12.7 v160)

    /// Re-keys the per-member rows of team copies (local ids) to their wire ids, the personal copy's.
    /// Where one meets the personal copy's row, the two merge column by column: the later time wins,
    /// and the ideas discussed are the union. Highlights, placements, card sources and dismissals are
    /// re-keyed with their readers (WP12b).
    func rekeyTeamCopiesPerMemberRows() throws {
        for (table, time) in [
            ("hidden_sources", "hidden_at"), ("hidden_podcast_episodes", "hidden_at"),
            ("visible_podcast_episode_overrides", "visible_at"), ("visible_youtube_video_overrides", "visible_at"),
        ] {
            try rekey(table: table, key: "source_id", time: time, columns: [])
        }
        try rekey(table: "walkthrough_progress", key: "subject_id", time: "updated_at", columns: ["progress_json"])
        try rekey(
            table: "source_understanding", key: "source_id", time: "generated_at",
            columns: ["relative_path", "derived_through_session_id", "generator_version", "body_sha256", "open_thread_count"],
            union: "discussed_idea_ids"
        )
    }

    private func rekey(table: String, key: String, time: String, columns: [String], union: String? = nil) throws {
        let teamCopy = "SELECT id FROM sources WHERE wire_id IS NOT NULL AND wire_id <> id"
        let all = [time] + columns + [union].compactMap { $0 }
        var assignments = columns.map { "\($0) = CASE WHEN excluded.\(time) > \(table).\(time) THEN excluded.\($0) ELSE \(table).\($0) END" }
        if let union {
            assignments.append("""
                \(union) = (SELECT json_group_array(value) FROM (
                    SELECT value FROM json_each(\(table).\(union)) UNION SELECT value FROM json_each(excluded.\(union)) ORDER BY value))
            """)
        }
        assignments.append("\(time) = MAX(\(table).\(time), excluded.\(time))")
        try execute("""
            INSERT INTO \(table) (\(key), \(all.joined(separator: ", ")))
            SELECT s.wire_id, \(all.map { "t.\($0)" }.joined(separator: ", "))
            FROM \(table) t JOIN sources s ON s.id = t.\(key)
            WHERE s.wire_id IS NOT NULL AND s.wire_id <> s.id
            ON CONFLICT(\(key)) DO UPDATE SET \(assignments.joined(separator: ", "))
        """, [])
        try execute("DELETE FROM \(table) WHERE \(key) IN (\(teamCopy))", [])
    }

    // MARK: reading_states from generation-1 truth (§13.3 step 3c)

    /// Every work's reading state as generation 1 holds it: the `sources` columns (position, locator,
    /// read, review depth, consumed), its notebook items' first completion, and the narration's resume
    /// point, the newer of the `listen.position.*` row and the `playback-position.json` on disk
    /// (`ListeningPositionSync`). A team copy's and the personal copy's columns meet on one wire id:
    /// the personal copy's place and depth first, the later read mark, the furthest fraction the
    /// maximum. Each derived column is exactly what that truth says; the columns no generation-1 value
    /// gives (walk variants, the Understanding FileRef) are kept. A narration file not on this Mac is
    /// queued for when it is (§13.3 step 4).
    func deriveReadingStates() throws {
        struct Derived {
            var locator: SyncJSON?
            var position: Int64?
            var readAt: Double?
            var reviewDepth: String?
            var furthest: Double?
            var completedAt: Double?
            var consumedAt: Double?
            var listen: ArticleSpeechPlaybackPosition?
        }
        var derived: [String: Derived] = [:]
        var placed = Set<String>()
        try query("""
            SELECT id, wire_key, reading_position_page, reading_position_locator, read_at, review_depth, is_consumed, date_added
            FROM sources
            WHERE reading_position_page IS NOT NULL OR reading_position_locator IS NOT NULL OR read_at IS NOT NULL
               OR review_depth IS NOT NULL OR is_consumed = 1
            ORDER BY wire_key, team_id IS NOT NULL, id
        """, []) { row in
            guard let key = row.text(1) else { return }
            var state = derived[key] ?? Derived()
            let page = row.integer(2)
            let locator = row.text(3)
            if !placed.contains(key), page != nil || locator != nil {
                placed.insert(key)
                state.position = page
                state.locator = locator.map(ReadingLocatorCodec.wire(macLocator:))
            }
            if let fraction = ReadingLocatorCodec.fraction(macLocator: locator) { state.furthest = max(state.furthest ?? 0, fraction) }
            if let read = row.real(4) { state.readAt = max(state.readAt ?? read, read) }
            if state.reviewDepth == nil { state.reviewDepth = row.text(5) }
            if row.integer(6) == 1 { state.consumedAt = state.consumedAt ?? row.real(4) ?? row.real(7) }
            derived[key] = state
        }
        try query("""
            SELECT COALESCE(s.wire_key, i.source_id), MIN(i.completed_at)
            FROM learning_goal_items i LEFT JOIN sources s ON s.id = i.source_id
            WHERE i.completed_at IS NOT NULL GROUP BY 1
        """, []) { row in
            guard let key = row.text(0), let completed = row.real(1) else { return }
            derived[key, default: Derived()].completedAt = completed
        }

        // The narration's resume points: the rows, then the files beside the narrations.
        var listenSources: [String: ArticleSpeechPlaybackPosition] = [:]
        try query("SELECT key, value FROM user_preferences WHERE key LIKE 'listen.position.%'", []) { row in
            guard let key = row.text(0), let sourceID = ListeningPositionSync.sourceID(fromPreferenceKey: key),
                  let encoded = row.text(1).flatMap(PreferenceStore.decodePlist) as? String,
                  let position = ListeningPositionSync.decode(encoded) else { return }
            listenSources[sourceID] = position
        }
        var sourceIDs: [String] = []
        try query("SELECT id FROM sources ORDER BY id", []) { row in if let id = row.text(0) { sourceIDs.append(id) } }
        let files = Self.listenFileProbeOverride?(sourceIDs) ?? Self.probeListenFiles(sourceIDs: sourceIDs)
        var evicted: [String] = []
        for (sourceID, probe) in files {
            switch probe {
            case .present(let position): listenSources[sourceID] = ListeningPositionSync.newest(listenSources[sourceID], position)
            case .evicted: evicted.append(sourceID)
            }
        }
        for (sourceID, position) in listenSources {
            let key = try readingStateKey(sourceID: sourceID)
            derived[key, default: Derived()].listen = ListeningPositionSync.newest(derived[key]?.listen, position)
        }

        var held: [String] = []
        try query("SELECT wire_id FROM reading_states", []) { row in if let id = row.text(0) { held.append(id) } }
        for key in Set(derived.keys).union(held).sorted() {
            let existing = try ReadingStateRow.load(key, connection: self)
            var row = existing ?? ReadingStateRow(wireID: key)
            let state = derived[key] ?? Derived()
            row.locator = state.locator
            row.position = state.position
            row.readAt = state.readAt
            row.reviewDepth = state.reviewDepth
            row.furthestEpoch = state.furthest == nil ? nil : 0
            row.furthest = state.furthest
            row.completedAt = state.completedAt
            row.consumedAt = state.consumedAt
            row.listen = state.listen.map(ListenPositionCodec.wire)
            guard row != existing, existing != nil || !row.isEmpty else { continue }
            try row.save(self)
        }
        for sourceID in evicted.sorted() {
            try execute("""
                INSERT INTO ck_backfill_queue (kind, target, enqueued_at) VALUES (?, ?, 0)
                ON CONFLICT(kind, target) DO NOTHING
            """, [.text(Self.listenFileBackfillKind), .text(sourceID)])
        }
    }

    /// The `playback-position.json` beside each narration this library has, read from iCloud Drive
    /// without downloading anything: only the folders the Audio root lists are looked at.
    static func probeListenFiles(sourceIDs: [String]) -> [String: ListenFileProbe] {
        let manager = FileManager.default
        // The iCloud Drive tree, not the working folder (§3.5.30): generation 1 wrote these files, and the
        // working folder holds nothing of them yet.
        guard let folders = try? manager.contentsOfDirectory(atPath: SyncedArticleAudioStore.ubiquityAudioRootURL().path) else { return [:] }
        let listed = Set(folders)
        var result: [String: ListenFileProbe] = [:]
        for sourceID in sourceIDs where listed.contains(SyncedArticleAudioStore.ubiquityPlaybackPositionURL(sourceID: sourceID).deletingLastPathComponent().lastPathComponent) {
            if let probe = probeListenFile(SyncedArticleAudioStore.ubiquityPlaybackPositionURL(sourceID: sourceID)) { result[sourceID] = probe }
        }
        return result
    }

    /// One file: present and downloaded, evicted (a placeholder, or not current), or absent (nil).
    static func probeListenFile(_ url: URL) -> ListenFileProbe? {
        let manager = FileManager.default
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        guard manager.fileExists(atPath: url.path) else {
            return manager.fileExists(atPath: placeholder.path) ? .evicted : nil
        }
        if manager.isUbiquitousItem(at: url),
           let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus,
           status != .current {
            return .evicted
        }
        guard let data = try? Data(contentsOf: url) else { return .evicted }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ArticleSpeechPlaybackPosition.self, from: data)).map(ListenFileProbe.present)
    }

    // MARK: Durable queue jobs (§13.3 step 4)

    /// Queues every Understanding document for its layout as the ReadingState's `understanding`
    /// satellite. Set-based, from the index alone, so it gives one result however often it runs.
    func queueUnderstandingBackfill() throws {
        try execute("""
            INSERT INTO ck_backfill_queue (kind, target, enqueued_at)
            SELECT ?, source_id, generated_at FROM source_understanding WHERE true
            ON CONFLICT(kind, target) DO NOTHING
        """, [.text(Self.understandingBackfillKind)])
    }

    /// Lays out up to `limit` queued Understanding documents: each file read once, gzipped into the
    /// staging folder, its FileRef (owned by the ReadingState, `rs:<wire id>`) written to its
    /// reading_states row with no outbox row, like WP7's satellites: the cutover seed sends the pointers
    /// and then the bytes. Off main, at `.utility`, resumable; generation 2 only. Returns how many it laid.
    @discardableResult
    func runUnderstandingBackfill(limit: Int = 50) throws -> Int {
        var queued: [(id: Int64, key: String)] = []
        try query("SELECT id, target FROM ck_backfill_queue WHERE kind = ? AND attempts < 5 ORDER BY attempts, id LIMIT ?", [
            .text(Self.understandingBackfillKind), .integer(Int64(limit)),
        ]) { row in
            if let id = row.integer(0), let key = row.text(1) { queued.append((id, key)) }
        }
        guard !queued.isEmpty else { return 0 }
        var laid: [(queueID: Int64, key: String, file: FileRef?, path: String?)] = []
        var failed: [(Int64, String)] = []
        for item in queued {
            guard let relative = try scalarText("SELECT relative_path FROM source_understanding WHERE source_id = ?", [.text(item.key)]) else {
                laid.append((item.id, item.key, nil, nil))
                continue
            }
            do {
                guard let absolute = Self.resolveUnderstandingPath(relative) else {
                    throw KnowledgeStoreError.invalidData("Understanding document not on this Mac: \(relative)")
                }
                let body = try Data(contentsOf: URL(fileURLWithPath: absolute))
                let owner = SyncIdentity.readingStateID(targetID: item.key)
                let satellite = SourceLocalSatellite(
                    map: .files, role: "understanding", mime: "text/markdown", encoding: .gzip, body: body, localPath: nil, input: nil
                )
                let (file, stored) = try SourceSatelliteLayout.layout(satellite, owner: owner)
                let folder = satelliteStagingFolder.appendingPathComponent(SyncIdentity.sha256Hex(Data(owner.utf8)), isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try stored.write(to: folder.appendingPathComponent("understanding.gz"), options: .atomic)
                laid.append((item.id, item.key, file, "ck-staging/\(folder.lastPathComponent)/understanding.gz"))
            } catch {
                failed.append((item.id, error.localizedDescription))
            }
        }
        try replica.apply { _ in
            for item in laid {
                if let file = item.file {
                    var row = try ReadingStateRow.load(item.key, connection: self) ?? ReadingStateRow(wireID: item.key)
                    row.understanding = file.value
                    row.understandingPath = item.path
                    try row.save(self)
                }
                try execute("DELETE FROM ck_backfill_queue WHERE id = ?", [.integer(item.queueID)])
            }
            for (id, message) in failed {
                try execute("UPDATE ck_backfill_queue SET attempts = attempts + 1, last_error = ? WHERE id = ?", [.text(message), .integer(id)])
            }
        }
        return laid.count
    }

    /// Reads up to `limit` narration files that were evicted at activation, once iCloud Drive has them,
    /// and writes each as a `ReadingState.listen` patch in `ck_patches` stamped with the file's own
    /// `updatedAt`, so a newer position from any device wins by its stamp (§13.3 step 4). A file still
    /// evicted is asked for and tried again later; one that went is dropped. Needs this Mac's device id
    /// (the stamp clock); generation 2 only. Returns how many it read.
    @discardableResult
    func runListenFileBackfill(limit: Int = 50) throws -> Int {
        guard let clock = try OutboxFeeder(connection: self, registry: Self.projectionRegistry).loadClock() else { return 0 }
        var queued: [(id: Int64, sourceID: String)] = []
        try query("SELECT id, target FROM ck_backfill_queue WHERE kind = ? AND attempts < 50 ORDER BY attempts, id LIMIT ?", [
            .text(Self.listenFileBackfillKind), .integer(Int64(limit)),
        ]) { row in
            if let id = row.integer(0), let sourceID = row.text(1) { queued.append((id, sourceID)) }
        }
        guard !queued.isEmpty else { return 0 }
        let probes = Self.listenFileProbeOverride?(queued.map(\.sourceID))
            ?? Dictionary(uniqueKeysWithValues: queued.compactMap { item in
                Self.probeListenFile(SyncedArticleAudioStore.ubiquityPlaybackPositionURL(sourceID: item.sourceID)).map { (item.sourceID, $0) }
            })
        var read = 0
        try replica.apply { _ in
            for item in queued {
                switch probes[item.sourceID] {
                case .present(let position)?:
                    let key = try readingStateKey(sourceID: item.sourceID)
                    try Self.stageListenPatch(position, targetID: key, deviceID: clock.deviceID, connection: self)
                    try execute("DELETE FROM ck_backfill_queue WHERE id = ?", [.integer(item.id)])
                    read += 1
                case .evicted?:
                    try? FileManager.default.startDownloadingUbiquitousItem(at: SyncedArticleAudioStore.ubiquityPlaybackPositionURL(sourceID: item.sourceID))
                    try execute("UPDATE ck_backfill_queue SET attempts = attempts + 1 WHERE id = ?", [.integer(item.id)])
                case nil:
                    try execute("DELETE FROM ck_backfill_queue WHERE id = ?", [.integer(item.id)])
                }
            }
        }
        return read
    }

    /// Folds a listen position into the ReadingState's pending patch, stamped at the position's own
    /// time; a pending listen with a later stamp stays.
    static func stageListenPatch(_ position: ArticleSpeechPlaybackPosition, targetID: String, deviceID: String, connection: SQLiteConnection) throws {
        let zoneKey = ReplicaZone.key(database: .private, zoneName: SyncZone.library.rawValue)
        let type = SyncRecordType.readingState.rawValue
        let wireID = SyncIdentity.readingStateID(targetID: targetID)
        let milliseconds = SyncTime.milliseconds(position.updatedAt)
        var patch = try PendingPatch.load(zoneKey: zoneKey, type: type, wireID: wireID, in: connection)
            ?? PendingPatch(changes: [:], stamps: [:], zoneKey: zoneKey, type: type, wireID: wireID)
        let stamp = SyncStamp(policy: .lastWriter, milliseconds: milliseconds, counter: 0, deviceID: deviceID)
        if case .value(let pending)? = patch.stamps["listen"], SyncStamp.compare(pending, stamp) >= 0 { return }
        patch.changes["listen"] = ListenPositionCodec.wire(position)
        patch.stamps["listen"] = .value(stamp)
        for (field, value) in [("targetKind", SyncJSON.string("source")), ("targetID", .string(targetID))] where patch.changes[field] == nil {
            patch.changes[field] = value
            patch.stamps[field] = .value(SyncStamp(policy: .serverFirst, milliseconds: milliseconds, counter: 0, deviceID: deviceID))
        }
        try patch.save(in: connection, now: Date())
    }
}
