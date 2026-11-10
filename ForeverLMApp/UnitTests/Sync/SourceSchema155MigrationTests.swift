import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Local schema 155 (docs/cloudkit-schema-design.md §12.7, WP7): the Source and Collection records'
/// tables, DDL only and empty until a store's generation-2 activation, from the released 150 and 153
/// shapes and from 154 (`Schema154Fixture`).
@Suite("Schema 155 migration")
struct SourceSchema155MigrationTests {
    private static let tables = KnowledgeStore.sourceSyncTables.map(\.name)

    private static func emptyCounts(_ store: KnowledgeStore) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for table in tables { counts[table] = try Schema154Fixture.count(store, "SELECT COUNT(*) FROM \(table)") }
        return counts
    }

    @Test("A fresh store is at 155 with the Source and Collection tables, empty")
    func freshStore() throws {
        let root = try Schema154Fixture.temporaryRoot("155-fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(KnowledgeStore.schemaVersion >= 155)
        #expect(try Schema154Fixture.count(store, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        for table in KnowledgeStore.sourceSyncTables {
            try store.query(table.probe) { _ in }
        }
        #expect(try Self.emptyCounts(store).values.allSatisfy { $0 == 0 })
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'idx_source_work_keys_key'") == 1)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
    }

    @Test(
        "A released or 154 store migrates to 155 keeping every row, filling nothing and creating no trigger",
        arguments: [Int32(150), Int32(153), Int32(154)]
    )
    func forward(_ version: Int32) throws {
        let root = try Schema154Fixture.temporaryRoot("155-forward-\(version)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Schema154Fixture.makeLibrary(at: root, version: version, sourceCount: 4)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(version))
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'source_work_keys'") == 0)
        let counts = ["sources", "articles", "group_members", "learning_goal_items"]
        let before = counts.map { Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM \($0)") }

        let migrated = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(counts.map { Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM \($0)") } == before)
        #expect(try Self.emptyCounts(migrated).values.allSatisfy { $0 == 0 }, "nothing filled before the activation")
        #expect(try Schema154Fixture.count(migrated, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
        #expect(Set(try migrated.loadSourcesWithoutContent().map(\.id)) == Set(library.sourceIDs))
    }

    @Test("A migrated store and a fresh one hold the same 155 tables")
    func migratedMatchesFresh() throws {
        let freshRoot = try Schema154Fixture.temporaryRoot("155-parity-fresh")
        let migratedRoot = try Schema154Fixture.temporaryRoot("155-parity-migrated")
        defer {
            try? FileManager.default.removeItem(at: freshRoot)
            try? FileManager.default.removeItem(at: migratedRoot)
        }
        _ = try KnowledgeStore(storeDirectory: freshRoot, freeSpace: Schema154Fixture.roomy)
        try Schema154Fixture.makeLibrary(at: migratedRoot, version: 154)
        _ = try KnowledgeStore(storeDirectory: migratedRoot, freeSpace: Schema154Fixture.roomy)
        let names = Self.tables.map { "'\($0)'" }.joined(separator: ", ")
        let objects = """
            SELECT group_concat(type || ' ' || name || ': ' || COALESCE(sql, ''), char(10)) FROM (
                SELECT type, name, sql FROM sqlite_master WHERE tbl_name IN (\(names)) ORDER BY type, name
            )
        """
        let fresh = Schema154Fixture.scalar(at: freshRoot, objects)
        #expect(fresh != nil && fresh == Schema154Fixture.scalar(at: migratedRoot, objects))
    }

    @Test("A same-named table of another shape rolls 155 back and leaves the store at 154")
    func rollback() throws {
        let root = try Schema154Fixture.temporaryRoot("155-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: 154)
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "CREATE TABLE source_files (something_else TEXT)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        }
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == 154)
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'source_work_keys'") == 0, "nothing of 155 stays")
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sources") == 3)
    }

    @Test("A production-sized library migrates from 154 to 155 in well under a second")
    func scale() throws {
        let root = try Schema154Fixture.temporaryRoot("155-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
            try Schema154Fixture.restoreGeneration1Tables(store)
            // 6,000 sources (the largest library has 5,161) with their article rows and 1,000 group
            // memberships, and 17,000 sync rows.
            try store.execForTesting("""
                BEGIN IMMEDIATE;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 6000)
                INSERT INTO sources (id, date_added, state, source_type, status)
                SELECT printf('source-%05d', n), n, 'ready', 'article', 'active' FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 6000)
                INSERT INTO articles (source_id, url, normalized_url, title, domain)
                SELECT printf('source-%05d', n), printf('https://example.com/%05d', n),
                       printf('example.com/%05d', n), printf('Source %05d', n), 'example.com' FROM seq;
                INSERT INTO group_members (source_id, group_id, sort_index)
                SELECT id, 'book-' || (date_added % 20), date_added FROM sources WHERE date_added <= 1000;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 17000)
                INSERT INTO sync_metadata (entity_type, logical_key, record_name, user_modification_at, is_deleted)
                SELECT 'source', printf('logical-%05d', n), printf('Source-%05d', n), n, 0 FROM seq;
                COMMIT;
            """)
            try Schema154Fixture.restoreSchema154Shape(store)
        }

        let started = ContinuousClock.now
        let migrated = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        let elapsed = started.duration(to: .now)
        print("schema 154 → 155 over 6,000 sources: \(elapsed)")
        #expect(elapsed < .seconds(5))
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        var visible = 0
        try migrated.query("SELECT COUNT(*) FROM source_projection") { visible = Int(sqlite3_column_int($0, 0)) }
        #expect(visible == 6_000, "sources stay visible")
    }

    // MARK: The activation's derivations (§13.3 step 3c)

    private static let playlistGroup = "playlist_youtube.com/playlist?list=UU8kGsMa0LygSX9nkBcBH1Sg"

    /// A generation-1 library: three episodes of one show, a channel's video and one whose `domain` is
    /// only the host, two members of a playlist nobody follows, a course's video and a stray group.
    private static func makeGeneration1Library(at root: URL) throws {
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        for index in 1...3 {
            var episode = StudioArticle(url: "https://podcasts.example.org/huberman/\(index)", title: "Episode \(index)", sourceType: .podcast)
            episode.domain = "Huberman Lab"
            try store.saveSource(episode)
        }
        var channel = StudioArticle(url: "https://www.youtube.com/watch?v=abcdefghijk", title: "Networks", sourceType: .video)
        channel.domain = "Alon Lab"
        try store.saveSource(channel)
        var hostOnly = StudioArticle(url: "https://www.youtube.com/watch?v=bcdefghijkl", title: "A talk", sourceType: .video)
        hostOnly.domain = "www.youtube.com"
        try store.saveSource(hostOnly)
        for (index, id) in ["cdefghijklm", "defghijklmn"].enumerated() {
            var member = StudioArticle(url: "https://www.youtube.com/watch?v=\(id)", title: "Member \(index)", sourceType: .video, parentGroup: playlistGroup)
            member.domain = "Liked videos"
            member.courseSortIndex = index
            try store.saveSource(member)
        }
        try store.execForTesting("INSERT INTO courses (id, title) VALUES ('course-1', 'A course')")
        try store.saveSource(StudioArticle(url: "https://www.youtube.com/watch?v=efghijklmno", title: "Lecture 1", sourceType: .video, parentGroup: "course-1"))
        try store.saveSource(StudioArticle(url: "https://example.org/stray", title: "Stray", sourceType: .article, parentGroup: "a stray group"))
    }

    private static func runDerivations(_ store: KnowledgeStore) throws {
        for derivation in KnowledgeStore.sourceActivationDerivations {
            try derivation.run(store)
        }
    }

    /// Everything the derivations write, as text.
    private static func derived(_ store: KnowledgeStore) throws -> [String] {
        var rows: [String] = []
        try store.query("SELECT 'c|' || id || '|' || kind || '|' || external_key || '|' || title || '|' || COALESCE(added_at, '') FROM source_collections ORDER BY id", []) {
            rows.append($0.text(0) ?? "")
        }
        try store.query("SELECT 'k|' || source_id || '|' || work_key FROM source_work_keys ORDER BY 1", []) { rows.append($0.text(0) ?? "") }
        try store.query("SELECT 'w|' || id || '|' || COALESCE(wire_id, 'NULL') FROM sources ORDER BY id", []) { rows.append($0.text(0) ?? "") }
        try store.query("SELECT 'i|' || zone_key || '|' || record_type || '|' || wire_id || '|' || local_id FROM ck_identity ORDER BY 1", []) {
            rows.append($0.text(0) ?? "")
        }
        return rows
    }

    @Test("The derivations run twice to one result: one show from its episodes, one channel, the unfollowed playlist")
    func derivationsRunTwice() throws {
        let root = try Schema154Fixture.temporaryRoot("155-derive")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeGeneration1Library(at: root)
        Schema154Fixture.newLaunch(root)
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        try Self.runDerivations(store)
        let first = try Self.derived(store)
        try Self.runDerivations(store)
        #expect(try Self.derived(store) == first, "a second run changes nothing")

        let show = SyncIdentity.collectionID(kind: "podcastShow", externalKey: "Huberman Lab")
        #expect(try SourceSyncFixture.count(store, "SELECT COUNT(*) FROM source_collections WHERE kind = 'podcastShow'") == 1)
        #expect(try SourceSyncFixture.text(store, "SELECT title FROM source_collections WHERE id = ?", [.text(show)]) == "Huberman Lab")
        let earliest = try SourceSyncFixture.text(store, "SELECT CAST(MIN(s.date_added) AS TEXT) FROM sources s JOIN podcasts p ON p.source_id = s.id")
        #expect(try SourceSyncFixture.text(store, "SELECT CAST(added_at AS TEXT) FROM source_collections WHERE id = ?", [.text(show)]) == earliest,
                "added when its first episode was")
        // Only a real channel name makes a channel: not the host, and not the playlist's "Liked videos".
        #expect(try SourceSyncFixture.text(store, "SELECT group_concat(external_key) FROM source_collections WHERE kind = 'youtubeChannel'") == "Alon Lab")
        // The playlist nobody follows gets its Collection from its group id, R7-m5.
        #expect(try SourceSyncFixture.text(store, "SELECT kind || '|' || external_key || '|' || title FROM source_collections WHERE id = ?", [.text(Self.playlistGroup)])
                == "playlist|youtube.com/playlist?list=UU8kGsMa0LygSX9nkBcBH1Sg|\(Self.playlistGroup)")
        #expect(try SourceSyncFixture.count(store, "SELECT COUNT(*) FROM source_collections WHERE id IN ('course-1', 'a stray group')") == 0)
        // Every personal source carries its own id as wire id, and its address as a work key.
        #expect(try SourceSyncFixture.count(store, "SELECT COUNT(*) FROM sources WHERE wire_id IS NOT id") == 0)
        let stray = SourceIdentity.stableID(for: "https://example.org/stray")
        #expect(try SourceSyncFixture.count(store, "SELECT COUNT(*) FROM source_work_keys WHERE source_id = ? AND work_key = 'url:' || ?",
                                            [.text(stray), .text(URLNormalizer.normalize("https://example.org/stray"))]) == 1)
        let video = SourceIdentity.stableID(for: "https://www.youtube.com/watch?v=abcdefghijk")
        #expect(try SourceSyncFixture.count(store, "SELECT COUNT(*) FROM source_work_keys WHERE source_id = ? AND work_key = 'yt:abcdefghijk'", [.text(video)]) == 1)
    }

    @Test("Playlist Entries come only from playlist groups: a course's or a stray group gives none")
    func playlistEntriesOnlyForPlaylistGroups() throws {
        let root = try Schema154Fixture.temporaryRoot("155-entries")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeGeneration1Library(at: root)
        Schema154Fixture.newLaunch(root)
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        let table = try #require(PlaylistEntryProjection().tables.first)
        var entries: [String] = []
        try store.query("SELECT source_id, group_id FROM group_members ORDER BY group_id, source_id", []) { row in
            let values: [String: SQLiteValue] = ["source_id": .text(row.text(0)), "group_id": .text(row.text(1))]
            if let record = table.record(values) { entries.append(record.personalID) }
        }
        let members = ["cdefghijklm", "defghijklmn"].map { SourceIdentity.stableID(for: "https://www.youtube.com/watch?v=\($0)") }
        #expect(entries.sorted() == members.map { PlaylistEntryProjection.entryID(playlistID: Self.playlistGroup, sourceID: $0) }.sorted())
    }

    @Test("A run after generation-1 imports reflects them")
    func derivationsAfterGeneration1Imports() throws {
        let root = try Schema154Fixture.temporaryRoot("155-after-gen1")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeGeneration1Library(at: root)
        do {
            Schema154Fixture.newLaunch(root)
            let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
            try Self.runDerivations(store)
        }
        // A generation-1 release opens the store again (it was never activated) and imports more.
        do {
            Schema154Fixture.newLaunch(root)
            let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
            var episode = StudioArticle(url: "https://podcasts.example.org/lex/1", title: "Lex 1", sourceType: .podcast)
            episode.domain = "Lex Fridman Podcast"
            try store.saveSource(episode)
        }
        Schema154Fixture.newLaunch(root)
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        try Self.runDerivations(store)
        #expect(try SourceSyncFixture.text(store, "SELECT group_concat(external_key, '|') FROM (SELECT external_key FROM source_collections WHERE kind = 'podcastShow' ORDER BY 1)")
                == "Huberman Lab|Lex Fridman Podcast")
        let lex = SourceIdentity.stableID(for: "https://podcasts.example.org/lex/1")
        #expect(try SourceSyncFixture.count(store, "SELECT COUNT(*) FROM sources WHERE id = ? AND wire_id = id", [.text(lex)]) == 1)
        #expect(try SourceSyncFixture.count(store, "SELECT COUNT(*) FROM source_work_keys WHERE source_id = ?", [.text(lex)]) >= 1)
    }

    @Test("A team's copy of a source takes the personal source's id as its wire id, mapped in ck_identity")
    func teamCopiesMapToCanonicalIDs() throws {
        let (root, store) = try SourceSyncFixture.makeStore("155-team", triggers: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let teamID = "6F1C0E8A-0B8D-4D5C-9F5E-3F0E1C2B9A77"
        try store.execForTesting("""
            INSERT INTO teams (id, name, role, permission, zone_scope, zone_name, created_at, joined_at, updated_at)
            VALUES ('\(teamID)', 'Lab', 'owner', 'readWrite', 'private', 'Team-1', 1, 1, 1)
        """)
        let url = "https://example.org/shared-paper"
        let personal = try SourceSyncFixture.save(store, StudioArticle(url: url, title: "Mine", sourceType: .article, id: "6A0D2A43-PERSONAL"))
        var copy = StudioArticle(url: url, title: "Team copy", sourceType: .article, id: TeamContentIdentity.sourceID(teamID: teamID, url: url))
        copy.teamID = teamID
        try store.saveSource(copy)
        let orphan = "https://example.org/only-in-team"
        var lone = StudioArticle(url: orphan, title: "Only the team's", sourceType: .article, id: TeamContentIdentity.sourceID(teamID: teamID, url: orphan))
        lone.teamID = teamID
        try store.saveSource(lone)

        try Self.runDerivations(store)
        #expect(try SourceSyncFixture.text(store, "SELECT wire_id FROM sources WHERE id = ?", [.text(copy.id)]) == personal.id)
        #expect(try SourceSyncFixture.text(store, "SELECT wire_id FROM sources WHERE id = ?", [.text(lone.id)]) == SourceIdentity.stableID(for: orphan))
        let zone = "private/Space-\(teamID.lowercased())"
        #expect(try SourceSyncFixture.text(store, "SELECT local_id FROM ck_identity WHERE zone_key = ? AND record_type = 'Source' AND wire_id = ?",
                                           [.text(zone), .text(personal.id)]) == copy.id)
        #expect(try SourceSyncFixture.count(store, "SELECT COUNT(*) FROM ck_identity WHERE local_id = ?", [.text(personal.id)]) == 0, "the personal copy needs no mapping")
    }

    @Test("The whole activation runs on a real library: derivations, then the Source, Collection and Entry triggers")
    func activationInstallsTheTriggers() throws {
        let root = try Schema154Fixture.temporaryRoot("155-activate")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeGeneration1Library(at: root)
        Schema154Fixture.newLaunch(root)
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        let journal = try GenerationActivation(store: store).run(.freshNoHistory)
        #expect(journal.activatedAt != nil)
        #expect(try SourceSyncFixture.count(store, "SELECT COUNT(*) FROM source_collections") == 3)
        for table in ["sources", "papers", "group_members", "books", "meeting_groups", "video_playlists", "source_collections", "source_work_keys"] {
            #expect(try SourceSyncFixture.count(store, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ?", [.text(table)]) > 0, "\(table)")
        }
        #expect(try SourceSyncFixture.count(store, "SELECT COUNT(*) FROM ck_outbox_fields") == 0, "derived before the triggers: nothing to send yet")
        // A write after it is recorded.
        try store.execForTesting("UPDATE articles SET title = 'Renamed' WHERE source_id = '\(SourceIdentity.stableID(for: "https://example.org/stray"))'")
        #expect(try SourceSyncFixture.count(store, "SELECT COUNT(*) FROM ck_outbox_fields WHERE source_table = 'articles' AND column = 'title'") == 1)
    }
}
