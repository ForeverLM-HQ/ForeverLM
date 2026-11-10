// MCPDataStore: direct SQLite and JSON access, with the store gate it runs under.
import Foundation
import ImageIO
import OSLog
import PDFKit
import SQLite3

/// Readers-writer gate for every MCP operation against the one cached SQLite
/// connection. `KnowledgeStore` uses multi-statement BEGIN/COMMIT boundaries;
/// FULLMUTEX protects individual SQLite calls but does not stop another Task's
/// read from observing uncommitted rows between those calls. Only a writer can
/// leave such rows behind, so readers share the connection and a writer holds
/// it alone. Until 2026-09-18 every tool held it alone, and a `list_teams`
/// waited half a minute behind a `publish_site` that spent the time uploading.
///
/// Admission is FIFO. A writer that arrives while readers hold the gate waits
/// for them; readers that arrive behind that writer wait for it. A stream of
/// reads therefore cannot starve a write, and a later read cannot jump a write
/// that was already queued.
private actor MCPKnowledgeStoreOperationGate {
    private var sharedHolders = 0
    private var exclusiveHeld = false
    private var waiters: [(mode: MCPStoreOperationMode, continuation: CheckedContinuation<Void, Never>)] = []

    func acquire(_ mode: MCPStoreOperationMode) async {
        if waiters.isEmpty, canAdmit(mode) {
            admit(mode)
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append((mode, continuation))
        }
    }

    func release() {
        if exclusiveHeld {
            exclusiveHeld = false
        } else {
            sharedHolders = max(0, sharedHolders - 1)
        }
        while let next = waiters.first, canAdmit(next.mode) {
            waiters.removeFirst()
            admit(next.mode)
            next.continuation.resume()
        }
    }

    private func canAdmit(_ mode: MCPStoreOperationMode) -> Bool {
        switch mode {
        case .shared: return !exclusiveHeld
        case .exclusive: return !exclusiveHeld && sharedHolders == 0
        }
    }

    private func admit(_ mode: MCPStoreOperationMode) {
        switch mode {
        case .shared: sharedHolders += 1
        case .exclusive: exclusiveHeld = true
        }
    }
}

// MARK: - Data Store (Direct SQLite + JSON access)

/// Reads/writes knowledge.db and source files directly.
final class MCPDataStore {
    let logger = Logger(subsystem: "ForeverLM", category: "MCPDataStore")
    typealias SourceEmbeddingProvider = @Sendable (String) async throws -> [Float]

    /// Apple epoch offset (2001-01-01 vs 1970-01-01)
    let appleEpochOffset: TimeInterval = 978307200

    /// Optional override for testing — when set, all DB operations use this path instead of iCloud.
    let dbPathOverride: String?
    let sourceEmbeddingProvider: SourceEmbeddingProvider?
    /// The writer `generate_explainer` runs when its caller hands in none; nil
    /// is the live model route. Tests hand in one that answers when told to.
    let explainerBackend: ExplainerModelBackend?
    /// Where the card tools read and write the `cards.state.<deckID>` rows:
    /// the standard defaults, which sync; a test hands in a suite of its own.
    let cardStateDefaults: UserDefaults

    /// One long-lived KnowledgeStore, reused across tool calls. Opening a fresh
    /// KnowledgeStore per call re-ran `createSchema` (DDL) and left connections with
    /// no busy_timeout, so concurrent MCP calls could churn connections and hit
    /// "database is locked". Guarded by `storeLock` because tool calls run on
    /// concurrent per-request Tasks.
    private let storeLock = NSLock()
    private var cachedStore: KnowledgeStore?
    let notebookFileStorage: StorageService
    private let operationGate = MCPKnowledgeStoreOperationGate()
    /// Built on first use and shared by every picture tool call, so a figure
    /// two calls ask about at once is indexed and explained once. Guarded by
    /// `storeLock` for the same reason `cachedStore` is.
    private var cachedPaperFigureIndexer: PaperFigureIndexer?
    var paperFigureIndexer: PaperFigureIndexer {
        storeLock.lock()
        defer { storeLock.unlock() }
        if let cachedPaperFigureIndexer { return cachedPaperFigureIndexer }
        let indexer = PaperFigureIndexer(storage: notebookFileStorage, aiService: AIService())
        cachedPaperFigureIndexer = indexer
        return indexer
    }

    // Tuning for Learning Companion source discovery (used by MCPTools+Companion.swift;
    // stored properties must live in the primary class declaration).
    //
    // The library's own hybrid search (`SourceSearchEngine`) lists the candidates and a
    // model keeps the ones that fit. No similarity gate can do the keeping: the
    // contextual embedding is anisotropic, so a topic's twelve nearest chunks scored
    // 0.922–0.929 whether they came from a paper on the topic or one on psychedelics and
    // terahertz waves (product owner, 2026-10-11: "it finds weird sources that are barely
    // related").
    let companionDiscoveryPool = 24
    /// Most of a goal's own sources that steer its discovery (`companionDiscoverySeeds`).
    let companionDiscoverySeedLimit = 6
    let companionDiscoveryLimit = 12
    /// Which of a discovery pass's candidates fit the Notebook or Goal, by
    /// candidate id. Nil is the live model (`liveLibraryFitJudge`); a test
    /// hands in its own verdict.
    typealias LibraryFitJudge = @Sendable (JournalMatchingNotebook, [JournalMatchingCandidate]) async throws -> Set<String>
    let libraryFitJudge: LibraryFitJudge?

    init(
        dbPath: String? = nil,
        sourceEmbeddingProvider: SourceEmbeddingProvider? = nil,
        explainerBackend: ExplainerModelBackend? = nil,
        libraryFitJudge: LibraryFitJudge? = nil,
        cardStateDefaults: UserDefaults = .standard
    ) {
        self.dbPathOverride = dbPath
        self.sourceEmbeddingProvider = sourceEmbeddingProvider
        self.explainerBackend = explainerBackend
        self.libraryFitJudge = libraryFitJudge
        self.cardStateDefaults = cardStateDefaults
        if let dbPath {
            self.notebookFileStorage = StorageService(storeRoot: URL(fileURLWithPath: dbPath).deletingLastPathComponent())
        } else {
            self.notebookFileStorage = StorageService()
        }
    }

    /// ForeverLM's iCloud Documents folder, read by plain path
    /// (`ForeverLMRuntimeIdentity.iCloudDocumentsFolderName`).
    var icloudContainer: URL {
        let home: URL
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: dir))
        } else {
            home = URL(fileURLWithPath: NSHomeDirectory())
        }
        return home
            .appendingPathComponent("Library/Mobile Documents/\(ForeverLMRuntimeIdentity.iCloudDocumentsFolderName)")
    }

    var libraryDir: URL {
        icloudContainer.appendingPathComponent(
            "Documents/\(ForeverLMRuntimeIdentity.productFolderName)"
        )
    }

    var localAppDataDir: URL {
        ForeverLMRuntimeIdentity.applicationSupportRootURL
            .appendingPathComponent(".appdata", isDirectory: true)
    }

    var knowledgeDBPath: String { dbPathOverride ?? localAppDataDir.appendingPathComponent("knowledge.db").path }

    var sourceContentRoot: URL {
        if dbPathOverride != nil {
            return URL(fileURLWithPath: knowledgeDBPath).deletingLastPathComponent()
        }
        return libraryDir
    }

    /// Relativize a path under `sourceContentRoot`. In production the content root
    /// is the ForeverLM root, so this matches `StorageService.relativeSourcePath`;
    /// with an overridden DB path (tests) the content root lives elsewhere and
    /// `relativeSourcePath` would return the absolute path unchanged.
    func relativeSourceContentPath(_ url: URL) -> String? {
        let root = sourceContentRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    func knowledgeStore() throws -> KnowledgeStore {
        storeLock.lock()
        defer { storeLock.unlock() }
        if let cachedStore {
            return cachedStore
        }
        let store = try KnowledgeStore(storeDirectory: URL(fileURLWithPath: knowledgeDBPath).deletingLastPathComponent())
        cachedStore = store
        return store
    }

    /// Every MCP tool acquires this before execution and releases it only after the
    /// whole tool returns. Keep the gate here beside ownership of the shared
    /// connection so future dispatch surfaces cannot accidentally grow a second,
    /// uncoordinated lock. The default is the exclusive hold, which is always
    /// safe; `MCPToolRegistry.storeGateMode(for:)` decides when a tool may share.
    func acquireToolOperation(_ mode: MCPStoreOperationMode = .exclusive) async {
        await operationGate.acquire(mode)
    }

    func releaseToolOperation() async {
        await operationGate.release()
    }

    /// Runs `body` holding the store gate. A tool in
    /// `MCPToolRegistry.selfGatedToolNames` wraps each stretch that touches the
    /// cached connection in this, and nothing else, so its model calls and
    /// downloads between the stretches hold nothing. Inside a hold that
    /// already covers `mode` (the dispatcher's for a gated tool, or an
    /// enclosing stretch) the body runs under that hold. A write asked for
    /// inside a shared hold is refused: the reader would wait on itself.
    func withStoreGate<T>(
        _ mode: MCPStoreOperationMode,
        _ body: () async throws -> T
    ) async throws -> T {
        if let held = MCPStoreGateHold.current, held.isHeld {
            guard held.mode == .exclusive || mode == .shared else {
                throw MCPError.database("A write to the library was attempted inside a call that holds it only to read.")
            }
            return try await body()
        }
        await operationGate.acquire(mode)
        let hold = MCPStoreGateHold(mode)
        do {
            let value = try await MCPStoreGateHold.$current.withValue(hold, operation: body)
            hold.end()
            await operationGate.release()
            return value
        } catch {
            hold.end()
            await operationGate.release()
            throw error
        }
    }

    /// Saves what a call learned about a source during a long wait (streaming
    /// a video's frames, a transcription, a model reading its slides), holding
    /// the store gate alone for the write only. The row is read again inside
    /// the gate and `change` edits that copy, so a field another call saved
    /// during the wait is kept rather than overwritten by the copy read before
    /// it, and a source deleted meanwhile is not written back. `change`
    /// answers false when the fresh copy needs nothing saved.
    @discardableResult
    func saveSourceAfterWait(
        _ sourceID: String,
        _ change: (inout StudioArticle) throws -> Bool
    ) async throws -> StudioArticle {
        try await withStoreGate(.exclusive) {
            let store = try knowledgeStore()
            guard var article = try store.loadSourceForSync(sourceID) else {
                throw MCPError.notFound("Source \(sourceID) was deleted while this call ran, so nothing was saved to it.")
            }
            if try change(&article) {
                try store.saveSource(article)
            }
            return article
        }
    }

    // MARK: - Client-Supplied Path Validation

    /// Largest file an MCP client may hand to an attach/import tool. Reads load the
    /// whole file into memory, so this bounds a single tool call's footprint.
    static let maxClientProvidedFileBytes = 100 * 1024 * 1024

    /// Most .json files one import_meeting_transcript_files call will process.
    static let maxClientProvidedFolderFiles = 500

    /// Roots an MCP client is allowed to read from, fully symlink-resolved so they
    /// compare cleanly against resolved candidate paths: the ForeverLM content root
    /// (plus the test-override content root when set), the app-data dir, the temp
    /// dir (internal tools stage files there), and the user's standard content
    /// folders where files to import naturally live.
    func allowedClientPathRoots() -> [String] {
        var roots: [URL] = [
            sourceContentRoot,
            libraryDir,
            localAppDataDir,
            FileManager.default.temporaryDirectory,
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        ]
        let home = Self.userHomeDirectory()
        for folder in ["Desktop", "Documents", "Downloads"] {
            roots.append(home.appendingPathComponent(folder, isDirectory: true))
        }
        return roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
    }

    /// The account's real home, not a sandbox container's.
    static func userHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// Where Claude Code keeps its session files: one directory per working
    /// directory, one `<session id>.jsonl` per session. Read by
    /// `import_review_chat`'s `transcript_file` and by nothing else.
    lazy var claudeCodeProjectsRoot: URL = Self.userHomeDirectory().appendingPathComponent(".claude/projects", isDirectory: true)

    /// Vet a path supplied by an MCP client before reading it.
    ///
    /// `attach_*` / import tools would otherwise read any path the caller names, so
    /// an external assistant could exfiltrate SSH keys, keychains, or system config —
    /// especially in the unsandboxed direct-download build. Only paths inside
    /// `allowedClientPathRoots()` are accepted, symlinks are resolved BEFORE the
    /// check so a link inside an allowed folder can't smuggle a read from elsewhere,
    /// known credential locations are refused outright as defense in depth, and
    /// oversized files are rejected. Returns the fully resolved URL — callers must
    /// perform the actual read through it, never through the raw input.
    @discardableResult
    /// An integer argument as JSON delivers it — an Int, or a Double when the
    /// number was written with a fraction or an exponent. A value Int cannot
    /// hold is refused: until 2026-09-19 `Int(1e30)` trapped in the handler and
    /// one authenticated request took the app, and its tunnel, down.
    static func intArgument(_ arguments: [String: Any], _ key: String) throws -> Int? {
        try intValue(arguments[key], key)
    }

    /// The one way an MCP argument value becomes an `Int`. JSON numbers arrive
    /// as `Double`, and `Int(double)` traps on NaN, infinity or a value `Int`
    /// cannot hold: `1e30` once took the app and its tunnel down (2026-09-19).
    /// Every tool's integer read, nested values included, comes through here.
    static func intValue(_ value: Any?, _ key: String) throws -> Int? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        if let int = value as? Int { return int }
        if let double = value as? Double {
            guard double.isFinite, let exact = Int(exactly: double.rounded(.towardZero)),
                  double.magnitude < 9_007_199_254_740_992 else {
                throw MCPError.invalidInput("\(key) must be a whole number Int can hold; got \(double).")
            }
            return exact
        }
        if let text = value as? String, let int = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return int }
        throw MCPError.invalidInput("\(key) must be a whole number.")
    }

    func validateClientProvidedPath(_ rawPath: String, additionalRoots: [String] = []) throws -> URL {
        var candidate = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            throw MCPError.invalidInput("file_path is required.")
        }
        if candidate.hasPrefix("file://") { candidate = String(candidate.dropFirst(7)) }
        if candidate.hasPrefix("~") { candidate = (candidate as NSString).expandingTildeInPath }

        // Reject traversal both in the raw input and after normalization.
        let standardized = URL(fileURLWithPath: candidate).standardizedFileURL
        if candidate.contains("../") || candidate.hasSuffix("/..") || candidate == ".."
            || standardized.pathComponents.contains("..") {
            throw MCPError.invalidInput("Refusing path with parent-directory traversal: \(rawPath)")
        }

        // Resolve symlinks so allowlist and denylist checks see the real target.
        let resolved = standardized.resolvingSymlinksInPath()
        let resolvedPath = resolved.path

        let roots = allowedClientPathRoots() + additionalRoots.map {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
        }
        guard roots.contains(where: { resolvedPath == $0 || resolvedPath.hasPrefix($0 + "/") }) else {
            let extra = additionalRoots.isEmpty ? "" : ", or \(additionalRoots.joined(separator: ", "))"
            throw MCPError.invalidInput("file_path must point inside the ForeverLM library or your Desktop, Documents, or Downloads folder\(extra): \(rawPath)")
        }

        // Defense in depth: never serve known credential locations, even if a
        // future root change or a mount under an allowed folder exposes one.
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let sensitivePrefixes = [
            "/etc", "/private/etc", "/var/db", "/var/root", "/System", "/Library/Keychains",
            home + "/.ssh", home + "/.aws", home + "/.gnupg", home + "/.config",
            home + "/Library/Keychains", home + "/Library/Cookies",
        ]
        for prefix in sensitivePrefixes where resolvedPath == prefix || resolvedPath.hasPrefix(prefix + "/") {
            throw MCPError.invalidInput("Refusing to read from a protected location: \(rawPath)")
        }

        if let size = try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > Self.maxClientProvidedFileBytes {
            throw MCPError.invalidInput("File is too large to import (\(size / (1024 * 1024)) MB; limit \(Self.maxClientProvidedFileBytes / (1024 * 1024)) MB): \(rawPath)")
        }
        return resolved
    }

    // MARK: - Local File Content Extraction

    /// Extract text from a local PDF or text file on disk: for a book chapter,
    /// `pages` of its book's file. Resolves relative paths against the app's
    /// Documents directory.
    static func extractTextFromLocalFile(_ path: String, pages: Range<Int>? = nil) -> String? {
        guard let resolved = SourceService.resolveLocalFileURL(path) else { return nil }
        let fullPath = resolved.path
        // A file on disk, or a chapter of an EPUB book kept as one file: its text, not its markup.
        let lower = fullPath.lowercased()
        if lower.hasSuffix(".xhtml") || lower.hasSuffix(".html") || lower.hasSuffix(".htm") {
            guard let raw = EPUBBookFiles.text(atPath: fullPath) else { return nil }
            let text = EPUBParser.stripHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        guard FileManager.default.fileExists(atPath: fullPath) else { return nil }

        if fullPath.lowercased().hasSuffix(".pdf") {
            guard let doc = PDFDocument(url: resolved) else { return nil }
            let range = pages ?? 0..<doc.pageCount
            guard range.upperBound <= doc.pageCount else { return nil }
            let text = PDFTextExtractor.textWithFigureReferences(from: doc, pages: range)
            return text.isEmpty ? nil : text
        }

        return try? String(contentsOfFile: fullPath, encoding: .utf8)
    }

    /// The pages `book_page_start` and `book_page_count` name in a
    /// `source_projection` row read through `query`: a book chapter's pages of
    /// its book's file.
    static func bookPages(_ row: [String: Any]) -> Range<Int>? {
        guard let start = row["book_page_start"] as? Int, let count = row["book_page_count"] as? Int,
              start >= 0, count > 0 else { return nil }
        return start..<(start + count)
    }

    // MARK: - SQLite Helper

    func withDB<T>(_ block: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(knowledgeDBPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw MCPError.database("Failed to open knowledge.db: \(msg)")
        }
        defer { sqlite3_close(db) }
        // Wait up to 5s for a competing writer instead of failing immediately with
        // "database is locked" when another connection (or CloudKit sync) holds it.
        sqlite3_busy_timeout(db, 5000)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        // As on KnowledgeStore's connection, so a delete made here would cascade
        // exactly as one made there (docs/cloudkit-schema-design.md §5.7).
        sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
        return try block(db)
    }

    func query(_ db: OpaquePointer, _ sql: String, params: [Any] = []) throws -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MCPError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case let s as String: SQLiteText.bind(stmt, idx, s)
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as Int64: sqlite3_bind_int64(stmt, idx, n)
            case let n as Int32: sqlite3_bind_int64(stmt, idx, Int64(n))
            default: sqlite3_bind_null(stmt, idx)
            }
        }

        var rows: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            let colCount = sqlite3_column_count(stmt)
            for c in 0..<colCount {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_TEXT: row[name] = SQLiteText.column(stmt, c)
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, c)
                case SQLITE_NULL: break
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }

    func execute(_ db: OpaquePointer, _ sql: String, params: [Any] = []) throws {
        _ = try query(db, sql, params: params)
    }

    func appleToISO(_ appleTimestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: appleTimestamp + appleEpochOffset)
        let fmt = ISO8601DateFormatter()
        return fmt.string(from: date)
    }

    func appleDate(_ appleTimestamp: Double) -> Date {
        Date(timeIntervalSince1970: appleTimestamp + appleEpochOffset)
    }

    func isoDateOnly(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return appleToISO(date.timeIntervalSince1970 - appleEpochOffset)
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    func jsonString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func decodeStringArray(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String] ?? []
    }

    // MARK: - Server Status

    func getMCPStatus(toolCount: Int) async throws -> String {
        var payload: [String: Any] = [
            "status": "active",
            "server": "ForeverLM MCP",
            "protocol": "MCP Streamable HTTP",
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "tool_count": toolCount,
            "message": "ForeverLM MCP is active and responding to tool calls.",
        ]

        // Which iCloud account this Mac's library syncs with, so a web page
        // reading another account's library is never relayed here
        // (MCPTools+ICloudAccount.swift).
        let syncs = CloudRuntimeAvailability.isEnabled
        let userRecordName = syncs ? await CloudKitAccountIdentity.shared.currentRecordName() : nil
        payload["icloud_account"] = Self.iCloudAccountStatus(
            syncs: syncs,
            userRecordName: userRecordName,
            environment: CloudRuntimeAvailability.containerEnvironment.rawValue
        )
        // Which Mac answered: two Macs on one Apple Account share the iCloud
        // account above, and the relay serves whichever holds the tunnel
        // (MCPTools+ICloudAccount.swift).
        payload["answered_by"] = await Self.answeringMac()
        if let note = Self.screenRecordNarrowedNote { payload["narrowed"] = note }

        // Search-index coverage, so the "every source is searchable" invariant can be
        // checked rather than assumed. `pending` counts active sources whose text has
        // changed since it was indexed, or that were never indexed at all; it drains in
        // the background and should settle at 0.
        // In a shared stretch of its own (`selfGatedToolNames`), so the wait
        // on CloudKit above never holds the gate.
        if let coverage = try? await withStoreGate(.shared, {
            try knowledgeStore().indexCoverage(model: StorageService.sourceEmbeddingModel)
        }) {
            payload["search_index"] = [
                "embedding_model": StorageService.sourceEmbeddingModel,
                "active_sources": coverage.activeSources,
                "indexed_sources": coverage.indexedSources,
                "pending_sources": max(0, coverage.activeSources - coverage.indexedSources),
                "full_text_rows": coverage.ftsRows,
                "chunk_vectors": coverage.chunkVectors,
            ]
        }

        return try jsonString(payload)
    }

    /// iCloud sync health: the generation-2 coordinator's status (`generationTwoSyncStatus`).
    func getSyncStatus() async throws -> String {
        try await generationTwoSyncStatus()
    }

}
