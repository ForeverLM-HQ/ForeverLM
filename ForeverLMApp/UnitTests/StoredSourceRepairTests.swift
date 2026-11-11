// Stored source repair and check migration tests.

import Testing
import CloudKit
import Foundation
import SQLite3
@testable import ForeverLM

/// Helper: create a StudioArticle with sensible defaults for testing.
private func makeArticle(url: String, title: String? = nil) -> StudioArticle {
    var article = StudioArticle(url: url, title: title)
    article.normalizedURL = URLNormalizer.normalize(url)
    return article
}

private func seedActivityDayRows(at root: URL, count: Int) throws {
    var statements = ["BEGIN IMMEDIATE;"]
    for index in 0..<count {
        let dayStart = 780_000_000 + Double(index) * 86_400
        statements.append("""
            INSERT INTO source_activity_days (
                id, scheduled_source_id, source_id, day_start,
                first_activity_at, last_activity_at, kinds, completed_kinds, max_fraction
            ) VALUES (
                'scale-activity-\(index)', 'scale-placement', 'scale-source', \(dayStart),
                \(dayStart), \(dayStart), 1, 0, 0
            );
            """)
    }
    statements.append("COMMIT;")
    try executeFixtureSQL(at: root, sql: statements.joined(separator: "\n"))
}

private func executeFixtureSQL(at root: URL, sql: String) throws {
    let dbPath = root.appendingPathComponent("knowledge.db").path
    var database: OpaquePointer?
    guard sqlite3_open(dbPath, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "ActivityDepthFixture", code: 1)
    }
    defer { sqlite3_close(database) }

    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &message)
    guard result == SQLITE_OK else {
        let detail = message.map { String(cString: $0) } ?? "SQLite fixture error"
        sqlite3_free(message)
        throw NSError(
            domain: "ActivityDepthFixture",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: detail]
        )
    }
}

/// Adds sources whose stored text still carries HTML character references to a
/// released-shape fixture, so the v68 staging pass has real work to find.
private func addEscapedSourceText(
    at root: URL,
    rows: [(id: String, content: String)]
) throws {
    let dbPath = root.appendingPathComponent("knowledge.db").path
    var database: OpaquePointer?
    guard sqlite3_open(dbPath, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "EscapedSourceTextFixture", code: 1)
    }
    defer { sqlite3_close(database) }

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "SQLite fixture error"
            sqlite3_free(message)
            throw NSError(
                domain: "EscapedSourceTextFixture",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }

    let statements = rows.map { row in
        let escaped = row.content.replacingOccurrences(of: "'", with: "''")
        return """
        INSERT INTO sources (id, date_added, state, source_type, status)
        VALUES ('\(row.id)', 1, 'ready', 'article', 'active');
        INSERT INTO source_content (source_id, content) VALUES ('\(row.id)', '\(escaped)');
        INSERT INTO articles (source_id, url, normalized_url, title, domain)
        VALUES ('\(row.id)', 'https://example.com/\(row.id)',
                'https://example.com/\(row.id)', 'Escaped \(row.id)', 'example.com');
        """
    }.joined(separator: "\n")
    try exec("BEGIN IMMEDIATE;\n\(statements)\nCOMMIT;")
}

@Suite("Stored HTML character reference repair")
struct StoredHTMLCharacterReferenceRepairTests {
    private static let escaped = "I&#39;ve heard people say &ldquo;M&amp;M&rdquo; &ndash; Pokorn&yacute;"
    private static let decoded = "I've heard people say \u{201C}M&M\u{201D} \u{2013} Pokorn\u{00FD}"

    private func makeRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Draining decodes the staged text and republishes the source")
    func drainDecodesAndRepublishes() throws {
        let store = try TestStores.inMemory()
        var article = makeArticle(url: "https://example.com/entities", title: "Entities")
        article.content = Self.escaped
        article.state = .ready
        try store.saveSource(article)
        try store.execForTesting("""
            INSERT INTO source_text_reference_repair_queue (source_id, enqueued_at)
            VALUES ('\(article.id)', 0)
        """)

        #expect(try store.drainSourceTextReferenceRepairBatch(limit: 50) == [article.id])
        #expect(try store.loadSourceContent(article.id) == Self.decoded)
        #expect(try store.sourceTextReferenceRepairQueueCount() == 0)

        // The iPad reads the content asset off the Source record, so a local-only
        // repair would leave the phone showing the references forever.

        // Resumable and idempotent: a second pass finds nothing left to do.
        #expect(try store.drainSourceTextReferenceRepairBatch(limit: 50).isEmpty)
    }

    @Test("Draining leaves text without references alone")
    func drainLeavesCleanTextAlone() throws {
        let store = try TestStores.inMemory()
        let text = "AT&T, Q&A, and a lone & walk through unchanged."
        var article = makeArticle(url: "https://example.com/clean", title: "Clean")
        article.content = text
        article.state = .ready
        try store.saveSource(article)
        try store.execForTesting("""
            INSERT INTO source_text_reference_repair_queue (source_id, enqueued_at)
            VALUES ('\(article.id)', 0)
        """)

        #expect(try store.drainSourceTextReferenceRepairBatch(limit: 50).isEmpty)
        #expect(try store.loadSourceContent(article.id) == text)
        #expect(try store.sourceTextReferenceRepairQueueCount() == 0)
    }

    @Test("A staged source whose content is gone leaves the queue")
    func drainClearsOrphanedQueueRows() throws {
        let store = try TestStores.inMemory()
        let article = makeArticle(url: "https://example.com/orphan", title: "Orphan")
        try store.saveSource(article)
        try store.execForTesting("DELETE FROM source_content")
        try store.execForTesting("""
            INSERT INTO source_text_reference_repair_queue (source_id, enqueued_at)
            VALUES ('\(article.id)', 0)
        """)

        #expect(try store.drainSourceTextReferenceRepairBatch(limit: 50).isEmpty)
        #expect(try store.sourceTextReferenceRepairQueueCount() == 0)
    }
}

/// Schema 144: a stored author that is not a name is cleared, and every paper
/// with a DOI is staged to have its title checked against the registered one.
/// The fixture is a released schema-143 library: today's shape without the one
/// table 144 adds. The markup and the profile link go in the way older builds
/// stored them, straight into the subtype table, because a save through
/// `StudioArticle` now turns them away.
@Suite("Stored author repair and registered-title staging")
struct StoredAuthorRepairMigrationTests {
    private static let headID = "src_772d6a3c1740e956a41c0eb9794158ee676fc8a16287282a198b0a67052701ee"
    private static let profileID = "63339EAA-D59E-49DA-8ED1-E530AA504D67"
    private static let namedID = "named-article"
    private static let paperID = "src_901f36ad0112f7d80758f2eb513a32b16d456a4dfdc9f23066a5f132414b8f6a"
    private static let noDOIID = "paper-without-doi"
    private static let headAuthor = #"width=device-width,initial-scale=1,maximum-scale=1" name="viewport"><link href="/fonts/libre-franklin-v4-latin-regular.woff2" rel="preload" as="font" crossorigin="anonymous"><title>Quantum Country</title><meta content="#
    private static let profileAuthor = "https://www.nytimes.com/by/jasmine-sun"
    private static let damagedTitle = "Generation of Reactive Oxygen Species in the Reaction Catalyzed by -Ketoglutarate Dehydrogenase"

    private func makeRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    /// Build 159 shipped 142 and main carried 143 before 144; neither changed a
    /// table, so both released shapes are today's without the 144 queue.
    private func createReleasedLibrary(at root: URL, version: Int32 = 143, extraRows: Int = 0) throws {
        let store = try KnowledgeStore(storeDirectory: root)
        try Schema154Fixture.restoreGeneration1Tables(store)
        try store.saveSource(StudioArticle(url: "https://quantum.country/", title: "Quantum Country", sourceType: .article, id: Self.headID))
        try store.saveSource(StudioArticle(
            url: "https://www.nytimes.com/2026/01/03/business/chinese-peptides-silicon-valley.html",
            title: "Chinese peptides",
            sourceType: .article,
            id: Self.profileID
        ))
        try store.saveSource(StudioArticle(url: "https://example.com/named", title: "Named", sourceType: .article, author: "Jane Doe", id: Self.namedID))
        var paper = StudioArticle(
            url: "https://doi.org/10.1523/jneurosci.1842-04.2004",
            title: Self.damagedTitle,
            sourceType: .paper,
            author: "Laszlo Tretter; Vera Adam-Vizi",
            id: Self.paperID
        )
        paper.doi = "10.1523/jneurosci.1842-04.2004"
        try store.saveSource(paper)
        try store.saveSource(StudioArticle(url: "https://example.com/paper.pdf", title: "A paper without a DOI", sourceType: .paper, id: Self.noDOIID))
        try store.execForTesting("UPDATE articles SET author = '\(Self.headAuthor)' WHERE source_id = '\(Self.headID)'")
        try store.execForTesting("UPDATE articles SET author = '\(Self.profileAuthor)' WHERE source_id = '\(Self.profileID)'")
        try store.replaceSourceFTS(sourceID: Self.headID, title: "Quantum Country", author: Self.headAuthor, body: "")
        if extraRows > 0 {
            // A production-sized library: one article author in a thousand is
            // a profile link, and every paper has a DOI to check.
            try store.execForTesting("""
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(extraRows))
                INSERT INTO sources (id, date_added, state, source_type)
                SELECT printf('article-%05d', i), 0, 'ready', 'article' FROM n;
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(extraRows))
                INSERT INTO articles (source_id, url, title, author)
                SELECT printf('article-%05d', i), printf('https://example.com/a/%d', i), printf('Article %d', i),
                       CASE WHEN i % 1000 = 0 THEN printf('https://example.com/by/writer-%d', i)
                            ELSE printf('Writer %d; Editor %d', i, i) END
                FROM n;
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(extraRows))
                INSERT INTO sources (id, date_added, state, source_type)
                SELECT printf('paper-%05d', i), 0, 'ready', 'paper' FROM n;
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(extraRows))
                INSERT INTO papers (source_id, url, title, author, doi)
                SELECT printf('paper-%05d', i), printf('https://doi.org/10.1000/x%d', i),
                       printf('Mitochondrial study %d', i), printf('Author %d; Colleague %d', i, i), printf('10.1000/x%d', i)
                FROM n;
            """)
        }
        try store.execForTesting("""
            DROP INDEX IF EXISTS idx_paper_registered_title_order;
            DROP TABLE paper_registered_title_queue;
            PRAGMA user_version = \(version);
        """)
    }

    private func author(_ sourceID: String, in store: KnowledgeStore) throws -> String? {
        var value: String?
        try store.query("""
            SELECT author FROM articles WHERE source_id = '\(sourceID)'
            UNION ALL SELECT author FROM papers WHERE source_id = '\(sourceID)'
        """) { statement in
            value = store.string(statement, 0)
        }
        return value
    }

    private func count(_ sql: String, in store: KnowledgeStore) throws -> Int {
        var value = 0
        try store.query(sql) { statement in value = Int(sqlite3_column_int64(statement, 0)) }
        return value
    }

    @Test("Schema 144 reads only the author cells that could fail at production scale")
    func version144ScaleRegression() throws {
        let root = makeRoot("v144-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        try createReleasedLibrary(at: root, extraRows: 5_000)

        let startedAt = Date()
        let migrated = try KnowledgeStore(storeDirectory: root)
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(elapsed < 1.0)
        // The fixture's two plus the five profile links; nothing else touched.
        #expect(try author("article-01000", in: migrated) == nil)
        #expect(try author("article-00999", in: migrated) == "Writer 999; Editor 999")
        #expect(try migrated.registeredPaperTitleQueueCount() == 5_001)
    }

    @Test("Schema 144 rolls back and leaves the released library intact")
    func version144RollsBack() throws {
        let root = makeRoot("v144-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        try createReleasedLibrary(at: root)

        // A structurally incompatible queue table `CREATE TABLE IF NOT EXISTS`
        // will not replace: staging fails after the author was cleared, inside
        // the migration transaction.
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        if let database {
            #expect(sqlite3_exec(
                database,
                "DROP TABLE source_sync_repair_queue; CREATE TABLE source_sync_repair_queue (unexpected TEXT)",
                nil, nil, nil
            ) == SQLITE_OK)
            sqlite3_close(database)
        }

        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root)
        }

        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        func text(_ sql: String) -> String? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: value)
        }
        #expect(text("PRAGMA user_version") == "143")
        #expect(text("SELECT COUNT(*) FROM sources") == "5")
        #expect(text("SELECT author FROM articles WHERE source_id = '\(Self.headID)'") == Self.headAuthor)
        #expect(text("SELECT COUNT(*) FROM sqlite_master WHERE name = 'paper_registered_title_queue'") == "0")
        #expect(text("SELECT COUNT(*) FROM source_fts_state WHERE source_id = '\(Self.headID)'") == "1")
    }

    @Test("A save never stores an author that is not a name, for a source or a book")
    func writersRefuseImplausibleAuthors() throws {
        let store = try KnowledgeStore(inMemory: true)
        var article = StudioArticle(url: "https://example.com/post", title: "A post", sourceType: .article, id: "post")
        article.author = Self.profileAuthor
        try store.saveSource(article)
        #expect(try author("post", in: store) == nil)

        try store.saveBookMetadata(groupName: "book-1", title: "A book", author: Self.headAuthor, coverPath: nil)
        #expect(try store.loadBooks().authors["book-1"] == nil)
        try store.saveBookMetadata(groupName: "book-1", title: "A book", author: "Nick Lane", coverPath: nil)
        #expect(try store.loadBooks().authors["book-1"] == "Nick Lane")
    }
}

/// The post-launch half of schema 144: each staged paper's title against the
/// title its DOI is registered under, with the catalogs stubbed.
@Suite("Registered paper title check")
struct RegisteredPaperTitleCheckServiceTests {
    private static let damaged = "Generation of Reactive Oxygen Species in the Reaction Catalyzed by -Ketoglutarate Dehydrogenase"
    private static let registered = "Generation of Reactive Oxygen Species in the Reaction Catalyzed by α-Ketoglutarate Dehydrogenase"

    private func makeRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func seedPaper(_ id: String, title: String, doi: String, in store: KnowledgeStore) throws {
        var paper = StudioArticle(url: "https://doi.org/\(doi)", title: title, sourceType: .paper, id: id)
        paper.doi = doi
        try store.saveSource(paper)
    }

    private func count(_ sql: String, in store: KnowledgeStore) throws -> Int {
        var value = 0
        try store.query(sql) { statement in value = Int(sqlite3_column_int64(statement, 0)) }
        return value
    }

    @Test("Restores the lost glyph, leaves another work's record and an unregistered DOI alone, and keeps asking an unanswered one")
    func drainAppliesTheRule() async throws {
        let root = makeRoot("registered-title")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let store = try await storage.cohortKnowledgeStore()
        try seedPaper("a-damaged", title: Self.damaged, doi: "10.1523/jneurosci.1842-04.2004", in: store)
        try seedPaper("b-wrong-record", title: "KL1333, a derivative of β-lapachone, protects against ototoxicity", doi: "10.1016/j.lfs.2020.118394", in: store)
        try seedPaper("c-unregistered", title: "A bioRxiv version suffix", doi: "10.1101/2025.06.26.661135v2", in: store)
        try seedPaper("d-offline", title: "Asked while offline", doi: "10.1000/offline", in: store)
        #expect(try store.enqueueRegisteredPaperTitleChecks() == 4)

        let service = RegisteredPaperTitleCheckService(storage: storage) { doi in
            switch doi {
            case "10.1523/jneurosci.1842-04.2004": return .title(Self.registered)
            case "10.1016/j.lfs.2020.118394": return .title("Cardiac function and tolerance to ischemia/reperfusion injury")
            case "10.1101/2025.06.26.661135v2": return .unregistered
            default: return .unavailable("offline")
            }
        }
        let result = await service.drain()

        #expect(result.restored == [RestoredPaperTitle(sourceID: "a-damaged", title: Self.registered)])
        #expect(try store.loadSourceForSync("a-damaged")?.title == Self.registered)
        #expect(try store.loadSourceForSync("a-damaged")?.doi == "10.1523/jneurosci.1842-04.2004")
        #expect(try store.loadSourceForSync("b-wrong-record")?.title == "KL1333, a derivative of β-lapachone, protects against ototoxicity")
        // Only the restored paper travels to the other devices.

        // Answered rows leave; the unanswered one stays, one attempt per batch
        // that reached it, and the drain stopped once nothing was answered.
        #expect(result.remainingCount == 1)
        #expect(try store.registeredPaperTitleCandidates(limit: 10).map(\.sourceID) == ["d-offline"])
        #expect(try count("SELECT attempt_count FROM paper_registered_title_queue WHERE source_id = 'd-offline'", in: store) == 2)

        // Offline again: the drain ends at once without answering anything.
        let offline = await service.drain()
        #expect(offline.checkedCount == 0)
        #expect(offline.restored.isEmpty)
    }

    @Test("A title the learner changed since it was staged, or a source that is no longer a paper, is not overwritten")
    func titlesTheLearnerOwnsStand() async throws {
        let root = makeRoot("registered-title-owned")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let store = try await storage.cohortKnowledgeStore()
        try seedPaper("renamed", title: Self.damaged, doi: "10.1523/jneurosci.1842-04.2004", in: store)
        try seedPaper("moved", title: Self.damaged, doi: "10.1000/moved-to-articles", in: store)
        #expect(try store.enqueueRegisteredPaperTitleChecks() == 2)
        // The learner renamed one; the other became an article.
        try store.execForTesting("UPDATE papers SET title = 'My notes on alpha-KGDH' WHERE source_id = 'renamed'")
        var moved = try #require(try store.loadSourceForSync("moved"))
        moved.sourceType = .article
        try store.saveSource(moved)

        let service = RegisteredPaperTitleCheckService(storage: storage) { _ in .title(Self.registered) }
        let result = await service.drain()

        #expect(result.restored.isEmpty)
        #expect(try store.loadSourceForSync("renamed")?.title == "My notes on alpha-KGDH")
        #expect(try store.registeredPaperTitleQueueCount() == 0, "both rows leave the queue")
    }
}

/// Schema 148: every personal YouTube video staged for the post-launch check
/// of its stored transcript against its captions.
@Suite("YouTube transcript check staging")
struct YouTubeTranscriptCheckMigrationTests {
    private func makeRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func count(_ sql: String, in store: KnowledgeStore) throws -> Int {
        var value = 0
        try store.query(sql) { statement in value = Int(sqlite3_column_int64(statement, 0)) }
        return value
    }

    /// Build 165 shipped 146 and main carried 147 before 148. 147 added
    /// `research_directions` and nothing else, so 146's shape is today's
    /// without it and without the 148 queue.
    private func createReleasedLibrary(at root: URL, version: Int32 = 147, extraVideos: Int = 0) throws {
        let store = try KnowledgeStore(storeDirectory: root)
        try Schema154Fixture.restoreGeneration1Tables(store)
        var lecture = StudioArticle(url: "https://www.youtube.com/watch?v=6BqWzEPN3xg", title: "Intact Cell Measurements 1", sourceType: .video, id: "yt-lecture")
        lecture.content = "[0:00] So hello again. Our class today is about how to measure mitochondrial bioenergetics."
        lecture.state = .ready
        try store.saveSource(lecture)
        try store.saveSource(StudioArticle(url: "https://youtu.be/cvfACkaRwU4", title: "Queued, no transcript yet", sourceType: .video, id: "yt-queued"))
        try store.saveSource(StudioArticle(url: "https://vimeo.com/76979871", title: "Not YouTube", sourceType: .video, id: "vimeo"))
        try store.saveSource(StudioArticle(url: "https://www.youtube.com/watch?v=Y0NPG98yEjY", title: "A team's copy", sourceType: .video, id: "yt-team"))
        try store.saveSource(StudioArticle(url: "https://example.com/post", title: "An article", sourceType: .article, id: "article"))
        try store.execForTesting("UPDATE sources SET team_id = 'team-1' WHERE id = 'yt-team'")
        if extraVideos > 0 {
            // A production-sized library: four in five videos are YouTube's,
            // each with a few thousand characters of text the migration never reads.
            try store.execForTesting("""
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(extraVideos))
                INSERT INTO sources (id, date_added, state, source_type)
                SELECT printf('video-%05d', i), 0, 'ready', 'video' FROM n;
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(extraVideos))
                INSERT INTO videos (source_id, url, title)
                SELECT printf('video-%05d', i),
                       CASE WHEN i % 5 = 0 THEN printf('https://vimeo.com/%d', i)
                            ELSE printf('https://www.youtube.com/watch?v=v%010d', i) END,
                       printf('Lecture %d', i)
                FROM n;
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(extraVideos))
                INSERT INTO source_content (source_id, content)
                SELECT printf('video-%05d', i), printf('[0:00] %s', hex(randomblob(1000))) FROM n;
            """)
        }
        try store.execForTesting("""
            DROP INDEX IF EXISTS idx_youtube_transcript_check_order;
            DROP TABLE youtube_transcript_check_queue;
            \(version < 147 ? "DROP TABLE IF EXISTS research_directions;" : "")
            PRAGMA user_version = \(version);
        """)
    }

    @Test("Schema 148 stages ids only at production scale")
    func version148ScaleRegression() throws {
        let root = makeRoot("v148-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        try createReleasedLibrary(at: root, extraVideos: 5_000)

        let startedAt = Date()
        let migrated = try KnowledgeStore(storeDirectory: root)
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(elapsed < 1.0)
        // The fixture's two plus the four in five of the extra videos on YouTube.
        #expect(try migrated.youTubeTranscriptCheckQueueCount() == 4_002)
        #expect(try count("SELECT COUNT(*) FROM youtube_transcript_check_queue WHERE source_id = 'video-00005'", in: migrated) == 0)
    }

    @Test("Schema 148 rolls back and leaves the released library intact")
    func version148RollsBack() throws {
        let root = makeRoot("v148-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        try createReleasedLibrary(at: root)

        // A same-named queue of another shape, which `CREATE TABLE IF NOT
        // EXISTS` will not replace: the probe fails inside the migration.
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        if let database {
            #expect(sqlite3_exec(database, "CREATE TABLE youtube_transcript_check_queue (unexpected TEXT)", nil, nil, nil) == SQLITE_OK)
            sqlite3_close(database)
        }

        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root)
        }

        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        func text(_ sql: String) -> String? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: value)
        }
        #expect(text("PRAGMA user_version") == "147")
        #expect(text("SELECT COUNT(*) FROM sources") == "5")
        #expect(text("SELECT COUNT(*) FROM youtube_transcript_check_queue") == "0")
        #expect(text("SELECT substr(content, 1, 22) FROM source_content WHERE source_id = 'yt-lecture'") == "[0:00] So hello again.")
    }
}

/// The post-launch half of schema 148: each staged video's stored transcript
/// against its captions, with the caption fetch stubbed. The fixture is
/// "Isolated Mitochondria and Permeabilized Cells/Tissues 3" at 8:47, as
/// Transcript Formatting stored it and as YouTube's captions have it.
@Suite("YouTube transcript check")
struct YouTubeTranscriptCheckServiceTests {
    private static let url = "https://www.youtube.com/watch?v=2GyLXusxhk4"

    private static let captions = """
    [8:47] of the mitochondrial inner membrane and the matrix and they can act as quenchers and blockers of lipid oxidation processes that happen by chain reactions in which one lipid will oxidize another and oxidize another sometimes these probes can block these reactions so they can be inhibitors of lipid oxidation so you may be measuring membrane potential and you're not aware of the fact that you're actually using a pretty good quencher of lipid oxidation

    [9:15] and inhibiting this process in your media because of your probe and not because it's not happening one of my pet peeves about membrane potential measurements and this is very important is that a change in fluorescence or a change in absorbance does not correlate one to one with your inner mitochondrial membrane potential
    """

    /// The model's text: the clause at 8:47 and the opening of 9:15 lost,
    /// the two blocks run into one paragraph.
    private static let formatted = """
    [8:47] Of the mitochondrial inner membrane and the matrix, they can act as quenchers and blockers of lipid oxidation processes that happen by chain reactions in which one lipid will oxidize another and oxidize another. Sometimes these probes can block these reactions, so you may be measuring membrane potential and you're not aware of the fact that you're actually using a pretty good quencher of lipid oxidation. And not because it's not happening; one of my pet peeves about membrane potential measurements, and this is very important, is that a change in fluorescence or a change in absorbance does not correlate one to one with your inner mitochondrial membrane potential.
    """

    private static let slides = """


    ## Extracted video slide frames

    ### Slide frame 1 [8:30–9:40]
    Image: Videos/video/Slides/slide_001_000510s.jpg
    """

    private func makeRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func seedVideo(_ id: String, content: String?, url: String = Self.url, in store: KnowledgeStore) throws {
        var video = StudioArticle(url: url, title: "Isolated Mitochondria 3", sourceType: .video, id: id)
        video.content = content
        video.state = content == nil ? .queued : .ready
        try store.saveSource(video)
    }

    private func count(_ sql: String, in store: KnowledgeStore) throws -> Int {
        var value = 0
        try store.query(sql) { statement in value = Int(sqlite3_column_int64(statement, 0)) }
        return value
    }

    @Test("Puts back what the model dropped, keeps the slide frames, publishes the change and leaves the queue")
    func rewritesADroppedRun() async throws {
        let root = makeRoot("yt-check-rewrite")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let store = try await storage.cohortKnowledgeStore()
        try seedVideo("video", content: Self.formatted + Self.slides, in: store)
        #expect(try store.enqueueYouTubeTranscriptChecks() == 1)

        let service = YouTubeTranscriptCheckService(storage: storage) { url in
            #expect(url == Self.url)
            return Self.captions
        }
        let result = await service.drain()

        let stored = try #require(try store.loadSourceContent("video"))
        #expect(result.rewritten.map(\.sourceID) == ["video"])
        #expect(result.rewritten.first?.content == stored)
        #expect(stored.contains("these reactions, so they can be inhibitors of lipid oxidation so you may be measuring"))
        #expect(stored.contains("\n\n[9:15] And inhibiting this process in your media because of your probe and not because it's not happening;"))
        #expect(stored.hasSuffix(Self.slides), "the slide frames block is kept as it was")
        #expect(result.remainingCount == 0)

        // Checked once: a later drain has nothing to fetch.
        let again = await YouTubeTranscriptCheckService(storage: storage) { _ in
            Issue.record("a checked video is not fetched again")
            return Self.captions
        }.drain()
        #expect(again.checkedCount == 0)
    }

    @Test("A transcript of raw captions, or one without markers, is left as it is")
    func leavesRawCaptionsAlone() async throws {
        let root = makeRoot("yt-check-raw")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let store = try await storage.cohortKnowledgeStore()
        try seedVideo("raw", content: Self.captions, in: store)
        try seedVideo("untimed", content: "A transcript someone pasted without times.", in: store)
        try seedVideo("empty", content: nil, in: store)
        #expect(try store.enqueueYouTubeTranscriptChecks() == 3)

        let result = await YouTubeTranscriptCheckService(storage: storage) { _ in Self.captions }.drain()

        #expect(result.rewritten.isEmpty)
        #expect(try store.loadSourceContent("raw") == Self.captions)
        #expect(try store.youTubeTranscriptCheckQueueCount() == 0, "all three are answered")
    }

    @Test("A transcript is kept when the check would move a highlight or the lines a quiz question rests on")
    func keepsAnchoredText() async throws {
        let root = makeRoot("yt-check-anchored")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let store = try await storage.cohortKnowledgeStore()
        try seedVideo("highlighted", content: Self.formatted, in: store)
        try seedVideo("quizzed", content: Self.formatted, in: store)
        try seedVideo("free", content: Self.formatted, in: store)

        // A highlight across the words the check puts back between.
        let quote = "block these reactions, so you may be measuring"
        try store.saveSourceHighlight(SourceHighlight(
            id: "hl", sourceID: "highlighted", quote: quote, note: "", color: .yellow,
            anchor: ReaderTextAnchor(exact: quote), createdAt: Date(), updatedAt: Date()
        ))
        // A question on line 1, where the model ran 9:15 into 8:47's
        // paragraph: re-cut into caption blocks, its quote is on line 2.
        try store.saveCourseGroup(name: "course", metadata: CourseMetadata(title: "Bioenergetics"))
        let lecture = CourseSession(courseName: "course", number: 1, title: "Membrane potential")
        try store.saveCourseLecture(lecture)
        try store.saveCourseQuiz(CourseQuiz(
            id: CourseQuizPlanning.practiceID(courseID: "course", lectureID: lecture.id),
            courseID: "course", kind: .practice, title: "Quiz", lectureIDs: [lecture.id],
            afterLectureID: lecture.id,
            questions: [CourseQuizQuestion(
                id: "q1", sourceID: "quizzed", firstLine: 1, lastLine: 1, startSeconds: nil,
                question: "Why calibrate?", answer: "Fluorescence is not membrane potential.",
                keyPoints: ["no one-to-one relation"],
                quote: "a change in fluorescence or a change in absorbance does not correlate one to one"
            )],
            author: .foreverlm, createdAt: Date(), updatedAt: Date()
        ))
        #expect(try store.enqueueYouTubeTranscriptChecks() == 3)

        let result = await YouTubeTranscriptCheckService(storage: storage) { _ in Self.captions }.drain()

        #expect(result.rewritten.map(\.sourceID) == ["free"])
        #expect(try store.loadSourceContent("highlighted") == Self.formatted)
        #expect(try store.loadSourceContent("quizzed") == Self.formatted)
        #expect(try store.youTubeTranscriptCheckQueueCount() == 0, "a kept transcript is answered too")
    }

    @Test("Offline, a failed fetch counts an attempt and ends the drain; a video without captions, or one reformatted meanwhile, is left alone")
    func failuresAndRaces() async throws {
        let root = makeRoot("yt-check-failures")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let store = try await storage.cohortKnowledgeStore()
        try seedVideo("a", content: Self.formatted, url: "https://www.youtube.com/watch?v=aaaaaaaaaaa", in: store)
        try seedVideo("b", content: Self.formatted, url: "https://www.youtube.com/watch?v=bbbbbbbbbbb", in: store)
        #expect(try store.enqueueYouTubeTranscriptChecks() == 2)

        let offline = await YouTubeTranscriptCheckService(storage: storage) { _ in
            throw URLError(.notConnectedToInternet)
        }.drain()
        #expect(offline.checkedCount == 0)
        #expect(try count("SELECT MAX(attempt_count) FROM youtube_transcript_check_queue", in: store) == 1)
        #expect(try store.youTubeTranscriptCheckQueueCount() == 2)

        // "a" has no captions any more; "b" is reformatted while its captions
        // are fetched, and the newer text stands.
        let database = root.appendingPathComponent("knowledge.db").path
        let result = await YouTubeTranscriptCheckService(storage: storage) { url in
            guard url.hasSuffix("bbbbbbbbbbb") else { throw YouTubeTranscriptError.noTranscriptAvailable }
            var connection: OpaquePointer?
            guard sqlite3_open(database, &connection) == SQLITE_OK else { throw URLError(.cannotOpenFile) }
            defer { sqlite3_close(connection) }
            sqlite3_busy_timeout(connection, 2_000)
            #expect(sqlite3_exec(
                connection,
                "UPDATE source_content SET content = '[0:00] Reformatted meanwhile.' WHERE source_id = 'b'",
                nil, nil, nil
            ) == SQLITE_OK)
            return Self.captions
        }.drain()
        #expect(result.rewritten.isEmpty)
        #expect(try store.loadSourceContent("a") == Self.formatted)
        #expect(try store.loadSourceContent("b") == "[0:00] Reformatted meanwhile.")
        #expect(try store.youTubeTranscriptCheckQueueCount() == 0)
    }
}
