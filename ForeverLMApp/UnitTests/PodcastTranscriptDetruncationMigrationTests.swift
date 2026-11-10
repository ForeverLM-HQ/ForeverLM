import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Schema 167 queues every podcast episode the completeness audit can measure,
/// because schema 85's audit passed transcripts the retired 50,000-character
/// cap had cut (it counted 85% of the TTML text as complete) and marked them
/// done. What the step queues, what it leaves alone and what it never touches
/// are the contract, asserted against released 165 (build 188) and 164 shapes.
@Suite("Podcast transcript detruncation migration")
struct PodcastTranscriptDetruncationMigrationTests {

    private static func episode(
        id: String,
        url: String? = nil,
        show: String = "Visible Show",
        title: String = "An Episode"
    ) -> StudioArticle {
        // A public episode address of its own, stable across runs.
        let trackID = id.unicodeScalars.reduce(1_000_700_000_000) { ($0 * 31 + Int64($1.value)) % 1_000_000_000_000 + 1_000_000_000_000 }
        var article = StudioArticle(
            url: url ?? "apple-podcast://episode/\(trackID)",
            title: title,
            sourceType: .podcast,
            id: id
        )
        article.domain = show
        return article
    }

    private static let ttml = "<tt><body><div><p begin='0' end='1' ttm:agent='SPEAKER_1'>The whole episode, every word of it.</p></div></body></tt>"
    private static let transcript = "A transcript as the library stores it, with enough words to measure."

    /// A released store at `version` (165, build 188, or 164): today's shape
    /// without schema 167's audit table and queue column, the queue rebuilt
    /// verbatim from production's `sqlite_master`, and for 164 without the three
    /// sensemaking tables 165 added. Schema 166's local queue goes too where a
    /// tree that carries it made the store. Rows are written first, as the
    /// released builds wrote them, then the shape is taken back: the old
    /// marker stands on the episodes schema 85 audited or hydration wrote.
    private static func makeReleasedStore(
        at root: URL,
        version: Int32,
        triggers: Bool = false,
        populate: (KnowledgeStore) throws -> Void
    ) throws {
        let store = try KnowledgeStore(storeDirectory: root)
        if triggers { try store.installOutboxTriggers() }
        try populate(store)
        if triggers {
            try store.execForTesting("DELETE FROM ck_outbox_fields; DELETE FROM ck_outbox;")
        }
        try store.execForTesting("""
            DROP TABLE IF EXISTS source_text_soft_hyphen_repair_queue;
            DROP TABLE podcast_transcript_audits;
            DROP TABLE podcast_transcript_detruncation_queue;
            CREATE TABLE podcast_transcript_detruncation_queue (
                    source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                    enqueued_at REAL NOT NULL,
                    attempt_count INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT
                );
            CREATE INDEX idx_podcast_transcript_detruncation_queue_order
                ON podcast_transcript_detruncation_queue(attempt_count, enqueued_at, source_id);
        """)
        if version < 165 {
            try store.execForTesting("DROP TABLE atlases; DROP TABLE source_levels; DROP TABLE source_faces;")
        }
        try store.execForTesting("PRAGMA user_version = \(version)")
    }

    private static func scalar(at root: URL, _ sql: String) -> String? {
        Schema154Fixture.scalar(at: root, sql)
    }

    private static func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The library the step is measured against: every kind of podcast row the
    /// audit must queue, and every kind it must leave alone.
    private static func populateLibrary(_ store: KnowledgeStore) throws {
        // Passed schema 85's 85% test with its end missing, and marked done.
        try store.saveSource(episode(id: "capped-marked"))
        try store.saveTranscript("capped-marked", transcript, rawTTML: ttml)
        // Hydrated whole, which marked it too. The marker cannot tell the two
        // apart, so both are measured again.
        try store.saveSource(episode(id: "hydrated-marked"))
        try store.saveTranscript("hydrated-marked", transcript, rawTTML: ttml)
        // Left in schema 85's queue with its attempts spent.
        try store.saveSource(episode(id: "exhausted"))
        try store.saveTranscript("exhausted", transcript, rawTTML: ttml)
        // A hidden episode is audited too; only the formatting is withheld.
        try store.saveSource(episode(id: "hidden-ttml"))
        try store.saveTranscript("hidden-ttml", transcript, rawTTML: ttml)
        try store.setPodcastEpisodeHidden("hidden-ttml", hidden: true)
        // No TTML here (it never syncs), a public Apple episode: one fetch.
        try store.saveSource(episode(id: "apple-ttmlless", url: "apple-podcast://episode/1000745466204"))
        try store.saveTranscript("apple-ttmlless", transcript)

        // Captions from a YouTube video, not Apple's transcript.
        try store.saveSource(episode(id: "youtube-text", url: "apple-podcast://episode/1000787449271"))
        try store.savePodcastYouTubeTranscript("youtube-text", transcript, youtubeURL: "https://www.youtube.com/watch?v=abc123")
        try store.saveSource(episode(id: "youtu-be-text", url: "apple-podcast://episode/1000787449272"))
        try store.savePodcastYouTubeTranscript("youtu-be-text", transcript, youtubeURL: "https://youtu.be/abc123")
        // A private feed's placeholder has no public id to fetch by.
        try store.saveSource(episode(
            id: "private-feed",
            url: "apple-podcast://episode/private/" + String(repeating: "0a1b2c3d", count: 8)
        ))
        try store.saveTranscript("private-feed", transcript)
        // No transcript yet: hydration writes it whole.
        try store.saveSource(episode(id: "transcriptless"))
        // Archived.
        try store.saveSource(episode(id: "archived"))
        try store.saveTranscript("archived", transcript, rawTTML: ttml)
        try store.archiveSource("archived")
        // The cap was a podcast import path.
        var article = StudioArticle(url: "https://example.com/article", title: "An Article", sourceType: .article, id: "article-source")
        article.domain = "example.com"
        try store.saveSource(article)
        try store.saveTranscript("article-source", "Article body text.")
    }

    /// What a released store held: the old marker on the audited and hydrated
    /// episodes, and schema 85's spent queue row.
    private static func stampReleasedState(at root: URL) throws {
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, """
            UPDATE podcasts SET detruncated_ttml_sha256 = 'schema-85-marker'
            WHERE source_id IN ('capped-marked', 'hydrated-marked', 'hidden-ttml', 'archived');
            INSERT INTO podcast_transcript_detruncation_queue (source_id, enqueued_at, attempt_count, last_error)
            VALUES ('exhausted', 1, 3, 'Could not extract transcript text from the stored TTML.');
        """, nil, nil, nil) == SQLITE_OK)
    }

    private static func queuedIDs(at root: URL) -> [String] {
        var ids: [String] = []
        var database: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("knowledge.db").path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(database, "SELECT source_id FROM podcast_transcript_detruncation_queue ORDER BY source_id", -1, &statement, nil)
        while sqlite3_step(statement) == SQLITE_ROW { ids.append(String(cString: sqlite3_column_text(statement, 0))) }
        sqlite3_finalize(statement)
        return ids
    }

    @Test("On a store with the outbox triggers the step records nothing in the outbox")
    func version167SendsNothingToTheOutbox() throws {
        let root = try Self.temporaryRoot("schema-v167-generation-2")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeReleasedStore(at: root, version: 165, triggers: true, populate: Self.populateLibrary)
        try Self.stampReleasedState(at: root)
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM ck_outbox_fields") == "0")
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'ck_outbox_update_podcasts'") == "1")

        _ = try KnowledgeStore(storeDirectory: root)
        #expect(Self.scalar(at: root, "PRAGMA user_version") == "\(KnowledgeStore.schemaVersion)")
        #expect(Self.queuedIDs(at: root).count == 5)
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM ck_outbox_fields") == "0")
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM ck_outbox") == "0")
    }

    @Test("A schema 167 migration that fails leaves the 165 store, its text and its marker as they were")
    func version167RollsBack() throws {
        let root = try Self.temporaryRoot("schema-v167-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeReleasedStore(at: root, version: 165, populate: Self.populateLibrary)
        try Self.stampReleasedState(at: root)
        // A queue of the right name and the wrong shape: the step cannot stage into it.
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, """
            DROP TABLE podcast_transcript_detruncation_queue;
            CREATE TABLE podcast_transcript_detruncation_queue (incompatible TEXT);
        """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root)
        }
        #expect(Self.scalar(at: root, "PRAGMA user_version") == "165")
        #expect(Self.scalar(at: root, "SELECT content FROM source_content WHERE source_id = 'capped-marked'") == Self.transcript)
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM podcasts WHERE detruncated_ttml_sha256 = 'schema-85-marker'") == "4")
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'podcast_transcript_audits'") == "0")
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM pragma_table_info('podcast_transcript_detruncation_queue') WHERE name = 'retry_after'") == "0")
    }

    @Test("An audited or hydrated episode is not queued again, and a new transcript without TTML is")
    func auditedEpisodeIsNotRequeued() throws {
        let root = try Self.temporaryRoot("schema-v167-audited")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)

        // Hydration wrote it from the whole TTML: recorded, never queued.
        try store.saveSource(Self.episode(id: "hydrated"))
        try store.saveTranscript("hydrated", Self.transcript, rawTTML: Self.ttml)
        #expect(try store.podcastTranscriptAudit(sourceID: "hydrated")?.outcome == .hydrated)
        #expect(try store.podcastTranscriptAudit(sourceID: "hydrated")?.ttmlSHA256 == PaperContentPreparationService.sha256(Self.ttml))
        #expect(try store.enqueuePodcastTranscriptDetruncationIfNeeded(sourceID: "hydrated") == false)
        // The ad pass saves without the TTML; that does not send it back.
        try store.saveTranscript("hydrated", Self.transcript + " Edited.")
        #expect(try store.podcastTranscriptDetruncationQueueCount() == 0)

        // A transcript saved without TTML on an episode no audit has seen is queued.
        try store.saveSource(Self.episode(id: "unaudited", url: "apple-podcast://episode/1000745902096"))
        try store.saveTranscript("unaudited", Self.transcript)
        #expect(try store.podcastTranscriptDetruncationQueueCount() == 1)
        #expect(try store.enqueuePodcastTranscriptDetruncationIfNeeded(sourceID: "unaudited") == false, "already queued")

        // Recording a finding takes it off the queue and keeps it off.
        try store.recordPodcastTranscriptAudit(sourceID: "unaudited", ttmlSHA256: "abc", outcome: .complete)
        #expect(try store.podcastTranscriptDetruncationQueueCount() == 0)
        #expect(try store.enqueuePodcastTranscriptDetruncationIfNeeded(sourceID: "unaudited") == false)
        #expect(try store.podcastTranscriptAudit(sourceID: "unaudited") == PodcastTranscriptAuditRecord(outcome: .complete, ttmlSHA256: "abc"))

        // A failed attempt waits for its retry time and is not due until then.
        try store.saveSource(Self.episode(id: "waiting", url: "apple-podcast://episode/1000744989426"))
        try store.saveTranscript("waiting", Self.transcript)
        try store.recordPodcastTranscriptDetruncationFailure(
            sourceID: "waiting",
            message: "offline",
            retryAfter: Date().addingTimeInterval(KnowledgeStore.podcastTranscriptAuditRetryDelay(afterAttempt: 1))
        )
        #expect(try store.podcastTranscriptDetruncationQueueCount() == 0)
        #expect(try store.podcastTranscriptDetruncationCandidates(fetchingTTML: true, limit: 5).isEmpty)
        #expect(try store.podcastTranscriptDetruncationQueueCount(now: Date().addingTimeInterval(16 * 60)) == 1)
        let due = try store.podcastTranscriptDetruncationCandidates(fetchingTTML: true, limit: 5, now: Date().addingTimeInterval(16 * 60))
        #expect(due.first?.attemptCount == 1)
        #expect(KnowledgeStore.podcastTranscriptAuditRetryDelay(afterAttempt: 1) == 15 * 60)
        #expect(KnowledgeStore.podcastTranscriptAuditRetryDelay(afterAttempt: 4) == 16 * 60 * 60)
    }

    @Test("A transcript write that would drop half an episode is refused")
    func saveTranscriptRefusesADowngrade() throws {
        let root = try Self.temporaryRoot("transcript-downgrade")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try KnowledgeStore(storeDirectory: root)
        try store.saveSource(Self.episode(id: "guarded-episode"))
        let full = String(repeating: "the whole episode. ", count: 400)
        try store.saveTranscript("guarded-episode", full)

        // The shape of the original bug: a fraction of the episode replacing it.
        #expect(throws: (any Error).self) {
            try store.saveTranscript("guarded-episode", String(full.prefix(full.count / 4)))
        }
        #expect(try store.loadSourceContent("guarded-episode") == full)

        // Deletion-only ad removal is the one pass that legitimately shrinks a
        // transcript, and it takes out sponsor reads rather than most of a show.
        let adTrimmed = String(full.prefix(full.count - 900))
        try store.saveTranscript("guarded-episode", adTrimmed)
        #expect(try store.loadSourceContent("guarded-episode") == adTrimmed)

        // A deliberate replacement still goes through when the caller says so.
        try store.saveTranscript(
            "guarded-episode",
            "A short but intended transcript.",
            allowsShorterTranscript: true
        )
        #expect(try store.loadSourceContent("guarded-episode") == "A short but intended transcript.")

        // And a fresh full extraction is never a downgrade: it carries its TTML.
        try store.saveTranscript(
            "guarded-episode",
            full,
            rawTTML: "<tt><body><p>complete</p></body></tt>"
        )
        #expect(try store.loadSourceContent("guarded-episode") == full)
    }

    @Test("A transcript that replaces another is indexed and published again; a first one, or the same one again, is not")
    func replacedTranscriptIsPublishedAgain() throws {
        let root = try Self.temporaryRoot("transcript-replaced")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        func republishQueued(_ id: String) throws -> Bool {
            try store.scalarInteger(
                "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = ? AND target = ?",
                [.text(KnowledgeStore.sourcePublishKind), .text(id)]
            ) == 1
        }
        func indexed(_ id: String) throws -> Bool {
            try store.scalarInteger("SELECT COUNT(*) FROM source_index_state WHERE source_id = ?", [.text(id)]) == 1
        }

        try store.saveSource(Self.episode(id: "episode"))
        // A first transcript is found by the publisher's sweep and the indexer.
        try store.saveTranscript("episode", Self.transcript, rawTTML: Self.ttml)
        #expect(try republishQueued("episode") == false)
        try store.recordSourceIndexed(sourceID: "episode")
        // The same text again changes nothing.
        try store.saveTranscript("episode", Self.transcript, rawTTML: Self.ttml)
        #expect(try republishQueued("episode") == false)
        #expect(try indexed("episode"))

        // Fetched or formatted again: new words, here at the same length,
        // which the indexer's own check (a change of length) would miss.
        let refetched = String(Self.transcript.reversed())
        try store.saveTranscript("episode", refetched, rawTTML: Self.ttml)
        #expect(try republishQueued("episode"))
        #expect(try indexed("episode") == false)

        // YouTube captions taken instead replace it too.
        try store.execForTesting("DELETE FROM ck_backfill_queue")
        try store.savePodcastYouTubeTranscript(
            "episode",
            "Captions from a video of the episode, with every word of it.",
            youtubeURL: "https://www.youtube.com/watch?v=abcdefghijk"
        )
        #expect(try republishQueued("episode"))

        // A text still owed its clean-up waits for the clean-up's own write.
        try store.saveSource(StudioArticle(url: "https://example.org/owed", title: "Owed", sourceType: .article, id: "owed"))
        try store.saveTranscript("owed", "The page as it was read the first time.")
        try store.execForTesting("""
            INSERT OR IGNORE INTO canonical_content_cleanup_queue (source_id, target_version, enqueued_at)
            VALUES ('owed', 1, 0)
        """)
        try store.saveTranscript("owed", "The page as it was read the second time.")
        #expect(try republishQueued("owed") == false)
    }
}
