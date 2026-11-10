import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif

enum CloudKitSyncDrainPolicy {
    static func shouldAttemptAgain(
        previousRemaining: Int,
        currentRemaining: Int,
        attempt: Int,
        maxAttempts: Int
    ) -> Bool {
        currentRemaining > 0
            && currentRemaining < previousRemaining
            && attempt < maxAttempts - 1
    }
}

/// Storage service backed by local iCloud files and SQLite.
/// Manages sources, embeddings, knowledge graph, and course metadata.
actor StorageService {
    /// Active embedding model key, chosen by the user (OpenAI vs Apple on-device).
    /// Doubles as the per-model key under which vectors are stored, so switching
    /// providers namespaces vectors instead of mixing incompatible vector spaces.
    static var sourceEmbeddingModel: String { EmbeddingSettings.modelID }
    static var sourceEmbeddingDimensions: Int { EmbeddingSettings.dimensions }
    private static let sourceChunkEmbeddingDelimiter = "::chunk::"

    static func sourceChunkEmbeddingPrefix(for sourceId: String) -> String {
        "\(sourceId)\(sourceChunkEmbeddingDelimiter)"
    }

    static func sourceChunkEmbeddingId(sourceId: String, index: Int) -> String {
        "\(sourceChunkEmbeddingPrefix(for: sourceId))\(String(format: "%04d", index))"
    }

    static func sourceId(fromSourceChunkEmbeddingId chunkId: String) -> String? {
        guard let range = chunkId.range(of: sourceChunkEmbeddingDelimiter) else { return nil }
        return String(chunkId[..<range.lowerBound])
    }

    static func sourceChunkIndex(fromSourceChunkEmbeddingId chunkId: String) -> Int? {
        guard let range = chunkId.range(of: sourceChunkEmbeddingDelimiter) else { return nil }
        return Int(chunkId[range.upperBound...])
    }

    let perfLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Performance")
    let migrationLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "StorageMigration")
    let fileManager = FileManager.default
    private let fallbackRoot: URL
    private let fallbackImagesRoot: URL
    let localAppSupportRoot: URL
    let overrideStoreRoot: URL?
    /// Whether this process can sync with CloudKit at all: false under tests
    /// and in a build not entitled to the library container.
    let cloudKitSyncCapable: Bool
    var _knowledgeStore: KnowledgeStore?
    /// Once normal store startup proves incompatible, usage writes stay on the
    /// narrow append path instead of repeating schema/CloudKit startup work for
    /// every billed call.
    var aiUsagePrimaryFailure: String?
    /// Extracted Notebook file context is stable until a workspace file changes.
    /// Keep it on the storage actor so opening or sending a Notebook chat never
    /// repeats PDF parsing/OCR on every turn.
    var notebookMaterialContextCache: [String: (signature: String, markdown: String)] = [:]
    /// When each linked doc's Google text export was last pulled, so opening a
    /// doc twice in a row costs one fetch. Process-local on purpose: a relaunch
    /// is allowed to fetch again.
    var linkedArtifactExportRefreshedAt: [String: Date] = [:]
    /// The Share… running for each notebook (`inNotebookShareLane`), so two at
    /// once never make two teams for it.
    var notebookShareLanes: [String: Task<Void, Never>] = [:]

    #if !os(macOS) && !targetEnvironment(simulator)
    private var requiresICloudUbiquity: Bool { true }
    #else
    private var requiresICloudUbiquity: Bool { false }
    #endif

    // MARK: - iCloud root

    /// Path inside ForeverLM's iCloud Documents folder in ~/Library/Mobile Documents/ (a simulator
    /// shares the host's), read by plain path: see `ForeverLMRuntimeIdentity.iCloudDocumentsFolderName`.
    func simulatorUbiquityPath(relativePath: String) -> URL {
        let hostHome = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
        let path = (hostHome as NSString).appendingPathComponent("Library/Mobile Documents/\(ForeverLMRuntimeIdentity.iCloudDocumentsFolderName)/\(relativePath)")
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // The container-locating resolver that used to live here is gone with the
    // content root it served, and no build is entitled to that container any
    // more: `url(forUbiquityContainerIdentifier:)` is never called. What still
    // sits in the folder is read by path through `ubiquityContentRootPath`.

    func ensureICloudUbiquityAvailable() throws {
        // No longer throws - we allow local fallback when iCloud is unavailable
    }
    
    init() {
        LegacyIdentityAdoption.adoptIfNeeded()
        self.overrideStoreRoot = nil
        self.cloudKitSyncCapable = CloudRuntimeAvailability.hasICloudContainerEntitlement
        self.localAppSupportRoot = ForeverLMRuntimeIdentity.applicationSupportRootURL
            .appendingPathComponent(".appdata", isDirectory: true)
        // Must stay identical to the static `libraryRootPath` fallback — an
        // instance root that disagrees with the static one is how the app ends up
        // writing files where it cannot later find them.
        self.fallbackRoot = URL(fileURLWithPath: Self.localContentRootPath, isDirectory: true)
        self.fallbackImagesRoot = URL(fileURLWithPath: Self.localContentRootPath, isDirectory: true)
            .appendingPathComponent("AI_Images", isDirectory: true)
    }

    /// Test-only initializer that uses a custom store root directory.
    init(storeRoot: URL) {
        self.overrideStoreRoot = storeRoot
        self.cloudKitSyncCapable = false
        self.localAppSupportRoot = storeRoot
        self.fallbackRoot = storeRoot
        self.fallbackImagesRoot = storeRoot.appendingPathComponent("AI_Images", isDirectory: true)
    }

    // MARK: - In-Memory Testing

    /// Test-only initializer that creates an in-memory KnowledgeStore (no disk I/O).
    init(inMemory: Bool) throws {
        self.fallbackRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        self.fallbackImagesRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        self.localAppSupportRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        self.overrideStoreRoot = nil
        self.cloudKitSyncCapable = false
        self._knowledgeStore = try KnowledgeStore(inMemory: true)
    }

}

/// One "Read next" pick on an empty chat: an unread source, and the recently
/// read source it sits closest to.
struct ReadNextSuggestion: Equatable, Sendable {
    let sourceID: String
    let nearestReadSourceID: String
    let score: Float
}

// MARK: - A PDF book is one file (schema 169)

extension StorageService {
    func dueBookFileMerges(limit: Int = 50) throws -> [String] {
        try ensureStoreExists()
        return try knowledgeStore().dueBookFileMerges(limit: limit)
    }

    func bookFileChapters(bookID: String) throws -> [BookFileChapterRow] {
        try ensureStoreExists()
        return try knowledgeStore().bookFileChapters(bookID: bookID)
    }

    func bookChapterPaths(bookID: String) throws -> [String] {
        try ensureStoreExists()
        return try knowledgeStore().bookChapterPaths(bookID: bookID)
    }

    /// Points a merged book's chapters at their pages of its file; their records
    /// then name the book's bytes and their pages (`SourceFilePublisher`).
    func pointBookChapters(bookID: String, bookFilePath: String, pages: [(sourceID: String, pages: Range<Int>)]) throws {
        try ensureStoreExists()
        try knowledgeStore().pointBookChapters(bookID: bookID, bookFilePath: bookFilePath, pages: pages)
        scheduleCloudKitSync(.immediate)
    }

    func failBookFileMerge(bookID: String, message: String) throws {
        try ensureStoreExists()
        try knowledgeStore().failBookFileMerge(bookID: bookID, message: message)
    }

    func dropBookFileMerge(bookID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().dropBookFileMerge(bookID: bookID)
    }
}

// MARK: - A book reads the moment it is added (schema 171)

extension StorageService {
    func enqueueBookImportFinish(bookID: String, bookFilePath: String, wholeBookSourceID: String?, kind: String?) throws {
        try ensureStoreExists()
        try knowledgeStore().enqueueBookImportFinish(
            bookID: bookID,
            bookFilePath: bookFilePath,
            wholeBookSourceID: wholeBookSourceID,
            kind: kind
        )
    }

    func dueBookImportFinishes(limit: Int = 20) throws -> [BookImportFinishJob] {
        try ensureStoreExists()
        return try knowledgeStore().dueBookImportFinishes(limit: limit)
    }

    func failBookImportFinish(bookID: String, message: String) throws {
        try ensureStoreExists()
        try knowledgeStore().failBookImportFinish(bookID: bookID, message: message)
    }

    func dropBookImportFinish(bookID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().dropBookImportFinish(bookID: bookID)
    }
}

// MARK: - Which book a file is (schema 173)

extension StorageService {
    func recordBookFileDigest(_ sha256: String, bookID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().recordBookFileDigest(sha256, bookID: bookID)
    }

    func bookID(forFileDigest sha256: String) throws -> String? {
        try ensureStoreExists()
        return try knowledgeStore().bookID(forFileDigest: sha256)
    }

    func dropBookFileDigests(bookID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().dropBookFileDigests(bookID: bookID)
    }

    func bookFolderNamesInUse() throws -> Set<String> {
        try ensureStoreExists()
        return try knowledgeStore().bookFolderNamesInUse()
    }
}
