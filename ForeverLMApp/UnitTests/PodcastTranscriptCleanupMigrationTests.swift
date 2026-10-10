import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Schema 77 stages the one-time sponsor/ad cleanup of podcast transcripts that
/// were formatted before the ad-read contract existed. Every model call is paid,
/// so what the migration stages — and what it refuses to stage — is the whole
/// cost contract, and it is asserted here against a released v76 shape.
@Suite("Podcast transcript cleanup migration")
struct PodcastTranscriptCleanupMigrationTests {

    private static func episode(
        id: String,
        show: String = "Visible Show",
        title: String = "An Episode"
    ) -> StudioArticle {
        var article = StudioArticle(
            url: "apple-podcast://episode/\(id)",
            title: title,
            sourceType: .podcast,
            id: id
        )
        article.domain = show
        return article
    }

    /// The released v76 shape is exactly today's minus the two tables this
    /// version adds, because that is the entire schema delta. Populating first
    /// and dropping after keeps the fixture's rows production-shaped.
    private static func makeVersion76Store(
        at root: URL,
        populate: (KnowledgeStore) throws -> Void
    ) throws {
        let store = try KnowledgeStore(storeDirectory: root)
        try populate(store)
        try store.clearAllPendingSyncChanges()
        try store.execForTesting("DROP TABLE podcast_transcript_cleanup_queue")
        try store.execForTesting("DROP TABLE podcast_transcript_preparations")
        try store.execForTesting("PRAGMA user_version = 76")
    }

    private static func userVersion(at root: URL) -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            root.appendingPathComponent("knowledge.db").path,
            &db,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        var version: Int32 = -1
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            version = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)
        return version
    }

    private static func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("A cleaned transcript leaves the queue, keeps its input, and republishes once")
    func applyingACleanupRetiresTheQueueRow() throws {
        let root = try Self.temporaryRoot("podcast-cleanup-apply")
        defer { try? FileManager.default.removeItem(at: root) }

        let editorial = String(
            repeating: "Replay during slow-wave sleep is what moves a memory from fragile to durable. ",
            count: 6
        )
        let input = "Welcome back. " + editorial
            + "This episode is brought to you by Sponsor. Use code SHOW for a discount. "
            + editorial
        let clean = "Welcome back. " + editorial + editorial
        let store = try KnowledgeStore(storeDirectory: root)
        try store.saveSource(Self.episode(id: "cleanable-episode"))
        try store.saveTranscript("cleanable-episode", input)
        try store.clearAllPendingSyncChanges()

        let candidate = try #require(
            try store.podcastTranscriptCleanupCandidates(limit: 1).first
        )
        let metadata = PodcastTranscriptCleanupMetadata(
            cleanerVersion: PodcastTranscriptCleanupMetadata.currentVersion,
            inputSHA256: candidate.inputSHA256,
            cleanSHA256: PaperContentPreparationService.sha256(clean),
            preparedAt: Date()
        )
        try store.applyPodcastTranscriptCleanup(
            candidate: candidate,
            prepared: PreparedPodcastTranscriptCleanup(input: input, clean: clean, metadata: metadata)
        )

        #expect(try store.loadSourceContent("cleanable-episode") == clean)
        #expect(try store.podcastTranscriptCleanupQueueCount() == 0)
        // The input survives separately, so a later contract can rerun without
        // re-downloading Apple's transcript.
        let preparation = try #require(try store.loadPodcastTranscriptPreparation("cleanable-episode"))
        #expect(preparation.input == input)
        #expect(preparation.metadata.cleanerVersion == PodcastTranscriptCleanupMetadata.currentVersion)
        // The cleaned text is the canonical record other devices must receive.
        #expect(try store.pendingSyncChanges().contains {
            $0.entity == .source && $0.logicalKey == "cleanable-episode"
        })
    }

    @Test("A drain that may not spend a model leaves the ad clean-up queue as it found it")
    func unpaidDrainLeavesTheQueueUntouched() async throws {
        let root = try Self.temporaryRoot("podcast-cleanup-unpaid")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = String(repeating: "Substantive editorial content. ", count: 20)
        let storage = StorageService(storeRoot: root)
        try await storage.saveSource(Self.episode(id: "unpaid-episode"))
        try await storage.saveTranscript("unpaid-episode", input)
        #expect(try await storage.podcastTranscriptCleanupQueueCount() == 1)

        let service = PodcastTranscriptCleanupService(
            storage: storage,
            aiService: AIService(),
            runsPaidCleanup: false
        )
        let result = await service.drain()

        #expect(result.processedCount == 0)
        #expect(result.remainingCount == 1)
        #expect(result.errorMessage == nil)
        #expect(try await storage.loadSourceContent("unpaid-episode") == input)
    }

    @Test("A cleanup that deletes too much, or lost its race, is refused")
    func applyingRefusesUnprovenResults() throws {
        let root = try Self.temporaryRoot("podcast-cleanup-refuse")
        defer { try? FileManager.default.removeItem(at: root) }

        let input = String(repeating: "Substantive editorial content. ", count: 20)
        let store = try KnowledgeStore(storeDirectory: root)
        try store.saveSource(Self.episode(id: "guarded-episode"))
        try store.saveTranscript("guarded-episode", input)
        let candidate = try #require(try store.podcastTranscriptCleanupCandidates(limit: 1).first)

        // Deleting most of an episode is a prompt failure, not a cleanup.
        let gutted = "Substantive editorial content."
        #expect(throws: (any Error).self) {
            try store.applyPodcastTranscriptCleanup(
                candidate: candidate,
                prepared: PreparedPodcastTranscriptCleanup(
                    input: input,
                    clean: gutted,
                    metadata: PodcastTranscriptCleanupMetadata(
                        cleanerVersion: PodcastTranscriptCleanupMetadata.currentVersion,
                        inputSHA256: candidate.inputSHA256,
                        cleanSHA256: PaperContentPreparationService.sha256(gutted),
                        preparedAt: Date()
                    )
                )
            )
        }

        // A transcript replaced while the model was running no longer matches
        // the input the result was derived from.
        try store.saveTranscript("guarded-episode", input + "A newly hydrated tail.")
        let stale = String(input.dropLast(10))
        #expect(throws: (any Error).self) {
            try store.applyPodcastTranscriptCleanup(
                candidate: candidate,
                prepared: PreparedPodcastTranscriptCleanup(
                    input: input,
                    clean: stale,
                    metadata: PodcastTranscriptCleanupMetadata(
                        cleanerVersion: PodcastTranscriptCleanupMetadata.currentVersion,
                        inputSHA256: candidate.inputSHA256,
                        cleanSHA256: PaperContentPreparationService.sha256(stale),
                        preparedAt: Date()
                    )
                )
            )
        }
        #expect(try store.loadSourceContent("guarded-episode") == input + "A newly hydrated tail.")
    }

    @Test("A transient failure retries; a durable one retires after three attempts")
    func queueLifecycleRetiresRepeatedFailures() throws {
        let root = try Self.temporaryRoot("podcast-cleanup-queue")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try KnowledgeStore(storeDirectory: root)
        try store.saveSource(Self.episode(id: "keeps-failing"))
        try store.saveTranscript("keeps-failing", "A transcript the model keeps refusing.")
        #expect(try store.podcastTranscriptCleanupQueueCount() == 1)

        // A provider timeout is a future-work event, not a spent attempt.
        try store.recordPodcastTranscriptCleanupFailure(
            sourceID: "keeps-failing",
            message: "operation timed out",
            sourceSHA256: "sha",
            consumesAttempt: false
        )
        #expect(try store.podcastTranscriptCleanupQueueCount() == 1)

        for attempt in 1...KnowledgeStore.maximumPodcastTranscriptCleanupAttempts {
            try store.recordPodcastTranscriptCleanupFailure(
                sourceID: "keeps-failing",
                message: "Invalid response on attempt \(attempt)",
                sourceSHA256: "sha",
                consumesAttempt: true
            )
        }
        // Exhausted rows stop being offered instead of billing forever.
        #expect(try store.podcastTranscriptCleanupQueueCount() == 0)
        #expect(try store.podcastTranscriptCleanupCandidates(limit: 10).isEmpty)
        // The record of what failed stays for a later build to inspect.
        var remaining = 0
        var lastError: String?
        try store.query("SELECT COUNT(*), MAX(last_error) FROM podcast_transcript_cleanup_queue") { stmt in
            remaining = Int(sqlite3_column_int64(stmt, 0))
            lastError = store.string(stmt, 1)
        }
        #expect(remaining == 1)
        #expect(lastError?.contains("attempt 3") == true)
    }

    @Test("Every path back to visible stages an episode that was never cleaned")
    func becomingVisibleAgainAlwaysStagesCleanup() throws {
        let root = try Self.temporaryRoot("podcast-cleanup-revisible")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try KnowledgeStore(storeDirectory: root)

        // A show unhidden on another device arrives as a deleted hidden-show
        // record, not as a call to setPodcastShowHidden.
        try store.saveSource(Self.episode(id: "remote-show-episode", show: "Remote Show"))
        try store.saveTranscript("remote-show-episode", "A transcript from a remotely hidden show.")
        try store.setPodcastShowHidden("Remote Show", hidden: true)
        #expect(try store.podcastTranscriptCleanupQueueCount() == 0)
        try store.deleteHiddenPodcastShowRecord(showName: "Remote Show")
        #expect(try store.podcastTranscriptCleanupCandidates(limit: 10).map(\.sourceID) == ["remote-show-episode"])

        // Likewise one episode unhidden elsewhere.
        try store.saveSource(Self.episode(id: "remote-episode", show: "Another Show"))
        try store.saveTranscript("remote-episode", "A transcript hidden from another device.")
        try store.setPodcastEpisodeHidden("remote-episode", hidden: true)
        try store.deleteHiddenSourceRecord(sourceID: "remote-episode")
        #expect(try store.podcastTranscriptCleanupQueueCount() == 2)

        // An episode of a hidden show made explicitly visible is owed the pass
        // even though its show stays hidden.
        try store.saveSource(Self.episode(id: "override-episode", show: "Remote Show"))
        try store.saveTranscript("override-episode", "A transcript the learner kept.")
        try store.setPodcastShowHidden("Remote Show", hidden: true)
        #expect(try store.podcastTranscriptCleanupQueueCount() == 1)
        try store.setPodcastEpisodeVisibleOverride("override-episode", visible: true)
        #expect(try store.podcastTranscriptCleanupCandidates(limit: 10).map(\.sourceID).contains("override-episode"))
    }

    @Test("An unarchived podcast that kept its transcript is staged")
    func unarchivingStagesCleanup() throws {
        let root = try Self.temporaryRoot("podcast-cleanup-unarchive")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try KnowledgeStore(storeDirectory: root)
        try store.saveSource(Self.episode(id: "archived-episode"))
        try store.saveTranscript("archived-episode", "A transcript that outlived its archive.")
        try store.execForTesting(
            "UPDATE sources SET status = 'archived' WHERE id = 'archived-episode'"
        )
        try store.execForTesting("DELETE FROM podcast_transcript_cleanup_queue")
        // An archived episode is not staged: it is not in the library.
        #expect(try store.podcastTranscriptCleanupQueueCount() == 0)

        try store.unarchiveSource("archived-episode")
        #expect(try store.podcastTranscriptCleanupCandidates(limit: 10).map(\.sourceID) == ["archived-episode"])
    }

    @Test("An already-cleaned episode is not restaged when it becomes visible again")
    func revisibilityDoesNotRepeatCompletedWork() throws {
        let root = try Self.temporaryRoot("podcast-cleanup-no-repeat")
        defer { try? FileManager.default.removeItem(at: root) }

        let editorial = String(
            repeating: "Replay during slow-wave sleep moves a memory from fragile to durable. ",
            count: 6
        )
        let input = editorial + "This episode is brought to you by Sponsor. " + editorial
        let clean = editorial + editorial
        let store = try KnowledgeStore(storeDirectory: root)
        try store.saveSource(Self.episode(id: "already-clean"))
        try store.saveTranscript("already-clean", input)
        let candidate = try #require(try store.podcastTranscriptCleanupCandidates(limit: 1).first)
        try store.applyPodcastTranscriptCleanup(
            candidate: candidate,
            prepared: PreparedPodcastTranscriptCleanup(
                input: input,
                clean: clean,
                metadata: PodcastTranscriptCleanupMetadata(
                    cleanerVersion: PodcastTranscriptCleanupMetadata.currentVersion,
                    inputSHA256: candidate.inputSHA256,
                    cleanSHA256: PaperContentPreparationService.sha256(clean),
                    preparedAt: Date()
                )
            )
        )
        #expect(try store.podcastTranscriptCleanupQueueCount() == 0)

        // Hiding and unhiding a cleaned episode must not buy the same pass twice.
        try store.setPodcastEpisodeHidden("already-clean", hidden: true)
        try store.setPodcastEpisodeHidden("already-clean", hidden: false)
        #expect(try store.podcastTranscriptCleanupQueueCount() == 0)
        try store.unarchiveSource("already-clean")
        #expect(try store.podcastTranscriptCleanupQueueCount() == 0)
        #expect(try store.loadSourceContent("already-clean") == clean)
    }

    @Test("Hiding an episode drops its queued work; unhiding stages it again")
    func hidingAnEpisodeDropsQueuedWork() throws {
        let root = try Self.temporaryRoot("podcast-cleanup-visibility")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try KnowledgeStore(storeDirectory: root)
        try store.saveSource(Self.episode(id: "toggled-episode"))
        try store.saveTranscript("toggled-episode", "A transcript whose visibility changes.")
        #expect(try store.podcastTranscriptCleanupQueueCount() == 1)

        try store.setPodcastEpisodeHidden("toggled-episode", hidden: true)
        #expect(try store.podcastTranscriptCleanupQueueCount() == 0)

        try store.setPodcastEpisodeHidden("toggled-episode", hidden: false)
        #expect(try store.podcastTranscriptCleanupQueueCount() == 1)
    }
}

/// The deletion boundaries the model proposes are applied by deterministic code,
/// so these are the tests that decide whether a transcript can lose editorial
/// text. They exercise the parser alone, with no provider involved.
@Suite("Podcast transcript ad removal boundaries")
struct PodcastTranscriptAdRemovalTests {

    private static let transcript = """
    Welcome to the show. Today we talk about sleep and memory consolidation.

    This episode is brought to you by Acme Mattress. Use code SHOW for twenty percent off your first order. Acme Mattress, sleep better tonight.

    So, back to the hippocampus. Replay during slow-wave sleep is what actually moves a memory from fragile to durable, and the evidence for that is now quite strong across species and methods.
    """

    private static func annotations(_ pairs: [(String, String)]) -> String {
        let items = pairs.map { #"{"ad_start":"\#($0.0)","ad_end":"\#($0.1)"}"# }
        return "[\(items.joined(separator: ","))]"
    }

    @Test("A uniquely anchored sponsor read is removed with its surrounding whitespace")
    func removesAnAnchoredSponsorRead() {
        let candidates = StudioViewModel.podcastTranscriptAdRemovalCandidatesOffMain(
            to: Self.transcript,
            from: Self.annotations([("This episode is brought to you by Acme", "Acme Mattress, sleep better tonight.")])
        )
        #expect(candidates.count == 1)

        let cleaned = StudioViewModel.applyPodcastTranscriptAdRemovalsOffMain(
            to: Self.transcript,
            candidates: candidates
        )
        #expect(!cleaned.contains("Acme Mattress"))
        #expect(cleaned.contains("Welcome to the show."))
        #expect(cleaned.contains("back to the hippocampus"))
    }

    @Test("An ambiguous or unmatched boundary deletes nothing")
    func refusesUnanchoredBoundaries() {
        // "sleep" appears several times: an ambiguous anchor could delete
        // anything between two unrelated passages.
        #expect(StudioViewModel.podcastTranscriptAdRemovalCandidatesOffMain(
            to: Self.transcript,
            from: Self.annotations([("sleep and memory", "sleep better tonight.")])
        ).isEmpty == false)
        #expect(StudioViewModel.podcastTranscriptAdRemovalCandidatesOffMain(
            to: Self.transcript,
            from: Self.annotations([("Sponsor text never spoken here", "nor was this line ever spoken")])
        ).isEmpty)
        // A hallucinated boundary that is not verbatim leaves the chunk intact.
        #expect(StudioViewModel.applyPodcastTranscriptAdRemovalsOffMain(
            to: Self.transcript,
            candidates: []
        ) == Self.transcript.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("A proposal that would delete most of the chunk is discarded whole")
    func refusesOversizedDeletions() {
        let candidates = StudioViewModel.podcastTranscriptAdRemovalCandidatesOffMain(
            to: Self.transcript,
            from: Self.annotations([("Welcome to the show. Today", "quite strong across species")])
        )
        #expect(candidates.isEmpty)
    }

    @Test("Overlapping proposals collapse to one non-overlapping deletion")
    func collapsesOverlappingProposals() {
        let candidates = StudioViewModel.podcastTranscriptAdRemovalCandidatesOffMain(
            to: Self.transcript,
            from: Self.annotations([
                ("This episode is brought to you by Acme", "Acme Mattress, sleep better tonight."),
                ("Use code SHOW for twenty", "Acme Mattress, sleep better tonight.")
            ])
        )
        #expect(candidates.count == 1)
        #expect(candidates.first?.proposedDeletion.contains("Use code SHOW") == true)
    }

    @Test("Chunking splits long transcripts on paragraph boundaries without losing text")
    func chunkingPreservesEveryCharacter() {
        let paragraph = String(repeating: "A sentence about memory. ", count: 40) + "\n\n"
        let transcript = String(repeating: paragraph, count: 60)
        let chunks = StudioViewModel.podcastTranscriptAdCleanupChunks(transcript, maximumCharacters: 20_000)
        #expect(chunks.count > 1)
        #expect(chunks.joined() == transcript)
        #expect(chunks.allSatisfy { $0.count <= 20_000 })
    }
}
