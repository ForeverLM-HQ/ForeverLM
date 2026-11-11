import AVFoundation
import CryptoKit
import Foundation

enum ArticleSpeechPCMTranscodeError: LocalizedError {
    case malformedPCM
    case unavailableFormat
    case unavailableBuffer

    var errorDescription: String? {
        switch self {
        case .malformedPCM:
            return "The speech provider returned malformed PCM audio."
        case .unavailableFormat:
            return "Could not create a PCM format for speech audio."
        case .unavailableBuffer:
            return "Could not allocate an audio buffer for speech audio."
        }
    }
}

/// Converts the raw 24 kHz, mono, 16-bit little-endian PCM returned by Gemini
/// speech models into compact AAC suitable for AVFoundation playback and iCloud
/// sync. This performs file I/O and must only be called off the main actor.
enum ArticleSpeechPCMTranscode {
    static func m4aData(fromPCM pcm: Data, sampleRate: Double = 24_000) throws -> Data {
        guard pcm.count >= 2, pcm.count.isMultiple(of: 2) else {
            throw ArticleSpeechPCMTranscodeError.malformedPCM
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw ArticleSpeechPCMTranscodeError.unavailableFormat
        }

        let frameCount = AVAudioFrameCount(pcm.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw ArticleSpeechPCMTranscodeError.unavailableBuffer
        }
        buffer.frameLength = frameCount
        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress,
                  let channel = buffer.int16ChannelData?.pointee else { return }
            memcpy(channel, base, Int(frameCount) * MemoryLayout<Int16>.size)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("article-speech-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // AVAudioFile finalizes the container header when it leaves scope.
        do {
            let file = try AVAudioFile(
                forWriting: tempURL,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64_000,
                ],
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            try file.write(from: buffer)
        }

        return try Data(contentsOf: tempURL)
    }
}

/// Rejects audio that cannot plausibly contain the narration it was generated
/// from. A syntactically valid MP3 is not enough: some neural TTS responses end
/// early, jump between distant sentences, and fill the remaining time with
/// invented speech while still returning HTTP 200.
enum ArticleSpeechAudioValidation {
    /// Normal audiobook narration is roughly 130–180 words per minute. Keep a
    /// deliberately generous ceiling so expressive or brisk voices pass while
    /// the severely compressed response that motivated this guard does not.
    static let maximumPlausibleWordsPerMinute = 300.0
    static let minimumLongFormWordCount = 80

    static func failureReason(text: String, duration: TimeInterval) -> String? {
        guard duration.isFinite, duration > 0 else {
            return "The returned audio has no playable duration."
        }

        let words = text.split(whereSeparator: { $0.isWhitespace }).filter { token in
            token.contains { $0.isLetter || $0.isNumber }
        }.count
        guard words >= minimumLongFormWordCount else { return nil }

        let minimumDuration = Double(words) * 60 / maximumPlausibleWordsPerMinute
        // Container duration can vary slightly between decoders. One second of
        // tolerance keeps the boundary from rejecting otherwise valid audio.
        guard duration + 1 < minimumDuration else { return nil }
        return String(
            format: "The returned audio is too short for its narration (%.1f seconds for %d words; expected at least %.1f seconds).",
            duration,
            words,
            minimumDuration
        )
    }
}

/// The durable, source-bound text derivative consumed by Listen. The text itself
/// lives in SQLite/CloudKit assets; this small envelope travels in the encrypted
/// Source payload so receivers can reject stale or mismatched narration.
struct SourceListenableContentMetadata: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let sourceSHA256: String
    let generatorVersion: Int
    let preparationSignature: String?
    /// Exact Swift character count of the durable text sent to TTS. Optional
    /// on older synced payloads so they continue decoding without inventing a
    /// price from canonical text or word counts.
    let characterCount: Int?
    let preparedAt: Date

    private enum CodingKeys: String, CodingKey {
        case sourceSHA256, generatorVersion, preparationSignature, characterCount, preparedAt
    }

    init(
        sourceSHA256: String,
        generatorVersion: Int,
        preparationSignature: String?,
        characterCount: Int? = nil,
        preparedAt: Date
    ) {
        self.sourceSHA256 = sourceSHA256
        self.generatorVersion = generatorVersion
        self.preparationSignature = preparationSignature
        self.characterCount = characterCount
        self.preparedAt = preparedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceSHA256 = try container.decode(String.self, forKey: .sourceSHA256)
        generatorVersion = try container.decode(Int.self, forKey: .generatorVersion)
        preparationSignature = try container.decodeIfPresent(String.self, forKey: .preparationSignature)
        characterCount = try container.decodeIfPresent(Int.self, forKey: .characterCount)
        preparedAt = try container.decode(Date.self, forKey: .preparedAt)
    }
}

struct SourceListenableContentSummary: Equatable, Sendable {
    let characterCount: Int
    let preparationSignature: String?
}

struct StoredSourceListenableContent: Equatable, Sendable {
    let text: String
    let metadata: SourceListenableContentMetadata
}

struct SyncedArticleAudioManifest: Codable, Equatable, Identifiable {
    static let schemaVersion = 1

    var id: String { sourceID }

    let schemaVersion: Int
    let sourceID: String
    let title: String
    let subtitle: String?
    let sourceType: String
    let sourceURL: String
    let provider: String
    let model: String
    let voice: String
    let voiceLabel: String
    let contentSignature: String
    let totalCharacters: Int
    let createdAt: Date
    var chunks: [Chunk]
    let sourceTextFileName: String?
    /// Version of speech-only paper filtering. Optional for manifests written
    /// before paper narration diverged from canonical source content.
    var narrationVersion: Int? = nil
    /// Hash of the canonical source text before speech-only AI adaptation.
    /// Lets text-to-speech reuse prepared narration without calling the model again.
    var sourceContentSignature: String? = nil
    /// Hash of the configured preparation route, prompt, and algorithm version.
    var narrationPreparationSignature: String? = nil
    /// "ios" or "macos". macOS records TTS usage per API call, so only
    /// iOS-generated manifests are imported as usage events on the Mac.
    var generatedOnPlatform: String? = nil

    var usesCurrentNarration: Bool {
        sourceType != "paper"
            || (narrationVersion == PaperNarrationFilter.version
                && sourceContentSignature != nil
                && narrationPreparationSignature != nil)
    }

    /// False for Fish Audio audio made with no reference voice: each of its
    /// requests was spoken by a different random speaker, so the recording
    /// changes voice every few sentences and is made again
    /// (`ArticleSpeechModelOption.init(directoryRow:)`). Only the audio:
    /// its prepared narration text (`usesCurrentNarration`) is still reused.
    var speaksInOneVoice: Bool {
        !ArticleSpeechCatalog.isFishAudioModel(model)
            || !voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Device preferences select future generations; they do not invalidate a
    /// supported, content-matched recording that another device already made.
    /// Nor does OpenRouter's list: the speech catalog follows its directory
    /// (`ArticleSpeechCatalog`), and audio already paid for plays whether or
    /// not OpenRouter still serves — or this device has yet read — the model
    /// that made it. Only a model retired for a reason is regenerated.
    var usesSupportedPlaybackFormat: Bool {
        schemaVersion == Self.schemaVersion
            && usesCurrentNarration
            && speaksInOneVoice
            && !ArticleSpeechCatalog.isRetiredModel(model)
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !chunks.isEmpty
    }

    struct Chunk: Codable, Equatable, Identifiable {
        var id: Int { index }

        let index: Int
        let fileName: String
        let byteCount: Int
        /// The narration text this chunk was generated from. Replay uses it to keep
        /// the reading highlight aligned with the audio even when the current
        /// provider would chunk the source differently, and Delete Cached Audio uses
        /// it to remove the matching per-request TTS cache entries. Optional so
        /// manifests written before this field existed still decode.
        var text: String? = nil
    }

    /// The same narration cut down to its first `chunkCount` chunks, in
    /// playback order. Never saved: it is the shape playback needs to start on
    /// the chunks that have reached this device while the rest are still
    /// coming down from iCloud, and it is replaced by the whole manifest the
    /// moment the last chunk lands.
    func prefix(chunkCount: Int) -> SyncedArticleAudioManifest {
        var copy = self
        let ordered = chunks.sorted { $0.index < $1.index }
        copy.chunks = Array(ordered.prefix(max(0, chunkCount)))
        return copy
    }
}

/// How far a narration's download from iCloud has come.
///
/// `readyChunks` is how many files are playable anywhere in the narration;
/// `contiguousChunks` is how many are playable from the very first one, which
/// is the only count playback can start on — CloudDocs fetches files in the
/// order it likes, and a chapter whose middle arrived first still has nothing
/// to play.
struct SyncedArticleAudioDownloadProgress: Hashable, Sendable {
    let readyChunks: Int
    let contiguousChunks: Int
    let totalChunks: Int

    var fraction: Double {
        guard totalChunks > 0 else { return 0 }
        return min(max(Double(readyChunks) / Double(totalChunks), 0), 1)
    }

    var isComplete: Bool {
        totalChunks > 0 && readyChunks >= totalChunks
    }

    /// The contiguous prefix from a per-chunk readiness list, first chunk first.
    static func measure(ready: [Bool]) -> SyncedArticleAudioDownloadProgress {
        let contiguous = ready.firstIndex(of: false) ?? ready.count
        return SyncedArticleAudioDownloadProgress(
            readyChunks: ready.filter { $0 }.count,
            contiguousChunks: contiguous,
            totalChunks: ready.count
        )
    }
}

/// Saved text-to-speech resume point for a source. Stored beside synced audio so it
/// rides along in the same iCloud-backed folder without a SQLite migration.
struct ArticleSpeechPlaybackPosition: Codable, Equatable {
    static let fileName = "playback-position.json"

    var globalTime: TimeInterval
    var appleCharacterOffset: Int?
    var contentSignature: String?
    var updatedAt: Date
}

/// The account-wide copy of a listening position.
///
/// The `playback-position.json` beside each narration is written by whichever
/// device is playing and read by the next one, but it travels by CloudDocs: the
/// phone does not fetch a file until something asks for it, and the ask used to
/// happen in the same instant as the read, so the second device almost always
/// resumed from the stale copy it already had — or from zero. Two devices
/// writing the same file also left CloudDocs conflict copies that nothing
/// resolved.
///
/// So every save is mirrored as a synced preference — one `Preference` record
/// per source, delivered by CloudKit push on the Mac and fetched fresh by the
/// phone when play starts. The file stays as the offline copy; whichever of the
/// two carries the newer `updatedAt` wins. The record is a preference in
/// transport only: it is state about the listener's progress, keyed by source,
/// not a setting.
enum ListeningPositionSync {
    /// `listen.position.<sourceID>` — one record per source, so two devices
    /// listening to two different sources never contend.
    static let preferenceKeyPrefix = "listen.position."

    /// How often a device that is still playing republishes to the account. A
    /// pause, a skip, a stop, or leaving the app publishes immediately; this
    /// only bounds how far behind the other device can be mid-playback.
    static let accountSaveInterval: TimeInterval = 15

    static func preferenceKey(sourceID: String) -> String {
        preferenceKeyPrefix + sourceID
    }

    static func sourceID(fromPreferenceKey key: String) -> String? {
        guard key.hasPrefix(preferenceKeyPrefix) else { return nil }
        let id = String(key.dropFirst(preferenceKeyPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// JSON rather than a plist dictionary so the Mac's `UserDefaults`, the
    /// phone's direct CloudKit fetch, and Web Studio all read one string shape.
    static func encode(_ position: ArticleSpeechPlaybackPosition) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(position) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ encoded: String) -> ArticleSpeechPlaybackPosition? {
        guard let data = encoded.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let position = try? decoder.decode(ArticleSpeechPlaybackPosition.self, from: data),
              position.globalTime.isFinite else {
            return nil
        }
        return position
    }

    /// The more recently saved of two copies of the same source's position.
    /// A copy that is missing loses; equal stamps keep the first argument.
    static func newest(
        _ first: ArticleSpeechPlaybackPosition?,
        _ second: ArticleSpeechPlaybackPosition?
    ) -> ArticleSpeechPlaybackPosition? {
        switch (first, second) {
        case (nil, nil):
            return nil
        case (let only?, nil), (nil, let only?):
            return only
        case (let a?, let b?):
            return b.updatedAt > a.updatedAt ? b : a
        }
    }
}

/// What a partly finished text-to-speech generation already paid for.
///
/// Audio chunks reach disk as each request lands, but `manifest.json` is
/// deliberately the last write — a truncated manifest would read as a complete
/// source on the listener's other devices. That left nothing describing the
/// files already written, so any interruption (the phone suspending the app in
/// the background, a dropped connection) threw every generated chunk away and
/// the next attempt re-billed the whole source from its first character.
///
/// This sidecar is that missing record. It names the gap-free prefix of
/// requests that finished and the durable files they produced, so the next
/// attempt resumes at the first missing chunk. Only `manifest.json` is ever
/// read as a playable source, so a progress file never makes a partial
/// generation look complete — on this device or on any other.
struct ArticleSpeechGenerationProgress: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let fileName = "generation-progress.json"

    let schemaVersion: Int
    let sourceID: String
    /// Hash of the exact narration text these chunks were generated from.
    let contentSignature: String
    /// The model and voice that spoke them. A resume must never stitch a new
    /// voice onto a half-narrated source, so both have to match exactly.
    let model: String
    let voice: String
    /// Requests in the whole plan, including the opening. The plan is derived
    /// from the text and the model's chunk limits, so a mismatch means the
    /// stored prefix no longer describes the same generation.
    let plannedRequestCount: Int
    /// How many of those requests finished, as a gap-free prefix.
    let completedRequestCount: Int
    /// The audio files on disk for that prefix, in playback order. A request
    /// the model refused whole contributes several files, so this is not the
    /// same count as `completedRequestCount`.
    let chunks: [SyncedArticleAudioManifest.Chunk]
    let updatedAt: Date

    init(
        sourceID: String,
        contentSignature: String,
        model: String,
        voice: String,
        plannedRequestCount: Int,
        completedRequestCount: Int,
        chunks: [SyncedArticleAudioManifest.Chunk],
        updatedAt: Date
    ) {
        self.schemaVersion = Self.schemaVersion
        self.sourceID = sourceID
        self.contentSignature = contentSignature
        self.model = model
        self.voice = voice
        self.plannedRequestCount = plannedRequestCount
        self.completedRequestCount = completedRequestCount
        self.chunks = chunks
        self.updatedAt = updatedAt
    }
}

enum SyncedArticleAudioStore {
    static let manifestFileName = "manifest.json"
    static let sourceTextFileName = "source-text.txt"
    static let chunksDirectoryName = "Chunks"

    /// The working folder of a device (§3.5.30), the phone's and the Mac's: set once by the app
    /// (`MobileNarrationLibrary.install`, `MacNarrationLibrary.install`).
    nonisolated(unsafe) static var workingFolderProvider: (@Sendable () -> SyncedArticleAudioWorkingFolder?)?

    static var workingFolder: SyncedArticleAudioWorkingFolder? { workingFolderProvider?() }

    static func contentSignature(for text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Where narration lives: a device's own working folder (`SyncedArticleAudioWorkingFolder`), the
    /// phone's and the Mac's alike, whose narrations travel as the source's `audio.*` satellites
    /// (§3.5.30). Before the folder is installed, the root `ubiquityLibraryRootURL` names.
    static func libraryRootURL() -> URL {
        if let folder = workingFolder { return folder.root }
        return ubiquityLibraryRootURL()
    }

    /// Where narration sat before the working folder. On the Mac it is ForeverLM's iCloud Documents
    /// folder, read by plain path (`StorageService.ubiquityContentRootPath`): what the activation reads a
    /// narration's saved position from, once, before the working folder holds anything. The iPhone never
    /// reads iCloud Documents (no build is entitled to that container any more), so its root is a folder
    /// of its own until the working folder is installed.
    static func ubiquityLibraryRootURL() -> URL {
        #if os(macOS)
        URL(fileURLWithPath: StorageService.ubiquityContentRootPath, isDirectory: true)
        #else
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Documents/ForeverLM", isDirectory: true)
        #endif
    }

    static func ubiquityAudioRootURL() -> URL {
        ubiquityLibraryRootURL().appendingPathComponent("Audio", isDirectory: true)
    }

    static func ubiquityPlaybackPositionURL(sourceID: String) -> URL {
        ubiquityAudioRootURL()
            .appendingPathComponent(sanitizedPathComponent(sourceID), isDirectory: true)
            .appendingPathComponent(ArticleSpeechPlaybackPosition.fileName)
    }

    #if !os(macOS)
    /// The iPhone writes narration only into its working folder (§3.5.30), so a generation is never
    /// reported as saved while it sits on that phone alone.
    private static func libraryRootURLForWritingAudio() throws -> URL {
        guard let folder = workingFolder else { throw SyncedArticleAudioStoreError.iCloudUnavailable }
        return folder.root
    }
    #endif

    /// Create a directory inside the audio tree without ever inventing the
    /// content root itself.
    ///
    /// `createDirectory(…, withIntermediateDirectories: true)` is exactly how
    /// this app used to resurrect a root that iCloud had merely not delivered
    /// yet, and a resurrected root is one half of a CloudDocs directory conflict
    /// — the other half being the copy iCloud restores to catch the other Mac's
    /// writes, which lands as `ForeverLM 2`. Audio is the last writer left inside
    /// the container, so it is the last place that can fork this library: a
    /// missing root here means "not synced down yet", never "make one".
    ///
    /// Intermediates *below* an existing root are still created — those are the
    /// per-source directories this store legitimately owns. The guard is macOS
    /// only: on iOS the resolved root can legitimately be a local fallback that
    /// does not exist until first write.
    private static func createAudioDirectory(at url: URL) throws {
        #if os(macOS)
        guard FileManager.default.fileExists(atPath: libraryRootURL().path) else {
            throw SyncedArticleAudioStoreError.iCloudUnavailable
        }
        #endif
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func ensureSyncedAudioStorageAvailable() throws {
        #if !os(macOS)
        _ = try libraryRootURLForWritingAudio()
        #endif
    }

    static func audioRootURL() -> URL {
        libraryRootURL().appendingPathComponent("Audio", isDirectory: true)
    }

    /// Whether `audioRootURL()` names the iCloud Documents tree right now: on
    /// the Mac before its working folder is installed. The phone never reads
    /// iCloud Documents, so an observer is never pointed at its root.
    static var isUbiquitousAudioRootAvailable: Bool {
        guard workingFolder == nil else { return false }
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    static func sourceDirectory(sourceID: String) -> URL {
        audioRootURL().appendingPathComponent(sanitizedPathComponent(sourceID), isDirectory: true)
    }

    private static func sourceDirectoryForWritingAudio(sourceID: String) throws -> URL {
        #if os(macOS)
        return sourceDirectory(sourceID: sourceID)
        #else
        return try libraryRootURLForWritingAudio()
            .appendingPathComponent("Audio", isDirectory: true)
            .appendingPathComponent(sanitizedPathComponent(sourceID), isDirectory: true)
        #endif
    }

    static func chunkFileName(index: Int, fileExtension: String) -> String {
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return String(format: "chunk-%04d.%@", index, ext.isEmpty ? "mp3" : ext)
    }

    static func chunkURL(sourceID: String, index: Int, fileExtension: String) -> URL {
        sourceDirectory(sourceID: sourceID)
            .appendingPathComponent(chunksDirectoryName, isDirectory: true)
            .appendingPathComponent(chunkFileName(index: index, fileExtension: fileExtension))
    }

    static func manifestURL(sourceID: String) -> URL {
        sourceDirectory(sourceID: sourceID).appendingPathComponent(manifestFileName)
    }

    static func playbackPositionURL(sourceID: String) -> URL {
        sourceDirectory(sourceID: sourceID).appendingPathComponent(ArticleSpeechPlaybackPosition.fileName)
    }

    /// The position saved beside the audio on this device's copy of the
    /// container. On the Mac this already includes the account copy, which
    /// `UserDefaults` holds locally; the phone has no local mirror of
    /// preferences and reads the account through
    /// `loadPlaybackPositionIncludingAccount` instead.
    static func loadPlaybackPosition(sourceID: String) -> ArticleSpeechPlaybackPosition? {
        let local = loadLocalPlaybackPosition(sourceID: sourceID)
        #if os(macOS)
        return ListeningPositionSync.newest(local, loadAccountPlaybackPosition(sourceID: sourceID))
        #else
        return local
        #endif
    }

    static func loadLocalPlaybackPosition(sourceID: String) -> ArticleSpeechPlaybackPosition? {
        let url = playbackPositionURL(sourceID: sourceID)
        triggerDownloadIfNeeded(url)
        guard let data = try? Data(contentsOf: url) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ArticleSpeechPlaybackPosition.self, from: data)
    }

    #if os(macOS)
    /// The account copy as it stands in `UserDefaults`, kept current by the
    /// preference sync rail (`PreferenceStore.applyInbound`).
    static func loadAccountPlaybackPosition(sourceID: String) -> ArticleSpeechPlaybackPosition? {
        let key = ListeningPositionSync.preferenceKey(sourceID: sourceID)
        guard let encoded = UserDefaults.standard.string(forKey: key) else { return nil }
        return ListeningPositionSync.decode(encoded)
    }

    /// Mirrors a position to the account. `PreferenceStore` is the one write
    /// path for synced preferences; a `UserDefaults` write behind its back
    /// would stay on this Mac.
    static func publishPlaybackPositionToAccount(
        _ position: ArticleSpeechPlaybackPosition,
        sourceID: String
    ) async {
        guard let encoded = ListeningPositionSync.encode(position) else { return }
        PreferenceStore.set(encoded, forKey: ListeningPositionSync.preferenceKey(sourceID: sourceID))
    }

    static func clearAccountPlaybackPosition(sourceID: String) {
        PreferenceStore.remove(forKey: ListeningPositionSync.preferenceKey(sourceID: sourceID))
    }
    #else
    /// The account copy, fetched from CloudKit. The phone keeps no local
    /// mirror of preferences, so this is a network read — bounded, because a
    /// listener who is offline should still get the file's answer promptly.
    static func loadAccountPlaybackPosition(
        sourceID: String,
        timeout: Duration = .seconds(4)
    ) async -> ArticleSpeechPlaybackPosition? {
        let key = ListeningPositionSync.preferenceKey(sourceID: sourceID)
        return await withTaskGroup(of: ArticleSpeechPlaybackPosition?.self) { group in
            group.addTask {
                guard let encoded = try? await MobileModelPreferenceStore.shared.string(forKey: key) else {
                    return nil
                }
                return ListeningPositionSync.decode(encoded)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            // Whichever answers first: the record, or the deadline with nothing.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The position to resume from: the newer of the file beside the audio
    /// and the account copy.
    static func loadPlaybackPositionIncludingAccount(
        sourceID: String
    ) async -> ArticleSpeechPlaybackPosition? {
        async let account = loadAccountPlaybackPosition(sourceID: sourceID)
        let local = loadLocalPlaybackPosition(sourceID: sourceID)
        return ListeningPositionSync.newest(local, await account)
    }

    static func publishPlaybackPositionToAccount(
        _ position: ArticleSpeechPlaybackPosition,
        sourceID: String
    ) async {
        guard let encoded = ListeningPositionSync.encode(position) else { return }
        try? await MobileModelPreferenceStore.shared.setString(
            encoded,
            forKey: ListeningPositionSync.preferenceKey(sourceID: sourceID)
        )
    }

    static func clearAccountPlaybackPosition(sourceID: String) {
        let key = ListeningPositionSync.preferenceKey(sourceID: sourceID)
        Task.detached(priority: .utility) {
            try? await MobileModelPreferenceStore.shared.removeValue(forKey: key)
        }
    }
    #endif

    static func savePlaybackPosition(_ position: ArticleSpeechPlaybackPosition, sourceID: String) throws {
        let url = playbackPositionURL(sourceID: sourceID)
        try createAudioDirectory(at: url.deletingLastPathComponent())

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(position).write(to: url, options: .atomic)
    }

    /// Forgets a finished source's position everywhere: the file beside the
    /// audio and the account copy, or the other device would resume a source
    /// this one has already finished.
    static func clearPlaybackPosition(sourceID: String) {
        clearAccountPlaybackPosition(sourceID: sourceID)
        let url = playbackPositionURL(sourceID: sourceID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func generationProgressURL(sourceID: String) -> URL {
        sourceDirectory(sourceID: sourceID)
            .appendingPathComponent(ArticleSpeechGenerationProgress.fileName)
    }

    /// The stored progress for an unfinished generation, or nil when there is
    /// none to resume. Every named file is verified on disk: a prefix that has
    /// lost its audio is not a prefix worth resuming from.
    static func loadGenerationProgress(sourceID: String) -> ArticleSpeechGenerationProgress? {
        let url = generationProgressURL(sourceID: sourceID)
        triggerDownloadIfNeeded(url)
        guard let data = try? Data(contentsOf: url) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let progress = try? decoder.decode(ArticleSpeechGenerationProgress.self, from: data),
              progress.schemaVersion == ArticleSpeechGenerationProgress.schemaVersion,
              progress.sourceID == sourceID,
              progress.completedRequestCount > 0,
              // A prefix that reached the end is still worth resuming: it means
              // every request was paid for and only the manifest write is
              // missing, and that costs nothing to redo.
              progress.completedRequestCount <= progress.plannedRequestCount,
              hasAllChunks(progress.chunks, sourceID: sourceID) else {
            return nil
        }
        return progress
    }

    static func hasGenerationProgress(sourceID: String) -> Bool {
        loadGenerationProgress(sourceID: sourceID) != nil
    }

    static func saveGenerationProgress(_ progress: ArticleSpeechGenerationProgress) throws {
        let url = try sourceDirectoryForWritingAudio(sourceID: progress.sourceID)
            .appendingPathComponent(ArticleSpeechGenerationProgress.fileName)
        try createAudioDirectory(at: url.deletingLastPathComponent())

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(progress).write(to: url, options: .atomic)
    }

    static func clearGenerationProgress(sourceID: String) {
        let url = generationProgressURL(sourceID: sourceID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func saveChunk(_ data: Data, sourceID: String, index: Int, fileExtension: String) throws -> SyncedArticleAudioManifest.Chunk {
        guard !data.isEmpty else {
            throw SyncedArticleAudioStoreError.emptyAudioChunk(index)
        }

        let url = try sourceDirectoryForWritingAudio(sourceID: sourceID)
            .appendingPathComponent(chunksDirectoryName, isDirectory: true)
            .appendingPathComponent(chunkFileName(index: index, fileExtension: fileExtension))
        try createAudioDirectory(at: url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        return SyncedArticleAudioManifest.Chunk(
            index: index,
            fileName: url.lastPathComponent,
            byteCount: data.count
        )
    }

    static func saveManifest(_ manifest: SyncedArticleAudioManifest) throws {
        let url = try sourceDirectoryForWritingAudio(sourceID: manifest.sourceID)
            .appendingPathComponent(manifestFileName)
        try createAudioDirectory(at: url.deletingLastPathComponent())

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
        // A narration finished on a generation-2 Mac is sent to the replica (the phone's own flow asks
        // for it after a generation, so its folder sets no `saved`).
        workingFolder?.saved?(manifest.sourceID)
    }

    /// Lays down the narration the replica names for a source and brings its chunks into the
    /// working folder, so what another device made plays here without being made again. Nothing
    /// when the replica names no narration the folder lacks.
    static func bringReplicaNarration(sourceID: String) async {
        guard let folder = workingFolder else { return }
        await folder.adopt(sourceID)
        guard let manifest = publishedManifest(sourceID: sourceID), manifest.usesSupportedPlaybackFormat,
              !hasLocalChunks(for: manifest) else { return }
        try? await folder.materialize(manifest) { _ in }
    }

    static func saveSourceText(_ text: String, sourceID: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let url = try sourceDirectoryForWritingAudio(sourceID: sourceID)
            .appendingPathComponent(sourceTextFileName)
        try createAudioDirectory(at: url.deletingLastPathComponent())
        try trimmed.write(to: url, atomically: true, encoding: .utf8)
    }

    static func loadSourceText(for manifest: SyncedArticleAudioManifest) throws -> String {
        let fileName = manifest.sourceTextFileName ?? sourceTextFileName
        let url = sourceDirectory(sourceID: manifest.sourceID)
            .appendingPathComponent(fileName)
        triggerDownloadIfNeeded(url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SyncedArticleAudioStoreError.missingSourceText
        }
        let text = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw SyncedArticleAudioStoreError.missingSourceText
        }
        return text
    }

    /// Returns the stored manifest without verifying chunk files exist. Used by
    /// cache deletion, which needs the manifest metadata even when audio files
    /// are already partially gone.
    static func loadManifestIgnoringChunks(sourceID: String) -> SyncedArticleAudioManifest? {
        let url = manifestURL(sourceID: sourceID)
        // Offline-save reaches for narration this device may never have held,
        // so the manifest itself has to be requested like any other chunk.
        triggerDownloadIfNeeded(url)
        guard let data = try? Data(contentsOf: url) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SyncedArticleAudioManifest.self, from: data)
    }

    /// The narration another device has published for this source, whether or
    /// not its audio has reached this device — the same test the library scan
    /// applies, for one source. nil when no readable manifest is here yet.
    static func publishedManifest(sourceID: String) -> SyncedArticleAudioManifest? {
        let url = manifestURL(sourceID: sourceID)
        triggerDownloadIfNeeded(url)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(SyncedArticleAudioManifest.self, from: data),
              manifest.schemaVersion == SyncedArticleAudioManifest.schemaVersion,
              manifest.usesCurrentNarration else {
            return nil
        }
        return manifest
    }

    /// Whether CloudDocs knows of a manifest for this source that this device
    /// has not materialized: a dataless file under its real name, or the
    /// hidden `.icloud` sidecar. Either means audio exists on the account and
    /// is worth waiting a moment for; neither means there is nothing to wait on.
    static func hasUnmaterializedManifest(sourceID: String) -> Bool {
        let url = manifestURL(sourceID: sourceID)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            guard fileManager.isUbiquitousItem(at: url),
                  let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                      .ubiquitousItemDownloadingStatus else {
                return false
            }
            return status != .current
        }
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        return fileManager.fileExists(atPath: placeholder.path)
    }

    /// The published manifest for a source, waiting a bounded time for
    /// CloudDocs to deliver one it has only announced so far.
    ///
    /// This is what stands between "the library has not caught up yet" and a
    /// second, billed generation of audio the account already owns: the phone
    /// learns of a Mac's narration through a one-shot walk of the audio tree,
    /// and a manifest that walk merely requested is invisible until the next
    /// walk. Returns immediately when the manifest is already readable, or
    /// when CloudDocs has nothing for this source at all — the wait is only
    /// ever spent on audio that is known to exist.
    static func awaitPublishedManifest(
        sourceID: String,
        timeout: Duration = .seconds(10)
    ) async -> SyncedArticleAudioManifest? {
        if let manifest = publishedManifest(sourceID: sourceID) { return manifest }
        // The replica is asked, not CloudDocs, and what it holds is laid down at once.
        if let folder = workingFolder {
            await folder.adopt(sourceID)
            return publishedManifest(sourceID: sourceID)
        }
        guard hasUnmaterializedManifest(sourceID: sourceID) else { return nil }

        let directory = sourceDirectory(sourceID: sourceID)
        let watcher = await UbiquitousDownloadWatcher(
            directory: directory,
            fileName: manifestFileName
        )
        defer { Task { await watcher.stop() } }
        let deadline = ContinuousClock.now + timeout
        for await _ in watcher.events {
            if Task.isCancelled { return nil }
            if let manifest = publishedManifest(sourceID: sourceID) { return manifest }
            if ContinuousClock.now >= deadline { return nil }
        }
        return publishedManifest(sourceID: sourceID)
    }

    /// Returns a playable manifest when every synced chunk file is present on disk.
    static func loadCompleteManifest(sourceID: String) -> SyncedArticleAudioManifest? {
        let url = manifestURL(sourceID: sourceID)
        triggerDownloadIfNeeded(url)
        guard let data = try? Data(contentsOf: url) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(SyncedArticleAudioManifest.self, from: data),
              manifest.schemaVersion == SyncedArticleAudioManifest.schemaVersion,
              manifest.usesCurrentNarration,
              manifest.speaksInOneVoice,
              hasAllChunks(for: manifest) else {
            return nil
        }
        return manifest
    }

    /// Every narration this account holds, whether or not its audio has reached
    /// this device yet.
    ///
    /// A manifest is a few kilobytes and a full narration is tens of megabytes,
    /// so requiring the audio here meant a phone showed nothing until gigabytes
    /// had landed — and asked CloudDocs about every chunk of every narration on
    /// every library load to find that out. The manifest alone is what the
    /// library needs to say "this has audio"; `materializeChunks` fetches the
    /// audio when someone actually presses play.
    ///
    /// `onProgress` reports (directories checked, directories total) after
    /// each source directory. On a device that has not materialized the tree,
    /// each manifest read blocks until CloudDocs delivers the file, so this is
    /// the only honest measure of how far a first pass has gotten.
    static func loadAvailableManifests(
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> [SyncedArticleAudioManifest] {
        let root = audioRootURL()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return [] }

        let sourceDirectories = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        onProgress?(0, sourceDirectories.count)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifests: [SyncedArticleAudioManifest] = []
        for (index, directory) in sourceDirectories.enumerated() {
            defer { onProgress?(index + 1, sourceDirectories.count) }
            let manifestURL = directory.appendingPathComponent(manifestFileName)
            triggerDownloadIfNeeded(manifestURL)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(SyncedArticleAudioManifest.self, from: data),
                  manifest.schemaVersion == SyncedArticleAudioManifest.schemaVersion,
                  manifest.usesCurrentNarration else {
                continue
            }
            manifests.append(manifest)
        }

        return manifests.sorted { $0.createdAt > $1.createdAt }
    }

    /// The chunk files a manifest names, in playback order — whether or not
    /// they have been downloaded.
    static func expectedChunkURLs(for manifest: SyncedArticleAudioManifest) -> [URL] {
        let directory = sourceDirectory(sourceID: manifest.sourceID)
            .appendingPathComponent(chunksDirectoryName, isDirectory: true)
        return manifest.chunks.sorted { $0.index < $1.index }.map { chunk in
            directory.appendingPathComponent(chunk.fileName)
        }
    }

    /// True when every chunk is on this device and playable without a network.
    static func hasLocalChunks(for manifest: SyncedArticleAudioManifest) -> Bool {
        hasAllChunks(for: manifest)
    }

    /// Brings a narration's audio down from iCloud, reporting how far along it
    /// is, and returns once every chunk is playable locally.
    ///
    /// The wait is driven by CloudDocs' own metadata updates rather than by
    /// asking the filesystem on a timer: an `NSMetadataQuery` over the chunk
    /// directory fires whenever iCloud changes an item's downloading state, and
    /// each of those events re-checks the files. A slow five-second tick backs
    /// it up for the case where the query has nothing to say at all.
    static func materializeChunks(
        for manifest: SyncedArticleAudioManifest,
        onProgress: @escaping @Sendable (SyncedArticleAudioDownloadProgress) -> Void
    ) async throws {
        let urls = expectedChunkURLs(for: manifest)
        guard !urls.isEmpty else {
            throw SyncedArticleAudioStoreError.missingAudioChunk(manifest.sourceID)
        }
        // The chunks are the narration's satellites, fetched by name.
        if let folder = workingFolder {
            try await folder.materialize(manifest, onProgress)
            return
        }
        try await materializeChunks(at: urls, sourceID: manifest.sourceID, onProgress: onProgress)
    }

    /// The file-level body of `materializeChunks(for:)`, so a test can point
    /// it at a directory it controls. Progress is reported once up front and
    /// then on every CloudDocs update, and only when it changed — a listener
    /// that starts playback on the first contiguous chunk must not be woken
    /// by the backstop tick to do nothing.
    static func materializeChunks(
        at urls: [URL],
        sourceID: String,
        onProgress: @escaping @Sendable (SyncedArticleAudioDownloadProgress) -> Void
    ) async throws {
        guard !urls.isEmpty else {
            throw SyncedArticleAudioStoreError.missingAudioChunk(sourceID)
        }

        func measure() -> SyncedArticleAudioDownloadProgress {
            SyncedArticleAudioDownloadProgress.measure(ready: urls.map(isMaterializedChunk))
        }

        var last = measure()
        if last.isComplete { return }
        for url in urls { triggerDownloadIfNeeded(url) }
        last = measure()
        onProgress(last)
        if last.isComplete { return }

        let directory = urls[0].deletingLastPathComponent()
        let watcher = await UbiquitousDownloadWatcher(directory: directory)
        defer { Task { await watcher.stop() } }

        for await _ in watcher.events {
            try Task.checkCancellation()
            let progress = measure()
            if progress != last {
                last = progress
                onProgress(progress)
            }
            if progress.isComplete { return }
        }

        guard measure().isComplete else {
            throw SyncedArticleAudioStoreError.missingAudioChunk(
                urls.first { !FileManager.default.fileExists(atPath: $0.path) }?.lastPathComponent
                    ?? sourceID
            )
        }
    }

    static func chunkURLs(for manifest: SyncedArticleAudioManifest) throws -> [URL] {
        let directory = sourceDirectory(sourceID: manifest.sourceID)
            .appendingPathComponent(chunksDirectoryName, isDirectory: true)

        let urls = manifest.chunks.sorted { $0.index < $1.index }.map { chunk in
            directory.appendingPathComponent(chunk.fileName)
        }

        for url in urls {
            triggerDownloadIfNeeded(url)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SyncedArticleAudioStoreError.missingAudioChunk(url.lastPathComponent)
            }
        }

        return urls
    }

    private static func hasAllChunks(for manifest: SyncedArticleAudioManifest) -> Bool {
        hasAllChunks(manifest.chunks, sourceID: manifest.sourceID)
    }

    private static func hasAllChunks(
        _ chunks: [SyncedArticleAudioManifest.Chunk],
        sourceID: String
    ) -> Bool {
        guard !chunks.isEmpty else { return false }
        let directory = sourceDirectory(sourceID: sourceID)
            .appendingPathComponent(chunksDirectoryName, isDirectory: true)

        return chunks.allSatisfy { chunk in
            let url = directory.appendingPathComponent(chunk.fileName)
            triggerDownloadIfNeeded(url)
            return isMaterializedChunk(url)
        }
    }

    /// Whether a chunk can be handed to AVFoundation right now.
    ///
    /// A file's presence and size are not enough on a device that is still
    /// pulling it from iCloud: CloudDocs materializes the item under its real
    /// name while the bytes arrive, so a size-only check called a half-fetched
    /// chapter playable and AVURLAsset then failed with the bare "The operation
    /// could not be completed". A ubiquitous item counts only once CloudDocs
    /// reports it current; anything not under iCloud's management is judged by
    /// its bytes as before.
    static func isMaterializedChunk(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return false }
        if fileManager.isUbiquitousItem(at: url),
           let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
               .ubiquitousItemDownloadingStatus,
           status == .notDownloaded {
            return false
        }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return true }
        return size > 0
    }

    /// Ask CloudDocs for a file this device has not materialized yet.
    ///
    /// Eviction — and a narration this device has simply never seen — leaves
    /// either a dataless file under its real name or a hidden `.icloud`
    /// sidecar. Only the first case answers `fileExists` at the real name, so
    /// guarding the whole function on that made discovery self-perpetuating:
    /// the phone requested downloads exclusively for audio it already had, and
    /// every narration the Mac published after the last sync stayed invisible
    /// forever. Both spellings are download triggers; neither being present is
    /// the one case where there is genuinely nothing to ask for.
    private static func triggerDownloadIfNeeded(_ url: URL) {
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: url.path) {
            guard fileManager.isUbiquitousItem(at: url),
                  let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
                  values.ubiquitousItemDownloadingStatus != .current else {
                return
            }
            try? fileManager.startDownloadingUbiquitousItem(at: url)
            return
        }

        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        guard fileManager.fileExists(atPath: placeholder.path) else { return }
        try? fileManager.startDownloadingUbiquitousItem(at: placeholder)
    }

    /// A source's folder name under `Audio`, in the working folder and in iCloud Drive alike.
    static func sanitizedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let result = value.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
        return result.isEmpty ? "source" : result
    }
}

#if !os(macOS)
extension SyncedArticleAudioStore {
    /// Republishes complete audio from one root into another, the manifest last. Only the
    /// iPhone tests call it; the app does not.
    @discardableResult
    static func recoverLocallyStrandedAudio(from localRoot: URL, to cloudRoot: URL) throws -> Int {
        let fileManager = FileManager.default
        let localAudioRoot = localRoot.appendingPathComponent("Audio", isDirectory: true)
        guard localRoot.standardizedFileURL != cloudRoot.standardizedFileURL,
              fileManager.fileExists(atPath: localAudioRoot.path) else {
            return 0
        }

        let cloudAudioRoot = cloudRoot.appendingPathComponent("Audio", isDirectory: true)
        try createAudioDirectory(at: cloudAudioRoot)
        let localDirectories = try fileManager.contentsOfDirectory(
            at: localAudioRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var recovered = 0
        for localDirectory in localDirectories {
            guard let (manifest, manifestData) = completeManifest(in: localDirectory) else { continue }
            let cloudDirectory = cloudAudioRoot.appendingPathComponent(
                localDirectory.lastPathComponent,
                isDirectory: true
            )
            if completeManifest(in: cloudDirectory) != nil { continue }

            let localChunks = localDirectory.appendingPathComponent(chunksDirectoryName, isDirectory: true)
            let cloudChunks = cloudDirectory.appendingPathComponent(chunksDirectoryName, isDirectory: true)
            try fileManager.createDirectory(at: cloudChunks, withIntermediateDirectories: true)
            for chunk in manifest.chunks {
                let source = localChunks.appendingPathComponent(chunk.fileName)
                let destination = cloudChunks.appendingPathComponent(chunk.fileName)
                let existingSize = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
                if let existingSize, existingSize > 0 { continue }
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: source, to: destination)
            }

            let localText = localDirectory.appendingPathComponent(sourceTextFileName)
            if fileManager.fileExists(atPath: localText.path) {
                let textData = try Data(contentsOf: localText)
                try textData.write(
                    to: cloudDirectory.appendingPathComponent(sourceTextFileName),
                    options: .atomic
                )
            }
            // Publish the manifest last: receivers never see it before all
            // files it names are present in the cloud directory.
            try manifestData.write(
                to: cloudDirectory.appendingPathComponent(manifestFileName),
                options: .atomic
            )
            guard completeManifest(in: cloudDirectory) != nil else {
                throw SyncedArticleAudioStoreError.recoveryIncomplete(manifest.sourceID)
            }
            recovered += 1
        }
        return recovered
    }

    private static func completeManifest(
        in directory: URL
    ) -> (SyncedArticleAudioManifest, Data)? {
        let url = directory.appendingPathComponent(manifestFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(SyncedArticleAudioManifest.self, from: data),
              manifest.schemaVersion == SyncedArticleAudioManifest.schemaVersion,
              !manifest.chunks.isEmpty else {
            return nil
        }
        let chunks = directory.appendingPathComponent(chunksDirectoryName, isDirectory: true)
        guard manifest.chunks.allSatisfy({ chunk in
            let url = chunks.appendingPathComponent(chunk.fileName)
            return ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        }) else {
            return nil
        }
        return (manifest, data)
    }
}
#endif

enum SyncedArticleAudioStoreError: LocalizedError {
    case emptyAudioChunk(Int)
    case missingAudioChunk(String)
    case missingSourceText
    case iCloudUnavailable
    case recoveryIncomplete(String)

    var errorDescription: String? {
        switch self {
        case .emptyAudioChunk(let index):
            return "Generated audio chunk \(index + 1) was empty."
        case .missingAudioChunk(let fileName):
            return "Missing synced audio file \(fileName)."
        case .missingSourceText:
            return "This source does not have synced review text yet. Play Text to Speech for it again on your Mac."
        case .iCloudUnavailable:
            return "iCloud Drive is not available. Generated audio was not saved locally because it could not sync to your other devices."
        case .recoveryIncomplete(let sourceID):
            return "Could not finish moving locally generated audio for \(sourceID) into iCloud Drive."
        }
    }
}

/// Turns CloudDocs' download reporting for one directory into an async stream
/// of "something changed" events.
///
/// `NSMetadataQuery` is the only API that reports ubiquitous download state as
/// it happens, and it needs a run loop, so it lives on the main actor. It is
/// used purely as the event source: what the files on disk actually say stays
/// the source of truth, which keeps a query that reports nothing useful from
/// being able to strand a caller.
@MainActor
final class UbiquitousDownloadWatcher {
    let events: AsyncStream<Void>

    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private var backstop: Task<Void, Never>?
    private var isStopped = false

    /// `fileName` narrows the query to items of that name under `directory`,
    /// so a watcher waiting on one small file is not woken by every chunk of
    /// audio landing beside it.
    init(directory: URL, fileName: String? = nil) {
        var madeContinuation: AsyncStream<Void>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { madeContinuation = $0 }
        let continuation = madeContinuation!

        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        if let fileName {
            query.predicate = NSPredicate(
                format: "%K BEGINSWITH %@ AND %K == %@",
                NSMetadataItemPathKey,
                directory.path,
                NSMetadataItemFSNameKey,
                fileName
            )
        } else {
            query.predicate = NSPredicate(
                format: "%K BEGINSWITH %@",
                NSMetadataItemPathKey,
                directory.path
            )
        }
        query.valueListAttributes = [
            NSMetadataUbiquitousItemDownloadingStatusKey,
            NSMetadataUbiquitousItemPercentDownloadedKey,
        ]

        let names: [Notification.Name] = [
            .NSMetadataQueryDidFinishGathering,
            .NSMetadataQueryDidUpdate,
        ]
        for name in names {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: query,
                    queue: .main
                ) { _ in continuation.yield(()) }
            )
        }

        query.start()

        // Backstop only: iCloud sometimes settles without a final update, and a
        // caller must never be left waiting on an event that will not come.
        backstop = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                continuation.yield(())
            }
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        backstop?.cancel()
        query.stop()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }
}

/// Tells a library when the set of narrations on the account changes.
///
/// The library's list of audio is a one-shot walk of the iCloud audio tree, so a
/// narration another device finished after that walk stayed invisible — the
/// row offered to generate audio the account already owned — until something
/// happened to run the walk again. This keeps an `NSMetadataQuery` open over
/// every `manifest.json` under the audio root: CloudDocs reports each new
/// manifest and each download that completes, the observer asks for any it has
/// not materialized, and it yields once the set of readable manifests differs
/// from what it last reported. The library rescans on that signal and nothing
/// else; there is deliberately no timer, because a rescan reads hundreds of
/// files.
@MainActor
final class SyncedAudioManifestObserver {
    let changes: AsyncStream<Void>

    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private var lastReadableManifestPaths: Set<String>?
    private var isStopped = false

    init(audioRoot: URL) {
        var madeContinuation: AsyncStream<Void>.Continuation!
        changes = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { madeContinuation = $0 }
        let continuation = madeContinuation!

        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(
            format: "%K BEGINSWITH %@ AND %K == %@",
            NSMetadataItemPathKey,
            audioRoot.path,
            NSMetadataItemFSNameKey,
            SyncedArticleAudioStore.manifestFileName
        )
        query.valueListAttributes = [NSMetadataUbiquitousItemDownloadingStatusKey]

        let names: [Notification.Name] = [
            .NSMetadataQueryDidFinishGathering,
            .NSMetadataQueryDidUpdate,
        ]
        for name in names {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: query,
                    queue: .main
                ) { [weak self] _ in
                    // Delivered on the main queue, which is this actor.
                    MainActor.assumeIsolated {
                        guard let self, !self.isStopped else { return }
                        if self.readableManifestSetChanged() {
                            continuation.yield(())
                        }
                    }
                }
            )
        }
        query.start()
    }

    /// Reads the query's current results, requests every manifest CloudDocs
    /// has announced but not delivered, and reports whether the readable set
    /// moved since the last report. The first gather seeds the baseline
    /// without yielding: the library's own walk already covers that state.
    private func readableManifestSetChanged() -> Bool {
        query.disableUpdates()
        defer { query.enableUpdates() }

        var readable: Set<String> = []
        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            if status == NSMetadataUbiquitousItemDownloadingStatusCurrent {
                readable.insert(path)
            } else {
                try? FileManager.default.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: path))
            }
        }

        guard let previous = lastReadableManifestPaths else {
            lastReadableManifestPaths = readable
            return false
        }
        guard readable != previous else { return false }
        lastReadableManifestPaths = readable
        return true
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        query.stop()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }
}

/// Where narration lives (docs/cloudkit-schema-design.md §3.5.30, `audio.<voiceKey>`):
/// the replica holds it, as the source's satellites, and a device keeps a working copy of the same layout
/// on its own disk instead of in iCloud Drive. What the device generates is written there first; what other
/// devices made is laid down there from the replica. The store's paths follow `root`; what it would ask
/// CloudDocs for it asks `materialize` and `adopt` instead.
struct SyncedArticleAudioWorkingFolder: Sendable {
    let root: URL
    /// Brings every chunk the manifest names into the folder, reporting as they arrive.
    let materialize: @Sendable (SyncedArticleAudioManifest, @escaping @Sendable (SyncedArticleAudioDownloadProgress) -> Void) async throws -> Void
    /// Lays down the narration the replica holds for a source, when the folder has none of it yet.
    let adopt: @Sendable (String) async -> Void
    /// A manifest was saved for a source: its narration is finished here.
    var saved: (@Sendable (String) -> Void)?
    /// The learner removed a source's narration: the replica's pointer goes too, or it would be laid down again.
    var removed: (@Sendable (String) -> Void)?
}
