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

/// A stored author that is not a name: a save turns it away. Schema 144's
/// step, which cleared the ones older builds had stored and staged the
/// registered-title check, went with the schema floor (174).
@Suite("A stored author is a name")
struct StoredAuthorRepairMigrationTests {
    private static let headAuthor = #"width=device-width,initial-scale=1,maximum-scale=1" name="viewport"><link href="/fonts/libre-franklin-v4-latin-regular.woff2" rel="preload" as="font" crossorigin="anonymous"><title>Quantum Country</title><meta content="#
    private static let profileAuthor = "https://www.nytimes.com/by/jasmine-sun"

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
