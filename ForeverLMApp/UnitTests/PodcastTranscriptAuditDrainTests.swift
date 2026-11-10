import Foundation
import Testing
@testable import ForeverLM

/// The completeness audit's drain (`PodcastTranscriptDetruncationService`):
/// what it restores, what it leaves alone, what it fetches, and what the
/// loaded library holds afterwards. The episodes are synthetic TTML whose
/// extracted text has the shape of a real one; the cut ones are cut where the
/// retired cap cut, at character 50,000 of that text.
@Suite("Podcast transcript audit drain")
@MainActor
struct PodcastTranscriptAuditDrainTests {

    /// A TTML of `turns` turns of 8 sentences of 9 words, speakers alternating.
    /// Its extracted text is laid out as `SourceService.extractTextFromTTMLContent`
    /// lays out every episode, and at 120 turns the cap falls inside a word.
    static func episodeTTML(turns: Int, firstWord: Int = 1) -> String {
        var paragraphs: [String] = []
        var n = firstWord - 1
        for turn in 0..<turns {
            var spans: [String] = []
            for _ in 0..<8 {
                for word in 0..<9 {
                    n += 1
                    spans.append("<span podcasts:unit=\"word\">Word\(n)\(word == 8 ? "." : "")</span>")
                }
            }
            paragraphs.append(
                "<p begin=\"\(turn).0\" end=\"\(turn).9\" ttm:agent=\"SPEAKER_\(turn % 2 + 1)\">\(spans.joined(separator: " "))</p>"
            )
        }
        return "<tt xmlns=\"http://www.w3.org/ns/ttml\"><body><div>\(paragraphs.joined())</div></body></tt>"
    }

    static let ttml = episodeTTML(turns: 120)
    static let episodeText = try! SourceService.extractTextFromTTMLContent(ttml)
    static let capped = String(episodeText.prefix(PodcastTranscriptCompleteness.retiredImportCap))

    static func makeStorage(_ name: String) throws -> (StorageService, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastTranscriptAudit-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StorageService(storeRoot: root), root)
    }

    static func episode(id: String, trackID: Int64) -> StudioArticle {
        var article = StudioArticle(
            url: "apple-podcast://episode/\(trackID)",
            title: "Episode \(id)",
            sourceType: .podcast,
            id: id
        )
        article.domain = "A Show"
        article.state = .queued
        return article
    }

    /// One episode holding `stored`, its TTML stored here when given, queued for
    /// the audit the way a transcript saved without its TTML queues it. Its ad
    /// pass is shown done, so a restore that stages it again is visible.
    static func seed(
        _ storage: StorageService,
        id: String,
        trackID: Int64,
        stored: String,
        ttml: String?,
        hidden: Bool = false
    ) async throws {
        try await storage.saveSource(episode(id: id, trackID: trackID))
        try await storage.saveTranscript(id, stored)
        if let ttml {
            try await storage.performStoreWork { store in
                try store.execute("UPDATE podcasts SET raw_ttml = ? WHERE source_id = ?", [.text(ttml), .text(id)])
            }
        }
        if hidden { try await storage.setPodcastEpisodeHidden(id, hidden: true) }
        let sha = PaperContentPreparationService.sha256(stored)
        try await storage.performStoreWork { store in
            try store.execute("DELETE FROM podcast_transcript_cleanup_queue WHERE source_id = ?", [.text(id)])
            try store.execute("""
                INSERT INTO podcast_transcript_preparations
                    (source_id, input_content, input_sha256, clean_sha256, cleaner_version, prepared_at)
                VALUES (?, ?, ?, ?, 1, 1)
            """, [.text(id), .text(stored), .text(sha), .text(sha)])
        }
        #expect(try await storage.performStoreWork { try $0.podcastTranscriptDetruncationQueueCount() } >= 1)
    }

    struct Row: Sendable {
        let content: String?
        let audit: PodcastTranscriptAuditRecord?
        let queued: Bool
        let rawTTML: String?
        let wordCount: Int?
        let adPassQueued: Bool
        let preparationKept: Bool
        let republishQueued: Bool
    }

    static func row(_ storage: StorageService, _ id: String) async throws -> Row {
        try await storage.performStoreWork { store in
            func count(_ sql: String) throws -> Int { Int(try store.scalarInteger(sql) ?? 0) }
            return Row(
                content: try store.loadSourceContent(id),
                audit: try store.podcastTranscriptAudit(sourceID: id),
                queued: try count("SELECT COUNT(*) FROM podcast_transcript_detruncation_queue WHERE source_id = '\(id)'") == 1,
                rawTTML: try store.scalarText("SELECT raw_ttml FROM podcasts WHERE source_id = '\(id)'"),
                wordCount: try store.scalarInteger("SELECT word_count FROM podcasts WHERE source_id = '\(id)'").map(Int.init),
                adPassQueued: try count("SELECT COUNT(*) FROM podcast_transcript_cleanup_queue WHERE source_id = '\(id)'") == 1,
                preparationKept: try count("SELECT COUNT(*) FROM podcast_transcript_preparations WHERE source_id = '\(id)'") == 1,
                republishQueued: try count("""
                    SELECT COUNT(*) FROM ck_backfill_queue
                    WHERE kind = '\(KnowledgeStore.sourcePublishKind)' AND target = '\(id)'
                """) == 1
            )
        }
    }

    actor Calls {
        var fetchedTrackIDs: [Int64] = []
        var formatted: [String] = []
        func fetched(_ trackID: Int64) { fetchedTrackIDs.append(trackID) }
        func format(_ text: String) { formatted.append(text) }
    }

    static func service(
        _ storage: StorageService,
        calls: Calls = Calls(),
        fetch: StudioViewModel.PodcastTranscriptFetchOutcome = .failed
    ) -> PodcastTranscriptDetruncationService {
        PodcastTranscriptDetruncationService(
            storage: storage,
            aiService: AIService(),
            homeDirectory: "/nonexistent",
            fetchAppleTranscript: { trackID, _ in
                await calls.fetched(trackID)
                return fetch
            },
            formattingConfig: { AITaskConfig(provider: .anthropic, apiKey: "test-key", model: "claude-sonnet-4-6") },
            formatTranscript: { text, _, _ in
                await calls.format(text)
                return "**Ada:** " + text
            }
        )
    }

    @Test("A transcript the cap cut is restored from its stored TTML, formatted, with the ad pass staged again")
    func restoresACappedEpisode() async throws {
        let (storage, root) = try Self.makeStorage("restore")
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.seed(storage, id: "capped", trackID: 1_000_745_466_204, stored: Self.capped, ttml: Self.ttml)
        let calls = Calls()

        let result = await Self.service(storage, calls: calls).drain()

        #expect(result.restoredSourceIDs == ["capped"])
        #expect(result.remainingCount == 0)
        let row = try await Self.row(storage, "capped")
        #expect(row.content == "**Ada:** " + Self.episodeText)
        #expect(await calls.formatted == [Self.episodeText], "formatted once, from the whole episode")
        #expect(row.audit == PodcastTranscriptAuditRecord(outcome: .restored, ttmlSHA256: PaperContentPreparationService.sha256(Self.ttml)))
        #expect(!row.queued)
        #expect(row.rawTTML == Self.ttml, "the stored TTML stays as it was")
        #expect(row.wordCount == ("**Ada:** " + Self.episodeText).split(whereSeparator: { $0.isWhitespace }).count)
        // The ad pass runs again over the whole episode; its record against the cut text goes.
        #expect(row.adPassQueued)
        #expect(!row.preparationKept)
        // The text other devices read is published again.
        #expect(row.republishQueued)
        #expect(await calls.fetchedTrackIDs.isEmpty, "a stored TTML is never fetched again")
    }

    @Test("A complete transcript and one whose closing read the ad pass removed are left as they are")
    func leavesCompleteEpisodes() async throws {
        let (storage, root) = try Self.makeStorage("complete")
        defer { try? FileManager.default.removeItem(at: root) }
        let lastTurn = try #require(Self.episodeText.range(of: "\n\n[SPEAKER_2]\n", options: .backwards))
        let outroRemoved = String(Self.episodeText[..<lastTurn.lowerBound])
        try await Self.seed(storage, id: "complete", trackID: 1_000_745_902_096, stored: Self.episodeText, ttml: Self.ttml)
        try await Self.seed(storage, id: "outro-removed", trackID: 1_000_744_989_426, stored: outroRemoved, ttml: Self.ttml)
        let calls = Calls()

        let result = await Self.service(storage, calls: calls).drain()

        #expect(result.restoredSourceIDs.isEmpty)
        #expect(result.verifiedCount == 2)
        for (id, stored) in [("complete", Self.episodeText), ("outro-removed", outroRemoved)] {
            let row = try await Self.row(storage, id)
            #expect(row.content == stored)
            #expect(row.audit?.outcome == .complete)
            #expect(!row.queued)
            #expect(row.preparationKept, "the ad pass's record stands")
            #expect(!row.republishQueued)
        }
        #expect(await calls.formatted.isEmpty)
    }

    @Test("A hidden episode is restored as plain text and never sent to the formatting pass")
    func restoresAHiddenEpisodeAsPlainText() async throws {
        let (storage, root) = try Self.makeStorage("hidden")
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.seed(storage, id: "hidden", trackID: 1_000_757_792_129, stored: Self.capped, ttml: Self.ttml, hidden: true)
        let calls = Calls()

        let result = await Self.service(storage, calls: calls).drain()

        #expect(result.restoredSourceIDs == ["hidden"])
        let row = try await Self.row(storage, "hidden")
        #expect(row.content == Self.episodeText)
        #expect(await calls.formatted.isEmpty)
        // Hidden episodes get no ad pass, before or after.
        #expect(!row.adPassQueued)
        #expect(row.audit?.outcome == .restored)
    }

    @Test("An episode with no TTML here is measured against one fetch of Apple's, which it then keeps")
    func fetchesTheTTMLItLacks() async throws {
        let (storage, root) = try Self.makeStorage("fetch")
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.seed(storage, id: "ttml-less", trackID: 1_000_778_586_977, stored: Self.capped, ttml: nil)
        let calls = Calls()

        let result = await Self.service(storage, calls: calls, fetch: .available(Self.ttml)).drain()

        #expect(await calls.fetchedTrackIDs == [1_000_778_586_977])
        #expect(result.restoredSourceIDs == ["ttml-less"])
        let row = try await Self.row(storage, "ttml-less")
        #expect(row.content == "**Ada:** " + Self.episodeText)
        #expect(row.rawTTML == Self.ttml, "kept, as hydration keeps one")
        #expect(row.audit == PodcastTranscriptAuditRecord(outcome: .restored, ttmlSHA256: PaperContentPreparationService.sha256(Self.ttml)))

        // A complete one is recorded and its fetched TTML not kept.
        try await Self.seed(storage, id: "ttml-less-complete", trackID: 1_000_780_290_597, stored: Self.episodeText, ttml: nil)
        _ = await Self.service(storage, calls: calls, fetch: .available(Self.ttml)).drain()
        let complete = try await Self.row(storage, "ttml-less-complete")
        #expect(complete.audit?.outcome == .complete)
        #expect(complete.rawTTML == nil)
        #expect(complete.content == Self.episodeText)
    }

    @Test("A failed fetch waits and is tried again; Apple having no transcript is recorded")
    func fetchFailuresAndUnavailableTranscripts() async throws {
        let (storage, root) = try Self.makeStorage("fetch-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.seed(storage, id: "offline", trackID: 1_000_783_904_288, stored: Self.capped, ttml: nil)

        let failed = await Self.service(storage, fetch: .failed).drain()
        #expect(failed.restoredSourceIDs.isEmpty)
        #expect(failed.errorMessage?.contains("could not be reached") == true)
        #expect(failed.remainingCount == 0, "waiting for its retry time, so not due")
        var row = try await Self.row(storage, "offline")
        #expect(row.queued)
        #expect(row.audit == nil)
        #expect(row.content == Self.capped)
        let attempts = try await storage.performStoreWork { store in
            try store.scalarInteger("SELECT attempt_count FROM podcast_transcript_detruncation_queue WHERE source_id = 'offline'")
        }
        let retryAfter = try await storage.performStoreWork { store in
            try store.scalarText("SELECT printf('%.3f', retry_after) FROM podcast_transcript_detruncation_queue WHERE source_id = 'offline'")
        }
        #expect(attempts == 1)
        let wait = (retryAfter.flatMap(Double.init) ?? 0) - Date().timeIntervalSinceReferenceDate
        #expect(wait > 14 * 60 && wait <= 15 * 60)

        // Its time comes; Apple now says it has no transcript for the episode.
        try await storage.performStoreWork { try $0.execForTesting("UPDATE podcast_transcript_detruncation_queue SET retry_after = 0") }
        _ = await Self.service(storage, fetch: .unavailable).drain()
        row = try await Self.row(storage, "offline")
        #expect(!row.queued)
        #expect(row.audit == PodcastTranscriptAuditRecord(outcome: .noTranscript, ttmlSHA256: nil))
        #expect(row.content == Self.capped, "nothing to measure against, so nothing is changed")
    }

    @Test("An Apple address too long to hold a track id is recorded, not skipped on every drain")
    func overlongAppleAddressIsRecorded() async throws {
        let (storage, root) = try Self.makeStorage("overlong")
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.seed(storage, id: "overlong", trackID: 1_000_783_904_289, stored: Self.capped, ttml: nil)
        // Digits the queue's SQL accepts and Int64 cannot hold.
        try await storage.performStoreWork {
            try $0.execForTesting(
                "UPDATE podcasts SET url = 'apple-podcast://episode/99999999999999999999' WHERE source_id = 'overlong'"
            )
        }
        let calls = Calls()

        let result = await Self.service(storage, calls: calls, fetch: .available(Self.ttml)).drain()

        #expect(await calls.fetchedTrackIDs.isEmpty)
        #expect(result.verifiedCount == 1)
        let row = try await Self.row(storage, "overlong")
        #expect(!row.queued, "a row skipped instead would hold one of the drain's fetch places for good")
        #expect(row.audit == PodcastTranscriptAuditRecord(outcome: .noTranscript, ttmlSHA256: nil))
        #expect(row.content == Self.capped)
    }

    @Test("A transcript whose ending is not in the episode is left as it is")
    func leavesAnUnplacedTranscript() async throws {
        let (storage, root) = try Self.makeStorage("unplaced")
        defer { try? FileManager.default.removeItem(at: root) }
        let other = try SourceService.extractTextFromTTMLContent(Self.episodeTTML(turns: 10, firstWord: 900_000))
        try await Self.seed(storage, id: "other-text", trackID: 1_000_758_651_501, stored: other, ttml: Self.ttml)

        let result = await Self.service(storage).drain()

        #expect(result.restoredSourceIDs.isEmpty)
        let row = try await Self.row(storage, "other-text")
        #expect(row.content == other)
        #expect(row.audit?.outcome == .unplaced)
    }

    @Test("A restore is written only over the transcript that was measured")
    func restoreComparesBeforeItWrites() async throws {
        let (storage, root) = try Self.makeStorage("compare")
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.seed(storage, id: "changed", trackID: 1_000_763_773_273, stored: Self.capped, ttml: Self.ttml)
        let replaced = try await storage.restorePodcastTranscript(
            sourceID: "changed",
            auditedTranscript: "a transcript the audit measured before it changed",
            restoredTranscript: Self.episodeText,
            fetchedTTML: nil,
            ttmlSHA256: "sha"
        )
        #expect(!replaced)
        let row = try await Self.row(storage, "changed")
        #expect(row.content == Self.capped)
        #expect(row.queued, "still queued, to be measured again")
        #expect(row.audit == nil)
        // The downgrade guard saveTranscript holds holds here too.
        await #expect(throws: (any Error).self) {
            try await storage.restorePodcastTranscript(
                sourceID: "changed",
                auditedTranscript: Self.capped,
                restoredTranscript: String(Self.capped.prefix(1_000)),
                fetchedTTML: nil,
                ttmlSHA256: "sha"
            )
        }
        #expect(try await Self.row(storage, "changed").content == Self.capped)
    }

    @Test("A restored episode's loaded copy is cleared, so a later save cannot write the cut text back")
    func restoredLoadedCopyIsNotWrittenBack() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastTranscriptAudit-loaded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage, observeCloudKitChanges: false)
        // Hidden, so the app's own drain restores it as plain text with no model.
        try await Self.seed(storage, id: "loaded", trackID: 1_000_486_719_578, stored: Self.capped, ttml: Self.ttml, hidden: true)
        var loaded = try #require(try await storage.loadPersistedSources(ids: ["loaded"]).first)
        loaded.content = Self.capped
        loaded.wordCount = Self.capped.split(separator: " ").count
        vm.articles.append(loaded)
        let staleCopy = loaded

        let result = await vm.runPodcastTranscriptAudit()

        #expect(result.restoredSourceIDs == ["loaded"])
        let index = try #require(vm.articles.firstIndex { $0.id == "loaded" })
        #expect(vm.articles[index].content == nil, "readers go back to storage for the restored text")
        let storedWords = try await Self.row(storage, "loaded").wordCount
        #expect(storedWords != staleCopy.wordCount)
        #expect(vm.articles[index].wordCount == storedWords)
        // Any later save of the loaded row (a rename, a hide, a reading mark)
        // keeps the restore.
        try await storage.saveSource(vm.articles[index])
        #expect(try await Self.row(storage, "loaded").content == Self.episodeText)
        #expect(try await Self.row(storage, "loaded").wordCount == storedWords)

        // What the refresh prevents: `saveSource` writes a loaded podcast's
        // text whole, so the copy as it was loaded would have undone the restore.
        try await storage.saveSource(staleCopy)
        #expect(try await Self.row(storage, "loaded").content == Self.capped)
    }
}
