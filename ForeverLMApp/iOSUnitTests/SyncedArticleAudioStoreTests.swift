import Foundation
import XCTest
@testable import ForeverLM

final class SyncedArticleAudioStoreTests: XCTestCase {
    func testSupportedIOSAudioDoesNotDependOnTheReceivingDevicesCurrentVoice() {
        let manifest = SyncedArticleAudioManifest(
            schemaVersion: SyncedArticleAudioManifest.schemaVersion,
            sourceID: "article-1",
            title: "Synced article",
            subtitle: nil,
            sourceType: "article",
            sourceURL: "https://example.com/article",
            provider: "xai",
            model: ArticleSpeechCatalog.grokModelID,
            voice: "rex",
            voiceLabel: "Rex",
            contentSignature: "content-signature",
            totalCharacters: 120,
            createdAt: Date(),
            chunks: [
                SyncedArticleAudioManifest.Chunk(
                    index: 0,
                    fileName: "chunk-0000.mp3",
                    byteCount: 128,
                    text: nil
                )
            ],
            sourceTextFileName: SyncedArticleAudioStore.sourceTextFileName,
            generatedOnPlatform: "ios"
        )

        XCTAssertTrue(manifest.usesSupportedPlaybackFormat)
    }

    func testDownloadProgressCountsOnlyTheContiguousPrefixAsPlayable() {
        // CloudDocs delivers files in the order it likes: a chapter whose
        // middle arrived first still has nothing playback can start on.
        let scattered = SyncedArticleAudioDownloadProgress.measure(ready: [false, true, true, false])
        XCTAssertEqual(scattered.readyChunks, 2)
        XCTAssertEqual(scattered.contiguousChunks, 0)
        XCTAssertEqual(scattered.totalChunks, 4)
        XCTAssertFalse(scattered.isComplete)

        let leading = SyncedArticleAudioDownloadProgress.measure(ready: [true, true, false, true])
        XCTAssertEqual(leading.readyChunks, 3)
        XCTAssertEqual(leading.contiguousChunks, 2)
        XCTAssertEqual(leading.fraction, 0.75)

        let whole = SyncedArticleAudioDownloadProgress.measure(ready: [true, true])
        XCTAssertEqual(whole.contiguousChunks, 2)
        XCTAssertTrue(whole.isComplete)

        XCTAssertFalse(SyncedArticleAudioDownloadProgress.measure(ready: []).isComplete)
    }

    func testManifestPrefixKeepsPlaybackOrderAndIdentity() {
        let manifest = Self.makeManifest(
            sourceID: "book-3",
            chunkFileNames: ["chunk-0002.mp3", "chunk-0000.mp3", "chunk-0001.mp3"]
        )
        // Chunks are handed over out of order to prove the prefix sorts them.
        let shuffled = SyncedArticleAudioManifest(
            schemaVersion: manifest.schemaVersion,
            sourceID: manifest.sourceID,
            title: manifest.title,
            subtitle: manifest.subtitle,
            sourceType: manifest.sourceType,
            sourceURL: manifest.sourceURL,
            provider: manifest.provider,
            model: manifest.model,
            voice: manifest.voice,
            voiceLabel: manifest.voiceLabel,
            contentSignature: manifest.contentSignature,
            totalCharacters: manifest.totalCharacters,
            createdAt: manifest.createdAt,
            chunks: [
                SyncedArticleAudioManifest.Chunk(index: 2, fileName: "chunk-0002.mp3", byteCount: 1, text: nil),
                SyncedArticleAudioManifest.Chunk(index: 0, fileName: "chunk-0000.mp3", byteCount: 1, text: nil),
                SyncedArticleAudioManifest.Chunk(index: 1, fileName: "chunk-0001.mp3", byteCount: 1, text: nil),
            ],
            sourceTextFileName: manifest.sourceTextFileName,
            generatedOnPlatform: "macos"
        )

        let prefix = shuffled.prefix(chunkCount: 2)
        XCTAssertEqual(prefix.chunks.map(\.fileName), ["chunk-0000.mp3", "chunk-0001.mp3"])
        XCTAssertEqual(prefix.sourceID, shuffled.sourceID)
        XCTAssertEqual(prefix.contentSignature, shuffled.contentSignature)
        XCTAssertEqual(prefix.id, shuffled.id, "The opening is the same source to the player and Now Playing")
        XCTAssertEqual(shuffled.prefix(chunkCount: 10).chunks.count, 3)
        XCTAssertTrue(shuffled.prefix(chunkCount: 0).chunks.isEmpty)
    }

    func testMaterializeChunksReportsThePrefixAsFilesLandAndFinishesWhenTheLastOneDoes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncedAudioMaterializeTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let urls = (0..<3).map { root.appendingPathComponent("chunk-000\($0).mp3") }
        let audio = Data(repeating: 1, count: 64)
        // The first chunk is here already; the other two "arrive" while the
        // download waits, out of order, the way CloudDocs delivers them.
        try audio.write(to: urls[0])

        let reported = ReportedProgress()
        let download = Task {
            try await SyncedArticleAudioStore.materializeChunks(at: urls, sourceID: "book-3") { progress in
                Task { await reported.append(progress) }
            }
        }

        try await Task.sleep(for: .milliseconds(300))
        try audio.write(to: urls[2])
        try await Task.sleep(for: .milliseconds(300))
        try audio.write(to: urls[1])

        // A plain temp directory is outside iCloud's metadata scope, so the
        // watcher's five-second backstop is what notices the new files.
        try await download.value
        let progresses = await reported.values

        XCTAssertEqual(progresses.first?.contiguousChunks, 1, "The first chunk is playable before anything else lands")
        XCTAssertEqual(progresses.first?.readyChunks, 1)
        XCTAssertEqual(progresses.last?.contiguousChunks, 3)
        XCTAssertTrue(progresses.last?.isComplete ?? false)
        XCTAssertEqual(progresses.map(\.contiguousChunks), progresses.map(\.contiguousChunks).sorted(),
                       "The playable prefix only ever grows")
        XCTAssertEqual(progresses.count, Set(progresses).count, "Unchanged state is not reported again")
    }

    func testMaterializeChunksReturnsAtOnceWhenEveryChunkIsLocal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncedAudioMaterializeLocalTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let urls = (0..<2).map { root.appendingPathComponent("chunk-000\($0).mp3") }
        for url in urls { try Data(repeating: 1, count: 8).write(to: url) }

        let reported = ReportedProgress()
        let started = Date()
        try await SyncedArticleAudioStore.materializeChunks(at: urls, sourceID: "book-3") { progress in
            Task { await reported.append(progress) }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        let progresses = await reported.values
        XCTAssertTrue(progresses.isEmpty, "Local audio has no download to report")
    }

    private actor ReportedProgress {
        private(set) var values: [SyncedArticleAudioDownloadProgress] = []
        func append(_ progress: SyncedArticleAudioDownloadProgress) { values.append(progress) }
    }

    private static func makeManifest(sourceID: String, chunkFileNames: [String]) -> SyncedArticleAudioManifest {
        SyncedArticleAudioManifest(
            schemaVersion: SyncedArticleAudioManifest.schemaVersion,
            sourceID: sourceID,
            title: "Chapter",
            subtitle: nil,
            sourceType: "book",
            sourceURL: "https://example.com/book",
            provider: "openrouter",
            model: ArticleSpeechCatalog.defaultModelID,
            voice: ArticleSpeechCatalog.defaultVoiceID,
            voiceLabel: "Kore",
            contentSignature: "signature",
            totalCharacters: 100,
            createdAt: Date(),
            chunks: chunkFileNames.enumerated().map { index, name in
                SyncedArticleAudioManifest.Chunk(index: index, fileName: name, byteCount: 1, text: nil)
            },
            sourceTextFileName: SyncedArticleAudioStore.sourceTextFileName,
            generatedOnPlatform: "macos"
        )
    }

    func testListeningPositionRoundTripsThroughTheAccountRecord() throws {
        let position = ArticleSpeechPlaybackPosition(
            globalTime: 87.25,
            appleCharacterOffset: nil,
            contentSignature: "content-signature",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let encoded = try XCTUnwrap(ListeningPositionSync.encode(position))
        XCTAssertEqual(ListeningPositionSync.decode(encoded), position)
        XCTAssertEqual(
            ListeningPositionSync.preferenceKey(sourceID: "article-1"),
            "listen.position.article-1"
        )

        // The phone's own file can be older than what the Mac published a
        // moment ago; the resume point is whichever was saved last.
        var fromMac = position
        fromMac.globalTime = 120
        fromMac.updatedAt = position.updatedAt.addingTimeInterval(30)
        XCTAssertEqual(ListeningPositionSync.newest(position, fromMac), fromMac)
        XCTAssertEqual(ListeningPositionSync.newest(fromMac, position), fromMac)
    }

    func testGeneratedSpeechResponseRetainsExactNarrationText() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://ai.foreverlm.com")!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: [
                "Content-Type": "audio/pcm",
                "x-foreverlm-request-id": "request-text-123",
            ]
        ))
        let narration = "A short narration whose audio belongs to this exact text."
        let pcm = Data(repeating: 0, count: 24_000 * MemoryLayout<Int16>.size)

        let validated = try CloudArticleTTS.validatedSpeechResponse(
            data: pcm,
            response: response,
            model: "google/gemini-3.1-flash-tts-preview",
            inputText: narration
        )

        XCTAssertEqual(validated.text, narration)
    }

    // MARK: - Interrupted generation resume

    /// Writes `count` chunk files and returns the manifest chunks naming them.
    private func writeChunkFiles(sourceID: String, count: Int) throws -> [SyncedArticleAudioManifest.Chunk] {
        let directory = SyncedArticleAudioStore.sourceDirectory(sourceID: sourceID)
            .appendingPathComponent(SyncedArticleAudioStore.chunksDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try (0..<count).map { index in
            let fileName = SyncedArticleAudioStore.chunkFileName(index: index, fileExtension: "mp3")
            let audio = Data(repeating: 3, count: 64)
            try audio.write(to: directory.appendingPathComponent(fileName))
            return SyncedArticleAudioManifest.Chunk(
                index: index,
                fileName: fileName,
                byteCount: audio.count,
                text: "Chunk \(index)"
            )
        }
    }

    private func writeGenerationProgress(_ progress: ArticleSpeechGenerationProgress) throws {
        let url = SyncedArticleAudioStore.generationProgressURL(sourceID: progress.sourceID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(progress).write(to: url, options: .atomic)
    }

    private func makeGenerationProgress(
        sourceID: String,
        signature: String = "narration-signature",
        model: String = ArticleSpeechCatalog.grokModelID,
        voice: String = "rex",
        plannedRequestCount: Int = 5,
        completedRequestCount: Int = 2,
        chunks: [SyncedArticleAudioManifest.Chunk]
    ) -> ArticleSpeechGenerationProgress {
        ArticleSpeechGenerationProgress(
            sourceID: sourceID,
            contentSignature: signature,
            model: model,
            voice: voice,
            plannedRequestCount: plannedRequestCount,
            completedRequestCount: completedRequestCount,
            chunks: chunks,
            updatedAt: Date()
        )
    }

    func testInterruptedGenerationResumesFromItsJournaledPrefix() throws {
        let sourceID = "resume-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: SyncedArticleAudioStore.sourceDirectory(sourceID: sourceID)) }

        let chunks = try writeChunkFiles(sourceID: sourceID, count: 2)
        try writeGenerationProgress(makeGenerationProgress(sourceID: sourceID, chunks: chunks))

        let resumable = try XCTUnwrap(CloudArticleTTS.resumableProgress(
            sourceID: sourceID,
            signature: "narration-signature",
            selection: CloudArticleTTS.Selection(model: ArticleSpeechCatalog.grokModelID, voice: "rex"),
            plannedRequestCount: 5
        ))
        XCTAssertEqual(resumable.completedRequestCount, 2)
        XCTAssertEqual(resumable.chunks.map(\.fileName), chunks.map(\.fileName))
    }

    func testJournalForDifferentNarrationOrVoiceIsRefusedAndDeleted() throws {
        let sourceID = "resume-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: SyncedArticleAudioStore.sourceDirectory(sourceID: sourceID)) }

        let chunks = try writeChunkFiles(sourceID: sourceID, count: 2)
        try writeGenerationProgress(makeGenerationProgress(sourceID: sourceID, chunks: chunks))

        // A journal from another voice must never be stitched onto new audio.
        XCTAssertNil(CloudArticleTTS.resumableProgress(
            sourceID: sourceID,
            signature: "narration-signature",
            selection: CloudArticleTTS.Selection(model: ArticleSpeechCatalog.grokModelID, voice: "eve"),
            plannedRequestCount: 5
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SyncedArticleAudioStore.generationProgressURL(sourceID: sourceID).path
        ))

        // ...and neither may one from narration that has since changed.
        try writeGenerationProgress(makeGenerationProgress(sourceID: sourceID, chunks: chunks))
        XCTAssertNil(CloudArticleTTS.resumableProgress(
            sourceID: sourceID,
            signature: "different-narration",
            selection: CloudArticleTTS.Selection(model: ArticleSpeechCatalog.grokModelID, voice: "rex"),
            plannedRequestCount: 5
        ))
    }

    /// HeyGen sends 44.1 kHz PCM, and before 2026-11-11 every PCM answer went
    /// into a 24 kHz container: such a prefix plays at 0.54x. A journal that
    /// records no rate is one of those, and is not stitched onto audio
    /// wrapped at the model's own rate.
    func testJournalWrappedAtAnotherSampleRateIsRefusedAndDeleted() throws {
        let sourceID = "resume-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: SyncedArticleAudioStore.sourceDirectory(sourceID: sourceID)) }
        let heygen = "heygen/heygen-voice-1-turbo"
        let selection = CloudArticleTTS.Selection(model: heygen, voice: "nadine")

        let chunks = try writeChunkFiles(sourceID: sourceID, count: 2)
        let journal = makeGenerationProgress(sourceID: sourceID, model: heygen, voice: "nadine", chunks: chunks)
        XCTAssertEqual(journal.pcmSampleRate, 44_100)
        try writeGenerationProgress(journal)
        XCTAssertNotNil(CloudArticleTTS.resumableProgress(
            sourceID: sourceID, signature: "narration-signature", selection: selection, plannedRequestCount: 5
        ))

        // The same journal as an earlier build wrote it: no rate recorded.
        let url = SyncedArticleAudioStore.generationProgressURL(sourceID: sourceID)
        var stored = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertNotNil(stored.removeValue(forKey: "pcmSampleRate"))
        try JSONSerialization.data(withJSONObject: stored).write(to: url, options: .atomic)
        XCTAssertNil(CloudArticleTTS.resumableProgress(
            sourceID: sourceID, signature: "narration-signature", selection: selection, plannedRequestCount: 5
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testJournalWhoseAudioIsGoneIsNotResumable() throws {
        let sourceID = "resume-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: SyncedArticleAudioStore.sourceDirectory(sourceID: sourceID)) }

        let chunks = try writeChunkFiles(sourceID: sourceID, count: 2)
        try writeGenerationProgress(makeGenerationProgress(sourceID: sourceID, chunks: chunks))
        try FileManager.default.removeItem(
            at: SyncedArticleAudioStore.sourceDirectory(sourceID: sourceID)
                .appendingPathComponent(SyncedArticleAudioStore.chunksDirectoryName, isDirectory: true)
                .appendingPathComponent(chunks[1].fileName)
        )

        XCTAssertNil(SyncedArticleAudioStore.loadGenerationProgress(sourceID: sourceID))
        XCTAssertFalse(SyncedArticleAudioStore.hasGenerationProgress(sourceID: sourceID))
    }

    /// Every request paid for, only the manifest write lost. Resuming that
    /// costs nothing and recovers the whole source.
    func testFullyGeneratedJournalWithoutAManifestStaysResumable() throws {
        let sourceID = "resume-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: SyncedArticleAudioStore.sourceDirectory(sourceID: sourceID)) }

        let chunks = try writeChunkFiles(sourceID: sourceID, count: 3)
        try writeGenerationProgress(makeGenerationProgress(
            sourceID: sourceID,
            plannedRequestCount: 3,
            completedRequestCount: 3,
            chunks: chunks
        ))

        let resumable = try XCTUnwrap(CloudArticleTTS.resumableProgress(
            sourceID: sourceID,
            signature: "narration-signature",
            selection: CloudArticleTTS.Selection(model: ArticleSpeechCatalog.grokModelID, voice: "rex"),
            plannedRequestCount: 3
        ))
        XCTAssertEqual(resumable.completedRequestCount, 3)
    }
}
