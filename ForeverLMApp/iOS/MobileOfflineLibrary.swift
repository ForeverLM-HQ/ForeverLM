import Combine
import CryptoKit
import Foundation

// Saving a source offline on the phone.
//
// Everything the phone keeps by default is a cache: MobileSourceFileStore writes
// source text, PDFs and thumbnails under Caches, which iOS purges whenever it
// wants the space back, and a paper's original document only arrives the first
// time it is opened. That is the right default for browsing and the wrong one for
// a flight. A saved source is copied into Application Support instead — never
// purged — and the read paths prefer that copy from then on.

/// Which sources this phone was asked to keep. Deliberately device-local: it
/// answers "what is on *this* device", which is a storage decision rather than
/// library content, and the `ios.` prefix keeps it out of the account preference
/// sync rail.
enum MobileOfflinePins {
    static let storageKey = "ios.offline.savedSourceIDs"

    static func saved(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    static func contains(_ sourceID: String, defaults: UserDefaults = .standard) -> Bool {
        saved(defaults: defaults).contains(sourceID)
    }

    static func write(_ sourceIDs: Set<String>, defaults: UserDefaults = .standard) {
        defaults.set(sourceIDs.sorted(), forKey: storageKey)
    }
}

/// The durable half of the phone's on-device storage. Nothing here is
/// authoritative — every byte can be re-fetched from the Mac's iCloud library —
/// so the directory is excluded from backup.
actor MobileOfflineSourceStore {
    static let shared = MobileOfflineSourceStore()

    private enum Kind: String, CaseIterable {
        case text = "Text"
        case pdf = "PDFs"
        /// The illustrated chapter document for a saved book. Without it a saved
        /// book would come back on a plane as text with every figure gone.
        case readerHTML = "ReaderHTML"

        var fileExtension: String {
            switch self {
            case .text: return "txt"
            case .pdf: return "pdf"
            case .readerHTML: return "html"
            }
        }
    }

    private let fileManager = FileManager.default
    /// Tests point this at a scratch directory. Production resolves Application
    /// Support lazily inside the actor: `init` must not touch the filesystem,
    /// because `shared` is first reached from the main actor.
    private let rootOverride: URL?
    private var resolvedRoot: URL?

    init(root: URL? = nil) {
        rootOverride = root
    }

    // MARK: - Readable text

    func savedText(sourceID: String) -> String? {
        guard let url = try? fileURL(kind: .text, sourceID: sourceID),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }

    func writeText(_ text: String, sourceID: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MobileOfflineSaveError.noReadableText }
        try Data(text.utf8).write(to: fileURL(kind: .text, sourceID: sourceID), options: .atomic)
    }

    // MARK: - Illustrated chapter documents

    func savedReaderHTML(sourceID: String) -> String? {
        guard let url = try? fileURL(kind: .readerHTML, sourceID: sourceID),
              let html = try? String(contentsOf: url, encoding: .utf8),
              !html.isEmpty else {
            return nil
        }
        return html
    }

    func writeReaderHTML(_ html: String, sourceID: String) throws {
        guard !html.isEmpty else { throw MobileOfflineSaveError.noReadableText }
        try Data(html.utf8).write(to: fileURL(kind: .readerHTML, sourceID: sourceID), options: .atomic)
    }

    // MARK: - Original documents

    func savedPDFURL(sourceID: String) -> URL? {
        guard let url = try? fileURL(kind: .pdf, sourceID: sourceID),
              fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    /// Copies an already-downloaded PDF into the durable directory and returns
    /// the durable URL, which is the one readers should hold from then on.
    @discardableResult
    func savePDF(copyingFrom origin: URL, sourceID: String) throws -> URL {
        let destination = try fileURL(kind: .pdf, sourceID: sourceID)
        // fetchPDF hands back the durable copy once one exists; copying a file
        // onto itself would delete it first and lose the document.
        guard origin.standardizedFileURL != destination.standardizedFileURL else { return destination }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: origin, to: destination)
        return destination
    }

    // MARK: - Accounting and removal

    func byteCount(sourceID: String) -> Int64 {
        Kind.allCases.reduce(into: Int64(0)) { total, kind in
            guard let url = try? fileURL(kind: kind, sourceID: sourceID),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                return
            }
            total += Int64(size)
        }
    }

    func byteCounts(sourceIDs: [String]) -> [String: Int64] {
        var counts: [String: Int64] = [:]
        for sourceID in sourceIDs {
            counts[sourceID] = byteCount(sourceID: sourceID)
        }
        return counts
    }

    func remove(sourceID: String) {
        for kind in Kind.allCases {
            guard let url = try? fileURL(kind: kind, sourceID: sourceID) else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    func removeAll() {
        guard let root = try? root() else { return }
        try? fileManager.removeItem(at: root)
        resolvedRoot = nil
    }

    // MARK: - Paths

    private func root() throws -> URL {
        if let resolvedRoot { return resolvedRoot }

        let base: URL
        if let rootOverride {
            base = rootOverride
        } else {
            base = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("ForeverLM/Offline", isDirectory: true)
        }
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)

        var directory = base
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)

        resolvedRoot = base
        return base
    }

    private func fileURL(kind: Kind, sourceID: String) throws -> URL {
        let directory = try root().appendingPathComponent(kind.rawValue, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Source ids are URLs and free text, not filesystem-safe. Hash them the
        // same way the Caches mirror does so the two stay comparable by eye.
        let digest = SHA256.hash(data: Data(sourceID.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).\(kind.fileExtension)")
    }
}

/// Narration is the one part of a saved source that is not copied. Text-to-speech
/// audio already lives in the shared iCloud container — the Mac publishes it
/// there and playback reads it from there — so keeping it offline means asking
/// CloudDocs to materialize evicted chunks, exactly what the audio store does
/// when it walks a manifest. Fire-and-forget: iCloud finishes in the background,
/// and a source with no synced narration has nothing to pull.
enum MobileOfflineNarration {
    static func materialize(sourceID: String) {
        guard let manifest = SyncedArticleAudioStore.loadManifestIgnoringChunks(sourceID: sourceID) else { return }

        let fileManager = FileManager.default
        let chunks = SyncedArticleAudioStore.sourceDirectory(sourceID: sourceID)
            .appendingPathComponent(SyncedArticleAudioStore.chunksDirectoryName, isDirectory: true)

        for fileName in manifest.chunks.map(\.fileName) {
            // Eviction leaves either a dataless file under its real name or a
            // hidden `.icloud` sidecar; both are download triggers, and neither
            // being present just means there is nothing to ask for.
            try? fileManager.startDownloadingUbiquitousItem(at: chunks.appendingPathComponent(fileName))
            let placeholder = chunks.appendingPathComponent(".\(fileName).icloud")
            guard fileManager.fileExists(atPath: placeholder.path) else { continue }
            try? fileManager.startDownloadingUbiquitousItem(at: placeholder)
        }
    }
}

enum MobileOfflineByteFormat {
    static func string(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}

enum MobileOfflineSaveError: LocalizedError {
    case noReadableText

    var errorDescription: String? {
        switch self {
        case .noReadableText:
            return "This source has no synced readable text to save."
        }
    }
}

/// UI-facing state for saved sources: what is saved, what is saving, how much
/// space it takes, and why a save failed. Every property a view body reads is a
/// dictionary or set lookup — the disk work belongs to `MobileOfflineSourceStore`.
@MainActor
final class MobileOfflineLibrary: ObservableObject {
    static let shared = MobileOfflineLibrary()

    enum SaveState: Equatable {
        case notSaved
        case saving
        case saved(bytes: Int64)
        case failed(String)
    }

    @Published private(set) var savedSourceIDs: Set<String>
    @Published private(set) var savingSourceIDs: Set<String> = []
    @Published private(set) var bytesBySourceID: [String: Int64] = [:]
    @Published private(set) var failureMessages: [String: String] = [:]
    /// What saved sources keep of one file more than once: a book kept as one
    /// file counts in each of its saved chapters, but is on the phone once.
    @Published private(set) var sharedBytes: Int64 = 0

    private let store: MobileOfflineSourceStore

    init(store: MobileOfflineSourceStore = .shared) {
        self.store = store
        savedSourceIDs = MobileOfflinePins.saved()
    }

    var totalBytes: Int64 {
        bytesBySourceID.values.reduce(0, +) - sharedBytes
    }

    /// nil until sizes have been read from disk, so no surface flashes a total of
    /// zero over downloads that are actually there.
    var formattedTotalBytes: String? {
        guard !savedSourceIDs.isEmpty, !bytesBySourceID.isEmpty else { return nil }
        return MobileOfflineByteFormat.string(totalBytes)
    }

    /// A pin outranks a notice: a paper saved without its original document is
    /// still saved, and offering Save Offline again would hide the copy that is
    /// already there.
    func state(for sourceID: String) -> SaveState {
        if savingSourceIDs.contains(sourceID) { return .saving }
        if savedSourceIDs.contains(sourceID) { return .saved(bytes: bytesBySourceID[sourceID] ?? 0) }
        if let message = failureMessages[sourceID] { return .failed(message) }
        return .notSaved
    }

    func failureMessage(for sourceID: String) -> String? {
        failureMessages[sourceID]
    }

    /// The one failed save allowed on screen right now.
    ///
    /// Every source row carries its own alert for its own failure, so a save
    /// that fails for several sources at once — a whole book, a bulk pin —
    /// would flip all of those alerts true in the same runloop turn. UIKit
    /// presents one alert at a time and aborts the process rather than queue
    /// the second, so the failures queue here instead: the lowest source ID
    /// shows, and the next takes its place as each is dismissed. Nothing is
    /// dropped, because a failure stays in `failureMessages` until it is
    /// cleared. See `MobileAsyncAlert`.
    var surfacedFailureSourceID: String? {
        failureMessages.keys.min()
    }

    /// Record a failed save, to be surfaced on that source's row once the
    /// queue reaches it. Paired with `clearFailure`, which is what dismissing
    /// the notice calls.
    func recordFailure(_ message: String, sourceID: String) {
        failureMessages[sourceID] = message
    }

    func clearFailure(sourceID: String) {
        failureMessages[sourceID] = nil
    }

    // MARK: - Saving

    func save(_ source: MobileCloudSource) async {
        guard !savingSourceIDs.contains(source.id) else { return }
        savingSourceIDs.insert(source.id)
        failureMessages[source.id] = nil
        defer { savingSourceIDs.remove(source.id) }

        do {
            let text = try await MobileCloudSourceTextStore.shared.loadSourceText(sourceID: source.id)
            try await store.writeText(text, sourceID: source.id)
        } catch {
            // Readable text is the floor. Without it nothing about this source
            // works offline, so keep nothing — partial bytes would report as
            // saved and then fail to open — and say why.
            await store.remove(sourceID: source.id)
            unpin(source.id)
            bytesBySourceID[source.id] = nil
            recordFailure(error.localizedDescription, sourceID: source.id)
            return
        }

        pin(source.id)

        if let satellites = await MobileSatellites.current() {
            await saveSatellites(of: source, satellites: satellites)
            bytesBySourceID[source.id] = await byteCount(sourceID: source.id)
            await recountSharedBytes()
            return
        }

        if source.sourceType == "paper" {
            // A paper's reader is its original document, so that document is part
            // of a complete save — but the text alone still carries Ask, chat and
            // text-to-speech offline. A phone with iCloud Drive off, or a paper whose
            // document the Mac never published, keeps the useful half and is told
            // what it did not get rather than losing the save.
            do {
                let downloaded = try await MobileSourceFileStore.shared.fetchPDF(
                    sourceID: source.id,
                    relativePath: MobileSourceFilePath.relativePDFPath(
                        localFilePath: source.localFilePath,
                        url: source.url
                    )
                )
                try await store.savePDF(copyingFrom: downloaded.url, sourceID: source.id)
            } catch {
                recordFailure(
                    "Saved this paper's text. Its original document could not be "
                        + "downloaded, so the reader still needs a connection.",
                    sourceID: source.id
                )
            }
        } else if source.isPDFBackedBookChapter {
            // A PDF chapter reads as its document too, but its reader falls
            // back to text when that document is unavailable — so an unreachable
            // chapter PDF is not worth a notice, let alone a failed save. The
            // copy kept here is only ever the chapter's own file: a chapter kept
            // as a run of its book's pages is never copied whole per chapter.
            if let downloaded = try? await MobileSourceFileStore.shared.fetchPDF(
                sourceID: source.id,
                relativePath: MobileSourceFilePath.relativePDFPath(
                    localFilePath: source.localFilePath,
                    url: source.url
                )
            ), downloaded.pages == nil {
                _ = try? await store.savePDF(copyingFrom: downloaded.url, sourceID: source.id)
            }
        } else if source.sourceType == "book",
                  let readerHTML = await MobileSourceFileStore.shared.fetchReaderHTML(
                      sourceID: source.id
                  ) {
            // An EPUB chapter's figures only exist in its reader document. Its
            // absence is not a failure: a text-only book, or one from a Mac build
            // without chapter documents, saves as text alone.
            try? await store.writeReaderHTML(readerHTML, sourceID: source.id)
        }

        bytesBySourceID[source.id] = await store.byteCount(sourceID: source.id)

        let sourceID = source.id
        Task.detached(priority: .utility) {
            MobileOfflineNarration.materialize(sourceID: sourceID)
        }
    }

    /// Generation 2 (docs/cloudkit-schema-design.md §2.3, §8b): a saved source's files are its
    /// satellites, kept durable for it (`MobileSatelliteHolder.source`): the paper's document, a
    /// chapter's document or reader page, and its narration with every chunk, which no longer lives in
    /// iCloud Drive for the phone to materialize. The text is saved above, as on generation 1. A
    /// chapter kept as a run of its book's pages keeps the book's file, which every saved chapter of
    /// that book keeps as a hard link to one copy, so a whole book saved is stored once.
    private func saveSatellites(of source: MobileCloudSource, satellites: MobileSatellites) async {
        if source.sourceType == "paper" {
            do {
                // Kept durable by the store itself, since the source is pinned now.
                _ = try await MobileSourceFileStore.shared.fetchPDF(sourceID: source.id)
            } catch {
                recordFailure(
                    "Saved this paper's text. Its original document could not be "
                        + "downloaded, so the reader still needs a connection.",
                    sourceID: source.id
                )
            }
        } else if source.isPDFBackedBookChapter {
            _ = try? await MobileSourceFileStore.shared.fetchPDF(sourceID: source.id)
        } else if source.sourceType == "book" {
            _ = await MobileSourceFileStore.shared.fetchReaderHTML(sourceID: source.id)
        }
        let holder = MobileSatelliteHolder.source(source.id)
        if let narration = try? await satellites.source(source.id, matching: { $0.hasPrefix("audio.") }) {
            for satellite in [narration] + narration.children(role: "audioChunk") {
                try? await satellites.keep(satellite, for: holder)
            }
        }
    }

    /// What a saved source takes on this phone: its saved text and files, and under generation 2 the
    /// satellites kept for it.
    private func byteCount(sourceID: String) async -> Int64 {
        let saved = await store.byteCount(sourceID: sourceID)
        guard let satellites = await MobileSatellites.current() else { return saved }
        return saved + (await satellites.byteCount(holder: MobileSatelliteHolder.source(sourceID)))
    }

    func remove(sourceID: String) async {
        await store.remove(sourceID: sourceID)
        await MobileSatellites.current()?.release(holder: MobileSatelliteHolder.source(sourceID))
        unpin(sourceID)
        bytesBySourceID[sourceID] = nil
        failureMessages[sourceID] = nil
        await recountSharedBytes()
    }

    func removeAll() async {
        await store.removeAll()
        if let satellites = await MobileSatellites.current() {
            for sourceID in savedSourceIDs { await satellites.release(holder: MobileSatelliteHolder.source(sourceID)) }
        }
        savedSourceIDs = []
        MobileOfflinePins.write([])
        bytesBySourceID = [:]
        failureMessages = [:]
        sharedBytes = 0
    }

    /// Counts again what saved sources keep of one file more than once
    /// (`MobileSatellites.sharedByteCount`), which the total takes off.
    private func recountSharedBytes() async {
        guard !savedSourceIDs.isEmpty, let satellites = await MobileSatellites.current() else {
            sharedBytes = 0
            return
        }
        sharedBytes = await satellites.sharedByteCount(holders: savedSourceIDs.map(MobileSatelliteHolder.source))
    }

    /// Recomputes sizes from disk and drops any pin whose files are gone, so the
    /// Offline screen can never offer a download that is not really there.
    func refreshUsage() async {
        let pinned = savedSourceIDs
        guard !pinned.isEmpty else {
            bytesBySourceID = [:]
            sharedBytes = 0
            return
        }

        var counts = await store.byteCounts(sourceIDs: Array(pinned))
        if let satellites = await MobileSatellites.current() {
            for sourceID in pinned { counts[sourceID, default: 0] += await satellites.byteCount(holder: MobileSatelliteHolder.source(sourceID)) }
        }
        let present = counts.filter { $0.value > 0 }
        bytesBySourceID = present
        if present.count != pinned.count {
            let survivors = Set(present.keys)
            savedSourceIDs = survivors
            MobileOfflinePins.write(survivors)
        }
        await recountSharedBytes()
    }

    // MARK: - Pins

    private func pin(_ sourceID: String) {
        var pins = savedSourceIDs
        pins.insert(sourceID)
        savedSourceIDs = pins
        MobileOfflinePins.write(pins)
    }

    private func unpin(_ sourceID: String) {
        var pins = savedSourceIDs
        pins.remove(sourceID)
        savedSourceIDs = pins
        MobileOfflinePins.write(pins)
    }
}
