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

/// A podcast transcript reads the moment it is fetched (schema 172): hydration
/// saves it laid out but unformatted, ready, and the formatting pass waits in
/// `podcast_transcript_cleanup_queue`, which a quit does not lose. These pin
/// the queue's side: what is owed, in what order, what a Stop or the daily cap
/// leaves, and that nobody's text is formatted or written over.
@Suite("Podcast transcript formatting queue", .serialized)
struct PodcastTranscriptFormattingQueueTests {

    private static func episode(id: String, show: String = "Visible Show") -> StudioArticle {
        var article = StudioArticle(
            url: "apple-podcast://episode/\(id)",
            title: "An Episode",
            sourceType: .podcast,
            id: id
        )
        article.domain = show
        return article
    }

    /// Apple's transcript as extraction gives it: one long turn, then a short one.
    private static let raw: String = {
        let host = (0..<12)
            .map { "Replay during slow-wave sleep is what moves a memory from fragile to durable. Here is point \($0)." }
            .joined(separator: " ")
        return "[SPEAKER_1]\n\(host)\n\n[SPEAKER_2]\nThanks for having me, Zara."
    }()

    private static let readable = StudioViewModel.readablePodcastTranscriptLayout(raw)

    /// What the injected formatter returns: the raw text with its speakers
    /// named and one break, as the model's pass would leave it.
    private static let formatted = raw
        .replacingOccurrences(of: "[SPEAKER_1]", with: "[Zara Holt]")
        .replacingOccurrences(of: "[SPEAKER_2]", with: "[Robin Vale]")
        .replacingOccurrences(of: "Here is point 5. ", with: "Here is point 5.\n\n")

    private static let config = AITaskConfig(provider: .anthropic, apiKey: "test-key", model: "example/formatter")

    private actor Recorded {
        var inputs: [String] = []
        func add(_ input: String) { inputs.append(input) }
    }

    private static func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func queueRow(_ store: KnowledgeStore, _ id: String) throws -> (formatSHA: String?, learnerAsked: Int, attempts: Int, lastError: String?)? {
        var row: (String?, Int, Int, String?)?
        try store.queryBind("""
            SELECT format_input_sha256, learner_asked, attempt_count, last_error
            FROM podcast_transcript_cleanup_queue WHERE source_id = ?
        """, bind: { stmt in store.bind(stmt, 1, id) }) { stmt in
            row = (store.string(stmt, 0), Int(sqlite3_column_int(stmt, 1)), Int(sqlite3_column_int(stmt, 2)), store.string(stmt, 3))
        }
        return row
    }

    @Test("Schema 172 adds the formatting columns to a 171 queue and keeps every row as an ad pass")
    func migrationFrom171() throws {
        let root = try Schema154Fixture.temporaryRoot("podcast-formatting-171")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        try store.saveSource(Self.episode(id: "queued-before"))
        try store.saveTranscript("queued-before", Self.raw)
        try store.clearAllPendingSyncChanges()
        // A store as schema 171 left it: the queue without its two columns.
        try store.execForTesting("""
            ALTER TABLE podcast_transcript_cleanup_queue DROP COLUMN learner_asked;
            ALTER TABLE podcast_transcript_cleanup_queue DROP COLUMN format_input_sha256;
            PRAGMA user_version = 171;
        """)
        #expect(try !store.holdsPodcastTranscriptFormattingColumns())

        Schema154Fixture.newLaunch(root)
        let migrated = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)

        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(KnowledgeStore.schemaVersion == 174)
        #expect(try migrated.holdsPodcastTranscriptFormattingColumns())
        let row = try #require(try Self.queueRow(migrated, "queued-before"))
        #expect(row.formatSHA == nil && row.learnerAsked == 0)
        let candidate = try #require(try migrated.podcastTranscriptCleanupCandidates(limit: 5).first)
        #expect(candidate.sourceID == "queued-before" && !candidate.formatsTranscript)
        #expect(try migrated.pendingSyncChanges().isEmpty)
    }

    @Test("A raw transcript is ready at once and owes the formatting pass for exactly that text")
    func rawTranscriptWaitsForFormatting() throws {
        let root = try Self.temporaryRoot("podcast-formatting-raw")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        try store.saveSource(Self.episode(id: "raw-first"))

        try store.saveTranscript("raw-first", Self.readable, podcastFormatting: .automatic)

        #expect(try store.loadSourceContent("raw-first") == Self.readable)
        #expect(try store.loadActiveSources().first { $0.id == "raw-first" }?.state == .ready)
        #expect(try Self.queueRow(store, "raw-first")?.formatSHA == PaperContentPreparationService.sha256(Self.readable))
        let candidate = try #require(try store.podcastTranscriptCleanupCandidates(limit: 5).first)
        #expect(candidate.formatsTranscript)
        #expect(candidate.input == Self.readable)
        // A formatted transcript is owed nothing; asking for both is a caller's bug.
        #expect(throws: (any Error).self) {
            try store.saveTranscript("raw-first", Self.formatted, podcastCleanupInput: Self.raw, podcastFormatting: .automatic)
        }
    }

    @Test("The drain formats the raw transcript in place, from the text without its layout, and records the raw as its input")
    func drainFormatsInPlace() async throws {
        let root = try Self.temporaryRoot("podcast-formatting-drain")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        try await storage.saveSource(Self.episode(id: "formats"))
        try await storage.saveTranscript("formats", Self.readable, podcastFormatting: .automatic)
        let recorded = Recorded()
        let service = PodcastTranscriptCleanupService(
            storage: storage,
            aiService: AIService(),
            explicitlyAuthorizedConfig: Self.config,
            formatTranscript: { raw, candidate, _ in
                await recorded.add(raw)
                #expect(candidate.sourceID == "formats")
                return Self.formatted
            }
        )

        let result = await service.drain()

        #expect(result.processedSourceIDs == ["formats"])
        #expect(result.remainingCount == 0)
        #expect(result.errorMessage == nil)
        #expect(await recorded.inputs == [Self.raw], "the model is given Apple's text, not the reading layout")
        #expect(await storage.loadSourceContent("formats") == Self.formatted)
        let preparation = try #require(try KnowledgeStore(storeDirectory: root).loadPodcastTranscriptPreparation("formats"))
        #expect(preparation.input == Self.readable)
        #expect(preparation.metadata.cleanerVersion == PodcastTranscriptCleanupMetadata.currentVersion)
        #expect(try await storage.podcastTranscriptCleanupQueueCount() == 0, "formatting did the ad pass too")
    }

    @Test("A learner's Stop leaves the transcript readable and waiting, with no attempt spent")
    func stopLeavesWorkWaiting() async throws {
        let root = try Self.temporaryRoot("podcast-formatting-stop")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        try await storage.saveSource(Self.episode(id: "stopped"))
        try await storage.saveTranscript("stopped", Self.readable, podcastFormatting: .learnerAsked)
        let service = PodcastTranscriptCleanupService(
            storage: storage,
            aiService: AIService(),
            explicitlyAuthorizedConfig: Self.config,
            formatTranscript: { _, _, _ in
                throw AIStepStoppedError(step: "Transcript Formatting", staysStopped: true)
            }
        )

        let result = await service.drain()

        #expect(result.processedCount == 0)
        #expect(result.errorMessage == nil)
        #expect(result.remainingCount == 1)
        #expect(await storage.loadSourceContent("stopped") == Self.readable)
        let store = try KnowledgeStore(storeDirectory: root)
        let row = try #require(try Self.queueRow(store, "stopped"))
        #expect(row.attempts == 0 && row.lastError == nil)
        #expect(row.formatSHA == PaperContentPreparationService.sha256(Self.readable) && row.learnerAsked == 1)
    }

    @Test("Past the daily background cap a new transcript is still formatted; the ad backlog waits")
    func capLeavesTheAdBacklog() async throws {
        let root = try Self.temporaryRoot("podcast-formatting-cap")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        try await storage.saveSource(Self.episode(id: "old-ad-pass"))
        try await storage.saveTranscript("old-ad-pass", Self.raw)
        try await storage.saveSource(Self.episode(id: "just-fetched"))
        try await storage.saveTranscript("just-fetched", Self.readable, podcastFormatting: .automatic)
        let service = PodcastTranscriptCleanupService(
            storage: storage,
            aiService: AIService(),
            explicitlyAuthorizedConfig: Self.config,
            formatTranscript: { _, _, _ in Self.formatted }
        )

        let result = await service.drain(backgroundSpendAllowed: false)

        #expect(result.processedSourceIDs == ["just-fetched"])
        #expect(await storage.loadSourceContent("just-fetched") == Self.formatted)
        #expect(await storage.loadSourceContent("old-ad-pass") == Self.raw)
        #expect(try await storage.podcastTranscriptCleanupCandidates(limit: 5).map(\.sourceID) == ["old-ad-pass"])
    }

    @Test("The learner's ask goes first, then transcripts owed formatting, then the ad backlog")
    func queueOrder() throws {
        let root = try Self.temporaryRoot("podcast-formatting-order")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        try store.saveSource(Self.episode(id: "ad-backlog"))
        try store.saveTranscript("ad-backlog", Self.raw)
        try store.saveSource(Self.episode(id: "bulk-import"))
        try store.saveTranscript("bulk-import", Self.readable, podcastFormatting: .automatic)
        try store.saveSource(Self.episode(id: "asked-for", show: "Hidden Show"))
        try store.setPodcastShowHidden("Hidden Show", hidden: true)
        try store.saveTranscript("asked-for", Self.readable, podcastFormatting: .learnerAsked)
        try store.saveSource(Self.episode(id: "hidden-bulk", show: "Hidden Show"))
        try store.saveTranscript("hidden-bulk", Self.readable, podcastFormatting: .automatic)

        let candidates = try store.podcastTranscriptCleanupCandidates(limit: 10)
        // A hidden episode is formatted only when the learner asked for it.
        #expect(candidates.map(\.sourceID) == ["asked-for", "bulk-import", "ad-backlog"])
        #expect(candidates.map(\.formatsTranscript) == [true, true, false])
        #expect(try store.podcastTranscriptCleanupQueueCount() == 3)
    }

    @Test("A save of the same text keeps the formatting owed; text someone changed falls back to the ad pass")
    func replacedTextIsNeverFormattedOver() throws {
        let root = try Self.temporaryRoot("podcast-formatting-replaced")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        var episode = Self.episode(id: "edited")
        try store.saveSource(episode)
        try store.saveTranscript("edited", Self.readable, podcastFormatting: .learnerAsked)

        // A rename or a hide saves the loaded row, transcript and all.
        episode.content = Self.readable
        episode.state = .ready
        episode.title = "Renamed Episode"
        try store.saveSource(episode)
        #expect(try store.podcastTranscriptCleanupCandidates(limit: 5).first?.formatsTranscript == true)

        // The learner names the speakers before the pass runs.
        let named = Self.readable.replacingOccurrences(of: "[SPEAKER_2]", with: "[Robin Vale]")
        try store.saveTranscript("edited", named)
        let candidate = try #require(try store.podcastTranscriptCleanupCandidates(limit: 5).first)
        #expect(!candidate.formatsTranscript)
        #expect(candidate.input == named)
        let row = try #require(try Self.queueRow(store, "edited"))
        #expect(row.formatSHA == nil && row.learnerAsked == 0)
    }

    @Test("A loaded copy still holding the raw transcript never writes it back over the formatted one")
    func staleLoadedCopyKeepsTheFormatting() throws {
        let root = try Self.temporaryRoot("podcast-formatting-stale-copy")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        var episode = Self.episode(id: "stale-copy")
        try store.saveSource(episode)
        try store.saveTranscript("stale-copy", Self.readable, podcastFormatting: .automatic)
        let candidate = try #require(try store.podcastTranscriptCleanupCandidates(limit: 1).first)
        try store.applyPodcastTranscriptCleanup(
            candidate: candidate,
            prepared: PreparedPodcastTranscriptCleanup(
                input: Self.readable,
                clean: Self.formatted,
                metadata: PodcastTranscriptCleanupMetadata(
                    cleanerVersion: PodcastTranscriptCleanupMetadata.currentVersion,
                    inputSHA256: candidate.inputSHA256,
                    cleanSHA256: PaperContentPreparationService.sha256(Self.formatted),
                    preparedAt: Date()
                )
            )
        )

        // The window between the drain's write and the refresh of loaded rows.
        episode.content = Self.readable
        episode.state = .ready
        episode.title = "Renamed Meanwhile"
        try store.saveSource(episode)

        #expect(try store.loadSourceContent("stale-copy") == Self.formatted)
        #expect(try store.loadActiveSources().first { $0.id == "stale-copy" }?.title == "Renamed Meanwhile")
        #expect(try store.podcastTranscriptCleanupQueueCount() == 0)
        // Text that is not the clean-up's input is still saved as given.
        episode.content = Self.formatted + "\n\nA correction."
        try store.saveSource(episode)
        #expect(try store.loadSourceContent("stale-copy") == Self.formatted + "\n\nA correction.")
    }
}

/// The layout a raw transcript is read in until it is formatted: deterministic,
/// no model, and undone exactly before the formatting pass.
@Suite("Podcast transcript reading layout")
struct PodcastTranscriptReadingLayoutTests {

    private static let longTurn = (0..<12)
        .map { "Replay during slow-wave sleep is what moves a memory from fragile to durable. Here is point \($0)." }
        .joined(separator: " ")

    @Test("A long turn is cut at sentence ends under its label, and the layout comes off exactly")
    func longTurnRoundTrips() {
        let raw = "[SPEAKER_1]\n\(Self.longTurn)\n\n[SPEAKER_2]\nThanks for having me, Zara. It is good to be here."
        let readable = StudioViewModel.readablePodcastTranscriptLayout(raw)

        #expect(readable != raw)
        #expect(readable.hasPrefix("[SPEAKER_1]\nReplay during slow-wave sleep"))
        #expect(readable.hasSuffix("\n\n[SPEAKER_2]\nThanks for having me, Zara. It is good to be here."))
        let paragraphs = readable.components(separatedBy: "\n\n")
        // Four sentences a paragraph: 24 sentences in the long turn make six, then the short turn.
        #expect(paragraphs.count == 7)
        #expect(paragraphs.dropFirst().dropLast().allSatisfy { $0.hasPrefix("Replay during") })
        #expect(readable.split(whereSeparator: \.isWhitespace) == raw.split(whereSeparator: \.isWhitespace))
        #expect(StudioViewModel.podcastTranscriptWithoutLayout(readable) == raw)
    }

    @Test("A short transcript, and one that already breaks into lines, are left as they are")
    func shortAndShapedTextUnchanged() {
        let short = "[SPEAKER_1]\nDom, welcome to the show.\n\n[SPEAKER_2]\nThanks for having me, Peter."
        #expect(StudioViewModel.readablePodcastTranscriptLayout(short) == short)
        #expect(StudioViewModel.podcastTranscriptWithoutLayout(short) == short)

        let shaped = "[SPEAKER_1]\n\(Self.longTurn)\nA second line of its own."
        #expect(StudioViewModel.readablePodcastTranscriptLayout(shaped) == shaped)
    }

    @Test("Speech-to-text with no speakers gets paragraphs, and runs together again for the model")
    func unlabeledSpeech() {
        let chunkOne = Self.longTurn
        let chunkTwo = "The second stretch of audio says one more thing."
        let raw = "\(chunkOne)\n\n\(chunkTwo)"
        let readable = StudioViewModel.readablePodcastTranscriptLayout(raw)

        #expect(readable.components(separatedBy: "\n\n").count == 7)
        #expect(readable.hasSuffix("\n\n\(chunkTwo)"))
        #expect(StudioViewModel.podcastTranscriptWithoutLayout(readable) == "\(chunkOne) \(chunkTwo)")
    }

    @Test("A run with no sentence ends is cut every 95 words")
    func noSentenceEnds() {
        let words = (0..<200).map { "word\($0)" }.joined(separator: " ")
        let paragraphs = StudioViewModel.readableTranscriptParagraphs(words).components(separatedBy: "\n\n")
        #expect(paragraphs.map { $0.split(separator: " ").count } == [95, 95, 10])
    }
}
