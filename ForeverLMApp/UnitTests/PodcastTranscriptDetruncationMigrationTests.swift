import Foundation
import Testing
@testable import ForeverLM

/// The podcast transcript completeness audit's queue and the transcript
/// writes that feed it. Schema 167's step, which queued every measurable
/// episode of an older store, went with the schema floor (174); what queues
/// an episode now, what records a finding and what a save refuses are the
/// live contract.
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

    private static func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
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
