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

    private let perfLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Performance")
    private let migrationLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "StorageMigration")
    private let fileManager = FileManager.default
    private let fallbackRoot: URL
    private let fallbackImagesRoot: URL
    private let localAppSupportRoot: URL
    private let overrideStoreRoot: URL?
    /// Whether this process can sync with CloudKit at all: false under tests
    /// and in a build not entitled to the library container.
    let cloudKitSyncCapable: Bool
    private var _knowledgeStore: KnowledgeStore?
    /// The generation a test-only store runs; nil for the app's own store, which takes the build's.
    private var overrideSyncGeneration: SyncGeneration?
    /// Once normal store startup proves incompatible, usage writes stay on the
    /// narrow append path instead of repeating schema/CloudKit startup work for
    /// every billed call.
    private var aiUsagePrimaryFailure: String?
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
    private func simulatorUbiquityPath(relativePath: String) -> URL {
        let hostHome = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
        let path = (hostHome as NSString).appendingPathComponent("Library/Mobile Documents/\(ForeverLMRuntimeIdentity.iCloudDocumentsFolderName)/\(relativePath)")
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // The container-locating resolver that used to live here is gone with the
    // content root it served, and no build is entitled to that container any
    // more: `url(forUbiquityContainerIdentifier:)` is never called. What still
    // sits in the folder is read by path through `ubiquityContentRootPath`.

    private func ensureICloudUbiquityAvailable() throws {
        // No longer throws - we allow local fallback when iCloud is unavailable
    }
    
    init() {
        LegacyIdentityAdoption.adoptIfNeeded()
        _ = LegacyIdentityAdoption.adoptRetiredMethodPreferenceKeysIfNeeded()
        _ = LegacyIdentityAdoption.adoptRetiredNotebookPreferenceKeysIfNeeded()
        ReadingListChooserAdoption.adoptIfNeeded()
        // After the rename adopter, never before: on a Mac still carrying the
        // retired FeynmanLM folder, the cache to adopt only reaches its
        // per-profile path once that move has happened.
        SharedDerivedCacheAdoption.adoptOnce()
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

    /// Test-only initializer that uses a custom store root directory. `syncGeneration` is the
    /// generation the store under it runs: a suite of generation 1's behaviour (teams as
    /// zones of the old container, copies that follow no space) pins `.one`, since the Debug
    /// configuration runs generation 2.
    init(storeRoot: URL, syncGeneration: SyncGeneration = ForeverLMRuntimeIdentity.syncGeneration) {
        self.overrideStoreRoot = storeRoot
        self.overrideSyncGeneration = syncGeneration
        self.cloudKitSyncCapable = false
        self.localAppSupportRoot = storeRoot
        self.fallbackRoot = storeRoot
        self.fallbackImagesRoot = storeRoot.appendingPathComponent("AI_Images", isDirectory: true)
    }

    // MARK: - Paths

    private var storeRoot: URL {
        overrideStoreRoot ?? localAppSupportRoot
    }

    /// The one directory this install stores content in. It does not change at
    /// runtime, and it is not in iCloud — see `libraryRootPath` for why.
    ///
    /// It used to depend on the live container lookup, and that was its own bug
    /// class: any momentary nil from `url(forUbiquityContainerIdentifier:)`
    /// silently redirected writes to `fallbackRoot`, and the failure was cached
    /// for only a second, so a brief hiccup mid-download dropped that one file
    /// into a different root — no error, no trace, and a knowledge base split
    /// across two locations from then on. A single unconditional local path
    /// retires the whole question.
    private var contentRoot: URL {
        if let overrideStoreRoot { return overrideStoreRoot }
        #if targetEnvironment(simulator)
        return simulatorUbiquityPath(relativePath: "Documents/ForeverLM")
        #else
        // Local, always, and identical to the static `libraryRootPath` — an
        // instance root that disagrees with the static one is how the app ends up
        // writing files where it cannot later find them. No ubiquity lookup: the
        // container is no longer a write target, so there is no longer a
        // momentary-nil hazard to guard against here.
        return URL(fileURLWithPath: Self.libraryRootPath, isDirectory: true)
        #endif
    }

    private var aiImagesDirURL: URL {
        if let overrideStoreRoot { return overrideStoreRoot.appendingPathComponent("AI_Images", isDirectory: true) }
        return contentRoot.appendingPathComponent("AI_Images", isDirectory: true)
    }

    var audioDirURL: URL {
        if let overrideStoreRoot { return overrideStoreRoot.appendingPathComponent("Audio", isDirectory: true) }
        return contentRoot.appendingPathComponent("Audio", isDirectory: true)
    }

    /// The working notes (`WorkingNoteStore`) of this library: one JSON file in
    /// the same directory as the knowledge database, shared by every caller in
    /// the process.
    func workingNotes() -> WorkingNoteStore {
        WorkingNoteStore.shared(directory: storeRoot)
    }

    /// The ForeverLM root directory (parent of .appdata, Books, Papers, etc.).
    /// Exposed so other components don't need to construct iCloud paths independently.
    var libraryRootURL: URL {
        contentRoot
    }

    /// Static helper for non-actor contexts that need the ForeverLM root path.
    /// This must stay deterministic and non-blocking because it is used from UI
    /// rendering and source identity hot paths.
    /// Home directory to resolve content roots against — the simulator resolves
    /// against its host so it shares the Mac's knowledge base.
    ///
    /// Resolved once per process, like every root below it. `ProcessInfo
    /// .environment` copies the whole environment on each read and the search
    /// path lookup goes through `FileManager`, and both were being paid per
    /// call from a SwiftUI row body: on 2026-09-07 a chat transcript's web
    /// sources footer resolved every library source's URL for each citation
    /// on every rebuild of the row while the learner scrolled, and the 1.05 s
    /// stall sample spent its time here. Neither input changes while the
    /// process runs.
    private static let contentHomeDirectory: String = {
        if let simHost = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"], !simHost.isEmpty {
            return simHost
        }
        return NSHomeDirectory()
    }()

    /// `~/Library/Application Support`, resolved once; see `contentHomeDirectory`.
    private static let applicationSupportPath: String = {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? (contentHomeDirectory as NSString).appendingPathComponent("Library/Application Support")
    }()

    /// Content root used when iCloud is unavailable. Deliberately inside
    /// Application Support, beside `knowledge.db`.
    ///
    /// This used to be `~/Documents/ForeverLM`, which is not local at all: with
    /// "Desktop & Documents Folders" syncing enabled — the macOS default —
    /// `~/Documents` IS iCloud Drive, so the fallback silently became a second
    /// synced root, user-visible and editable in Finder, alongside the app's
    /// private container. That is the highest-conflict place the KB could live,
    /// and it is where iCloud forked it into `ForeverLM 2`. `knowledge.db` came
    /// through the same event untouched precisely because Application Support is
    /// never synced.
    ///
    /// Content written here does not sync. That is the point: an iCloud outage
    /// should degrade to local storage, not to a second cloud root that can fork
    /// against the first.
    static let localContentRootPath: String = (applicationSupportPath as NSString).appendingPathComponent(
        "\(ForeverLMRuntimeIdentity.productFolderName)/Content"
    )

    /// iCloud Drive, document scope. Ordinary content does not live here — but
    /// understanding documents deliberately do, because they are the one artifact
    /// the learner is invited to open in their own editor. That needs a folder
    /// visible in Finder and present on every Mac without the app running, which
    /// Application Support is not and the ubiquity container is not either.
    static let cloudDocsContentRootPath: String = (contentHomeDirectory as NSString)
        .appendingPathComponent(
            "Library/Mobile Documents/com~apple~CloudDocs/Documents/\(ForeverLMRuntimeIdentity.productFolderName)"
        )

    /// The iCloud Documents folder's document-scope root. This is where content
    /// used to live and where most of it still sits, so it stays resolvable — but
    /// the app no longer writes documents here. See `libraryRootPath`. A fixed
    /// folder name read by plain path, never a container the app resolves:
    /// `ForeverLMRuntimeIdentity.iCloudDocumentsFolderName` says why.
    static let ubiquityContentRootPath: String = (contentHomeDirectory as NSString)
        .appendingPathComponent(
            "Library/Mobile Documents/\(ForeverLMRuntimeIdentity.iCloudDocumentsFolderName)/Documents/\(ForeverLMRuntimeIdentity.productFolderName)"
        )

    /// Where this app writes content: a local directory that iCloud never
    /// touches.
    ///
    /// This used to be the ubiquity container's `Documents/ForeverLM`, and that
    /// is what kept forking the library into `ForeverLM 2`, `ForeverLM 3`, …
    /// Two mechanisms combined. CloudDocs resolves a *directory* conflict in
    /// document scope by bouncing one side to a numbered name (TN2336), and it
    /// only needs a directory to be removed-or-late on one Mac while the other
    /// writes into it: iCloud resurrects the folder for the incoming files, then
    /// applies the first Mac's re-creation as a second folder at the same path.
    /// Meanwhile every writer here called `createDirectory(…, withIntermediate‐
    /// Directories: true)` before its first write, so a root that iCloud had not
    /// yet materialized — after an OS upgrade, an eviction, a fresh login — was
    /// instantly reborn locally with a fresh identity. The app was the other
    /// half of the fork.
    ///
    /// Documents do not need CloudDocs to reach another device: the source
    /// record already carries the original as `sourcePDFAsset`, and CloudKit is
    /// the transport iOS has always used. So content is local, CloudKit moves
    /// the bytes, and a directory conflict has nowhere to happen.
    ///
    /// Historical roots — container, iCloud Drive, `~/Documents`, and numbered
    /// forks — remain searchable only while the detached consolidator copies,
    /// verifies, and removes their files. New writes and migrated bytes land here.
    static let libraryRootPath: String = localContentRootPath

    /// Every content root this app writes to, or ever has, current first. A
    /// stored relative path is tried against each, which is what lets a KB
    /// survive moving between the private container, iCloud Drive, and local
    /// storage — including files this Mac wrote under a since-changed
    /// configuration. Resolving by root beats rewriting path segments: a root
    /// that is added here is searched everywhere, with nothing to keep in sync.
    ///
    /// Only the first entry is written to. Everything below it is a temporary
    /// compatibility input for the resumable legacy-content consolidator, so a
    /// source stays readable until its verified move finishes.
    static let knownContentRoots: [String] = {
        let home = contentHomeDirectory
        let appSupport = applicationSupportPath
        // The retired FeynmanLM container's roots are gone: the consolidator
        // drained them, `didConsolidateLegacyContent` is set, and the container
        // holds an empty `Documents` with no `ForeverLM` or `FeynmanLM` folder
        // under it. Searching them is a stat that can only ever miss.
        //
        // The CloudDocs entries stay. Those are not tied to the retired
        // container — they are where an iCloud Drive fork or a manual move can
        // still put a file, under either product name, on a Mac this migration
        // has not run on.
        //
        // `~/Documents` itself is deliberately absent. With "Desktop & Documents
        // Folders" syncing on — the macOS default — it is the same folder as
        // `com~apple~CloudDocs/Documents`, which is already listed; with it off
        // it is a plain local folder that iCloud never forked. Either way the
        // entry could only find what the CloudDocs spelling already finds, and
        // unlike that spelling every path lookup under `~/Documents` is gated by
        // TCC, so the first miss raised the "access files in your Documents
        // folder" prompt on every launch of a differently signed build.
        if ForeverLMRuntimeIdentity.isDevelopment {
            return [
                libraryRootPath,
                localContentRootPath,
                ubiquityContentRootPath,
                cloudDocsContentRootPath,
            ]
        }

        let retired = LegacyIdentityAdoption.retiredProductFolderName
        return [
            libraryRootPath,
            localContentRootPath,
            ubiquityContentRootPath,
            (appSupport as NSString).appendingPathComponent("\(retired)/Content"),
            (home as NSString).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents/ForeverLM"),
            (home as NSString).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents/\(retired)"),
        ]
    }()

    /// The two shapes `normalizedRelativeSourcePath` recognizes, compiled once.
    /// `String.range(of:options: .regularExpression)` builds a fresh
    /// `NSRegularExpression` on every call, which is what put ICU's compiler
    /// in the transcript's scroll path (see `contentHomeDirectory`).
    private static let libraryRootFolderNamePattern: NSRegularExpression = {
        let retired = NSRegularExpression.escapedPattern(for: LegacyIdentityAdoption.retiredProductFolderName)
        return try! NSRegularExpression(pattern: "^(ForeverLM First Run|ForeverLM Dev|ForeverLM|\(retired))(?: [0-9]+)?$")
    }()
    private static let strayConflictNumberPattern = try! NSRegularExpression(pattern: #"^ [0-9]+$"#)

    private static func wholeMatch(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func isLibraryRootFolderName(_ name: String) -> Bool {
        // This is lexical normalization only: recognizing a stored path does not
        // make that root readable. Dev must understand production/retired paths
        // copied into its seed database while `knownContentRoots` remains strictly
        // Dev-only so it can never open the production files themselves.
        return wholeMatch(libraryRootFolderNamePattern, name)
    }

    private static func normalizedRelativeSourcePath(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let first = components.first else { return path }

        if isLibraryRootFolderName(first), components.count > 1 {
            return components.dropFirst().joined(separator: "/")
        }

        // A previous prefix-based normalizer could turn
        // ".../Documents/ForeverLM 4/Papers/X.pdf" into " 4/Papers/X.pdf".
        if wholeMatch(strayConflictNumberPattern, first),
           components.count > 1 {
            return components.dropFirst().joined(separator: "/")
        }

        return path
    }

    /// Standardize an absolute path without asking Foundation to infer whether
    /// any component is a file or directory. `URL(fileURLWithPath:)` performs an
    /// `lstat` for that inference; an iCloud placeholder can make that call block
    /// while CloudDocs downloads metadata. Source identity normalization runs in
    /// UI hot paths, so it must remain a purely lexical operation.
    private static func lexicallyStandardizedAbsolutePath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }

        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty {
                    components.removeLast()
                }
            default:
                components.append(component)
            }
        }

        guard !components.isEmpty else { return "/" }
        return "/" + components.joined(separator: "/")
    }

    private static func relativeContentPath(fromAbsolutePath path: String) -> String? {
        let absolutePath = lexicallyStandardizedAbsolutePath(path)

        if let relative = relativeContentPathByComponents(absolutePath) {
            return relative
        }

        // Every root, not just the current one: a file under the local content
        // root has to relativize even while iCloud is available, or the same file
        // would be stored as an absolute path on one launch and a relative path
        // on the next.
        for root in knownContentRoots {
            let rootPath = lexicallyStandardizedAbsolutePath(root)
            if absolutePath.hasPrefix(rootPath + "/") {
                return String(absolutePath.dropFirst(rootPath.count + 1))
            }
        }

        // The same roots once more, matched without their `/Users/<name>` prefix.
        //
        // `normalizedSourceKey` has always promised that a path from another Mac
        // reduces to the same relative key as a local one, and for every root
        // under `Documents/ForeverLM` the component scan above delivers that.
        // The local content root broke the promise: `Library/Application
        // Support/ForeverLM/Content` carries no `Documents/<root>` marker, so
        // the only reduction left was an exact prefix match against this
        // device's own roots — which can never match a different `/Users/<name>`.
        //
        // A foreign path that reduces to nothing is not merely stored oddly. It
        // cannot be located on disk, `isAppManagedSourcePath` disowns it, and
        // `materializeInboundSourcePDFIfNeeded` refuses to install the PDF bytes
        // CloudKit delivered in the very record carrying that path — which is
        // what left papers published before commit 3c62e0d reporting "PDF
        // needed" on the receiving Mac forever. Matching the home-relative
        // suffix repairs all of it, and repairs it in place: `saveSource`
        // relativizes on every write, so a row rewrites itself the next time it
        // is touched.
        //
        // Sandbox differences fall out for free — the container home and the
        // real home produce the same suffix — and `readSourceRow` already
        // re-homes foreign paths for local readers, so this is that same fact
        // expressed where sync and file location can reach it.
        //
        // The product folder is matched by name class, not by this build's own
        // name. A Dev build's roots end in `ForeverLM Dev/Content`, a release
        // build's in `ForeverLM/Content`, and a foreign path names whichever
        // build wrote it: Dev reads production paths through its seeded
        // library and through CloudKit records another Mac's release build
        // published. An exact suffix match left every such path whole, so the
        // receiving apply saw an "incoming" absolute path that differed from
        // the portable one it had just installed and asked for a republish
        // that could never converge (`inboundArchivedArticleHTMLMaterializes`).
        guard let foreignRelative = pathBelowForeignHome(absolutePath) else { return nil }
        let foreignComponents = foreignRelative.split(separator: "/", omittingEmptySubsequences: true)
        for root in knownContentRoots {
            guard let suffix = homeRelativeRootSuffix(root) else { continue }
            let suffixComponents = suffix.split(separator: "/", omittingEmptySubsequences: true)
            guard foreignComponents.count > suffixComponents.count else { continue }
            let rootMatches = zip(suffixComponents, foreignComponents).allSatisfy { expected, actual in
                expected == actual
                    || (isLibraryRootFolderName(String(expected)) && isLibraryRootFolderName(String(actual)))
            }
            if rootMatches {
                return foreignComponents[suffixComponents.count...].joined(separator: "/")
            }
        }

        return nil
    }

    /// A content root with this device's home directory removed —
    /// `Library/Application Support/ForeverLM/Content`, and so on. Every Mac
    /// composes its roots from the same suffix; only the `/Users/<name>` prefix
    /// differs, so the suffix is the portable half.
    private static func homeRelativeRootSuffix(_ root: String) -> String? {
        let home = lexicallyStandardizedAbsolutePath(contentHomeDirectory)
        let rootPath = lexicallyStandardizedAbsolutePath(root)
        guard rootPath.hasPrefix(home + "/") else { return nil }
        let suffix = String(rootPath.dropFirst(home.count + 1))
        return suffix.isEmpty ? nil : suffix
    }

    /// The portion of an absolute path below some *other* home directory, or nil
    /// when the path is not under `/Users/<name>/`. A path under this device's
    /// own home returns nil too: the exact-root loop is the authority there, and
    /// letting a home-relative match run second would reduce paths this device
    /// deliberately keeps whole.
    private static func pathBelowForeignHome(_ absolutePath: String) -> String? {
        let home = lexicallyStandardizedAbsolutePath(contentHomeDirectory)
        guard !absolutePath.hasPrefix(home + "/") else { return nil }
        let components = absolutePath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 2, components[0] == "Users" else { return nil }
        return components[2...].joined(separator: "/")
    }

    private static func relativeContentPathByComponents(_ absolutePath: String) -> String? {
        let components = absolutePath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2 else { return nil }

        for index in components.indices where components[index] == "Documents" {
            let rootIndex = components.index(after: index)
            guard components.indices.contains(rootIndex),
                  isLibraryRootFolderName(String(components[rootIndex])) else {
                continue
            }
            let relativeStart = components.index(after: rootIndex)
            guard components.indices.contains(relativeStart) else { return nil }
            return components[relativeStart...].joined(separator: "/")
        }

        return nil
    }

    /// Convert an absolute iCloud path to a relative path from the ForeverLM root.
    /// E.g. `/Users/foo/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM/Courses/X.pdf`
    /// → `Courses/X.pdf`.  Non-local URLs and already-relative paths are returned unchanged.
    /// This is used for source identity and must never touch the filesystem.
    static func relativeSourcePath(_ path: String) -> String {
        guard path.hasPrefix("/") else {
            guard !path.contains("://") else { return path }
            return normalizedRelativeSourcePath(path)
        }
        return relativeContentPath(fromAbsolutePath: path) ?? path
    }

    /// Resolve a relative source path to an absolute path on this machine.
    /// Already-absolute paths are returned unchanged.
    static func absoluteSourcePath(_ path: String) -> String {
        if path.hasPrefix("/") || path.contains("://") { return path }
        return (libraryRootPath as NSString).appendingPathComponent(normalizedRelativeSourcePath(path))
    }

    /// Every directory on this Mac that can hold a ForeverLM content root: the
    /// app's iCloud Documents folder and iCloud Drive proper. Content has historically
    /// been written under both — `locateLocalPath` already swaps between them for
    /// the canonical folder — so a conflict fork can appear beside either.
    private static var contentRootParents: [URL] {
        // Only synced locations can fork, so the local content root is absent here
        // by design. So is `~/Documents`: when "Desktop & Documents Folders"
        // syncing is on it is the CloudDocs `Documents` listed below, and when it
        // is off it is not synced and cannot fork. Listing it added nothing and
        // cost a TCC prompt — `contentsOfDirectory` on `~/Documents` is what
        // raised "would like to access files in your Documents folder" on the
        // first `knowledgeStore()` of every launch, and the grant never stuck
        // because every Dev binary shares `com.foreverlm.dev` while ad-hoc test
        // builds carry a different code signature each time.
        let home = contentHomeDirectory
        // The retired container is not scanned: its `Documents` is empty, so it
        // has no folder that iCloud could have forked in the first place.
        return [
            "Library/Mobile Documents/\(ForeverLMRuntimeIdentity.iCloudDocumentsFolderName)/Documents",
            "Library/Mobile Documents/com~apple~CloudDocs/Documents",
        ].map {
            URL(fileURLWithPath: (home as NSString).appendingPathComponent($0), isDirectory: true)
        }
    }

    private static let numberedConflictRootsLock = NSLock()
    nonisolated(unsafe) private static var cachedNumberedConflictRoots: [URL]?

    /// Numbered iCloud conflict folders ("ForeverLM 2", "ForeverLM 3", …) sitting
    /// beside any content root. iCloud creates one of these when two devices
    /// disagree about a directory, and the files inside are the real content, not
    /// a discardable copy — the macOS 27 upgrade (2026-07-20) forked this KB into
    /// `com~apple~CloudDocs/Documents/ForeverLM 2`, which is where ~370 paper PDFs
    /// and ~340 archived articles ended up.
    ///
    /// Discovered once per session and cached: this enumerates directories, while
    /// callers resolve one path per source and there are hundreds of them. A fork
    /// that appears later is picked up on the next launch; one that disappears
    /// merely yields a miss, because every candidate is stat'd before it is used.
    /// Newest-numbered first, so the most recent fork wins when several exist.
    static var numberedConflictRoots: [URL] {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--run-podcast-cleanup") {
            return []
        }
        #endif
        numberedConflictRootsLock.lock()
        defer { numberedConflictRootsLock.unlock() }
        if let cached = cachedNumberedConflictRoots { return cached }

        let roots = contentRootParents
            .flatMap { parent -> [URL] in
                guard let children = try? FileManager.default.contentsOfDirectory(
                    at: parent,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { return [] }
                return children.filter { url in
                    guard url.lastPathComponent.range(of: #"^(ForeverLM|FeynmanLM) [0-9]+$"#, options: .regularExpression) != nil else {
                        return false
                    }
                    return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                }
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }

        cachedNumberedConflictRoots = roots
        return roots
    }

    /// Candidate paths for source files that live in an iCloud conflict fork.
    /// This is a read-time compatibility helper only; new writes continue to use
    /// `ForeverLM/`.
    static func legacyNumberedAbsoluteSourcePaths(forRelativePath path: String) -> [String] {
        guard !path.hasPrefix("/"), !path.contains("://") else { return [] }
        let relativePath = normalizedRelativeSourcePath(path)
        return numberedConflictRoots.map { $0.appendingPathComponent(relativePath).path }
    }

    // MARK: - Source file location (single source of truth)

    /// Every place a stored source path could point to on this Mac, most likely
    /// first. Pure string work apart from the cached fork discovery.
    ///
    /// This is deliberately the ONLY list of relocation rules in the app. It used
    /// to be three: `StudioArticle.locateLocalPath` knew about re-homing, the
    /// simulator prefix, container swaps and the Knowledge→ForeverLM rename;
    /// `SourceService.resolveLocalFileURL` knew about `file://`, `~`, iCloud
    /// placeholders and conflict forks; `reconcileLocalFiles` had a third partial
    /// copy. Each was missing rules the others had, so the app could open a file
    /// it simultaneously reported as missing — which is exactly how an iCloud
    /// conflict fork turned into "222 papers need attention" while every PDF sat
    /// safely in `ForeverLM 2`. Add a new location rule HERE and every caller
    /// gets it; there is nowhere else for the answers to diverge.
    static func sourceFileCandidatePaths(for storedPath: String) -> [String] {
        var input = storedPath
        if input.hasPrefix("file://") { input = String(input.dropFirst(7)) }
        if input.hasPrefix("~") { input = (input as NSString).expandingTildeInPath }
        guard !input.isEmpty, !input.contains("://") else { return [] }

        let home = contentHomeDirectory
        var candidates: [String] = []
        var seen = Set<String>()
        func add(_ path: String?) {
            guard let path, path.hasPrefix("/"), seen.insert(path).inserted else { return }
            candidates.append(path)
        }

        // The path itself: relative paths resolve against the current content root.
        if input.hasPrefix("/") {
            add(input)
        } else {
            add(absoluteSourcePath(input))
        }

        // A path written by another Mac (or another account) under a different
        // /Users/<name>, and the iOS simulator's sandboxed copy of the same path.
        let mobileDocsMarker = "Library/Mobile Documents/"
        if let range = input.range(of: mobileDocsMarker) {
            add((home as NSString).appendingPathComponent(String(input[range.lowerBound...])))
        }

        // Anything under a content root — the private container, iCloud Drive,
        // local storage, a historical folder name, or an iCloud conflict fork —
        // reduces to the same relative path. Resolve that relative path against
        // every root we know of, then against every fork.
        let relative = relativeSourcePath(input)
        let relativeForm = relative.hasPrefix("/") ? nil : relative
        if let relativeForm {
            for root in knownContentRoots {
                add((root as NSString).appendingPathComponent(relativeForm))
            }
            for forkPath in legacyNumberedAbsoluteSourcePaths(forRelativePath: relativeForm) {
                add(forkPath)
            }
        }

        // A "/Documents/…" path that lost its home prefix.
        if input.hasPrefix("/Documents/") {
            add(home + input)
        }

        return candidates
    }

    /// Where a stored source path's file actually is, or nil when no candidate
    /// exists. A file that iCloud has not downloaded yet counts as present: the
    /// legacy CloudDocs form leaves a `.name.ext.icloud` placeholder beside it,
    /// and treating that as absent is what makes the app offer to re-download a
    /// paper it already has.
    ///
    /// Stats the filesystem — callers on the main actor must go through
    /// `StudioArticle`'s memoized accessors rather than calling this directly.
    static func locateSourceFile(_ storedPath: String) -> String? {
        let fm = FileManager.default
        let candidates = sourceFileCandidatePaths(for: storedPath)
        for candidate in candidates {
            if fm.fileExists(atPath: candidate) { return candidate }
            let url = URL(fileURLWithPath: candidate)
            let placeholder = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).icloud")
            if fm.fileExists(atPath: placeholder.path) { return candidate }
        }
        // A chapter of an EPUB book kept as one file is an entry of the book's
        // file, at the address it had when the book was unpacked (`EPUBBookFiles`).
        return candidates.first { EPUBBookFiles.exists(atPath: $0) }
    }

    /// Returns true for files managed under the ForeverLM content root.
    ///
    /// These files are synced by iCloud Drive separately from the SQLite/CloudKit
    /// source record. A receiving Mac can see the source metadata before iCloud
    /// has created either the file or its `.icloud` placeholder, so startup
    /// reconciliation must not treat temporary absence as a deletion.
    static func isAppManagedSourcePath(_ path: String) -> Bool {
        guard !path.contains("://") else { return false }
        if !path.hasPrefix("/") { return true }
        return relativeSourcePath(path) != path
    }

    private func ensureStoreExists() throws {
        try ensureICloudUbiquityAvailable()
        try fileManager.createDirectory(at: storeRoot, withIntermediateDirectories: true)
    }

    func ensureAIImagesDirectoryExists() throws {
        try fileManager.createDirectory(at: aiImagesDirURL, withIntermediateDirectories: true)
    }

    func ensureAudioDirectoryExists() throws {
        try fileManager.createDirectory(at: audioDirURL, withIntermediateDirectories: true)
    }

    // MARK: - Knowledge Store (SQLite)

    /// Screen record mode's scope against this store's Notebooks (see
    /// `ScreenRecordScope`); nil when the mode is off, which it is for every
    /// learner but the admin. Readers that hold no view model — the Planner,
    /// the memory review — narrow what they show with it.
    func screenRecordScope() -> ScreenRecordScope? {
        guard ScreenRecordMode.isEffective else { return nil }
        return (try? knowledgeStore())?.screenRecordScope()
    }

    /// Runs one body of the schema-v2 private sync on the store, on this actor, so an apply's
    /// transaction never interleaves with another write (`MacPrivateSyncStore`, generation 2 only).
    func performSync(_ body: (KnowledgeStore) throws -> Void) throws {
        try body(try knowledgeStore())
    }

    /// One bounded step of the generation-2 activation on the store, on this actor, returning what it
    /// read (`StorageStoreAccess`).
    func performStoreWork<T: Sendable>(_ body: @Sendable (KnowledgeStore) throws -> T) throws -> T {
        try body(try knowledgeStore())
    }

    /// Lazily initialized SQLite-backed knowledge store.
    private func knowledgeStore() throws -> KnowledgeStore {
        if let _knowledgeStore { return _knowledgeStore }
        try ensureStoreExists()
        // A test-only override is already the complete storage universe for
        // that instance. Resolving live legacy iCloud roots here is unrelated,
        // can contend with parallel tests, and can block on CloudDocs while an
        // isolated temporary database is being exercised.
        let legacyDirectories = overrideStoreRoot == nil ? Self.legacyICloudContentRoots : []
        let store = try KnowledgeStore(
            storeDirectory: storeRoot,
            contentDirectory: contentRoot,
            legacyContentDirectories: legacyDirectories,
            startupPreferenceSnapshot: overrideStoreRoot == nil
                ? UserDefaults.standard.dictionaryRepresentation()
                : [:],
            syncGeneration: overrideSyncGeneration ?? ForeverLMRuntimeIdentity.syncGeneration
        )
        if overrideStoreRoot == nil {
            store.automaticAudioSourceTypes = { SourceAudioAutomation.enabledSourceTypes() }
            // What another device changed reaches the models that hold the rows in memory.
            store.appliedRemoteChangesHandler = { AppliedRemoteChangesAnnouncer.announce($0) }
        }
        // A store whose full activation has not finished is read-only from its first moment (§13.3).
        GenerationActivationRunner.holdIfActivationMayBeFull(store)
        _knowledgeStore = store
        return store
    }

    /// Narrow internal bridge for the Notebook Files extension. The projection
    /// still shares this actor's one lazily opened store; callers outside
    /// StorageService never receive the handle.
    func notebookFilesKnowledgeStore() throws -> KnowledgeStore {
        try knowledgeStore()
    }

    /// The same narrow bridge for the learning-cohort extension, which needs both
    /// the store and this actor's in-memory vector index to assemble a cohort.
    func cohortKnowledgeStore() throws -> KnowledgeStore {
        try knowledgeStore()
    }

    private enum CloudKitSyncUrgency {
        /// Bulk imports and content extraction: one send for the burst, not one per record.
        case coalesced
        /// Review exchange streams: push soon, but avoid sending after every prompt/answer pair.
        case soon
        /// Small user intent writes: collapse bursts, then push now so another Mac catches up quickly.
        case immediate
    }

    /// How long a bulk write waits before its send, so a burst shares one: the outbox watcher's old interval,
    /// so bulk work sends no more often than it did.
    private static let coalescedSendDelay: TimeInterval = 10

    /// A write announces itself: the outbox triggers recorded it already, and the Mac's generation-2 session
    /// sends it a few seconds later, past the outbox's debounce (`MacSyncSession.localWrite`). `OutboxWatcher`
    /// is the backstop for writes that announce nothing. No session (the First Run app, a unit-test host)
    /// sends nothing.
    private func scheduleCloudKitSync(_ urgency: CloudKitSyncUrgency = .coalesced) {
        guard let session = MacSyncSession.current else { return }
        let delay = urgency == .coalesced ? Self.coalescedSendDelay : SyncCoordinator.sendSoonDelay
        Task { await session.localWrite(after: delay) }
    }

    /// `scheduleCloudKitSync` stays private so the urgency choice cannot leak
    /// out of this actor. These two named bridges let the scheduled-tasks
    /// extension pick between the same two urgencies without widening it.
    func scheduleImmediateCloudKitSyncForScheduledTasks() {
        scheduleCloudKitSync(.immediate)
    }

    /// The same bridge for the teams extension: a share, a task edit or an
    /// accepted invitation should reach the other members promptly.
    func scheduleImmediateCloudKitSyncForTeams() {
        keepTeamCopiesForGeneration2()
        scheduleCloudKitSync(.immediate)
    }

    func scheduleSoonCloudKitSyncForScheduledTasks() {
        scheduleCloudKitSync(.soon)
    }

    /// A review session row changed in an extension file: the closer's summary
    /// landing on the record (`StorageService+DayClose`).
    func scheduleImmediateCloudKitSyncForReviewSessions() {
        scheduleCloudKitSync(.immediate)
    }

    /// The planner's bridge: a redrawn day should be on the other Mac before
    /// the learner sits down at it.
    func scheduleImmediateCloudKitSyncForDayPlans() {
        scheduleCloudKitSync(.immediate)
    }

    /// A source's draft deck grew (`StorageService+CardDrafts`): the other
    /// Mac should see the cards to check soon, without a push per card.
    func scheduleSoonCloudKitSyncForCardDrafts() {
        scheduleCloudKitSync(.soon)
    }

    /// A mnemonic reading's answer kept or answered a card, or a source's
    /// questions were written (`StorageService+MnemonicReading`): the other
    /// devices should see it soon.
    func scheduleSoonCloudKitSyncForMnemonicReadings() {
        scheduleCloudKitSync(.soon)
    }

    /// "Sync now": a round of the generation-2 sync, which starts one that did not get going.
    func syncCloudKitNow() async {
        await MacSyncSession.current?.syncNow()
    }

    /// The SQLite half of `ICloudStorageUsage.measure(storage:)`, which does the
    /// file half off this actor.
    func iCloudSyncedSourceStorage() throws -> ICloudSyncedSourceStorage {
        try knowledgeStore().iCloudSyncedSourceStorage()
    }

    /// "Retry now": the same round; the coordinator's pacer owns every wait.
    func retryCloudKitNow() async {
        await MacSyncSession.current?.syncNow()
    }

    /// Pushes the outbox now and waits for it, for a durability boundary such as a finished import: rounds
    /// until it is empty or a round stops making progress. Returns how many local changes still wait, zero
    /// only when the outbox is empty. A Mac that does not sync (no session) has nothing to wait for.
    func syncCloudKitNowAndWaitForDrain(maxAttempts: Int = 4) async -> Int {
        await MacSyncSession.current?.pushAndWaitForOutbox(maxAttempts: maxAttempts) ?? 0
    }

    /// The local changes still waiting for iCloud; zero on a Mac that does not sync.
    func pendingCloudKitChangeCount() async -> Int {
        await MacSyncSession.current?.outboxBacklog() ?? 0
    }

    /// Permanent create-once/immutable CloudKit collisions quarantined out of
    /// the active retry queue. Callers can surface these failures explicitly;
    /// they are never counted as ordinary pending work that background sync can
    /// resolve by retrying.
    func cloudKitSyncConflicts() throws -> [CloudKitSyncConflict] {
        try ensureStoreExists()
        return try knowledgeStore().loadSyncConflicts()
    }

    /// Drain one bounded post-launch repair batch into the normal CloudKit
    /// queue. Returning zero means this versioned repair is complete.
    func drainSourceSyncRepairBatch(limit: Int = 50) throws -> Int {
        try ensureStoreExists()
        let drained = try knowledgeStore().drainSourceSyncRepairBatch(limit: limit)
        if drained > 0 {
            scheduleCloudKitSync(.immediate)
        }
        return drained
    }

    func sourceSyncRepairQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().sourceSyncRepairQueueCount()
    }

    /// The schema-98 counterpart for review sessions: one bounded batch of
    /// sessions re-enqueued under the renamed CloudKit record type. Zero
    /// means the re-upload is staged in full.
    func drainReviewSessionSyncRepairBatch(limit: Int = 50) throws -> Int {
        try ensureStoreExists()
        let drained = try knowledgeStore().drainReviewSessionSyncRepairBatch(limit: limit)
        if drained > 0 {
            scheduleCloudKitSync(.immediate)
        }
        return drained
    }

    func reviewSessionSyncRepairQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().reviewSessionSyncRepairQueueCount()
    }

    func drainZoomMeetingAdoptionBatch(limit: Int = 50) throws -> [String] {
        try ensureStoreExists()
        let adopted = try knowledgeStore().drainZoomMeetingAdoptionBatch(limit: limit)
        if !adopted.isEmpty { scheduleCloudKitSync(.immediate) }
        return adopted
    }

    func zoomMeetingAdoptionQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().zoomMeetingAdoptionQueueCount()
    }

    /// Returns the sources whose text actually changed, so the caller can drop
    /// its in-memory copies and let them reload from canonical storage.
    func drainSourceTextReferenceRepairBatch(limit: Int = 50) throws -> [String] {
        try ensureStoreExists()
        let repaired = try knowledgeStore().drainSourceTextReferenceRepairBatch(limit: limit)
        if !repaired.isEmpty {
            scheduleCloudKitSync(.immediate)
        }
        return repaired
    }

    func sourceTextReferenceRepairQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().sourceTextReferenceRepairQueueCount()
    }

    /// One batch of schema 166's soft hyphen repair. It asks no CloudKit sync of
    /// its own: at launch it runs before sync starts, which then sends what it
    /// changed, and once sync runs, the changes it records reach it like any other.
    func drainStoredSoftHyphenRepairBatch(limit: Int = 50) throws -> StoredSoftHyphenRepairBatch {
        try ensureStoreExists()
        return try knowledgeStore().drainStoredSoftHyphenRepairBatch(limit: limit)
    }

    func storedSoftHyphenRepairQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().storedSoftHyphenRepairQueueCount()
    }

    /// One batch of the word count repair. The counts it wrote are returned so
    /// the caller can give its in-memory copies the same numbers.
    func drainSourceWordCountRepairBatch(after cursor: String?, limit: Int = 50) throws -> SourceWordCountRepairBatch {
        try ensureStoreExists()
        let batch = try knowledgeStore().drainSourceWordCountRepairBatch(after: cursor, limit: limit)
        if !batch.counts.isEmpty {
            scheduleCloudKitSync()
        }
        return batch
    }

    /// Returns the sources whose text actually changed, so the caller can drop
    /// its in-memory copies and let them reload from canonical storage.
    func drainPaperFigureMarkdownRepairBatch(limit: Int = 50) throws -> [String] {
        try ensureStoreExists()
        let repaired = try knowledgeStore().drainPaperFigureMarkdownRepairBatch(limit: limit)
        if !repaired.isEmpty {
            scheduleCloudKitSync(.immediate)
        }
        return repaired
    }

    func paperFigureMarkdownRepairQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().paperFigureMarkdownRepairQueueCount()
    }

    // MARK: - Paper Figure Index

    func nextPaperFigureIndexCandidate() throws -> PaperFigureIndexCandidate? {
        try ensureStoreExists()
        return try knowledgeStore().nextPaperFigureIndexCandidate()
    }

    func paperFigureIndexCandidate(sourceID: String) throws -> PaperFigureIndexCandidate? {
        try ensureStoreExists()
        return try knowledgeStore().paperFigureIndexCandidate(sourceID: sourceID)
    }

    func paperFigureIndexTarget(sourceID: String) throws -> PaperFigureIndexCandidate? {
        try ensureStoreExists()
        return try knowledgeStore().paperFigureIndexTarget(sourceID: sourceID)
    }

    func ensurePaperFigureIndexQueuedForReview(sourceID: String, force: Bool) throws {
        try ensureStoreExists()
        try knowledgeStore().ensurePaperFigureIndexQueuedForReview(sourceID: sourceID, force: force)
    }

    func paperFigureIndexQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().paperFigureIndexQueueCount()
    }

    func recordPaperFigureIndexFailure(sourceID: String, message: String) throws {
        try ensureStoreExists()
        try knowledgeStore().recordPaperFigureIndexFailure(sourceID: sourceID, message: message)
    }

    @discardableResult
    func updatePaperFigureAnalysis(
        sourceID: String,
        figureID: String,
        analysis: PaperFigureAnalysis
    ) throws -> Bool {
        try ensureStoreExists()
        return try knowledgeStore().updatePaperFigureAnalysis(
            sourceID: sourceID,
            figureID: figureID,
            analysis: analysis
        )
    }

    func replacePaperFigureIndex(
        sourceID: String,
        pdfPath: String,
        pageCount: Int,
        figures: [PaperFigureRecord],
        indexVersion: Int
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().replacePaperFigureIndex(
            sourceID: sourceID,
            pdfPath: pdfPath,
            pageCount: pageCount,
            figures: figures,
            indexVersion: indexVersion
        )
    }

    /// Stable figure/page relationships for multimodal retrieval. Image paths
    /// remain portable and must be resolved off-main immediately before use.
    func paperFigureImageSweepIsPending() throws -> Bool {
        try ensureStoreExists()
        return try knowledgeStore().paperFigureImageSweepIsPending()
    }

    func completePaperFigureImageSweep(removedDirectoryCount: Int) throws {
        try ensureStoreExists()
        try knowledgeStore().completePaperFigureImageSweep(
            removedDirectoryCount: removedDirectoryCount
        )
    }

    func recordPaperFigureImageSweepFailure(message: String) throws {
        try ensureStoreExists()
        try knowledgeStore().recordPaperFigureImageSweepFailure(message: message)
    }

    func paperFigureIndexedPDFPath(sourceID: String) throws -> String? {
        try ensureStoreExists()
        return try knowledgeStore().paperFigureIndexedPDFPath(sourceID: sourceID)
    }

    func paperFigures(sourceID: String) throws -> [PaperFigureRecord] {
        try ensureStoreExists()
        return try knowledgeStore().paperFigures(sourceID: sourceID)
    }

    func syncedPaperFigures(sourceID: String) throws -> [SyncedPaperFigure] {
        try ensureStoreExists()
        return try knowledgeStore().syncedPaperFigures(sourceID: sourceID)
    }

    // MARK: - Reader Highlights and Notes

    func sourceHighlights(sourceID: String) throws -> [SourceHighlight] {
        try ensureStoreExists()
        return try knowledgeStore().sourceHighlights(sourceID: sourceID)
    }

    func sourceHighlights(sourceIDs: [String]) throws -> [String: [SourceHighlight]] {
        try ensureStoreExists()
        return try knowledgeStore().sourceHighlights(sourceIDs: sourceIDs)
    }

    func saveSourceHighlight(_ highlight: SourceHighlight) throws {
        try ensureStoreExists()
        try knowledgeStore().saveSourceHighlight(highlight)
    }

    @discardableResult
    func linkSourceHighlight(id: String, toChat sessionID: String?) throws -> SourceHighlight? {
        try ensureStoreExists()
        return try knowledgeStore().linkSourceHighlight(id: id, toChat: sessionID)
    }

    func deleteSourceHighlight(id: String) throws {
        try ensureStoreExists()
        try knowledgeStore().deleteSourceHighlight(id: id)
    }

    func insertImportedSourceHighlights(_ highlights: [SourceHighlight]) throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().insertImportedSourceHighlights(highlights)
    }

    // MARK: - Chunk Vector Index

    /// Nearest source chunks from the process-shared vector index, loading it from SQLite
    /// the first time it is used this session. Kept current afterwards by
    /// `saveSourceChunkEmbeddings`, so an ingest never forces a full reload.
    ///
    /// Static and nonisolated so the MCP tools — which reach the database through their
    /// own `KnowledgeStore` rather than this actor — search the same in-memory copy
    /// instead of re-reading every vector per query. Must not be called from the main
    /// actor: the first call reads every vector out of SQLite.
    nonisolated static func searchChunkVectors(
        queryVector: [Float],
        topK: Int,
        threshold: Float,
        restrictedTo: Set<String>? = nil,
        excludedSources: Set<String> = [],
        using ks: KnowledgeStore
    ) -> [(sourceId: String, chunkId: String, score: Float)] {
        guard let policyExcludedSources = try? ks.knowledgeSearchExcludedSourceIDs() else {
            return []
        }
        let effectiveExcludedSources = excludedSources.union(policyExcludedSources)
        let results = SharedSourceVectorIndex.shared.withIndex(storePath: ks.dbPath, dimensions: sourceEmbeddingDimensions) { index in
            if index.rowCount == 0,
               let embeddings = try? ks.loadAllEmbeddings(
                   entityType: .sourceChunk,
                   model: sourceEmbeddingModel
               ), !embeddings.isEmpty {
                // Only the chunks of sources search covers. An archive or a delete takes its
                // vectors from the store, but one that arrived by sync, or an older build, can
                // leave them there, and a vector once loaded is searched until the index is
                // rebuilt.
                let inSearch = try? ks.sourceIDsInSearch()
                index.load(
                    inSearch.map { chunkVectors(embeddings, ofSourcesIn: $0) } ?? embeddings,
                    sourceIDForChunk: sourceId(fromSourceChunkEmbeddingId:)
                )
            }
            return index.search(
                queryVector: queryVector,
                topK: topK,
                threshold: threshold,
                allowedSources: restrictedTo,
                excludedSources: effectiveExcludedSources
            )
        }
        return results.compactMap { result in
            guard let source = sourceId(fromSourceChunkEmbeddingId: result.id) else { return nil }
            return (sourceId: source, chunkId: result.id, score: result.score)
        }
    }

    /// The chunk vectors, by chunk id, whose source is one of `sourceIDs`.
    nonisolated static func chunkVectors(_ embeddings: [String: [Float]], ofSourcesIn sourceIDs: Set<String>) -> [String: [Float]] {
        embeddings.filter { chunk in
            sourceId(fromSourceChunkEmbeddingId: chunk.key).map(sourceIDs.contains) == true
        }
    }

    /// How far back "Read next" looks for what the learner has been reading,
    /// and how many of those sources it measures the library against.
    static let readNextLookback: TimeInterval = 30 * 24 * 60 * 60
    static let readNextSeedLimit = 10

    /// Unread sources nearest to what the learner has been reading lately.
    ///
    /// Deterministic and free: no model call. Each recently read source
    /// (`recentReadingSourceIDs`) is reduced to the mean of its chunk vectors,
    /// and every candidate is scored by its best chunk against the nearest of
    /// those. `candidateIDs` is the caller's pool (the active library's ready
    /// sources, less what is already planned); anything the learner has
    /// already opened, read or marked consumed is removed here, as is anything
    /// the knowledge policy keeps out of AI discovery. Empty when there is no
    /// recent reading or none of it is embedded yet: there is nothing to
    /// measure against, and nothing is guessed in its place.
    nonisolated static func readNextSuggestions(
        candidateIDs: Set<String>,
        limit: Int,
        now: Date = Date(),
        using ks: KnowledgeStore
    ) throws -> [ReadNextSuggestion] {
        let seeds = try ks.recentReadingSourceIDs(
            since: now.addingTimeInterval(-readNextLookback),
            limit: readNextSeedLimit
        )
        guard !seeds.isEmpty, limit > 0 else { return [] }
        let excluded = try ks.touchedSourceIDs().union(ks.knowledgeSearchExcludedSourceIDs())
        let pool = candidateIDs.subtracting(excluded)
        guard !pool.isEmpty else { return [] }

        let scored = SharedSourceVectorIndex.shared.withIndex(storePath: ks.dbPath, dimensions: sourceEmbeddingDimensions) { index -> (seeds: [String], best: [String: (score: Float, query: Int)]) in
            if index.rowCount == 0,
               let embeddings = try? ks.loadAllEmbeddings(entityType: .sourceChunk, model: sourceEmbeddingModel),
               !embeddings.isEmpty {
                index.load(embeddings, sourceIDForChunk: sourceId(fromSourceChunkEmbeddingId:))
            }
            let centroids = index.centroids(forSources: Set(seeds))
            let embeddedSeeds = seeds.filter { centroids[$0] != nil }
            let best = index.bestSourceScores(
                queries: embeddedSeeds.compactMap { centroids[$0] },
                allowedSources: pool
            )
            return (embeddedSeeds, best)
        }

        return scored.best
            .map { ReadNextSuggestion(sourceID: $0.key, nearestReadSourceID: scored.seeds[$0.value.query], score: $0.value.score) }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.sourceID < rhs.sourceID }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map { $0 }
    }

    func readNextSuggestions(candidateIDs: Set<String>, limit: Int) throws -> [ReadNextSuggestion] {
        try Self.readNextSuggestions(candidateIDs: candidateIDs, limit: limit, using: knowledgeStore())
    }

    /// Hybrid source search against an arbitrary store — the one ranking shared by the
    /// in-app Studio search and the MCP `search_sources_semantic` tool.
    /// See `SourceSearchEngine`.
    ///
    /// `restrictedTo` narrows every branch to an explicit source set, for
    /// callers ranking within a pool they already hold — a chat's attached
    /// sources, say. Passing nil searches the whole library.
    nonisolated static func searchSources(
        queryText: String,
        queryVector: [Float]?,
        limit: Int,
        threshold: Float,
        restrictedTo: Set<String>? = nil,
        using ks: KnowledgeStore
    ) -> [SourceSearchHit] {
        guard let excludedSources = try? ks.knowledgeSearchExcludedSourceIDs() else {
            return []
        }
        return (try? SourceSearchEngine.search(
            queryText: queryText,
            queryVector: queryVector,
            limit: limit,
            threshold: threshold,
            store: ks,
            restrictedTo: restrictedTo,
            excludedSources: excludedSources,
            semanticChunkSearch: { vector, topK, threshold, allowed, excluded in
                searchChunkVectors(
                    queryVector: vector,
                    topK: topK,
                    threshold: threshold,
                    restrictedTo: allowed,
                    excludedSources: excluded,
                    using: ks
                )
            }
        )) ?? []
    }

    // MARK: - Source Embeddings

    /// Active source counts per user-built plugin label, for the Settings
    /// plugins list.
    func activePluginSourceCounts() throws -> [String: Int] {
        try knowledgeStore().activePluginSourceCounts()
    }

    /// Save an embedding vector for a source.
    func saveSourceEmbedding(sourceId: String, vector: [Float]) throws {
        let ks = try knowledgeStore()
        try ks.saveEmbedding(entityType: .source, entityId: sourceId, vector: vector, model: Self.sourceEmbeddingModel)
    }

    /// Load the embedding vector for a source, or nil if not yet embedded.
    func loadSourceEmbedding(sourceId: String) -> [Float]? {
        guard let ks = try? knowledgeStore() else { return nil }
        return try? ks.loadEmbedding(entityType: .source, entityId: sourceId, model: Self.sourceEmbeddingModel)
    }

    func saveAIUsageEvent(_ event: AIUsageEvent) throws {
        if let aiUsagePrimaryFailure {
            try KnowledgeStore.appendAIUsageEventForwardCompatibly(
                event,
                storeDirectory: storeRoot,
                after: aiUsagePrimaryFailure
            )
            return
        }
        do {
            try knowledgeStore().saveAIUsageEvent(event)
        } catch {
            // A lock another writer held past the busy timeout is not a schema
            // problem: the store opened fine. Latching the narrow path here sent
            // every later billed call around it, and that path takes the same
            // lock. The caller retries a lock instead.
            if KnowledgeStoreError.isTransientLock(error) { throw error }
            // A Mac that is one release behind must reject the newer knowledge
            // schema for normal reads and writes, but it must not lose spend
            // while doing so. The usage table is append-only and additive, so a
            // narrowly scoped writer can safely insert the columns this build
            // recognizes without migrating, downgrading, or otherwise opening
            // the newer store for application work.
            // Do not call ensureStoreExists() here: it also initializes the
            // CloudKit engine, which opens KnowledgeStore and would repeat the
            // same schema-version failure before accounting got its chance.
            try fileManager.createDirectory(at: storeRoot, withIntermediateDirectories: true)
            let primaryFailure = error.localizedDescription
            aiUsagePrimaryFailure = primaryFailure
            try KnowledgeStore.appendAIUsageEventForwardCompatibly(
                event,
                storeDirectory: storeRoot,
                after: primaryFailure
            )
        }
    }

    func managedAIUsageCursor() throws -> Int64 {
        try knowledgeStore().managedAIUsageCursor()
    }

    func cachedAIResponse(for requestKey: String, notOlderThan cutoff: Date) throws -> String? {
        try knowledgeStore().cachedAIResponse(for: requestKey, notOlderThan: cutoff)
    }

    func saveCachedAIResponse(_ response: String, for requestKey: String) throws {
        try knowledgeStore().saveCachedAIResponse(response, for: requestKey)
    }

    func importManagedAIUsageEvents(
        _ rows: [ManagedAI.UsageLedgerEvent],
        through cursor: Int64
    ) throws {
        try knowledgeStore().importManagedAIUsageEvents(rows, through: cursor)
    }

    func aiUsageSummaries(
        filter: KnowledgeStore.AIUsageEventFilter = .init()
    ) throws -> [AIUsageSummary] {
        try knowledgeStore().loadAIUsageSummaries(filter: filter)
    }

    /// Recorded spend for one chat/review session, over rows created before
    /// `cutoff` (see KnowledgeStore.aiUsageCost for the live/persisted split).
    func aiUsageCost(sessionID: String, before cutoff: Date) throws -> KnowledgeStore.AIUsageSessionCost {
        try knowledgeStore().aiUsageCost(sessionID: sessionID, before: cutoff)
    }

    /// Individual recorded calls, newest first — the AI Usage pane pages
    /// through the whole ledger with this rather than showing a fixed slice.
    func aiUsageEvents(
        filter: KnowledgeStore.AIUsageEventFilter = .init(),
        limit: Int,
        offset: Int = 0
    ) throws -> [AIUsageEvent] {
        try knowledgeStore().loadAIUsageEvents(filter: filter, limit: limit, offset: offset)
    }

    func aiUsageEventCount(filter: KnowledgeStore.AIUsageEventFilter = .init()) throws -> Int {
        try knowledgeStore().countAIUsageEvents(filter: filter)
    }

    func aiUsageTaskActivities(
        filter: KnowledgeStore.AIUsageEventFilter = .init()
    ) throws -> [AIUsageTaskActivitySummary] {
        try knowledgeStore().loadAIUsageTaskActivities(filter: filter)
    }

    func aiUsageSubjectActivities(
        task: String?,
        filter: KnowledgeStore.AIUsageEventFilter = .init(),
        limit: Int = Int.max,
        offset: Int = 0
    ) throws -> [AIUsageSubjectActivitySummary] {
        try knowledgeStore().loadAIUsageSubjectActivities(
            task: task,
            filter: filter,
            limit: limit,
            offset: offset
        )
    }

    /// Count, total spend, unpriced-call count, and prompt-cache read/write
    /// tokens for the AI Usage pane.
    func aiUsageEventTotals(
        filter: KnowledgeStore.AIUsageEventFilter = .init()
    ) throws -> AIUsageEventTotals {
        try knowledgeStore().aiUsageEventTotals(filter: filter)
    }

    /// Prices stored usage rows that have no cost yet but can now get one.
    /// See `KnowledgeStore.repriceUnpricedAIUsageEvents`.
    @discardableResult
    func repriceUnpricedAIUsageEvents() throws -> Int {
        try knowledgeStore().repriceUnpricedAIUsageEvents()
    }

    /// See `KnowledgeStore.unpricedImageUsageEventCount`.
    func unpricedImageUsageEventCount() throws -> Int {
        try knowledgeStore().unpricedImageUsageEventCount()
    }

    /// See `KnowledgeStore.aiUsageEventsAwaitingGenerationCost`.
    func aiUsageEventsAwaitingGenerationCost(limit: Int) throws -> [(id: String, rawUsageJSON: String)] {
        try knowledgeStore().aiUsageEventsAwaitingGenerationCost(limit: limit)
    }

    /// See `KnowledgeStore.setAIUsageEventGenerationCost`.
    func setAIUsageEventGenerationCost(id: String, costUSD: Double) throws {
        try knowledgeStore().setAIUsageEventGenerationCost(id: id, costUSD: costUSD)
    }

    /// Zeroes stored estimates OpenRouter says it never billed.
    /// See `KnowledgeStore.zeroEstimatesOpenRouterDidNotBill`.
    @discardableResult
    func zeroEstimatesOpenRouterDidNotBill() throws -> Int {
        try knowledgeStore().zeroEstimatesOpenRouterDidNotBill()
    }

    func aiUsageFacets(since: Date? = nil) throws -> (providers: [String], models: [String], operations: [String], tasks: [String], platforms: [String]) {
        try knowledgeStore().loadAIUsageFacets(since: since)
    }

    func aiUsageDailyTotals(since: Date? = nil) throws -> [AIUsageDailyTotal] {
        try knowledgeStore().loadAIUsageDailyTotals(since: since)
    }

    func aiUsageOperationSummaries(since: Date? = nil) throws -> [AIUsageOperationSummary] {
        try knowledgeStore().loadAIUsageOperationSummaries(since: since)
    }

    /// Return the set of source IDs that already have embeddings (single query, not N queries).
    func embeddedSourceIds() -> Set<String> {
        guard let ks = try? knowledgeStore() else { return [] }
        return (try? ks.embeddedEntityIds(entityType: .source, model: Self.sourceEmbeddingModel)) ?? []
    }

    /// Save chunk-level embeddings for a source, replacing any older chunks for that source.
    func saveSourceChunkEmbeddings(sourceId: String, embeddings: [(chunkId: String, vector: [Float])]) throws {
        let ks = try knowledgeStore()
        try ks.deleteEmbeddings(
            entityType: .sourceChunk,
            entityIdPrefix: Self.sourceChunkEmbeddingPrefix(for: sourceId),
            model: Self.sourceEmbeddingModel
        )
        guard !embeddings.isEmpty else { return }
        let keyed = Dictionary(uniqueKeysWithValues: embeddings.map { ($0.chunkId, $0.vector) })
        try ks.saveEmbeddingsBatch(entityType: .sourceChunk, embeddings: keyed, model: Self.sourceEmbeddingModel)

        // Keep the in-memory index in step with the write, so the backfill never forces
        // a full reload and a search right after an ingest sees the new vectors.
        // `replace` no-ops while the index is still unloaded, so this does not fault in
        // 184 MB of vectors during a backfill that nobody has searched yet.
        SharedSourceVectorIndex.shared.withIndex(storePath: ks.dbPath, dimensions: Self.sourceEmbeddingDimensions) { index in
            index.replace(
                sourceID: sourceId,
                chunks: embeddings,
                sourceIDForChunk: Self.sourceId(fromSourceChunkEmbeddingId:)
            )
        }
    }

    /// Active, ready sources missing either index (chunk vectors or full text) — the
    /// work list for the background indexer. Empty on any store error (the indexer
    /// treats that as "nothing to do" and retries on its next trigger).
    func sourcesMissingIndex() -> [KnowledgeStore.EmbeddingCandidate] {
        guard let ks = try? knowledgeStore() else { return [] }
        return (try? ks.sourcesMissingIndex(model: Self.sourceEmbeddingModel)) ?? []
    }

    /// Sources whose record says another device finished their ingestion (`Source.ingest` arrived `ready`). The
    /// automatic sweeps for unprocessed sources skip these: the work is done and its satellites are on their
    /// way (`InboundSourceFiles`). Empty on any store error.
    func sourceIDsIngestedOnAnotherDevice() -> Set<String> {
        guard let ks = try? knowledgeStore() else { return [] }
        return (try? ks.sourceIDsIngestedOnAnotherDevice()) ?? []
    }

    /// Sources whose full-text row predates the current index-time analysis. Text-only
    /// maintenance: repairing this gap rewrites rows and never embeds.
    func sourcesNeedingFTSRebuild() -> [KnowledgeStore.EmbeddingCandidate] {
        guard let ks = try? knowledgeStore() else { return [] }
        return (try? ks.sourcesNeedingFTSRebuild(
            analyzerVersion: SourceSearchEngine.indexAnalyzerVersion
        )) ?? []
    }

    /// Write a source's full-text row. Fed the same resolved text used for embedding, so
    /// both halves of search always describe the same content.
    func replaceSourceFTS(sourceID: String, title: String, author: String, body: String) throws {
        try knowledgeStore().replaceSourceFTS(sourceID: sourceID, title: title, author: author, body: body)
    }

    /// Record the rowids of up to `limit` full-text rows written before schema 168; whether
    /// rows remain (`KnowledgeStore.recordSourceFTSRows`).
    func recordSourceFTSRows(limit: Int) throws -> Bool {
        try knowledgeStore().recordSourceFTSRows(limit: limit)
    }

    /// Record that a source is fully indexed against the current version of its text.
    func recordSourceIndexed(sourceID: String) throws {
        try knowledgeStore().recordSourceIndexed(sourceID: sourceID, model: Self.sourceEmbeddingModel)
    }

    /// Coverage of the search index: active sources vs sources actually indexed.
    func searchIndexCoverage() -> (activeSources: Int, indexedSources: Int, ftsRows: Int, chunkVectors: Int)? {
        guard let ks = try? knowledgeStore() else { return nil }
        return try? ks.indexCoverage(model: Self.sourceEmbeddingModel)
    }

    /// Raw podcast transcript for a source, when its text lives only in `podcasts`.
    func podcastRawTTML(forSourceID sourceID: String) -> String? {
        guard let ks = try? knowledgeStore() else { return nil }
        return (try? ks.podcastRawTTML(forSourceID: sourceID)) ?? nil
    }

    /// Return the source IDs that already have at least one chunk embedding.
    func embeddedChunkSourceIds() -> Set<String> {
        guard let ks = try? knowledgeStore(),
              let chunkIds = try? ks.embeddedEntityIds(entityType: .sourceChunk, model: Self.sourceEmbeddingModel) else {
            return []
        }
        return Set(chunkIds.compactMap(Self.sourceId(fromSourceChunkEmbeddingId:)))
    }

    /// Find the nearest source chunks. Callers can use this when they need chunk-level evidence.
    /// Served from the in-memory `SourceVectorIndex` — one BLAS pass, no per-query SQLite read.
    func findSimilarSourceChunks(queryVector: [Float], topK: Int = 120, threshold: Float = EmbeddingSettings.similarityThreshold) -> [(sourceId: String, chunkId: String, score: Float)] {
        guard let ks = try? knowledgeStore() else { return [] }
        return Self.searchChunkVectors(queryVector: queryVector, topK: topK, threshold: threshold, using: ks)
    }

    /// Hybrid source search — the one ranking used by both the in-app Studio search and
    /// the MCP `search_sources_semantic` tool. See `SourceSearchEngine`.
    func searchSources(
        queryText: String,
        queryVector: [Float]?,
        limit: Int,
        threshold: Float = EmbeddingSettings.similarityThreshold,
        restrictedTo: Set<String>? = nil
    ) -> [SourceSearchHit] {
        guard let ks = try? knowledgeStore() else { return [] }
        return Self.searchSources(
            queryText: queryText,
            queryVector: queryVector,
            limit: limit,
            threshold: threshold,
            restrictedTo: restrictedTo,
            using: ks
        )
    }

    /// Strict indexed-content matches for list-filter UIs. Unlike hybrid source
    /// discovery, every returned source contains every typed term.
    func strictSourceContentMatchIDs(
        queryText: String,
        limit: Int,
        restrictedTo: Set<String>? = nil
    ) -> Set<String> {
        guard let ks = try? knowledgeStore(),
              let excludedSources = try? ks.knowledgeSearchExcludedSourceIDs() else {
            return []
        }
        return (try? SourceSearchEngine.strictContentMatchIDs(
            queryText: queryText,
            limit: limit,
            store: ks,
            restrictedTo: restrictedTo,
            excludedSources: excludedSources
        )) ?? []
    }

    /// Find sources most similar to a query vector, scoring each source by its best chunk.
    func findSimilarSources(queryVector: [Float], topK: Int = 30, threshold: Float = EmbeddingSettings.similarityThreshold) -> [(id: String, score: Float)] {
        let chunkResults = findSimilarSourceChunks(
            queryVector: queryVector,
            topK: max(topK * 4, 80),
            threshold: threshold
        )
        guard !chunkResults.isEmpty else { return [] }

        var bestBySource: [String: Float] = [:]
        for result in chunkResults {
            bestBySource[result.sourceId] = max(bestBySource[result.sourceId] ?? -.greatestFiniteMagnitude, result.score)
        }
        return bestBySource
            .map { (id: $0.key, score: $0.value) }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.id < rhs.id }
                return lhs.score > rhs.score
            }
            .prefix(topK)
            .map { $0 }
    }

    /// Whether the source has durable readable text. Cheaper than
    /// `loadSourceContent` — it never pulls the body into memory — and it is the
    /// same predicate `saveSource` enforces before admitting a source as ready.
    func hasReadableSourceContent(_ sourceId: String) -> Bool {
        guard let ks = try? knowledgeStore() else { return false }
        return (try? ks.hasReadableSourceContent(sourceId)) ?? false
    }

    /// Load persisted source content from SQLite.
    ///
    /// Stored text wins. Deriving text from a local file — a book chapter's
    /// PDF, a course handout — happens only for a source that has nothing
    /// stored yet, and it runs off this actor. It used to run here on every
    /// read of a PDF-backed source, re-extracting the whole file to compare it
    /// against the stored copy, which held the single storage lane for as long
    /// as the extraction took while every chat send, sync hop and reader open
    /// queued behind it (see `ChatSendPreparationTrace`). A stale derived copy
    /// is refreshed by the ingestion paths that replace the file, not by reads.
    func loadSourceContent(_ sourceId: String) async -> String? {
        guard let ks = try? knowledgeStore() else { return nil }

        let article = try? ks.loadSourceForSync(sourceId)
        // Deferred upgrades may temporarily leave the pre-v18 extraction in
        // source_content. It is ingestion input, not canonical paper content,
        // until the paper is ready and cleanup has committed.
        if article?.sourceType == .paper, article?.state != .ready {
            return nil
        }
        if let cached = try? ks.loadSourceContent(sourceId),
           !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cached
        }
        // A paper without canonical content is still in ingestion. Never bypass
        // the cleanup boundary by extracting its local PDF in a read path.
        if article?.sourceType == .paper { return nil }
        guard let article else { return nil }
        let derived = await Task.detached(priority: .userInitiated) {
            Self.deriveLocalSourceContent(for: article)
        }.value
        guard let derived else { return nil }
        // Another caller may have stored this source's text during the
        // extraction; the stored copy stays authoritative.
        if let cached = try? ks.loadSourceContent(sourceId),
           !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cached
        }
        try? ks.saveDerivedSourceContent(sourceId, content: derived)
        return derived
    }

    /// Stored text for many sources in one read. No derivation and no network:
    /// this is what a chat send hydrates attached sources from, so it must be
    /// as cheap as the query.
    func loadStoredSourceContents(for sourceIDs: [String]) -> [String: String] {
        guard !sourceIDs.isEmpty, let ks = try? knowledgeStore() else { return [:] }
        return (try? ks.loadSourceContents(for: sourceIDs)) ?? [:]
    }

    /// What a website refresh measures its capture against. Unlike
    /// `loadSourceContent`, nothing is derived from the archived page, and a
    /// failed read throws, so a refresh never takes an unreadable copy for a
    /// missing one.
    func savedArticleCopy(_ sourceID: String) throws -> ArticleRefreshSavedCopy {
        let store = try knowledgeStore()
        return ArticleRefreshSavedCopy(
            text: try store.loadSourceContent(sourceID),
            stagedRaw: try store.loadArticleContentPreparation(sourceID)?.raw
        )
    }

    /// Raw paper extraction for the ingestion pipeline only. Downstream source
    /// readers intentionally have no equivalent API.
    func loadRawPaperContent(_ sourceID: String) -> String? {
        guard let store = try? knowledgeStore() else { return nil }
        // A pre-v18 database may still hold its extraction in source_content
        // until the deferred cleanup queue processes it. This ingestion-only
        // API may use that legacy input; ordinary consumers still see only the
        // canonical ready-source boundary.
        return (try? store.loadPaperContentPreparation(sourceID)?.raw)
            ?? (try? store.loadSourceContent(sourceID))
    }

    /// The staged extraction of a source whose canonical cleanup has not run,
    /// whichever preparation table holds it. Ingestion-only, for the same
    /// reason as `loadRawPaperContent`: it is pre-cleanup text, so no reading
    /// surface may take this path to the content.
    func loadStagedRawContent(_ sourceID: String) -> String? {
        guard let store = try? knowledgeStore() else { return nil }
        return (try? store.loadPaperContentPreparation(sourceID)?.raw)
            ?? (try? store.loadArticleContentPreparation(sourceID)?.raw)
            ?? (try? store.loadSourceContent(sourceID))
    }

    func articleChromeRefilterCandidates(limit: Int) throws -> [ArticleChromeRefilterCandidate] {
        try ensureStoreExists()
        return try knowledgeStore().articleChromeRefilterCandidates(limit: limit)
    }

    func articleChromeRefilterQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().articleChromeRefilterQueueCount()
    }

    func completeArticleChromeRefilter(sourceID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().completeArticleChromeRefilter(sourceID: sourceID)
    }

    func recordArticleChromeRefilterFailure(sourceID: String, message: String) throws {
        try ensureStoreExists()
        try knowledgeStore().recordArticleChromeRefilterFailure(sourceID: sourceID, message: message)
    }

    func republishArticleReaderDocument(sourceID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().republishArticleReaderDocument(sourceID: sourceID)
    }

    // MARK: - Registered paper titles (schema 144)

    func registeredPaperTitleCandidates(limit: Int) throws -> [RegisteredPaperTitleCandidate] {
        try ensureStoreExists()
        return try knowledgeStore().registeredPaperTitleCandidates(limit: limit)
    }

    func registeredPaperTitleQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().registeredPaperTitleQueueCount()
    }

    func dropRegisteredPaperTitleChecksWithoutPapers() throws {
        try ensureStoreExists()
        try knowledgeStore().dropRegisteredPaperTitleChecksWithoutPapers()
    }

    func completeRegisteredPaperTitleCheck(sourceID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().completeRegisteredPaperTitleCheck(sourceID: sourceID)
    }

    func recordRegisteredPaperTitleCheckFailure(sourceID: String, message: String) throws {
        try ensureStoreExists()
        try knowledgeStore().recordRegisteredPaperTitleCheckFailure(sourceID: sourceID, message: message)
    }

    @discardableResult
    func restoreRegisteredPaperTitle(
        sourceID: String,
        checkedTitle: String,
        registeredTitle: String
    ) throws -> Bool {
        try ensureStoreExists()
        let changed = try knowledgeStore().restoreRegisteredPaperTitle(
            sourceID: sourceID,
            checkedTitle: checkedTitle,
            registeredTitle: registeredTitle
        )
        if changed { scheduleCloudKitSync(.coalesced) }
        return changed
    }

    // MARK: - YouTube transcript checks (schema 148)

    func youTubeTranscriptCheckCandidates(limit: Int) throws -> [YouTubeTranscriptCheckCandidate] {
        try ensureStoreExists()
        return try knowledgeStore().youTubeTranscriptCheckCandidates(limit: limit)
    }

    func youTubeTranscriptCheckQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().youTubeTranscriptCheckQueueCount()
    }

    func dropYouTubeTranscriptChecksWithoutVideos() throws {
        try ensureStoreExists()
        try knowledgeStore().dropYouTubeTranscriptChecksWithoutVideos()
    }

    func completeYouTubeTranscriptCheck(sourceID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().completeYouTubeTranscriptCheck(sourceID: sourceID)
    }

    func recordYouTubeTranscriptCheckFailure(sourceID: String, message: String) throws {
        try ensureStoreExists()
        try knowledgeStore().recordYouTubeTranscriptCheckFailure(sourceID: sourceID, message: message)
    }

    func memoryAnchorExcerpts(sourceID: String) throws -> [String] {
        try ensureStoreExists()
        return try knowledgeStore().memoryAnchorExcerpts(sourceID: sourceID)
    }

    @discardableResult
    func replaceCheckedYouTubeTranscript(
        sourceID: String,
        checkedContent: String,
        content: String
    ) throws -> Bool {
        try ensureStoreExists()
        let changed = try knowledgeStore().replaceCheckedYouTubeTranscript(
            sourceID: sourceID,
            checkedContent: checkedContent,
            content: content
        )
        if changed { scheduleCloudKitSync(.coalesced) }
        return changed
    }

    func podcastTranscriptDetruncationCandidates(
        fetchingTTML: Bool,
        limit: Int
    ) throws -> [PodcastTranscriptDetruncationCandidate] {
        try ensureStoreExists()
        return try knowledgeStore().podcastTranscriptDetruncationCandidates(
            fetchingTTML: fetchingTTML,
            limit: limit
        )
    }

    func podcastTranscriptDetruncationQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().podcastTranscriptDetruncationQueueCount()
    }

    func podcastTranscriptAuditInputs(sourceID: String) throws -> PodcastTranscriptAuditInputs? {
        try ensureStoreExists()
        return try knowledgeStore().podcastTranscriptAuditInputs(sourceID: sourceID)
    }

    /// Stage one episode for the completeness audit. An episode the audit
    /// already measured, or hydration wrote from a whole TTML, is left alone.
    /// Returns whether it was staged.
    @discardableResult
    func enqueuePodcastTranscriptDetruncation(sourceID: String) throws -> Bool {
        try ensureStoreExists()
        return try knowledgeStore().enqueuePodcastTranscriptDetruncationIfNeeded(sourceID: sourceID)
    }

    func youTubeLegacyCapNeedsVerification(sourceID: String) throws -> Bool {
        try ensureStoreExists()
        return try knowledgeStore().youTubeLegacyCapNeedsVerification(sourceID: sourceID)
    }

    func markYouTubeLegacyCapVerified(sourceID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().markYouTubeLegacyCapVerified(sourceID: sourceID)
    }

    /// See `KnowledgeStore.restorePodcastTranscript`. A replaced transcript is
    /// sent to the other devices and starts the derived work that follows a
    /// new transcript (the ad pass, the indexes).
    @discardableResult
    func restorePodcastTranscript(
        sourceID: String,
        auditedTranscript: String,
        restoredTranscript: String,
        fetchedTTML: String?,
        ttmlSHA256: String
    ) throws -> Bool {
        try ensureStoreExists()
        let restored = try knowledgeStore().restorePodcastTranscript(
            sourceID: sourceID,
            auditedTranscript: auditedTranscript,
            restoredTranscript: restoredTranscript,
            fetchedTTML: fetchedTTML,
            ttmlSHA256: ttmlSHA256
        )
        if restored {
            scheduleCloudKitSync()
            NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
        }
        return restored
    }

    func removePodcastTranscriptFromDetruncationQueue(sourceID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().removePodcastTranscriptFromDetruncationQueue(sourceID: sourceID)
    }

    func recordPodcastTranscriptAudit(
        sourceID: String,
        ttmlSHA256: String?,
        outcome: PodcastTranscriptAuditOutcome
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().recordPodcastTranscriptAudit(
            sourceID: sourceID,
            ttmlSHA256: ttmlSHA256,
            outcome: outcome
        )
    }

    func recordPodcastTranscriptDetruncationFailure(
        sourceID: String,
        message: String,
        retryAfter: Date?
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().recordPodcastTranscriptDetruncationFailure(
            sourceID: sourceID,
            message: message,
            retryAfter: retryAfter
        )
    }

    func nextCanonicalContentCleanupCandidate() throws -> CanonicalContentCleanupCandidate? {
        try ensureStoreExists()
        return try knowledgeStore().nextCanonicalContentCleanupCandidate()
    }

    func canonicalContentCleanupCandidates(
        limit: Int,
        pendingIngestionOnly: Bool = false,
        now: Date = Date()
    ) throws -> [CanonicalContentCleanupCandidate] {
        try ensureStoreExists()
        return try knowledgeStore().canonicalContentCleanupCandidates(
            limit: limit,
            pendingIngestionOnly: pendingIngestionOnly,
            now: now
        )
    }

    func canonicalContentCleanupQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().canonicalContentCleanupQueueCount()
    }

    func nextCanonicalContentCleanupRetryDate() throws -> Date? {
        try ensureStoreExists()
        return try knowledgeStore().nextCanonicalContentCleanupRetryDate()
    }

    func pruneIneligibleCanonicalContentCleanupQueue() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().pruneIneligibleCanonicalContentCleanupQueue()
    }

    @discardableResult
    func recordCanonicalContentCleanupFailure(
        sourceID: String,
        message: String,
        sourceSHA256: String? = nil,
        consumesAttempt: Bool = true
    ) throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().recordCanonicalContentCleanupFailure(
            sourceID: sourceID,
            message: message,
            sourceSHA256: sourceSHA256,
            consumesAttempt: consumesAttempt
        )
    }

    func failPendingCanonicalContentCleanup(
        candidate: CanonicalContentCleanupCandidate,
        message: String
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().failPendingCanonicalContentCleanup(
            candidate: candidate,
            message: message
        )
        scheduleCloudKitSync(.coalesced)
    }

    func clearCompletedCanonicalContentCleanupFailure(sourceID: String) throws -> Bool {
        try ensureStoreExists()
        let changed = try knowledgeStore().clearCompletedCanonicalContentCleanupFailure(
            sourceID: sourceID
        )
        if changed { scheduleCloudKitSync(.coalesced) }
        return changed
    }

    /// See `KnowledgeStore.auditCanonicalContentIntegrity`.
    func auditCanonicalContentIntegrity(
        limit: Int
    ) throws -> (audited: Int, requeuedSourceIDs: [String], remaining: Int) {
        try ensureStoreExists()
        let result = try knowledgeStore().auditCanonicalContentIntegrity(limit: limit)
        if !result.requeuedSourceIDs.isEmpty { scheduleCloudKitSync(.coalesced) }
        return result
    }

    func applyCanonicalContentCleanup(
        candidate: CanonicalContentCleanupCandidate,
        prepared: PreparedPaperContent
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().applyCanonicalContentCleanup(candidate: candidate, prepared: prepared)
        removeFromSearchIndexes(candidate.sourceID)
        scheduleCloudKitSync(.coalesced)
    }

    /// The Dev build's substitute for `applyCanonicalContentCleanup`: the raw
    /// text is published as-is and no model is called. See
    /// `PaidSourceCleanupPolicy`.
    func publishCanonicalContentWithoutCleanup(
        candidate: CanonicalContentCleanupCandidate
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().publishCanonicalContentWithoutCleanup(candidate: candidate)
        removeFromSearchIndexes(candidate.sourceID)
        scheduleCloudKitSync(.coalesced)
    }

    func podcastTranscriptCleanupCandidates(
        limit: Int,
        formattingOnly: Bool = false
    ) throws -> [PodcastTranscriptCleanupCandidate] {
        try ensureStoreExists()
        return try knowledgeStore().podcastTranscriptCleanupCandidates(
            limit: limit,
            formattingOnly: formattingOnly
        )
    }

    func podcastTranscriptCleanupQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().podcastTranscriptCleanupQueueCount()
    }

    func recordPodcastTranscriptCleanupFailure(
        sourceID: String,
        message: String,
        sourceSHA256: String,
        consumesAttempt: Bool
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().recordPodcastTranscriptCleanupFailure(
            sourceID: sourceID,
            message: message,
            sourceSHA256: sourceSHA256,
            consumesAttempt: consumesAttempt
        )
    }

    func applyPodcastTranscriptCleanup(
        candidate: PodcastTranscriptCleanupCandidate,
        prepared: PreparedPodcastTranscriptCleanup
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().applyPodcastTranscriptCleanup(candidate: candidate, prepared: prepared)
        removeFromSearchIndexes(candidate.sourceID)
        scheduleCloudKitSync(.coalesced)
    }

    func restorePodcastTranscriptCleanups(limit: Int) throws -> [String] {
        try ensureStoreExists()
        let sourceIDs = try knowledgeStore().restorePodcastTranscriptCleanups(limit: limit)
        for sourceID in sourceIDs { removeFromSearchIndexes(sourceID) }
        if !sourceIDs.isEmpty { scheduleCloudKitSync(.coalesced) }
        return sourceIDs
    }

    // MARK: - Background AI spend control (schema 135)

    /// Dollars background AI tasks spent in `[start, end)`, own-key calls
    /// included (`BackgroundAIBudget`).
    func backgroundAISpendUSD(from start: Date, to end: Date) throws -> Double {
        try ensureStoreExists()
        return try knowledgeStore().backgroundAISpendUSD(from: start, to: end)
    }

    /// Bulk re-queues waiting for the learner, with counts and estimates.
    func pendingBackgroundAIBulkJobs() throws -> [BackgroundAIBulkJob] {
        try ensureStoreExists()
        return try knowledgeStore().pendingBackgroundAIBulkJobs()
    }

    /// Applies the learner's choice and starts the drains on what it released.
    func decideBackgroundAIBulkJob(
        id: String,
        decision: BackgroundAIBulkDecision
    ) throws -> KnowledgeStore.BackgroundAIBulkDecisionOutcome {
        try ensureStoreExists()
        let outcome = try knowledgeStore().decideBackgroundAIBulkJob(id: id, decision: decision)
        NotificationCenter.default.post(name: .backgroundAIBulkJobsDidChange, object: nil)
        if outcome.releasedCount > 0 {
            NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
        }
        return outcome
    }

    /// Released bulk re-queues the drains are still working through.
    func runningBackgroundAIBulkJobs() throws -> [KnowledgeStore.RunningBackgroundAIBulkJob] {
        try ensureStoreExists()
        return try knowledgeStore().runningBackgroundAIBulkJobs()
    }

    /// Stops a released run; what is left waits for the learner again.
    func stopBackgroundAIBulkJob(id: String) throws -> KnowledgeStore.BackgroundAIBulkStopOutcome {
        try ensureStoreExists()
        let outcome = try knowledgeStore().stopBackgroundAIBulkJob(id: id)
        NotificationCenter.default.post(name: .backgroundAIBulkJobsDidChange, object: nil)
        return outcome
    }

    func nextSourceListenableContentCandidate() throws -> SourceListenableContentCandidate? {
        try ensureStoreExists()
        return try knowledgeStore().nextSourceListenableContentCandidate()
    }

    /// Queues one source's Listen preparation for automatic audio that found
    /// none ready, and wakes the drain.
    func queueSourceListenableContentPreparation(sourceID: String) throws {
        try ensureStoreExists()
        if try knowledgeStore().queueSourceListenableContentPreparation(sourceID: sourceID) {
            NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
        }
    }

    func sourceListenableContentCandidates(limit: Int) throws -> [SourceListenableContentCandidate] {
        try ensureStoreExists()
        return try knowledgeStore().sourceListenableContentCandidates(limit: limit)
    }

    func sourceListenableContentQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().sourceListenableContentQueueCount()
    }

    func recordSourceListenableContentFailure(
        sourceID: String,
        message: String,
        sourceSHA256: String
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().recordSourceListenableContentFailure(
            sourceID: sourceID,
            message: message,
            sourceSHA256: sourceSHA256
        )
    }

    func applySourceListenableContent(
        candidate: SourceListenableContentCandidate,
        text: String,
        preparationSignature: String?
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().applySourceListenableContent(
            candidate: candidate,
            text: text,
            preparationSignature: preparationSignature
        )
        scheduleCloudKitSync(.coalesced)
    }

    func loadSourceListenableContent(_ sourceID: String) throws -> StoredSourceListenableContent? {
        try ensureStoreExists()
        return try knowledgeStore().loadSourceListenableContent(sourceID)
    }

    func sourceListenableContentSummaries(
        for sourceIDs: [String]
    ) -> [String: SourceListenableContentSummary] {
        guard let ks = try? knowledgeStore() else { return [:] }
        return (try? ks.sourceListenableContentSummaries(for: sourceIDs)) ?? [:]
    }

    func sourceReviewGuideCandidate(sourceID: String) throws -> SourceReviewGuideCandidate? {
        try ensureStoreExists()
        return try knowledgeStore().sourceReviewGuideCandidate(sourceID: sourceID)
    }

    func ensureSourceReviewGuidePreparationQueued(sourceID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().ensureSourceReviewGuidePreparation(sourceID: sourceID)
    }

    func likelyReviewSourceIDsWithoutGuide(
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        lookbackDays: Int,
        limit: Int
    ) throws -> [String] {
        try ensureStoreExists()
        return try knowledgeStore().likelyReviewSourceIDsWithoutGuide(
            now: now,
            calendar: calendar,
            lookbackDays: lookbackDays,
            limit: limit
        )
    }

    func sourceReviewGuideQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().sourceReviewGuideQueueCount()
    }

    func recordSourceReviewGuideFailure(sourceID: String, message: String) throws {
        try ensureStoreExists()
        try knowledgeStore().recordSourceReviewGuideFailure(sourceID: sourceID, message: message)
    }

    func applySourceReviewGuide(candidate: SourceReviewGuideCandidate, guide: String) throws {
        try ensureStoreExists()
        try knowledgeStore().applySourceReviewGuide(candidate: candidate, guide: guide)
        scheduleCloudKitSync(.coalesced)
    }

    func loadSourceReviewGuide(_ sourceID: String) throws -> SourceReviewGuide? {
        try ensureStoreExists()
        return try knowledgeStore().loadSourceReviewGuide(sourceID)
    }

    // MARK: Walkthroughs

    /// The paper's walkthrough, when it has one for its current text.
    func loadPaperWalkthrough(_ sourceID: String) throws -> PaperWalkthrough? {
        try ensureStoreExists()
        return try knowledgeStore().loadPaperWalkthrough(sourceID)
    }

    /// Every source's walkthrough as `list_walkthroughs` lists it, newest
    /// first (`PaperWalkthroughSummary`).
    func paperWalkthroughSummaries() throws -> [PaperWalkthroughSummary] {
        try ensureStoreExists()
        return try knowledgeStore().paperWalkthroughSummaries()
    }

    /// The walkthroughs of `sourceIDs` alone, newest first: a notebook's
    /// Studio lists its own sources' walks without decoding the library's.
    func paperWalkthroughSummaries(forSources sourceIDs: [String]) throws -> [PaperWalkthroughSummary] {
        try ensureStoreExists()
        return try knowledgeStore().paperWalkthroughSummaries(forSources: sourceIDs)
    }

    /// Whether the paper has any walkthrough row, current or stale.
    func hasPaperWalkthrough(_ sourceID: String) throws -> Bool {
        try ensureStoreExists()
        return try knowledgeStore().hasPaperWalkthroughRow(sourceID)
    }

    /// `ok` or `stale` for each of the ids that has a walkthrough row; absent
    /// for the rest. One query for a Planner day or a `get_day_plan` answer.
    func paperWalkthroughStatuses(for sourceIDs: some Collection<String>) throws -> [String: PaperWalkthroughStatus] {
        try ensureStoreExists()
        return try knowledgeStore().paperWalkthroughStatuses(for: sourceIDs)
    }

    func savePaperWalkthrough(_ walkthrough: PaperWalkthrough) throws {
        try ensureStoreExists()
        try knowledgeStore().savePaperWalkthrough(walkthrough)
        scheduleCloudKitSync(.coalesced)
    }

    @discardableResult
    func deletePaperWalkthrough(_ sourceID: String) throws -> Bool {
        try ensureStoreExists()
        let removed = try knowledgeStore().deletePaperWalkthrough(sourceID)
        if removed { scheduleCloudKitSync(.coalesced) }
        return removed
    }

    // MARK: Walkthrough progress

    /// Where the learner is in the walk of `subjectID` (a source or an
    /// animation), and how its questions went.
    func loadWalkthroughProgress(_ subjectID: String) throws -> WalkthroughProgress? {
        try ensureStoreExists()
        return try knowledgeStore().loadWalkthroughProgress(subjectID)
    }

    func saveWalkthroughProgress(_ progress: WalkthroughProgress) throws {
        try ensureStoreExists()
        try knowledgeStore().saveWalkthroughProgress(progress)
        scheduleCloudKitSync(.coalesced)
    }

    /// A graded question about a source — a walkthrough's or a course
    /// quiz's — as a Memory attempt, a miss keeping its card
    /// (`KnowledgeStore.recordSourceQuestionAttempt`).
    func recordSourceQuestionAttempt(
        _ question: SourceMemoryQuestion,
        answer: String,
        feedback: String,
        score: Double,
        rating: MemoryScheduleRating
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().recordSourceQuestionAttempt(
            question,
            answer: answer,
            feedback: feedback,
            score: score,
            rating: rating
        )
        scheduleCloudKitSync(.soon)
    }

    // MARK: Animation walkthroughs

    /// The animation's walkthrough, when it has one for its current address.
    func loadArtifactWalkthrough(_ artifactID: String) throws -> PaperWalkthrough? {
        try ensureStoreExists()
        return try knowledgeStore().loadArtifactWalkthrough(artifactID)
    }

    /// Whether the animation has any walkthrough row, current or stale.
    func hasArtifactWalkthrough(_ artifactID: String) throws -> Bool {
        try ensureStoreExists()
        return try knowledgeStore().hasArtifactWalkthroughRow(artifactID)
    }

    /// Every artifact with a walkthrough row, for the Animations list.
    func artifactIDsWithWalkthroughs() throws -> Set<String> {
        try ensureStoreExists()
        return try knowledgeStore().artifactIDsWithWalkthroughs()
    }

    func saveArtifactWalkthrough(_ walkthrough: PaperWalkthrough) throws {
        try ensureStoreExists()
        try knowledgeStore().saveArtifactWalkthrough(walkthrough)
        scheduleCloudKitSync(.coalesced)
    }

    @discardableResult
    func deleteArtifactWalkthrough(_ artifactID: String) throws -> Bool {
        try ensureStoreExists()
        let removed = try knowledgeStore().deleteArtifactWalkthrough(artifactID)
        if removed { scheduleCloudKitSync(.coalesced) }
        return removed
    }

    /// One artifact by id, or nil.
    func loadArtifact(_ artifactID: String) throws -> ArtifactRecord? {
        try ensureStoreExists()
        return try knowledgeStore().loadArtifact(artifactID)
    }

    func sourceReviewGuideFailure(_ sourceID: String) throws -> String? {
        try ensureStoreExists()
        return try knowledgeStore().sourceReviewGuideFailure(sourceID: sourceID)
    }

    /// Stored content length per source, without materializing the text or
    /// deriving anything from local files.
    ///
    /// Deliberately does not fall back to `deriveLocalSourceContent` the way
    /// `loadSourceContent` does: the callers here are sizing a catalog, not
    /// reading it, and per-source PDF extraction or Vision OCR across a whole
    /// notebook pool is exactly the blocking work this is meant to replace.
    func sourceContentLengths(for sourceIDs: [String]) -> [String: Int] {
        guard let ks = try? knowledgeStore() else { return [:] }
        return (try? ks.sourceContentLengths(for: sourceIDs)) ?? [:]
    }

    /// A book's display title by group id, for the Now Playing subtitle and
    /// the synced audio manifest. Nil when the store has no title for it.
    func bookTitle(forGroupID groupID: String) -> String? {
        guard let ks = try? knowledgeStore() else { return nil }
        return (try? ks.bookTitle(forGroupID: groupID)) ?? nil
    }

    /// Search persisted source text without deriving missing local-file content.
    /// Used by explicit All-tab searches so cached book chapter text can match
    /// even when it is not loaded into `StudioArticle.content`.
    func searchSourceContent(query: String, maxResults: Int = 300) -> [String: Float] {
        guard let ks = try? knowledgeStore() else { return [:] }
        guard let excludedSources = try? ks.knowledgeSearchExcludedSourceIDs() else { return [:] }
        return (try? ks.searchSourceContent(
            query: query,
            maxResults: maxResults,
            excludedSources: excludedSources
        )) ?? [:]
    }

    private func isLocalPDFBackedSource(_ article: StudioArticle) -> Bool {
        let candidatePath = article.localFilePath ?? article.url
        guard !candidatePath.hasPrefix("http://"), !candidatePath.hasPrefix("https://") else { return false }
        return candidatePath.lowercased().hasSuffix(".pdf")
    }

    func clearSourceDerivedData(_ sourceId: String) {
        guard let ks = try? knowledgeStore() else { return }
        try? ks.clearSourceDerivedData(sourceId)
    }

    private static let derivationLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
        category: "Performance"
    )

    /// Text for a source whose only copy is a local file. Static and
    /// nonisolated so `loadSourceContent` can run it off the storage actor:
    /// a whole-book PDF extraction is seconds of CPU that must not hold the
    /// lane every read shares.
    nonisolated static func deriveLocalSourceContent(for article: StudioArticle) -> String? {
        let candidatePath = article.localFilePath ?? article.url
        guard !candidatePath.hasPrefix("http://"), !candidatePath.hasPrefix("https://"),
              let resolvedURL = SourceService.resolveLocalFileURL(candidatePath) else {
            return nil
        }
        let path = resolvedURL.path
        let ext = resolvedURL.pathExtension.lowercased()
        // A chapter of an EPUB book kept as one file is an entry of it, not a file.
        if ["html", "htm", "xhtml"].contains(ext), EPUBBookFiles.location(ofPath: path) != nil {
            guard let raw = EPUBBookFiles.text(atPath: path) else { return nil }
            let text = EPUBParser.stripHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        guard ensureICloudFileDownloaded(at: resolvedURL, fileManager: .default) else { return nil }

        do {
            switch ext {
            case "pdf":
                #if canImport(PDFKit)
                guard let document = PDFDocument(url: resolvedURL) else { return nil }
                // A book chapter's text is its pages of the book's file.
                let pages = article.bookPages ?? 0..<document.pageCount
                guard pages.upperBound <= document.pageCount else { return nil }
                let text = PDFTextExtractor.textWithFigureReferences(from: document, pages: pages)
                return text.isEmpty ? nil : text
                #else
                return nil
                #endif
            case "ttml":
                let raw = try String(contentsOf: resolvedURL, encoding: .utf8)
                return try? SourceService.extractTextFromTTMLContent(raw)
            case "html", "htm", "xhtml":
                let raw = try String(contentsOf: resolvedURL, encoding: .utf8)
                return EPUBParser.stripHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            default:
                let raw = try String(contentsOf: resolvedURL, encoding: .utf8)
                let trimmed = raw.removingSoftHyphens().trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        } catch {
            derivationLogger.error("Failed to derive source content from \(path, privacy: .public): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Legacy Content Consolidation

    /// Throttle so launch plus repeated foreground activations cannot start two
    /// large consolidation walks. Every move is independently resumable.
    private static let legacyConsolidationLock = NSLock()
    private nonisolated(unsafe) static var lastLegacyConsolidationStartedAt: Date?
    private nonisolated(unsafe) static var legacyConsolidationIsRunning = false
    private static let legacyConsolidationThrottle: TimeInterval = 300
    private static let legacyConsolidationDefaultsKey =
        "StorageService.didConsolidateLegacyContent.v1"

    /// Drain historical iCloud/CloudDocs/Documents trees into the canonical
    /// local root. Audio moves to the one canonical private-container `Audio/`
    /// directory because iPhone playback still consumes that transport.
    ///
    /// Completion is versioned, but a cheap root-level presence check re-arms
    /// the worker if CloudDocs later resurrects a legacy folder. All work stays
    /// detached from the main actor.
    static func scheduleLegacyContentConsolidation(initialDelay: TimeInterval = 0) {
        Task.detached(priority: .utility) {
            let shouldProceed = legacyConsolidationLock.withLock { () -> Bool in
                if legacyConsolidationIsRunning { return false }
                if let last = lastLegacyConsolidationStartedAt,
                   Date().timeIntervalSince(last) < legacyConsolidationThrottle {
                    return false
                }
                lastLegacyConsolidationStartedAt = Date()
                legacyConsolidationIsRunning = true
                return true
            }
            guard shouldProceed else { return }
            defer {
                legacyConsolidationLock.withLock {
                    legacyConsolidationIsRunning = false
                }
            }
            if initialDelay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(initialDelay * 1_000_000_000))
                } catch {
                    return
                }
            }

            let roots = legacyContentRootDescriptors()
            let defaults = UserDefaults.standard
            let alreadyCompleted = defaults.bool(forKey: legacyConsolidationDefaultsKey)
            let hasMigratableContent = rootsContainMigratableContent(roots)
            guard hasMigratableContent else {
                if !alreadyCompleted {
                    defaults.set(true, forKey: legacyConsolidationDefaultsKey)
                }
                return
            }

            let logger = Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
                category: "StorageMigration"
            )
            let report = LegacyContentConsolidator.consolidate(
                roots: roots,
                contentRoot: URL(fileURLWithPath: localContentRootPath, isDirectory: true),
                canonicalAudioRoot: URL(
                    fileURLWithPath: ubiquityContentRootPath,
                    isDirectory: true
                ).appendingPathComponent("Audio", isDirectory: true)
            ) { progress in
                logger.info(
                    "Legacy content: consolidated \(progress.changedFileCount) file(s)"
                )
            }

            if report.changedFileCount > 0 {
                await publishLegacyContentMigration()
            }
            if report.isComplete && !rootsContainMigratableContent(roots) {
                defaults.set(true, forKey: legacyConsolidationDefaultsKey)
            }
            if !report.failures.isEmpty {
                logger.error(
                    "Legacy content: \(report.failures.count) failure(s); first: \(report.failures[0], privacy: .public)"
                )
            } else if report.pendingDownloads > 0 {
                logger.info(
                    "Legacy content: requested \(report.pendingDownloads) iCloud download(s); activation will resume"
                )
            } else if report.changedFileCount > 0 || !report.removedRoots.isEmpty {
                logger.info(
                    "Legacy content complete: installed \(report.installed), deduplicated \(report.deduplicated), preserved \(report.conflictsPreserved) conflict(s), removed \(report.removedRoots.count) root(s)"
                )
            }

            #if os(macOS)
            _ = await ArticleArchiveCache.shared.warmExistingArchives(
                canonicalArticlesRoot: URL(
                    fileURLWithPath: localContentRootPath,
                    isDirectory: true
                ).appendingPathComponent("Articles", isDirectory: true)
            )
            #endif
        }
    }

    /// NotificationCenter delivers synchronously on the posting thread. Both
    /// notifications below feed SwiftUI `onReceive` closures, so publishing them
    /// from the detached migration task would mutate observable UI state off-main.
    // MARK: - Book folder adoption

    private static let bookFolderAdoptionDefaultsKey = "StorageService.didAdoptBookFolderNames.v1"
    private nonisolated(unsafe) static var bookFolderAdoptionIsRunning = false
    private static let bookFolderAdoptionLock = NSLock()

    /// The one directory imported books live in, under this instance's content
    /// root — the same place `importBook` writes and the store's relative
    /// `Books/…` paths resolve against.
    var booksDirectoryURL: URL {
        contentRoot.appendingPathComponent("Books", isDirectory: true)
    }

    /// Drop the archive tag from the book folders that were imported before
    /// `BookFolderNaming` existed, on disk and in every row that names them.
    ///
    /// Disk first, then rows, one book at a time. A folder that will not move
    /// keeps its rows; rows are rewritten only once the clean folder is really
    /// there, so at no point does a chapter URL name a folder that does not
    /// exist. The store's own enumeration of tagged references is the safety
    /// net for a run that stopped between the two halves.
    ///
    /// Bounded by the number of books, which is small everywhere, and by the
    /// number of chapter rows for the rewrite. Not a startup migration: it
    /// touches files, so it runs from the launch-time deferred pass below,
    /// off-main, and retires itself through UserDefaults once nothing tagged
    /// remains.
    func adoptTaggedBookFolders() throws -> BookFolderAdoption.Report {
        let fm = FileManager.default
        let booksDirectory = booksDirectoryURL
        var report = BookFolderAdoption.Report()

        for rename in BookFolderAdoption.plannedRenames(in: booksDirectory, fileManager: fm) {
            do {
                if try BookFolderAdoption.performRename(rename, in: booksDirectory, fileManager: fm) {
                    report.renamed.append(rename)
                } else {
                    report.skippedBecauseDestinationExists.append(rename.oldName)
                }
            } catch {
                report.failed.append(rename.oldName)
                migrationLogger.error(
                    "Book folder rename failed for \(rename.oldName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        try ensureStoreExists()
        let ks = try knowledgeStore()
        var taggedNames = try ks.referencedTaggedBookFolderNames()
        taggedNames.formUnion(report.renamed.map(\.oldName))
        for oldName in taggedNames.sorted() {
            let newName = BookFolderNaming.cleanedFolderName(fromFileBaseName: oldName)
            guard newName != oldName else { continue }
            let cleanFolder = booksDirectory.appendingPathComponent(newName, isDirectory: true).path
            let taggedFolder = booksDirectory.appendingPathComponent(oldName, isDirectory: true).path
            // Rows follow the folder. If the tagged folder is still there the
            // rename did not happen (or the clean name is taken by another
            // edition), and rewriting the rows would point them at the wrong
            // book. If neither exists there is nothing to point them at.
            guard !fm.fileExists(atPath: taggedFolder), fm.fileExists(atPath: cleanFolder) else {
                if !report.skippedBecauseDestinationExists.contains(oldName), !report.failed.contains(oldName) {
                    report.unresolvedReferences.append(oldName)
                }
                continue
            }
            report.rewrittenChapterCount += try ks.rewriteBookFolderReferences(from: oldName, to: newName)
        }

        if report.didChangeAnything {
            StudioArticle.invalidateAllResolvedPathCaches()
            // Observers of these are views and the view model; like the legacy
            // consolidator's, the posts are delivered on the main thread.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .syncedArtworkDidInstall, object: nil)
                // Rows changed underneath the view model's snapshot; this is the
                // same event an inbound CloudKit change raises, and it reloads
                // from the store rather than merely re-resolving cached paths.
                NotificationCenter.default.post(
                    name: .cloudKitSyncRemoteStoreDidChange,
                    object: nil,
                    userInfo: [
                        CloudKitSyncNotificationInfo.affectedEntitiesKey: [
                            CloudKitSyncEntity.source.rawValue,
                            CloudKitSyncEntity.book.rawValue,
                        ],
                        CloudKitSyncNotificationInfo.requiresFullRefreshKey: true,
                    ]
                )
            }
        }
        return report
    }

    /// Run `adoptTaggedBookFolders()` once per install, a few seconds after
    /// launch so first paint never waits on it. A complete run sets the
    /// defaults flag and later launches cost one `bool(forKey:)`; an incomplete
    /// one — a folder that would not move — runs again next launch.
    static func scheduleBookFolderAdoptionAfterLaunch(storage: StorageService) {
        guard !LegacyIdentityAdoption.isRunningAutomatedTests else { return }
        guard !UserDefaults.standard.bool(forKey: bookFolderAdoptionDefaultsKey) else { return }
        Task.detached(priority: .utility) {
            let shouldProceed = bookFolderAdoptionLock.withLock { () -> Bool in
                if bookFolderAdoptionIsRunning { return false }
                bookFolderAdoptionIsRunning = true
                return true
            }
            guard shouldProceed else { return }
            defer { bookFolderAdoptionLock.withLock { bookFolderAdoptionIsRunning = false } }
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                return
            }
            let logger = Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
                category: "StorageMigration"
            )
            do {
                let report = try await storage.adoptTaggedBookFolders()
                if report.didChangeAnything {
                    logger.notice(
                        "Book folders: renamed \(report.renamed.count) folder(s), rewrote \(report.rewrittenChapterCount) chapter path(s)"
                    )
                }
                if report.isComplete {
                    UserDefaults.standard.set(true, forKey: bookFolderAdoptionDefaultsKey)
                } else {
                    logger.error(
                        "Book folders: \(report.skippedBecauseDestinationExists.count) skipped (clean name taken), \(report.failed.count) failed, \(report.unresolvedReferences.count) unresolved; will retry next launch"
                    )
                }
            } catch {
                logger.error("Book folder adoption failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Keep the file walk detached, then make only this small publication hop.
    @MainActor
    static func publishLegacyContentMigration() {
        StudioArticle.invalidateAllResolvedPathCaches()
        NotificationCenter.default.post(name: .syncedArtworkDidInstall, object: nil)
        NotificationCenter.default.post(name: .legacyContentDidMigrate, object: nil)
    }

    static func scheduleLegacyContentConsolidationAfterLaunch() {
        scheduleLegacyContentConsolidation(initialDelay: 2)
    }

    /// Historical content roots are migration inputs, not permanent homes. They
    /// stay in the resolver only while a verified per-file move is pending.
    static var legacyICloudContentRoots: [URL] {
        #if DEBUG
        // The transcript maintenance runner needs only SQLite. Avoid touching
        // historical CloudDocs roots, which can block while an evicted parent
        // downloads metadata and are unrelated to this bounded backfill.
        if ProcessInfo.processInfo.arguments.contains("--run-podcast-cleanup") {
            return []
        }
        #endif
        let localRoots: Set<String> = [libraryRootPath, localContentRootPath]
        let named = knownContentRoots
            .filter { !localRoots.contains($0) }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        var seen = Set<String>()
        return (named + numberedConflictRoots).filter {
            seen.insert($0.standardizedFileURL.path).inserted
                && FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private static func legacyContentRootDescriptors() -> [LegacyContentRoot] {
        let canonicalContainer = URL(
            fileURLWithPath: ubiquityContentRootPath,
            isDirectory: true
        ).standardizedFileURL.path
        return legacyICloudContentRoots.map { url in
            let path = url.standardizedFileURL.path
            let namespace: String
            if path == canonicalContainer {
                namespace = "Private iCloud"
            } else if path.contains("com~apple~CloudDocs") {
                namespace = "iCloud Drive"
            } else if url.lastPathComponent != "ForeverLM" {
                namespace = "Private iCloud \(url.lastPathComponent)"
            } else {
                namespace = "Documents"
            }
            return LegacyContentRoot(
                id: namespace,
                url: url,
                preservesRootForCanonicalAudio: path == canonicalContainer
            )
        }
    }

    private static func rootsContainMigratableContent(_ roots: [LegacyContentRoot]) -> Bool {
        let fileManager = FileManager.default
        for root in roots {
            guard let children = try? fileManager.contentsOfDirectory(
                at: root.url,
                includingPropertiesForKeys: nil
            ) else { continue }
            if root.preservesRootForCanonicalAudio {
                if children.contains(where: { $0.lastPathComponent != "Audio" }) {
                    return true
                }
            } else if !children.isEmpty {
                return true
            }
        }
        return false
    }

    /// Check whether a specific iCloud file is a placeholder (.icloud stub) and trigger
    /// its download if so. Returns true if the real file exists and is ready to read.
    func ensureICloudFileDownloaded(at url: URL) -> Bool {
        Self.ensureICloudFileDownloaded(at: url, fileManager: fileManager)
    }

    nonisolated static func ensureICloudFileDownloaded(at url: URL, fileManager: FileManager) -> Bool {
        if fileManager.fileExists(atPath: url.path) {
            return true
        }
        // Check for .icloud placeholder: parent/.filename.icloud
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        if fileManager.fileExists(atPath: placeholder.path) {
            try? fileManager.startDownloadingUbiquitousItem(at: placeholder)
        }
        return false
    }

    // MARK: - Source Index

    /// Normalize a source path so that sources from different machines
    /// (different macOS usernames) or with different path formats (absolute vs relative)
    /// map to the same key. Uses `relativeSourcePath` so both `/Users/foo/.../Courses/X.pdf`
    /// and `Courses/X.pdf` normalize to `Courses/X.pdf`.
    /// Web URLs are returned unchanged.
    static func normalizedSourceKey(_ url: String) -> String {
        relativeSourcePath(url)
    }

    // MARK: - Reading List

    func loadSources() throws -> [StudioArticle] {
        try ensureStoreExists()
        return try knowledgeStore().loadSourcesWithoutContent()
    }

    /// Lenient batch read by id — returns only the rows that exist, skipping any
    /// missing ids instead of throwing. Use when a stale in-memory snapshot must
    /// be reconciled against the freshest persisted truth (e.g. metadata backfill).
    func loadPersistedSources(ids: [String]) throws -> [StudioArticle] {
        try ensureStoreExists()
        let store = try knowledgeStore()
        var sources: [StudioArticle] = []
        var seen = Set<String>()
        for id in ids {
            let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanID.isEmpty, seen.insert(cleanID).inserted else { continue }
            if let source = try store.loadSourceForSync(cleanID) {
                sources.append(source)
            }
        }
        return sources
    }

    func loadSourcesForExport(sourceIDs: [String]) throws -> [StudioArticle] {
        try ensureStoreExists()
        let uniqueIDs = sourceIDs.reduce(into: [String]()) { result, sourceID in
            let cleanID = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanID.isEmpty, !result.contains(cleanID) else { return }
            result.append(cleanID)
        }

        var sources: [StudioArticle] = []
        var missingIDs: [String] = []
        for sourceID in uniqueIDs {
            if let source = try knowledgeStore().loadSourceForSync(sourceID) {
                sources.append(source)
            } else {
                missingIDs.append(sourceID)
            }
        }
        guard missingIDs.isEmpty else {
            throw KnowledgeStoreError.invalidData("Could not export Notebook sources because \(missingIDs.count) linked source(s) could not be loaded: \(missingIDs.joined(separator: ", "))")
        }
        return sources
    }

    // MARK: - Dismissed Sources

    // MARK: - User preferences

    /// Persist a locally-changed preference and queue it for CloudKit.
    func writePreference(key: String, valuePlistXML: String) throws {
        try knowledgeStore().writePreference(key: key, valuePlistXML: valuePlistXML)
    }

    /// Clear a preference locally and tombstone it for CloudKit.
    func deletePreference(key: String) throws {
        try knowledgeStore().deletePreference(key: key)
    }

    /// Every stored preference as `key -> plist XML`, for rehydrating UserDefaults.
    func allPreferences() throws -> [String: String] {
        try knowledgeStore().loadAllPreferences()
    }

    /// When each of `keys` was last written, on whatever device wrote it: the
    /// row's `updated_at`, which an inbound row takes from its payload. A key
    /// with no row is left out. One lookup per key, for the few rows a caller
    /// names.
    func preferenceWriteDates(keys: [String]) throws -> [String: Date] {
        let store = try knowledgeStore()
        var dates: [String: Date] = [:]
        for key in Set(keys) {
            if let row = try store.loadPreferenceForSync(key) {
                dates[key] = row.updatedAt
            }
        }
        return dates
    }

    /// Rewrite preference rows stored in a form hydration cannot read, and report
    /// what was repaired and what could not be.
    func repairUnreadablePreferences() throws -> KnowledgeStore.PreferenceRepairReport {
        try knowledgeStore().repairUnreadablePreferences()
    }

    func dismissSources(_ articles: [StudioArticle]) throws {
        try ensureStoreExists()
        let ks = try knowledgeStore()
        for article in articles {
            try ks.dismissSource(url: article.url, title: article.title)
            if let webURL = article.podcastWebPageURL {
                try ks.dismissSource(url: webURL, title: article.title)
            }
        }
        scheduleCloudKitSync(.immediate)
    }

    func loadDismissedSourceURLs() throws -> Set<String> {
        try ensureStoreExists()
        return try knowledgeStore().loadDismissedSourceURLs()
    }

    /// Dismissal timestamps keyed by the stored URL.
    func loadDismissedSourceDates() throws -> [String: Date] {
        try ensureStoreExists()
        return try knowledgeStore().loadDismissedSourceDates()
    }

    func loadHiddenPodcastShows() throws -> Set<String> {
        try ensureStoreExists()
        return try knowledgeStore().loadHiddenPodcastShows()
    }

    /// Returns the ids of episodes an unhide revealed along with the show.
    @discardableResult
    func setPodcastShowHidden(_ showName: String, hidden: Bool) throws -> [String] {
        try ensureStoreExists()
        let revealed = try knowledgeStore().setPodcastShowHidden(showName, hidden: hidden)
        scheduleCloudKitSync(.immediate)
        return revealed
    }

    func loadHiddenYouTubeChannels() throws -> Set<String> {
        try ensureStoreExists()
        return try knowledgeStore().loadHiddenYouTubeChannels()
    }

    func setYouTubeChannelHidden(_ channelName: String, hidden: Bool) throws {
        try ensureStoreExists()
        try knowledgeStore().setYouTubeChannelHidden(channelName, hidden: hidden)
        scheduleCloudKitSync(.immediate)
    }

    func loadHiddenPodcastEpisodeIDs() throws -> Set<String> {
        try ensureStoreExists()
        return try knowledgeStore().loadHiddenPodcastEpisodeIDs()
    }

    func setPodcastEpisodeHidden(_ sourceID: String, hidden: Bool) throws {
        try ensureStoreExists()
        try knowledgeStore().setPodcastEpisodeHidden(sourceID, hidden: hidden)
        scheduleCloudKitSync(.immediate)
    }

    func setSourceHidden(_ sourceID: String, hidden: Bool) throws {
        try ensureStoreExists()
        try knowledgeStore().setSourceHidden(sourceID, hidden: hidden)
        scheduleCloudKitSync(.immediate)
    }

    func loadVisiblePodcastEpisodeOverrideIDs() throws -> Set<String> {
        try ensureStoreExists()
        return try knowledgeStore().loadVisiblePodcastEpisodeOverrideIDs()
    }

    func setPodcastEpisodeVisibleOverride(_ sourceID: String, visible: Bool) throws {
        try ensureStoreExists()
        try knowledgeStore().setPodcastEpisodeVisibleOverride(sourceID, visible: visible)
        scheduleCloudKitSync(.immediate)
    }

    func loadVisibleYouTubeVideoOverrideIDs() throws -> Set<String> {
        try ensureStoreExists()
        return try knowledgeStore().loadVisibleYouTubeVideoOverrideIDs()
    }

    func setYouTubeVideoVisibleOverride(_ sourceID: String, visible: Bool) throws {
        try ensureStoreExists()
        try knowledgeStore().setYouTubeVideoVisibleOverride(sourceID, visible: visible)
        scheduleCloudKitSync(.immediate)
    }

    // MARK: - Books

    struct BookRecord {
        var titles: [String: String]
        var subtitles: [String: String]
        var authors: [String: String]
        var editions: [String: String]
        var coverPaths: [String: String]
        var kinds: [String: String]
    }

    func loadBooks() throws -> BookRecord {
        try ensureStoreExists()
        let row = try knowledgeStore().loadBooks()
        return BookRecord(
            titles: row.titles,
            subtitles: row.subtitles,
            authors: row.authors,
            editions: row.editions,
            coverPaths: row.coverPaths,
            kinds: row.kinds
        )
    }

    func saveBooks(
        titles: [String: String] = [:],
        subtitles: [String: String] = [:],
        authors: [String: String],
        editions: [String: String] = [:],
        coverPaths: [String: String] = [:],
        kinds: [String: String] = [:]
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().saveBooks(
            titles: titles,
            subtitles: subtitles,
            authors: authors,
            editions: editions,
            coverPaths: coverPaths,
            kinds: kinds
        )
        scheduleCloudKitSync()
    }

    func saveBookMetadata(
        groupName: String,
        title: String? = nil,
        subtitle: String? = nil,
        author: String? = nil,
        edition: String? = nil,
        coverPath: String?,
        kind: String? = nil
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().saveBookMetadata(
            groupName: groupName,
            title: title,
            subtitle: subtitle,
            author: author,
            edition: edition,
            coverPath: coverPath,
            kind: kind
        )
        scheduleCloudKitSync()
    }

    func renameBookGroup(from oldName: String, to newName: String) throws {
        try ensureStoreExists()
        try knowledgeStore().renameBookGroup(from: oldName, to: newName)
        scheduleCloudKitSync(.immediate)
    }

    func unarchiveSource(_ sourceID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().unarchiveSource(sourceID)
        scheduleCloudKitSync()
    }

    /// The full restore the `unarchive_source` MCP tool performs — status,
    /// dismissal, and text rebuilt from a local file — for the app's own
    /// Unarchive actions. Nil when no source row carries the id.
    func unarchiveSourceRestoringContent(_ sourceID: String) throws -> SourceUnarchiveOutcome? {
        try ensureStoreExists()
        let outcome = try knowledgeStore().unarchiveSourceRestoringContent(sourceID)
        if outcome != nil { scheduleCloudKitSync() }
        return outcome
    }

    /// Title and status for each id that has a `sources` row, archived rows
    /// included; ids without a row are absent.
    func sourceRowSummaries(for sourceIDs: some Collection<String>) throws -> [String: SourceRowSummary] {
        try ensureStoreExists()
        return try knowledgeStore().sourceRowSummaries(for: sourceIDs)
    }

    /// Whether a source row with this id exists in the library, regardless of its
    /// active/archived status. Used to safely resolve Chat citations that may point at
    /// archived sources before mutating any state.
    func sourceExists(_ sourceID: String) throws -> Bool {
        try ensureStoreExists()
        return try knowledgeStore().sourceExists(sourceID)
    }

    /// Resolve the id carried by a Chat citation link to a real `sources.id`, tolerating
    /// truncated or shortened ids (see `KnowledgeStore.resolveSourceID(forLinkToken:)`).
    func resolveSourceID(forLinkToken token: String) throws -> String? {
        try ensureStoreExists()
        return try knowledgeStore().resolveSourceID(forLinkToken: token)
    }

    func archiveSourcesByParentGroup(_ parentGroup: String) throws {
        try ensureStoreExists()
        let sourceIDs = try knowledgeStore().sourceIDsByParentGroup(parentGroup)
        for sourceID in sourceIDs {
            try archiveSource(sourceID)
        }
    }

    /// Inverse of `archiveSourcesByParentGroup`. Group membership outlives
    /// archiving, so this finds the archived members and sets them active again.
    /// Archiving cleared their text, so callers that can re-fetch (a Drive-backed
    /// meeting group, say) should refresh the group afterwards.
    func unarchiveSourcesByParentGroup(_ parentGroup: String) throws {
        try ensureStoreExists()
        let sourceIDs = try knowledgeStore().sourceIDsByParentGroup(parentGroup)
        for sourceID in sourceIDs {
            try unarchiveSource(sourceID)
        }
    }

    func sourceCountByParentGroup(_ parentGroup: String) throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().sourceCountByParentGroup(parentGroup)
    }

    /// Chapter paths relative to the extracted `Chapters` directory, mapped to their archived state, for
    /// aligning the EPUB reader's Contents menu with ingested chapter sources.
    func bookChapterArchivedByRelativePath(groupID: String) throws -> [String: Bool] {
        try ensureStoreExists()
        return try knowledgeStore().bookChapterArchivedByRelativePath(groupID: groupID)
    }

    // MARK: - Course Metadata

    func loadCourseMetadata() throws -> [String: CourseMetadata] {
        try ensureStoreExists()
        return try knowledgeStore().loadCourseGroups()
    }

    func saveCourseGroup(name: String, metadata: CourseMetadata) throws {
        try ensureStoreExists()
        try knowledgeStore().saveCourseGroup(name: name, metadata: metadata)
        scheduleCloudKitSync(.immediate)
    }

    // MARK: - Video Playlist Metadata

    func loadVideoPlaylistMetadata() throws -> [String: VideoPlaylistMetadata] {
        try ensureStoreExists()
        return try knowledgeStore().loadVideoPlaylistGroups()
    }

    func saveVideoPlaylistGroup(id: String, metadata: VideoPlaylistMetadata) throws {
        try ensureStoreExists()
        try knowledgeStore().saveVideoPlaylistGroup(id: id, metadata: metadata)
        scheduleCloudKitSync(.immediate)
    }

    func deleteVideoPlaylistGroup(id: String) throws {
        try ensureStoreExists()
        try knowledgeStore().deleteVideoPlaylistGroup(id: id)
        scheduleCloudKitSync(.immediate)
    }

    func loadCourseLectures() throws -> [CourseSession] {
        try ensureStoreExists()
        return try knowledgeStore().loadCourseLectures()
    }

    func loadCourseLectureItems() throws -> [CourseLectureItem] {
        try ensureStoreExists()
        return try knowledgeStore().loadCourseLectureItems()
    }

    // MARK: Course quizzes (schema 138)

    func loadCourseQuizzes(courseID: String? = nil) throws -> [CourseQuiz] {
        try ensureStoreExists()
        return try knowledgeStore().loadCourseQuizzes(courseID: courseID)
    }

    /// The course outline a chat about these sources reads
    /// (`CourseChatOutline`); nil when none of them is lecture material.
    /// A read beside the catalog's `sourceContentLengths`, so like it this
    /// creates nothing.
    func courseChatOutlineMaterial(forSourceIDs sourceIDs: [String]) throws -> CourseChatOutline.Material? {
        try knowledgeStore().courseChatOutlineMaterial(forSourceIDs: sourceIDs)
    }

    func loadCourseQuiz(_ id: String) throws -> CourseQuiz? {
        try ensureStoreExists()
        return try knowledgeStore().loadCourseQuiz(id)
    }

    /// The quizzes whose questions' JSON holds any of `texts`
    /// (`KnowledgeStore.loadCourseQuizzes(mentioning:)`).
    func loadCourseQuizzes(mentioning texts: [String]) throws -> [CourseQuiz] {
        try ensureStoreExists()
        return try knowledgeStore().loadCourseQuizzes(mentioning: texts)
    }

    func saveCourseQuiz(_ quiz: CourseQuiz) throws {
        try ensureStoreExists()
        try knowledgeStore().saveCourseQuiz(quiz)
        scheduleCloudKitSync(.coalesced)
    }

    func deleteCourseQuiz(_ id: String) throws {
        try ensureStoreExists()
        try knowledgeStore().deleteCourseQuiz(id)
        scheduleCloudKitSync(.coalesced)
    }

    func loadCourseArtworkURLs() throws -> [String: String] {
        try ensureStoreExists()
        return try knowledgeStore().loadCourseArtworkURLs()
    }

    func saveCourseLecture(_ lecture: CourseSession) throws {
        try ensureStoreExists()
        try knowledgeStore().saveCourseLecture(lecture)
        scheduleCloudKitSync(.immediate)
    }

    @discardableResult
    func saveCourseLectureItem(_ item: CourseLectureItem) throws -> Int {
        try ensureStoreExists()
        let store = try knowledgeStore()
        // A team's course files the team's rows: an own source goes into the
        // team first (teams-design.md, decision 21), and the store files it.
        if let courseID = try store.courseNameForLecture(item.lectureId), try store.courseTeamID(courseID) != nil {
            let needed = try courseItemSourceIDs([item], store: store)
            let filed = try courseLibrarySourceIDs(courseID: courseID, needed)
            guard needed.allSatisfy({ filed[$0] != nil }) else {
                throw KnowledgeStoreError.invalidData("This source could not be copied into the team that holds the course.")
            }
        }
        let notebookSourcesAdded = try store.saveCourseLectureItem(item)
        scheduleCloudKitSync(.immediate)
        return notebookSourcesAdded
    }

    /// Every source a lecture item names: its own, and the chapter its page
    /// unit reads.
    private func courseItemSourceIDs(_ items: [CourseLectureItem], store: KnowledgeStore) throws -> [String] {
        let unitSources = try store.loadSourceUnits(ids: items.compactMap(\.sourceUnitId)).map(\.sourceId)
        return items.compactMap(\.sourceId) + unitSources
    }

    func deleteCourseLectureItem(_ itemId: String) throws {
        try ensureStoreExists()
        try knowledgeStore().deleteCourseLectureItem(itemId)
        scheduleCloudKitSync(.immediate)
    }

    func deleteCourseLecture(_ lectureId: String) throws {
        try ensureStoreExists()
        try knowledgeStore().deleteCourseLecture(lectureId)
        scheduleCloudKitSync(.immediate)
    }

    func saveSourceUnit(_ unit: SourceUnit) throws {
        try ensureStoreExists()
        try knowledgeStore().saveSourceUnit(unit)
        scheduleCloudKitSync()
    }

    func saveCourseOutline(courseName: String, lectures: [CourseSession], items: [CourseLectureItem]) throws {
        try ensureStoreExists()
        let store = try knowledgeStore()
        var items = items
        // A team's course files the team's rows: own sources go into the team
        // first (teams-design.md, decision 21), and an item whose source could
        // not be copied is left out rather than naming a row only this
        // library holds.
        if try store.courseTeamID(courseName) != nil {
            let unitSources = Dictionary(
                try store.loadSourceUnits(ids: items.compactMap(\.sourceUnitId)).map { ($0.id, $0.sourceId) },
                uniquingKeysWith: { first, _ in first }
            )
            let filed = try courseLibrarySourceIDs(
                courseID: courseName,
                items.compactMap(\.sourceId) + Array(unitSources.values)
            )
            items = items.filter { item in
                let needed = [item.sourceId, item.sourceUnitId.flatMap { unitSources[$0] }].compactMap { $0 }
                return needed.allSatisfy { filed[$0] != nil }
            }
        }
        try store.saveCourseOutline(courseName: courseName, lectures: lectures, items: items)
        scheduleCloudKitSync()
    }

    // MARK: Textbook readings (docs/textbook-readings-design.md)

    /// Replaces a book's readings in a course; see
    /// `KnowledgeStore.replaceTextbookReadings`. The book's chapters are read
    /// here, archived and hidden ones included, so a chapter hidden since the
    /// last plan still loses the readings that plan gave it.
    @discardableResult
    func replaceTextbookReadings(
        courseID: String,
        bookID: String,
        placements: [TextbookReadingPlacement]
    ) throws -> [CourseLectureItem] {
        try ensureStoreExists()
        let store = try knowledgeStore()
        let chapterIDs = try store.bookChapterSourceIDs(bookID: bookID, includingUnavailable: true)
        var bookChapterIDs = Set(chapterIDs.map(\.sourceID))
        var placements = placements
        // A team's course reads the team's copies of the chapters
        // (teams-design.md, decision 21): the ones placed are copied into the
        // team first, files included, and the plan names them; every chapter's
        // team copy counts as the book's, so planning again replaces the
        // readings an earlier plan gave the team's course.
        if let teamID = try store.courseTeamID(courseID) {
            let filed = try courseLibrarySourceIDs(courseID: courseID, placements.map(\.chapterSourceID))
            for chapter in chapterIDs {
                if let url = try store.loadSourceWithoutContent(chapter.sourceID)?.url {
                    bookChapterIDs.insert(try store.teamSourceCopyID(teamID: teamID, url: url))
                }
            }
            placements = placements.compactMap { placement in
                filed[placement.chapterSourceID].map { chapterSourceID in
                    TextbookReadingPlacement(
                        lectureID: placement.lectureID,
                        lectureNumber: placement.lectureNumber,
                        chapterSourceID: chapterSourceID,
                        chapterNumber: placement.chapterNumber,
                        chapterTitle: placement.chapterTitle,
                        pages: placement.pages,
                        title: placement.title,
                        reason: placement.reason
                    )
                }
            }
        }
        let items = try store.replaceTextbookReadings(
            courseID: courseID,
            bookChapterIDs: bookChapterIDs,
            placements: placements
        )
        scheduleCloudKitSync(.immediate)
        // The chapters joined every Notebook that follows the course; a Notebook
        // shared with a team passes them on (teams-design.md, decision 10).
        let read = Array(Set(placements.map(\.chapterSourceID))).sorted()
        // Never throws: the readings are saved, and a follow-on that fails is
        // logged by the propagation, not turned into an error about them.
        for notebookID in (try? store.notebookIDsLinkedToCourse(courseID)) ?? [] {
            propagateNotebookSourcesToTeams(notebookID: notebookID, sourceIDs: read)
        }
        return items
    }

    /// The chapters the reading planner may offer, in reading order: active,
    /// not hidden, and not kept from AI (`knowledgeSearchExcludedSourceIDs`).
    func textbookChapterSources(bookID: String) throws -> [(sourceID: String, title: String, sortIndex: Int?)] {
        try ensureStoreExists()
        let store = try knowledgeStore()
        let excluded = try store.knowledgeSearchExcludedSourceIDs()
        return try store.bookChapterSourceIDs(bookID: bookID).filter { !excluded.contains($0.sourceID) }
    }

    /// Sources the learner keeps from AI, which no planner reads.
    func knowledgeBoundaryExcludedSourceIDs() throws -> Set<String> {
        try ensureStoreExists()
        return try knowledgeStore().knowledgeSearchExcludedSourceIDs()
    }

    /// The same boundary with archived sources counted too, as a tool that
    /// opens one source by id asks it.
    func knowledgeSearchExcludedSourceIDs(includeArchived: Bool) throws -> Set<String> {
        try ensureStoreExists()
        return try knowledgeStore().knowledgeSearchExcludedSourceIDs(includeArchived: includeArchived)
    }

    func loadCourseSourceUnits() throws -> [String: SourceUnit] {
        try ensureStoreExists()
        return try knowledgeStore().loadCourseSourceUnits()
    }

    func learnerContextNotebooks(courseID: String) throws -> [CourseLearnerContext.Notebook] {
        try ensureStoreExists()
        return try knowledgeStore().learnerContextNotebooks(courseID: courseID)
    }

    /// Returns the course sources hidden because the deletion left them in no
    /// course — see `KnowledgeStore.hideCourseSourcesWithoutCourse`.
    @discardableResult
    func deleteCourseGroup(name: String) throws -> [String] {
        try ensureStoreExists()
        let hiddenSourceIDs = try knowledgeStore().deleteCourseGroup(name: name)
        scheduleCloudKitSync(.immediate)
        return hiddenSourceIDs
    }

    // MARK: - Meeting Metadata

    func loadMeetingMetadata() throws -> [String: MeetingMetadata] {
        try ensureStoreExists()
        return try knowledgeStore().loadMeetingGroups()
    }

    func saveMeetingGroup(name: String, metadata: MeetingMetadata) throws {
        try ensureStoreExists()
        try knowledgeStore().saveMeetingGroup(name: name, metadata: metadata)
        scheduleCloudKitSync(.immediate)
    }

    /// The series that meet at a fixed time, for the Planner's import.
    func scheduledMeetingGroups() throws -> [(id: String, title: String, schedule: MeetingSchedule)] {
        try ensureStoreExists()
        return try knowledgeStore().scheduledMeetingGroups()
    }

    func canonicalMeetingGroupID(_ groupID: String) throws -> String {
        try ensureStoreExists()
        return try knowledgeStore().canonicalMeetingGroupID(groupID)
    }

    func meetingGroupIDs() throws -> [String] {
        try ensureStoreExists()
        return try knowledgeStore().meetingGroupIDs()
    }

    /// A series' schedule, set or cleared; the series' record syncs at once
    /// and the Planner is told so today is redrawn.
    func setMeetingSchedule(_ schedule: MeetingSchedule?, groupID: String) throws {
        try ensureStoreExists()
        let store = try knowledgeStore()
        guard var metadata = try store.loadMeetingGroups()[groupID] else {
            throw KnowledgeStoreError.invalidData("Meeting group not found: \(groupID)")
        }
        metadata.schedule = schedule
        try store.saveMeetingGroup(name: groupID, metadata: metadata)
        scheduleCloudKitSync(.immediate)
        NotificationCenter.default.post(name: .meetingSchedulesDidChange, object: nil)
    }

    func loadMeetingActionItems(groupID: String? = nil, sourceID: String? = nil) throws -> [MeetingActionItem] {
        try ensureStoreExists()
        return try knowledgeStore().loadMeetingActionItems(groupID: groupID, sourceID: sourceID)
    }

    func hasMeetingActionItems(sourceID: String) throws -> Bool {
        try ensureStoreExists()
        return try knowledgeStore().hasMeetingActionItems(sourceID: sourceID)
    }

    func saveMeetingActionItems(_ items: [MeetingActionItem], groupID: String, sourceID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().saveMeetingActionItems(items, groupID: groupID, sourceID: sourceID)
        scheduleCloudKitSync()
        NotificationCenter.default.post(name: .dayPlansDidChange, object: nil)
    }

    @discardableResult
    func setMeetingActionItemDone(_ id: String, done: Bool) throws -> MeetingActionItem {
        try ensureStoreExists()
        let item = try knowledgeStore().setMeetingActionItemDone(id, done: done)
        scheduleCloudKitSync(.immediate)
        NotificationCenter.default.post(name: .dayPlansDidChange, object: nil)
        return item
    }

    /// The active meeting group a plugin's stable ID or title names, after
    /// any merge alias — the same lookup the MCP tools use to file a session.
    func resolvedMeetingGroupID(matching input: String) throws -> String? {
        try ensureStoreExists()
        return try knowledgeStore().resolvedMeetingGroupID(matching: input)
    }

    func loadMeetingArtifacts(groupID: String? = nil, sourceID: String? = nil) throws -> [MeetingArtifact] {
        try ensureStoreExists()
        return try knowledgeStore().loadMeetingArtifacts(groupID: groupID, sourceID: sourceID)
    }

    func saveMeetingArtifact(_ artifact: MeetingArtifact) throws {
        try ensureStoreExists()
        try knowledgeStore().saveMeetingArtifact(artifact)
        scheduleCloudKitSync()
    }

    func deleteMeetingGroup(name: String) throws {
        try ensureStoreExists()
        try knowledgeStore().deleteMeetingGroup(name: name)
        scheduleCloudKitSync(.immediate)
    }

    /// Delete a meeting series and its sessions for good, and drop each deleted
    /// session out of the search indexes the way `deleteSource` does.
    /// Returns the source IDs that were deleted.
    func deleteMeetingGroupWithSessions(
        name: String,
        additionalSessionIDs: Set<String> = []
    ) throws -> [String] {
        try ensureStoreExists()
        let deleted = try knowledgeStore().deleteMeetingGroupWithSessions(
            name: name,
            additionalSessionIDs: additionalSessionIDs
        )
        for sourceID in deleted {
            removeFromSearchIndexes(sourceID)
        }
        scheduleCloudKitSync(.immediate)
        return deleted
    }

    /// Atomically update a source's type in the database and mark it as manually set.
    func updateSourceType(_ sourceId: String, to newType: String) throws {
        try knowledgeStore().updateSourceType(sourceId, to: newType)
        scheduleCloudKitSync(.immediate)
    }

    private func elapsedMs(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
    
    /// Sanitize filename: stem must match [0-9a-zA-Z]{4,16}
    static func sanitizeFilename(_ filename: String) -> String {
        let url = URL(fileURLWithPath: filename)
        let ext = url.pathExtension
        var stem = url.deletingPathExtension().lastPathComponent
        
        // Remove non-alphanumeric characters
        stem = stem.filter { $0.isLetter || $0.isNumber }
        
        // Ensure length 4-16
        if stem.count < 4 {
            stem = stem + String(repeating: "x", count: 4 - stem.count)
        }
        if stem.count > 16 {
            stem = String(stem.prefix(16))
        }
        
        return ext.isEmpty ? stem : "\(stem).\(ext)"
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

    // MARK: - Targeted Source Persistence

    /// Insert a source if it doesn't already exist (by normalized URL). Returns true if inserted.
    @discardableResult
    func sourceExistsByURL(_ url: String) throws -> (id: String, status: SourceStatus)? {
        try ensureStoreExists()
        return try knowledgeStore().sourceExistsByURL(url)
    }

    func insertSourceIfNew(_ article: inout StudioArticle) throws -> Bool {
        let inserted = try knowledgeStore().insertSourceIfNew(&article)
        if inserted {
            scheduleCloudKitSync(.immediate)
        }
        return inserted
    }

    func newSourceCandidates(from articles: [StudioArticle]) throws -> [StudioArticle] {
        try knowledgeStore().newSourceCandidates(from: articles)
    }

    /// Load all active (non-archived) sources.
    /// One library at a time: nil is My Library, a team id is that team's.
    func loadActiveSources(teamID: String? = nil) throws -> [StudioArticle] {
        try knowledgeStore().loadActiveSources(teamID: teamID)
    }

    /// What the Studio lists while `teamID`'s library is open: the learner's
    /// own sources and the team's that they lack (docs/teams-design.md,
    /// decision 19). Nil is My Library.
    func loadLibrarySources(teamID: String?) throws -> LibrarySourceList {
        try knowledgeStore().loadLibrarySources(teamID: teamID)
    }

    /// Returns the latest review date for each source, including completed Schedule items.
    func sourceReviewDates() throws -> [String: Date] {
        try knowledgeStore().sourceReviewDates()
    }

    /// Per-source retention stats for the daily memory-training surface. Optionally
    /// restricted to a set of source IDs (one Notebook's sources) for a per-notebook refresh.
    func memoryReviewStats(restrictToSourceIDs: Set<String>? = nil) throws -> [MemoryReviewStat] {
        try knowledgeStore().memoryReviewStats(restrictToSourceIDs: restrictToSourceIDs)
    }

    /// Consumed-but-never-reviewed sources — the never-reviewed half of the daily
    /// memory-training surface. Same optional per-Notebook restriction.
    func unreviewedConsumedSources(restrictToSourceIDs: Set<String>? = nil) throws -> [MemoryReviewNewCandidate] {
        try knowledgeStore().unreviewedConsumedSources(restrictToSourceIDs: restrictToSourceIDs)
    }

    /// Keeps legacy-history bootstrap, candidate fetches, exclusion joins, and
    /// scheduling sorts on the storage actor. Both intake buckets — previously
    /// reviewed sources that are due again, and consumed-never-reviewed sources —
    /// are gathered in full and bounded together by
    /// `MemoryReviewScheduler.firstReviewIntake`, so a large legacy backlog can
    /// no longer spend the whole daily plan before recently consumed material is
    /// even considered.
    func firstReviewMemoryItems(
        now: Date,
        limit: Int,
        restrictToSourceIDs: Set<String>? = nil
    ) throws -> [MemoryReviewNewItem] {
        let boundedLimit = Swift.max(0, limit)
        guard boundedLimit > 0 else { return [] }
        let store = try knowledgeStore()
        let representedSourceIDs = try store.activeMemoryItemSourceIDs(
            restrictToSourceIDs: restrictToSourceIDs
        )
        let legacyStats = try store.memoryReviewStats(
            restrictToSourceIDs: restrictToSourceIDs
        ).filter { !representedSourceIDs.contains($0.sourceID) }
        let newCandidates = try store.unreviewedConsumedSources(
            restrictToSourceIDs: restrictToSourceIDs
        ).filter { !representedSourceIDs.contains($0.sourceID) }
        return MemoryReviewScheduler.firstReviewIntake(
            legacyStats: legacyStats,
            freshCandidates: newCandidates,
            now: now,
            limit: boundedLimit
        )
    }

    func recentReviewSourceActivity(
        now: Date = Date(),
        sessionLimit: Int = 12,
        maximumAgeDays: Int = 14
    ) throws -> [MemoryTutorRecentSourceActivity] {
        try knowledgeStore().recentReviewSourceActivity(
            now: now,
            sessionLimit: sessionLimit,
            maximumAgeDays: maximumAgeDays
        )
    }

    // MARK: - AI-native memory tutor

    func saveMemoryItem(_ item: MemoryItem) throws {
        try knowledgeStore().saveMemoryItem(item)
        scheduleCloudKitSync(.soon)
    }

    func loadMemoryItem(_ id: String) throws -> MemoryItem? {
        try knowledgeStore().loadMemoryItem(id)
    }

    func loadMemoryItems(
        status: MemoryItemStatus? = nil,
        goalID: String? = nil
    ) throws -> [MemoryItem] {
        try knowledgeStore().loadMemoryItems(status: status, goalID: goalID)
    }

    func loadMemoryItemsForSession(_ sessionID: String) throws -> [MemoryItem] {
        try knowledgeStore().loadMemoryItemsForSession(sessionID)
    }

    func setMemoryItemStatus(
        id: String,
        status: MemoryItemStatus,
        updatedAt: Date = Date()
    ) throws {
        try knowledgeStore().setMemoryItemStatus(id: id, status: status, updatedAt: updatedAt)
        scheduleCloudKitSync(.soon)
    }

    func deleteMemoryItem(_ id: String) throws {
        try knowledgeStore().deleteMemoryItem(id)
        scheduleCloudKitSync(.soon)
    }

    @discardableResult
    func recordMemoryAttempt(_ attempt: MemoryAttempt) throws -> Bool {
        let inserted = try knowledgeStore().recordMemoryAttempt(attempt)
        if inserted {
            scheduleCloudKitSync(.soon)
        }
        return inserted
    }

    func loadMemoryAttempt(_ id: String) throws -> MemoryAttempt? {
        try knowledgeStore().loadMemoryAttempt(id)
    }

    func loadMemoryAttempts(
        memoryItemID: String? = nil,
        sessionID: String? = nil
    ) throws -> [MemoryAttempt] {
        try knowledgeStore().loadMemoryAttempts(memoryItemID: memoryItemID, sessionID: sessionID)
    }

    func reviewedMemorySourceIDs(sessionID: String) throws -> [String] {
        try knowledgeStore().reviewedMemorySourceIDs(sessionID: sessionID)
    }

    func memoryStruggleProjection(
        memoryItemID: String,
        limit: Int = 3
    ) throws -> MemoryStruggleProjection? {
        try knowledgeStore().memoryStruggleProjection(
            memoryItemID: memoryItemID,
            limit: limit
        )
    }

    func deleteMemoryAttempt(_ id: String) throws {
        try knowledgeStore().deleteMemoryAttempt(id)
        scheduleCloudKitSync(.soon)
    }

    func loadMemorySchedule(memoryItemID: String) throws -> MemorySchedule? {
        try knowledgeStore().loadMemorySchedule(memoryItemID: memoryItemID)
    }

    @discardableResult
    func rebuildMemorySchedule(memoryItemID: String) throws -> MemorySchedule? {
        try knowledgeStore().rebuildMemorySchedule(memoryItemID: memoryItemID)
    }

    // MARK: Memory cards (KnowledgeStore+MemoryCards.swift)

    /// Keeps a drafted card as its Memory item, once
    /// (`KnowledgeStore.keepMemoryCard`).
    @discardableResult
    func keepMemoryCard(
        _ card: MemoryCard,
        sourceID: String,
        quote: String,
        alsoFrom: [CardSourceLink] = [],
        ideaID: String? = nil,
        at now: Date = Date()
    ) throws -> MemoryItem {
        let item = try knowledgeStore().keepMemoryCard(
            card,
            sourceID: sourceID,
            quote: quote,
            alsoFrom: alsoFrom,
            ideaID: ideaID,
            at: now
        )
        scheduleCloudKitSync(.soon)
        return item
    }

    /// Retires a card's item (`KnowledgeStore.retireMemoryCard`).
    func retireMemoryCard(memoryItemID: String, at now: Date = Date()) throws {
        try knowledgeStore().retireMemoryCard(memoryItemID: memoryItemID, at: now)
        scheduleCloudKitSync(.soon)
    }

    /// Retires a card's item and keeps its revision under a new card id
    /// (`KnowledgeStore.startMemoryCardOver`).
    @discardableResult
    func startMemoryCardOver(
        memoryItemID: String,
        as revision: MemoryCard,
        at now: Date = Date()
    ) throws -> MemoryItem {
        let item = try knowledgeStore().startMemoryCardOver(memoryItemID: memoryItemID, as: revision, at: now)
        scheduleCloudKitSync(.soon)
        return item
    }

    /// A card the learner graded themselves, written only when it counts
    /// (`KnowledgeStore.recordSelfGradedMemoryCardAttempt`).
    @discardableResult
    func recordSelfGradedMemoryCardAttempt(
        memoryItemID: String,
        prompt: String,
        remembered: Bool,
        sessionKey: String,
        practice: Bool = false,
        at now: Date = Date()
    ) throws -> MemoryCardAnswerOutcome {
        let outcome = try knowledgeStore().recordSelfGradedMemoryCardAttempt(
            memoryItemID: memoryItemID,
            prompt: prompt,
            remembered: remembered,
            sessionKey: sessionKey,
            practice: practice,
            at: now
        )
        if outcome == .recorded {
            scheduleCloudKitSync(.soon)
        }
        return outcome
    }

    /// "This asks something else" on a card's variant, written once a
    /// sitting (`KnowledgeStore.recordMemoryCardAskedSomethingElse`). Under
    /// generation 2 the rewording is also taken out on the card's Card (its
    /// variant `retired`), as the phone takes it out, so every device leaves
    /// it out whatever answers it holds.
    @discardableResult
    func recordMemoryCardAskedSomethingElse(
        memoryItemID: String,
        prompt: String,
        variantIndex: Int,
        sessionKey: String,
        at now: Date = Date()
    ) throws -> Bool {
        let store = try knowledgeStore()
        let inserted = try store.recordMemoryCardAskedSomethingElse(
            memoryItemID: memoryItemID,
            prompt: prompt,
            variantIndex: variantIndex,
            sessionKey: sessionKey,
            at: now
        )
        if inserted, try store.recordsMemoryForGeneration2() {
            try store.retireCardRecordVariant(cardID: memoryItemID, text: prompt, at: now)
            MemoryCardStateStore.reload()
        }
        if inserted {
            scheduleCloudKitSync(.soon)
        }
        return inserted
    }

    /// One batch of the schedule rows an older scheduler wrote, after
    /// `afterID`. See `KnowledgeStore.rebuildStaleMemorySchedules`.
    @discardableResult
    func rebuildStaleMemorySchedules(
        after afterID: String? = nil,
        limit: Int
    ) throws -> KnowledgeStore.MemoryScheduleRebuildBatch {
        try knowledgeStore().rebuildStaleMemorySchedules(after: afterID, limit: limit)
    }

    /// Today's cards in a scope, the new cards practice would take, the
    /// scope's kept cards and its cards to check, in one read
    /// (`KnowledgeStore.memoryCardReviewSnapshot`). With `includesToCheck`
    /// the sources' draft decks (`loadCardDrafts`) and their states
    /// (`cardDeckStates`: the Card rows under generation 2, the rows in
    /// `stateDefaults` under generation 1) are read; a sitting, which deals
    /// kept cards only, leaves them out.
    func memoryCardReviewSnapshot(
        now: Date,
        budgetMinutes: Int?,
        newPerDay: Int,
        deadlines: [MemoryCardDeadline],
        scope: MemoryCardScope?,
        includesListings: Bool = true,
        includesToCheck: Bool = true,
        stateDefaults: UserDefaults = .standard
    ) throws -> MemoryCardReviewSnapshot {
        let drafts: [MemoryCardDraftDeck]? = try includesToCheck ? loadCardDrafts() : nil
        let deckStates = try includesToCheck ? cardDeckStates(stateDefaults: stateDefaults) : { _ in MemoryCardDeckState() }
        return try knowledgeStore().memoryCardReviewSnapshot(
            now: now,
            budgetMinutes: budgetMinutes,
            newPerDay: newPerDay,
            deadlines: deadlines,
            scope: scope,
            includesListings: includesListings,
            toCheckFrom: drafts,
            deckState: { deckStates($0) }
        )
    }

    /// What a notebook's Practice deals: its kept cards and its undecided
    /// drafts (`KnowledgeStore.memoryCardNotebookPractice`), the draft decks
    /// and their states read as `memoryCardReviewSnapshot` reads them.
    func memoryCardNotebookPractice(
        scope: MemoryCardScope,
        now: Date,
        stateDefaults: UserDefaults = .standard
    ) throws -> MemoryCardNotebookPractice {
        let drafts = try loadCardDrafts()
        let deckStates = try cardDeckStates(stateDefaults: stateDefaults)
        return try knowledgeStore().memoryCardNotebookPractice(
            scope: scope,
            now: now,
            toCheckFrom: drafts,
            deckState: { deckStates($0) }
        )
    }

    /// What the cards a chat chose deal (`KnowledgeStore.memoryCardChosenPractice`).
    func memoryCardChosenPractice(cardIDs: [String], now: Date) throws -> MemoryCardChosenPractice {
        try knowledgeStore().memoryCardChosenPractice(cardIDs: cardIDs, now: now)
    }

    /// Today's cards, in the order they are asked (`MemoryCardQueue.today` over
    /// every item the library may ask).
    func memoryCardQueueToday(
        now: Date,
        budgetMinutes: Int?,
        newPerDay: Int,
        deadlines: [MemoryCardDeadline],
        restrictToSourceIDs: Set<String>? = nil
    ) throws -> MemoryCardQueue.Today {
        try knowledgeStore().memoryCardQueueToday(
            now: now,
            budgetMinutes: budgetMinutes,
            newPerDay: newPerDay,
            deadlines: deadlines,
            restrictToSourceIDs: restrictToSourceIDs
        )
    }

    func dueMemoryItems(
        now: Date,
        limit: Int,
        restrictToSourceIDs: Set<String>? = nil
    ) throws -> [DueMemoryItem] {
        try knowledgeStore().dueMemoryItems(
            now: now,
            limit: limit,
            restrictToSourceIDs: restrictToSourceIDs
        )
    }

    func dueMemoryItems(
        now: Date,
        limit: Int,
        goalID: String?,
        restrictToSourceIDs: Set<String>? = nil
    ) throws -> [DueMemoryItem] {
        try knowledgeStore().dueMemoryItems(
            now: now,
            limit: limit,
            goalID: goalID,
            restrictToSourceIDs: restrictToSourceIDs
        )
    }

    func canonicalMemorySourceSnapshot(sourceID: String) throws -> MemorySourceSnapshot {
        try knowledgeStore().canonicalMemorySourceSnapshot(sourceID: sourceID)
    }

    func portableMemorySourceKey(sourceID: String) throws -> String {
        try knowledgeStore().portableMemorySourceKey(sourceID: sourceID)
    }

    func resolveMemorySourceID(
        portableSourceKey: String,
        restrictToSourceIDs sourceIDs: [String]
    ) throws -> String? {
        try knowledgeStore().resolveMemorySourceID(
            portableSourceKey: portableSourceKey,
            restrictToSourceIDs: sourceIDs
        )
    }

    func validatedMemorySourceAnchor(
        sourceID: String,
        excerpt: String
    ) throws -> MemorySourceAnchorValidation {
        try knowledgeStore().validatedMemorySourceAnchor(sourceID: sourceID, excerpt: excerpt)
    }

    @discardableResult
    func completePendingReviewExchangeAndRecordMemoryAttempt(
        sessionID: String,
        sequence: Int? = nil,
        answer: String,
        evaluation: String,
        knowledgeNote: String?,
        sourceRefs: [String],
        item: MemoryItem? = nil,
        expectedExistingItem: MemoryItem? = nil,
        attempt: MemoryAttempt,
        answeredAt: Date = Date()
    ) throws -> MemoryAttempt {
        let linkedAttempt = try knowledgeStore().completePendingReviewExchangeAndRecordMemoryAttempt(
            sessionID: sessionID,
            sequence: sequence,
            answer: answer,
            evaluation: evaluation,
            knowledgeNote: knowledgeNote,
            sourceRefs: sourceRefs,
            item: item,
            expectedExistingItem: expectedExistingItem,
            attempt: attempt,
            answeredAt: answeredAt
        )
        scheduleCloudKitSync(.soon)
        return linkedAttempt
    }

    func completeReviewSessionAndRecordMemoryAttempts(
        sessionID: String,
        overallScore: Double?,
        summary: String,
        endedAt: Date = Date(),
        exportedTranscript: String? = nil,
        transcriptKnowledgeNote: String? = nil,
        sessionSourceIDs: [String] = [],
        reviewedSourceIDs: [String]? = nil,
        scheduleReviewDate: Date? = nil,
        companionGoalID: String? = nil,
        companionQuizDate: String? = nil,
        companionGaps: [LearningGoalGap] = [],
        createIfMissing: ReviewSessionRecoverySeed? = nil,
        items: [MemoryItem] = [],
        expectedCurriculumFingerprints: [String: String] = [:],
        attempts: [MemoryAttempt]
    ) throws {
        try knowledgeStore().completeReviewSessionAndRecordMemoryAttempts(
            sessionID: sessionID,
            overallScore: overallScore,
            summary: summary,
            endedAt: endedAt,
            exportedTranscript: exportedTranscript,
            transcriptKnowledgeNote: transcriptKnowledgeNote,
            sessionSourceIDs: sessionSourceIDs,
            reviewedSourceIDs: reviewedSourceIDs,
            scheduleReviewDate: scheduleReviewDate,
            companionGoalID: companionGoalID,
            companionQuizDate: companionQuizDate,
            companionGaps: companionGaps,
            createIfMissing: createIfMissing,
            items: items,
            expectedCurriculumFingerprints: expectedCurriculumFingerprints,
            attempts: attempts
        )
        scheduleCloudKitSync(.soon)
    }

    @discardableResult
    func recordMemoryAttemptCreatingReviewExchange(
        sessionID: String,
        sourceRefs: [String],
        item: MemoryItem? = nil,
        expectedExistingItem: MemoryItem? = nil,
        attempt: MemoryAttempt
    ) throws -> MemoryAttempt {
        let linkedAttempt = try knowledgeStore().recordMemoryAttemptCreatingReviewExchange(
            sessionID: sessionID,
            sourceRefs: sourceRefs,
            item: item,
            expectedExistingItem: expectedExistingItem,
            attempt: attempt
        )
        scheduleCloudKitSync(.soon)
        return linkedAttempt
    }

    /// Returns the set of source IDs that have been reviewed.
    func sourceIdsWithCompletedReviewSession() throws -> Set<String> {
        try knowledgeStore().sourceIdsWithCompletedReviewSession()
    }

    func sourceIdsWithReviewSession() throws -> Set<String> {
        try knowledgeStore().sourceIdsWithReviewSession()
    }

    func sourceIdsWithLinkedChatSession() throws -> Set<String> {
        try knowledgeStore().sourceIdsWithLinkedChatSession()
    }

    func createReviewSession(
        id: String,
        topic: String,
        sourceIDs: [String],
        cardIDs: [String] = [],
        startedAt: Date = Date(),
        modelProvider: String? = nil,
        modelID: String? = nil,
        modelEffort: String? = nil,
        modelSpeed: String? = nil,
        goalID: String? = nil,
        scheduleActivityAt: Date? = nil,
        scheduleActivityKind: SourceActivityKind = .review,
        kind: ReviewSessionKind? = nil,
        briefing: String? = nil,
        chatKind: ChatKind? = nil
    ) throws {
        try knowledgeStore().createReviewSession(
            id: id,
            topic: topic,
            sourceIDs: sourceIDs,
            cardIDs: cardIDs,
            startedAt: startedAt,
            modelProvider: modelProvider,
            modelID: modelID,
            modelEffort: modelEffort,
            modelSpeed: modelSpeed,
            goalID: goalID,
            scheduleActivityAt: scheduleActivityAt,
            scheduleActivityKind: scheduleActivityKind,
            kind: kind,
            briefing: briefing,
            chatKind: chatKind
        )
        scheduleCloudKitSync(.soon)
    }

    // MARK: - Source ideas and memory review

    func loadSourceIdeas(sourceIDs: [String], includeRetired: Bool = false) throws -> [String: [SourceIdea]] {
        try knowledgeStore().loadSourceIdeas(sourceIDs: sourceIDs, includeRetired: includeRetired)
    }

    func loadSourceIdea(_ id: String) throws -> SourceIdea? {
        try knowledgeStore().loadSourceIdea(id)
    }

    /// One source's row without its text, for callers that need its title and
    /// type and nothing else.
    func loadSourceWithoutContent(_ id: String) throws -> StudioArticle? {
        try knowledgeStore().loadSourceForSync(id)
    }

    func sourceIdeaContentHash(sourceID: String) throws -> String? {
        try knowledgeStore().sourceIdeaContentHash(sourceID: sourceID)
    }

    func replaceSourceIdeas(sourceID: String, contentHash: String, ideas: [SourceIdea]) throws {
        try knowledgeStore().replaceSourceIdeas(sourceID: sourceID, contentHash: contentHash, ideas: ideas)
        scheduleCloudKitSync(.coalesced)
    }

    func setSourceIdeaStatus(id: String, status: SourceIdeaStatus) throws {
        try knowledgeStore().setSourceIdeaStatus(id: id, status: status)
        scheduleCloudKitSync(.coalesced)
    }

    func loadSourceReviewDepths(sourceIDs: [String]) throws -> [String: MemoryReviewDepth] {
        try knowledgeStore().loadSourceReviewDepths(sourceIDs: sourceIDs)
    }

    func setSourceReviewDepth(sourceID: String, depth: MemoryReviewDepth?) throws {
        try knowledgeStore().setSourceReviewDepth(sourceID: sourceID, depth: depth)
        scheduleCloudKitSync(.coalesced)
    }

    func setReviewSessionBriefing(sessionID: String, briefing: String?) throws {
        try knowledgeStore().setReviewSessionBriefing(sessionID: sessionID, briefing: briefing)
        scheduleCloudKitSync(.coalesced)
    }

    func loadReviewSessionBriefing(sessionID: String) throws -> String? {
        try knowledgeStore().loadReviewSessionBriefing(sessionID: sessionID)
    }

    func loadCourseQuizSittingRows() throws -> [(sessionID: String, startedAt: Date, briefing: String?)] {
        try knowledgeStore().loadCourseQuizSittingRows()
    }

    func recordMemoryContourGrade(sessionID: String, sequence: Int, grade: MemoryContourGrade) throws {
        try knowledgeStore().recordMemoryContourGrade(sessionID: sessionID, sequence: sequence, grade: grade)
        scheduleCloudKitSync(.coalesced)
    }

    @discardableResult
    func recordMemoryReviewSteer(sessionID: String, steer: MemoryReviewSteer) throws -> [MemoryIdeaCoverage]? {
        let coverage = try knowledgeStore().recordMemoryReviewSteer(sessionID: sessionID, steer: steer)
        scheduleCloudKitSync(.coalesced)
        return coverage
    }

    func memoryReviewSteers(sessionID: String) throws -> [(sourceID: String, steer: MemoryReviewSteer)] {
        try knowledgeStore().memoryReviewSteers(sessionID: sessionID)
    }

    func forkReviewSession(
        sessionID: String,
        throughExchangeID: String,
        field: ReviewExchangeMessageField
    ) throws -> ReviewSessionRecord {
        let session = try knowledgeStore().forkReviewSession(
            sessionID: sessionID,
            throughExchangeID: throughExchangeID,
            field: field
        )
        scheduleCloudKitSync(.immediate)
        return session
    }

    func loadReviewSessionCardIDs(sessionID: String) throws -> [String] {
        try knowledgeStore().loadReviewSessionCardIDs(sessionID: sessionID)
    }

    func updateReviewSessionModel(
        sessionID: String,
        modelProvider: String,
        modelID: String,
        modelEffort: String?,
        modelSpeed: String?
    ) throws {
        try knowledgeStore().updateReviewSessionModel(
            sessionID: sessionID,
            modelProvider: modelProvider,
            modelID: modelID,
            modelEffort: modelEffort,
            modelSpeed: modelSpeed
        )
        scheduleCloudKitSync(.soon)
    }

    func loadReviewSessionModelRoute(sessionID: String) throws -> ReviewSessionModelRoute? {
        try knowledgeStore().loadReviewSessionModelRoute(sessionID: sessionID)
    }

    func updateReviewSessionTitle(sessionID: String, title: String) throws {
        try knowledgeStore().updateReviewSessionTitle(sessionID: sessionID, title: title)
        scheduleCloudKitSync(.soon)
        propagateChatToTeams(sessionID: sessionID)
    }

    /// Swap in the AI-suggested title only if the learner has not renamed the
    /// chat since it was opened. Returns false when the rename won.
    func replaceProvisionalReviewSessionTitle(
        sessionID: String,
        provisionalTitle: String,
        title: String
    ) throws -> Bool {
        let replaced = try knowledgeStore().replaceProvisionalReviewSessionTitle(
            sessionID: sessionID,
            provisionalTitle: provisionalTitle,
            title: title
        )
        if replaced {
            scheduleCloudKitSync(.soon)
            propagateChatToTeams(sessionID: sessionID)
        }
        return replaced
    }

    func updateReviewSessionGoal(sessionID: String, goalID: String?) throws {
        try knowledgeStore().updateReviewSessionGoal(sessionID: sessionID, goalID: goalID)
        scheduleCloudKitSync(.soon)
        propagateChatToTeams(sessionID: sessionID)
    }

    /// Hides a chat from the sidebar on every Mac signed into this account, or
    /// shows it again. Not a change to the chat: its record is not republished
    /// and no team copy follows, because hiding is the learner's view of the
    /// chat, not a fact about it (the same rule as `setArtifactHidden`); the
    /// view syncs as its own private-zone record. Returns the resulting
    /// `hiddenAt`.
    @discardableResult
    func setReviewSessionHidden(sessionID: String, hidden: Bool) throws -> Date? {
        let hiddenAt = try knowledgeStore().setReviewSessionHidden(sessionID, hidden: hidden)
        scheduleCloudKitSync(.soon)
        return hiddenAt
    }

    // What a chat had loaded describes this Mac's prompt, not the
    // conversation, so like the history digest below it never schedules a
    // CloudKit pass.
    func updateReviewSessionLoadedSources(sessionID: String, sourceIDs: [String]) throws {
        try knowledgeStore().updateReviewSessionLoadedSources(sessionID: sessionID, sourceIDs: sourceIDs)
    }

    func loadReviewSessionLoadedSourceIDs(sessionID: String) throws -> [String]? {
        try knowledgeStore().loadReviewSessionLoadedSourceIDs(sessionID: sessionID)
    }

    func chatDiscussedSourceIDs(sessionID: String) throws -> [String] {
        try knowledgeStore().chatDiscussedSourceIDs(sessionID: sessionID)
    }

    func loadReviewSessionGoalID(sessionID: String) throws -> String? {
        try knowledgeStore().loadReviewSessionGoalID(sessionID: sessionID)
    }

    // The history digest is a local cache of the synced exchanges, so neither
    // accessor schedules a CloudKit pass.
    func loadReviewSessionHistoryDigest(sessionID: String) throws -> ReviewSessionHistoryDigest? {
        try knowledgeStore().loadReviewSessionHistoryDigest(sessionID: sessionID)
    }

    func saveReviewSessionHistoryDigest(_ digest: ReviewSessionHistoryDigest) throws {
        try knowledgeStore().saveReviewSessionHistoryDigest(digest)
    }

    @discardableResult
    func addReviewExchange(
        sessionID: String,
        question: String,
        answer: String,
        evaluation: String,
        score: Double? = nil,
        knowledgeNote: String? = nil,
        sourceRefs: [String],
        answeredAt: Date = Date()
    ) throws -> Int {
        let sequence = try knowledgeStore().addReviewExchange(
            sessionID: sessionID,
            question: question,
            answer: answer,
            evaluation: evaluation,
            score: score,
            knowledgeNote: knowledgeNote,
            sourceRefs: sourceRefs,
            answeredAt: answeredAt
        )
        scheduleCloudKitSync(.soon)
        return sequence
    }

    @discardableResult
    func addReviewPrompt(
        sessionID: String,
        question: String,
        sourceRefs: [String]
    ) throws -> Int {
        let sequence = try knowledgeStore().addReviewPrompt(
            sessionID: sessionID,
            question: question,
            sourceRefs: sourceRefs
        )
        scheduleCloudKitSync(.soon)
        propagateChatToTeams(sessionID: sessionID)
        return sequence
    }

    @discardableResult
    func recordPendingReviewUserMessage(
        sessionID: String,
        answer: String,
        sourceRefs: [String],
        contextContent: String? = nil
    ) throws -> Int {
        let sequence = try knowledgeStore().recordPendingReviewUserMessage(
            sessionID: sessionID,
            answer: answer,
            sourceRefs: sourceRefs,
            contextContent: contextContent
        )
        scheduleCloudKitSync(.soon)
        propagateChatToTeams(sessionID: sessionID)
        return sequence
    }

    @discardableResult
    func answerPendingReviewExchange(
        sessionID: String,
        sequence: Int? = nil,
        answer: String,
        evaluation: String,
        score: Double? = nil,
        knowledgeNote: String? = nil,
        sourceRefs: [String],
        answeredAt: Date = Date()
    ) throws -> Int? {
        let answered = try knowledgeStore().answerPendingReviewExchange(
            sessionID: sessionID,
            sequence: sequence,
            answer: answer,
            evaluation: evaluation,
            score: score,
            knowledgeNote: knowledgeNote,
            sourceRefs: sourceRefs,
            answeredAt: answeredAt
        )
        if answered != nil {
            scheduleCloudKitSync(.soon)
            propagateChatToTeams(sessionID: sessionID)
        }
        return answered
    }

    func completeReviewSession(sessionID: String, overallScore: Double? = nil, summary: String, endedAt: Date = Date()) throws {
        try knowledgeStore().completeReviewSession(
            sessionID: sessionID,
            overallScore: overallScore,
            summary: summary,
            endedAt: endedAt
        )
        scheduleCloudKitSync(.immediate)
        propagateChatToTeams(sessionID: sessionID)
    }

    func reopenReviewSession(sessionID: String) throws {
        try knowledgeStore().reopenReviewSession(sessionID: sessionID)
        scheduleCloudKitSync(.immediate)
        propagateChatToTeams(sessionID: sessionID)
    }

    @discardableResult
    func saveReviewSessionLink(title: String, url: String, sourceIDs: [String] = []) throws -> ReviewSessionRecord {
        let link = try knowledgeStore().saveReviewSessionLink(title: title, url: url, sourceIDs: sourceIDs)
        scheduleCloudKitSync(.immediate)
        return link
    }

    /// What `saveImportedChat` did.
    struct ImportedChatOutcome: Equatable, Sendable {
        let sessionID: String
        let created: Bool
        let appended: Int
        let replaced: Int
    }

    /// A chat read from another app's own record of it — a Gemini Notebook
    /// conversation — kept under an id that record gives it. The first import
    /// writes it; a later one brings the stored chat level with the record, as
    /// `import_review_chat` does for a Claude Code session file, so reading a
    /// notebook again adds what was said since without a second copy. It is a
    /// chat and not a review (`kind` chat), so its sources are not marked
    /// reviewed, and it is drawn on the day's log (the Activity pane) at the
    /// hours the record's own stamps say it ran.
    @discardableResult
    func saveImportedChat(
        id: String,
        title: String,
        messages: [ReviewTranscriptMessage],
        sourceIDs: [String],
        notebookID: String?,
        modelProvider: String
    ) throws -> ImportedChatOutcome {
        let store = try knowledgeStore()
        let turns = ReviewTranscriptParser.turns(from: messages)
        guard !turns.isEmpty else {
            throw KnowledgeStoreError.invalidData("The chat “\(title)” had no readable messages.")
        }
        let stamps = messages.compactMap(\.timestamp)
        let outcome: ImportedChatOutcome
        if try store.loadReviewSessionForSync(id) != nil {
            let reconciled = try store.reconcileReviewChatExchanges(
                sessionID: id,
                turns: turns,
                sourceIDs: sourceIDs,
                summary: nil,
                overallScore: nil,
                modelProvider: modelProvider,
                modelID: nil,
                endedAt: stamps.max()
            )
            outcome = ImportedChatOutcome(sessionID: id, created: false, appended: reconciled.appended, replaced: reconciled.replaced)
        } else {
            try store.importReviewChatSession(
                id: id,
                title: title,
                turns: turns,
                sourceIDs: sourceIDs,
                goalID: notebookID,
                summary: nil,
                overallScore: nil,
                modelProvider: modelProvider,
                modelID: nil,
                createdAt: stamps.min() ?? Date(),
                endedAt: stamps.max(),
                kind: .chat,
                chatKind: .chat,
                marksReviewed: false
            )
            outcome = ImportedChatOutcome(sessionID: id, created: true, appended: turns.count, replaced: 0)
        }
        if !stamps.isEmpty {
            do {
                _ = try store.recordDayActivityObservations(kind: .chat, targetID: id, title: title, at: stamps)
            } catch {
                // The chat is saved either way; only its place on the clock is lost.
                perfLogger.error("Imported chat \(id, privacy: .public) could not be put on the day's log: \(error.localizedDescription, privacy: .public)")
            }
        }
        scheduleCloudKitSync(.immediate)
        propagateChatToTeams(sessionID: id)
        return outcome
    }

    func loadReviewSessionLinks() throws -> [ReviewSessionRecord] {
        try knowledgeStore().loadReviewSessionLinks()
    }

    func loadReviewSessionExchanges(sessionID: String) throws -> [ReviewExchangeRecord] {
        try knowledgeStore().loadReviewSessionExchanges(sessionID: sessionID)
    }

    func searchReviewSessionIDs(matching query: String) throws -> Set<String> {
        try knowledgeStore().searchReviewSessionIDs(matching: query)
    }

    func deleteReviewExchangeMessage(
        sessionID: String,
        exchangeID: String,
        field: ReviewExchangeMessageField
    ) throws {
        try knowledgeStore().deleteReviewExchangeMessage(
            sessionID: sessionID,
            exchangeID: exchangeID,
            field: field
        )
        scheduleCloudKitSync(.immediate)
        propagateChatToTeams(sessionID: sessionID)
    }

    func deleteReviewSession(_ sessionId: String) throws {
        try knowledgeStore().deleteReviewSession(sessionId)
        scheduleCloudKitSync(.immediate)
    }

    @discardableResult
    func deleteReviewSessionIfNoRecordedConversation(_ sessionID: String) throws -> Bool {
        let deleted = try knowledgeStore().deleteReviewSessionIfNoRecordedConversation(sessionID)
        if deleted {
            scheduleCloudKitSync(.immediate)
        }
        return deleted
    }

    func updateReviewSessionSources(sessionID: String, sourceIDs: [String]) throws {
        try knowledgeStore().updateReviewSessionSources(sessionID: sessionID, sourceIDs: sourceIDs)
        scheduleCloudKitSync(.immediate)
        propagateChatToTeams(sessionID: sessionID)
    }

    func loadLearningGoals() throws -> [LearningGoalRecord] {
        try knowledgeStore().loadLearningGoals()
    }

    /// A Notebook's own sources followed by each context notebook's, put into
    /// its chats or not: every source one of its boxes can stand for
    /// (`KnowledgeStore.notebookContextSourceIDs`). Its chats read only the
    /// context notebooks put in (`NotebookChatContext.chatPool`).
    func notebookContextSourceIDs(notebookID: String) throws -> [String] {
        try knowledgeStore().notebookContextSourceIDs(notebookID: notebookID)
    }

    func loadLearningGoal(_ id: String) throws -> LearningGoalRecord? {
        try knowledgeStore().loadLearningGoal(id)
    }

    // MARK: - Shared Schedule placements

    func loadScheduledSources(goalID: String? = nil) throws -> [ScheduledSourceEntry] {
        try knowledgeStore().loadScheduledSources(goalID: goalID)
    }

    func addSourceToGoal(sourceID: String, goalID: String, plannedAt: Date? = nil) throws {
        try knowledgeStore().addSourceToGoal(sourceID: sourceID, goalID: goalID, plannedAt: plannedAt)
        scheduleCloudKitSync(.immediate)
    }

    func removeSourceFromGoal(sourceID: String, goalID: String) throws {
        try knowledgeStore().removeSourceFromGoal(sourceID: sourceID, goalID: goalID)
        scheduleCloudKitSync(.immediate)
    }

    func removeScheduledSource(sourceID: String) throws {
        try knowledgeStore().removeScheduledSource(sourceID: sourceID)
        scheduleCloudKitSync(.immediate)
    }

    /// Batch schedule removal for day and week clears. Goal-scoped clears
    /// remove only that goal's tag; unified Schedule clears delete the placements.
    /// KnowledgeStore records CloudKit metadata for each mutation, then the batch
    /// schedules one outbound sync (including any changes made before an error).
    func removeSourcesFromSchedule(goalID: String?, sourceIDs: [String]) throws {
        guard !sourceIDs.isEmpty else { return }
        defer { scheduleCloudKitSync(.immediate) }
        try knowledgeStore().removeSourcesFromSchedule(goalID: goalID, sourceIDs: sourceIDs)
    }

    func setScheduledSourcePlannedDate(
        sourceID: String,
        plannedAt: Date,
        beforeSourceID: String? = nil
    ) throws {
        try knowledgeStore().setScheduledSourcePlannedDate(
            sourceID: sourceID,
            plannedAt: plannedAt,
            beforeSourceID: beforeSourceID
        )
        scheduleCloudKitSync(.immediate)
    }

    /// Read-only: the History pane's day-by-day record of what was consumed.
    func loadSourceConsumptionHistory(limit: Int = 500, since: Date? = nil) throws -> [SourceConsumptionEntry] {
        try knowledgeStore().loadSourceConsumptionHistory(limit: limit, since: since)
    }

    func setScheduledSourceCompletion(sourceID: String, isCompleted: Bool) throws {
        try knowledgeStore().setScheduledSourceCompletion(sourceID: sourceID, isCompleted: isCompleted)
        scheduleCloudKitSync(.immediate)
    }

    func recordScheduledSourceReview(sourceID: String, on day: Date) throws {
        try knowledgeStore().recordScheduledSourceReview(sourceID: sourceID, on: day)
        scheduleCloudKitSync(.immediate)
    }

    func recordScheduledSourceCompletion(
        sourceID: String,
        on day: Date,
        kind: SourceActivityKind
    ) throws {
        try knowledgeStore().recordScheduledSourceCompletion(
            sourceID: sourceID,
            on: day,
            kind: kind
        )
        scheduleCloudKitSync(.immediate)
    }

    func recordScheduledSourceCompletions(
        sourceIDs: [String],
        on day: Date,
        kind: SourceActivityKind
    ) throws {
        try knowledgeStore().recordScheduledSourceCompletions(
            sourceIDs: sourceIDs,
            on: day,
            kind: kind
        )
        scheduleCloudKitSync(.immediate)
    }

    /// Record automatic learning activity and make sure the source has a
    /// Schedule anchor. Explicit goal-backed plans remain independent.
    @discardableResult
    func recordScheduledSourceActivity(
        sourceID: String,
        on day: Date,
        kind: SourceActivityKind,
        fraction: Double? = nil,
        engagedSeconds: Double = 0
    ) throws -> Bool {
        let inserted = try knowledgeStore().recordScheduledSourceActivity(
            sourceID: sourceID,
            on: day,
            kind: kind,
            fraction: fraction,
            engagedSeconds: engagedSeconds
        )
        scheduleCloudKitSync(.immediate)
        return inserted
    }

    /// Plays Apple Podcasts saw, recorded as listening on the day of each play.
    /// See `KnowledgeStore.recordExternalListening`. A sync pass can record a
    /// month of plays at once, so the push is coalesced; the day's log is told
    /// only when something landed on it.
    @discardableResult
    func recordExternalListening(_ listens: [ExternalListen]) throws -> [String] {
        guard !listens.isEmpty else { return [] }
        let recorded = try knowledgeStore().recordExternalListening(listens)
        if !recorded.isEmpty {
            scheduleCloudKitSync(.coalesced)
            NotificationCenter.default.post(name: .dayPlansDidChange, object: nil)
        }
        return recorded
    }

    /// Time spent with one source across its activity days.
    func sourceEngagedSeconds(sourceID: String) throws -> Double {
        try knowledgeStore().sourceEngagedSeconds(sourceID: sourceID)
    }

    func setCompanionItemReviewState(goalID: String, sourceIDs: [String], state: LearningGoalItemReviewState) throws {
        try knowledgeStore().setCompanionItemReviewState(goalID: goalID, sourceIDs: sourceIDs, state: state)
        scheduleCloudKitSync(.immediate)
        if state == .approved {
            propagateNotebookSourcesToTeams(notebookID: goalID, sourceIDs: sourceIDs)
        }
    }

    func removeCompanionSources(goalID: String, sourceIDs: [String]) throws {
        try knowledgeStore().removeCompanionSources(goalID: goalID, sourceIDs: sourceIDs)
        scheduleCloudKitSync(.immediate)
    }

    func reorderCompanionSources(goalID: String, orderedSourceIDs: [String]) throws {
        try knowledgeStore().reorderCompanionSources(goalID: goalID, orderedSourceIDs: orderedSourceIDs)
        scheduleCloudKitSync(.immediate)
    }

    @discardableResult
    func createCompanionGoal(
        title: String,
        description: String? = nil,
        summary: String? = nil,
        topic: String,
        startAt: Date,
        endAt: Date,
        dailyTarget: Int,
        discoveryEnabled: Bool,
        seedSourceIDs: [String],
        parentNotebookID: String? = nil,
        teamID: String? = nil,
        artifactID: String? = nil
    ) throws -> LearningGoalRecord {
        let goal = try knowledgeStore().createCompanionGoal(
            title: title,
            description: description,
            summary: summary,
            topic: topic,
            startAt: startAt,
            endAt: endAt,
            dailyTarget: dailyTarget,
            discoveryEnabled: discoveryEnabled,
            seedSourceIDs: seedSourceIDs,
            parentNotebookID: parentNotebookID,
            teamID: teamID,
            artifactID: artifactID
        )
        scheduleCloudKitSync(.immediate)
        if let parentNotebookID, teamID == nil {
            propagateNestedGoalToTeams(goalID: goal.id)
            propagateNotebookSourcesToTeams(notebookID: parentNotebookID, sourceIDs: seedSourceIDs)
        }
        return goal
    }

    /// The Board's Notebook (`KnowledgeStore.ensureBoardNotebook`), made on
    /// first use and synced when it is.
    func ensureBoardNotebook() throws -> LearningGoalRecord {
        let result = try knowledgeStore().ensureBoardNotebook()
        if result.created { scheduleCloudKitSync(.immediate) }
        return result.notebook
    }

    func companionRecentSessions(goalID: String, limit: Int) throws -> [CompanionSessionSummary] {
        try knowledgeStore().companionRecentSessions(goalID: goalID, limit: limit)
    }

    func deleteLearningGoal(
        _ goalID: String,
        cascadeChildGoals: Bool = false,
        deleteLinkedChats: Bool = false
    ) throws {
        // Resolved before the row goes: the workspace path is derived from a
        // Notebook that still has to load. `notebook_files` cascades on the FK,
        // but those rows are only an index — the folder on disk is the file.
        let workspaceURL = try? notebookWorkspaceURL(notebookID: goalID, createIfNeeded: false)
        try knowledgeStore().deleteLearningGoal(
            goalID,
            cascadeChildGoals: cascadeChildGoals,
            deleteLinkedChats: deleteLinkedChats
        )
        if let workspaceURL {
            discardNotebookWorkspace(at: workspaceURL)
        }
        scheduleCloudKitSync(.immediate)
    }

    func splitCompanionGoal(
        sourceGoalID: String,
        splits: [CompanionGoalSplitSpec],
        keepParent: Bool = true
    ) throws -> CompanionGoalSplitResult {
        let store = try knowledgeStore()
        // Resolved while the parent still exists, as a merge does: a split
        // that removes the parent hands its folder to the heir.
        let parent = try store.loadLearningGoal(sourceGoalID)
        let parentWorkspace = parent?.isNotebook == true
            ? try notebookWorkspaceURL(notebookID: sourceGoalID, createIfNeeded: false)
            : nil
        let result = try store.splitCompanionGoal(
            sourceGoalID: sourceGoalID,
            splits: splits,
            keepParent: keepParent
        )
        if let heirID = result.heirGoalID, let parent, let parentWorkspace,
           FileManager.default.fileExists(atPath: parentWorkspace.path) {
            let heirWorkspace = try notebookWorkspaceURL(notebookID: heirID, createIfNeeded: true)
            _ = Self.adoptNotebookWorkspace(from: parentWorkspace, into: heirWorkspace, mergedNotebookTitle: parent.title)
            _ = try? loadNotebookFiles(notebookID: heirID)
        }
        scheduleCloudKitSync(.immediate)
        if store.syncGeneration == .two {
            // Generation 2's split job handed the member's NotebookState sets
            // to the heir in the store (schema v2 §5.2); the surfaces read them again.
            if result.heirGoalID != nil { NotebookStateStore.reload() }
        } else if let heirID = result.heirGoalID {
            // The parent's unticked boxes and the context notebooks its chats
            // read go to the heir and the parent's rows go, as MCP
            // `split_notebook` does.
            NotebookChatSelection.handOver(
                fromParent: sourceGoalID,
                toHeir: heirID,
                heirPool: try store.notebookContextSourceIDs(notebookID: heirID),
                heirLinks: try store.relatedNotebookIDsForNotebook(notebookID: heirID)
            )
            // And its collections.
            NotebookCollectionRows.handOver(fromParent: sourceGoalID, toHeir: heirID)
        }
        return result
    }

    func mergeCompanionGoals(
        notebookIDs: [String],
        title: String? = nil,
        mergeNotes: Bool = true
    ) throws -> CompanionGoalMergeResult {
        let store = try knowledgeStore()
        // Workspace folders are resolved while every Notebook still exists: the
        // path is derived from a row the merge is about to delete, and the
        // folder — not the `notebook_files` index that cascades with the row —
        // is the learner's files.
        var mergeeWorkspaces: [(title: String, url: URL)] = []
        var seen = Set<String>()
        for id in notebookIDs.dropFirst() where seen.insert(id).inserted && id != notebookIDs.first {
            guard let goal = try store.loadLearningGoal(id), goal.isNotebook else { continue }
            let url = try notebookWorkspaceURL(notebookID: id, createIfNeeded: false)
            mergeeWorkspaces.append((goal.title, url))
        }
        var result = try store.mergeCompanionGoals(
            notebookIDs: notebookIDs,
            title: title,
            mergeNotes: mergeNotes
        )
        let occupied = mergeeWorkspaces.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if !occupied.isEmpty {
            let survivorWorkspace = try notebookWorkspaceURL(notebookID: result.survivorGoalID, createIfNeeded: true)
            for workspace in occupied {
                result.filesMoved += Self.adoptNotebookWorkspace(
                    from: workspace.url,
                    into: survivorWorkspace,
                    mergedNotebookTitle: workspace.title
                )
            }
            _ = try? loadNotebookFiles(notebookID: result.survivorGoalID)
        }
        scheduleCloudKitSync(.immediate)
        return result
    }

    func setLearningGoalDescription(goalID: String, description: String?) throws {
        try knowledgeStore().setLearningGoalDescription(goalID: goalID, description: description)
        scheduleCloudKitSync(.immediate)
    }

    func setLearningGoalTitle(goalID: String, title: String) throws {
        try knowledgeStore().setLearningGoalTitle(goalID: goalID, title: title)
        scheduleCloudKitSync(.immediate)
    }

    func setLearningGoalSummary(goalID: String, summary: String?) throws {
        try knowledgeStore().setLearningGoalSummary(goalID: goalID, summary: summary)
        scheduleCloudKitSync(.immediate)
    }

    func setLearningGoalNotes(goalID: String, notes: String) throws {
        try knowledgeStore().setLearningGoalNotes(goalID: goalID, notes: notes)
        scheduleCloudKitSync(.immediate)
    }

    func setLearningGoalResearchQuestions(goalID: String, questions: [String]) throws {
        try knowledgeStore().setLearningGoalResearchQuestions(goalID: goalID, questions: questions)
        scheduleCloudKitSync(.immediate)
    }

    func setRelatedNotebooks(notebookID: String, relatedNotebookIDs: [String]) throws {
        try knowledgeStore().setRelatedNotebooks(
            notebookID: notebookID,
            relatedNotebookIDs: relatedNotebookIDs
        )
        scheduleCloudKitSync(.immediate)
    }

    func setNotebookRepository(notebookID: String, repository: String?) throws {
        try knowledgeStore().setNotebookRepository(notebookID: notebookID, repository: repository)
        scheduleCloudKitSync(.immediate)
    }

    /// Link a Goal to the Doc, Site or animation it is for, or unlink it with nil.
    func setLearningGoalArtifact(goalID: String, artifactID: String?) throws {
        try knowledgeStore().setLearningGoalArtifact(goalID: goalID, artifactID: artifactID)
        scheduleCloudKitSync(.immediate)
    }

    /// Put the Goals in the learner's order: the listed ids first, the rest
    /// as they read; an empty list is deadline order again.
    @discardableResult
    func reorderLearningGoals(goalIDs: [String]) throws -> [String] {
        let order = try knowledgeStore().reorderLearningGoals(goalIDs: goalIDs)
        scheduleCloudKitSync(.immediate)
        return order
    }

    func loadLearningGoalGaps(goalID: String) throws -> [LearningGoalGap] {
        try knowledgeStore().loadLearningGoalGaps(goalID: goalID)
    }

    // MARK: - Video Cited Papers

    func saveVideoCitedPaper(_ paper: VideoCitedPaper) throws {
        try ensureStoreExists()
        try knowledgeStore().saveVideoCitedPaper(paper)
        scheduleCloudKitSync(.immediate)
    }

    func loadVideoCitedPapers(forSourceID sourceID: String) throws -> [VideoCitedPaper] {
        try ensureStoreExists()
        return try knowledgeStore().loadVideoCitedPapers(forSourceID: sourceID)
    }

    func loadVideoCitedPaper(id: String) throws -> VideoCitedPaper? {
        try ensureStoreExists()
        return try knowledgeStore().loadVideoCitedPaper(id: id)
    }

    func deleteVideoCitedPaper(id: String) throws {
        try ensureStoreExists()
        try knowledgeStore().deleteVideoCitedPaper(id: id)
        scheduleCloudKitSync(.immediate)
    }

    func upsertCompanionGaps(goalID: String, gaps: [LearningGoalGap]) throws {
        try knowledgeStore().upsertCompanionGaps(goalID: goalID, gaps: gaps)
        scheduleCloudKitSync(.immediate)
    }

    func saveLearningGoalGap(_ gap: LearningGoalGap, goalID: String) throws {
        try knowledgeStore().saveLearningGoalGap(gap, goalID: goalID)
        try knowledgeStore().touchLearningGoal(goalID)
        scheduleCloudKitSync(.immediate)
    }

    @discardableResult
    func addCompanionSeedSources(goalID: String, sourceIDs: [String]) throws -> Int {
        let sourceIDs = try sourceIDsForGoalLibrary(goalID: goalID, sourceIDs)
        let added = try knowledgeStore().addCompanionSeedSources(goalID: goalID, sourceIDs: sourceIDs)
        scheduleCloudKitSync(.immediate)
        propagateNotebookSourcesToTeams(notebookID: goalID, sourceIDs: sourceIDs)
        return added
    }

    @discardableResult
    func linkCourseToNotebook(goalID: String, courseID: String, sourceIDs: [String]) throws -> Int {
        let sourceIDs = try sourceIDsForGoalLibrary(goalID: goalID, sourceIDs)
        let added = try knowledgeStore().linkCourseToNotebook(
            goalID: goalID,
            courseID: courseID,
            sourceIDs: sourceIDs
        )
        scheduleCloudKitSync(.immediate)
        propagateNotebookSourcesToTeams(notebookID: goalID, sourceIDs: sourceIDs)
        return added
    }

    /// The Sources sidebar's Remove All on a course the notebook follows.
    @discardableResult
    func unlinkCourseFromNotebook(goalID: String, courseID: String) throws -> Bool {
        let unlinked = try knowledgeStore().unlinkCourseFromNotebook(goalID: goalID, courseID: courseID)
        if unlinked { scheduleCloudKitSync(.immediate) }
        return unlinked
    }

    func linkedCourseIDsForNotebook(goalID: String) throws -> [String] {
        try knowledgeStore().linkedCourseIDsForNotebook(goalID: goalID)
    }

    // MARK: - A course and its notebooks (docs/courses-design.md, "A course is its own thing")

    func screenRecordShownCourseIDs(scope: ScreenRecordScope) throws -> Set<String> {
        try knowledgeStore().screenRecordShownCourseIDs(scope: scope)
    }

    /// A notebook follows a course, validated: Link to Notebook, a course
    /// made or imported from a notebook, an MCP `notebook_id`
    /// (`KnowledgeStore.followCourse`). A personal notebook shared with teams
    /// passes the course's sources on, as any addition to it does
    /// (teams-design.md, decision 10). Returns how many sources joined.
    @discardableResult
    func followCourse(courseID: String, notebookID: String) throws -> Int {
        let store = try knowledgeStore()
        let added = try store.followCourse(courseID: courseID, notebookID: notebookID)
        scheduleCloudKitSync(.immediate)
        if added > 0 {
            propagateNotebookSourcesToTeams(notebookID: notebookID, sourceIDs: try store.sourceIDsForCourse(courseID))
        }
        return added
    }

    /// "Make Study Notebook" on a course (`KnowledgeStore.makeStudyNotebook`).
    @discardableResult
    func makeStudyNotebook(courseID: String) throws -> CourseStudyNotebook {
        let store = try knowledgeStore()
        let made = try store.makeStudyNotebook(courseID: courseID)
        scheduleCloudKitSync(.immediate)
        if made.sourcesAdded > 0 {
            propagateNotebookSourcesToTeams(notebookID: made.notebookID, sourceIDs: try store.sourceIDsForCourse(courseID))
        }
        return made
    }

    /// The notebook as `NotebookMembership` asks it, for a list filtered to it.
    func notebookMembership(notebookID: String) throws -> NotebookMembership {
        try knowledgeStore().notebookMembership(notebookID: notebookID)
    }

    /// Every course each notebook follows, keyed by course.
    func loadCourseFollowers() throws -> [String: [String]] {
        try knowledgeStore().loadCourseFollowers()
    }

    func setLearningGoalStatus(goalID: String, status: LearningGoalStatus) throws {
        try knowledgeStore().setLearningGoalStatus(goalID: goalID, status: status)
        scheduleCloudKitSync(.immediate)
    }

    func setLearningGoalDeadline(goalID: String, endAt: Date) throws {
        try knowledgeStore().setLearningGoalDeadline(goalID: goalID, endAt: endAt)
        scheduleCloudKitSync(.immediate)
    }

    func setLearningGoalParentNotebook(goalID: String, parentNotebookID: String?) throws {
        try knowledgeStore().setLearningGoalParentNotebook(goalID: goalID, parentNotebookID: parentNotebookID)
        scheduleCloudKitSync(.immediate)
        if parentNotebookID != nil {
            propagateNestedGoalToTeams(goalID: goalID)
        }
    }

    /// Archive a source: mark as archived, delete content and embeddings,
    /// and drop it from both search indexes.
    func archiveSource(_ sourceId: String) throws {
        try knowledgeStore().archiveSource(sourceId)
        scheduleCloudKitSync(.immediate)
        removeFromSearchIndexes(sourceId)
    }

    /// Take every preprint's published DOI out of its work keys, so the journal
    /// version is no duplicate of it (`KnowledgeStore.removePublishedDOIWorkKeys`).
    @discardableResult
    func removePublishedDOIWorkKeys() throws -> Int {
        let removed = try knowledgeStore().removePublishedDOIWorkKeys()
        if removed > 0 { scheduleCloudKitSync(.immediate) }
        return removed
    }

    /// Collapse a deterministic paper duplicate without dropping relationships
    /// authored against the losing source id.
    func archivePaperIdentityDuplicate(
        _ duplicateID: String,
        replacingWith canonicalID: String
    ) throws {
        try knowledgeStore().archivePaperIdentityDuplicate(
            duplicateID,
            replacingWith: canonicalID
        )
        scheduleCloudKitSync(.immediate)
        removeFromSearchIndexes(duplicateID)
    }

    /// Collapse a meeting session that a retired session-key rule filed twice,
    /// keeping every relationship authored against the losing session id.
    func archiveMeetingSessionDuplicate(
        _ duplicateID: String,
        replacingWith canonicalID: String
    ) throws {
        try knowledgeStore().archiveMeetingSessionDuplicate(
            duplicateID,
            replacingWith: canonicalID
        )
        scheduleCloudKitSync(.immediate)
        removeFromSearchIndexes(duplicateID)
    }

    /// Permanently delete a source and propagate the deletion to CloudKit.
    func deleteSource(_ sourceId: String) throws {
        let explainerID = GeneratedExplainer.sourceID(explaining: sourceId)
        let hadExplainer = try knowledgeStore().loadSourceWithoutContent(explainerID) != nil
        // An audio overview's carrier takes its Artifact with it, in the
        // store's transaction; the Artifact's body directory goes here.
        let overviewID = try knowledgeStore().loadSourceWithoutContent(sourceId)
            .flatMap(GeneratedAudioOverview.artifactID(ofCarrier:))
        let overviewDirectory = try overviewID.flatMap { id in
            try knowledgeStore().loadArtifact(id) == nil ? nil : try artifactDirectoryURL(artifactID: id, createIfNeeded: false)
        }
        try knowledgeStore().deleteSource(sourceId)
        scheduleCloudKitSync(.immediate)
        removeFromSearchIndexes(sourceId)
        // The store deleted the source's explainer with it; its index rows go too.
        if hadExplainer {
            removeFromSearchIndexes(explainerID)
        }
        if let overviewDirectory {
            try? FileManager.default.removeItem(at: overviewDirectory)
        }
    }

    /// Drop a source from the in-memory vector index and from every search row the store keeps
    /// for it (`KnowledgeStore.dropSourceSearchRows`: full-text row, stamps, vectors), so an
    /// archived or deleted source stops surfacing in search now and after the next launch.
    func removeFromSearchIndexes(_ sourceId: String) {
        do {
            let ks = try knowledgeStore()
            SharedSourceVectorIndex.shared.withIndex(storePath: ks.dbPath, dimensions: Self.sourceEmbeddingDimensions) { index in
                index.replace(
                    sourceID: sourceId,
                    chunks: [],
                    sourceIDForChunk: Self.sourceId(fromSourceChunkEmbeddingId:)
                )
            }
            try ks.dropSourceSearchRows(sourceID: sourceId)
        } catch {
            perfLogger.error("Failed to drop search index rows for \(sourceId, privacy: .public): \(error.localizedDescription)")
        }
    }

    /// Take out of search up to `limit` sources that are out of it yet still hold a part of it
    /// (`KnowledgeStore.sourcesOutOfSearchHoldingSearchRows`: archived or deleted by sync, indexed
    /// while being archived, or left by an older build), and return how many. Each one's rows go
    /// from the store; the vectors in memory go one source at a time for a few, and for more the
    /// index is dropped once and rebuilt from the store by the next search, since each removal
    /// rewrites the whole matrix.
    func dropSearchRowsOfSourcesOutOfSearch(limit: Int) throws -> Int {
        let ks = try knowledgeStore()
        let sourceIDs = try ks.sourcesOutOfSearchHoldingSearchRows(limit: limit)
        guard !sourceIDs.isEmpty else { return 0 }
        for sourceID in sourceIDs {
            try ks.dropSourceSearchRows(sourceID: sourceID)
        }
        SharedSourceVectorIndex.shared.withIndex(storePath: ks.dbPath, dimensions: Self.sourceEmbeddingDimensions) { index in
            guard sourceIDs.count <= Self.searchSweepInPlaceRemovals else {
                index.invalidate()
                return
            }
            for sourceID in sourceIDs {
                index.replace(sourceID: sourceID, chunks: [], sourceIDForChunk: Self.sourceId(fromSourceChunkEmbeddingId:))
            }
        }
        return sourceIDs.count
    }

    /// Sources a sweep takes out of the vectors in memory one by one; more drop the index.
    static let searchSweepInPlaceRemovals = 4

    /// Check all active sources with local file paths.
    /// Archive any whose file no longer exists on disk.
    /// Returns the count of archived sources.
    func reconcileLocalFiles() throws -> Int {
        try ensureStoreExists()
        let ks = try knowledgeStore()
        let sources = try ks.loadActiveSources()
        let fm = FileManager.default
        var archivedCount = 0

        for source in sources {
            guard let filePath = source.localFilePath, !filePath.isEmpty else { continue }

            // Resolve through the app's single list of relocation rules rather
            // than a local existence check. This pass decides whether to archive
            // a source, so a rule it doesn't know about is a source it would
            // wrongly declare gone — a file sitting in an iCloud conflict fork,
            // or one iCloud hasn't downloaded yet, is present.
            if let located = Self.locateSourceFile(filePath) {
                if !fm.fileExists(atPath: located) {
                    try? fm.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: located))
                }
                continue
            }

            if Self.isAppManagedSourcePath(filePath) {
                continue
            }

            // If the source has a web URL, don't archive — just clear the local
            // file path. The web URL is still valid and the PDF can be re-downloaded.
            let sourceURL = source.url
            if sourceURL.hasPrefix("http://") || sourceURL.hasPrefix("https://") {
                var updated = source
                updated.localFilePath = nil
                try ks.saveSource(updated)
                continue
            }

            try ks.archiveSource(source.id)
            archivedCount += 1
        }

        return archivedCount
    }

    /// Save content for a source and update its state to 'ready'. See
    /// `KnowledgeStore.saveTranscript` for the podcast clean-up parameters.
    func saveTranscript(
        _ sourceId: String,
        _ text: String,
        rawTTML: String? = nil,
        podcastCleanupInput: String? = nil,
        podcastFormatting: PodcastTranscriptFormattingRequest? = nil,
        allowsShorterTranscript: Bool = false
    ) throws {
        try knowledgeStore().saveTranscript(
            sourceId,
            text,
            rawTTML: rawTTML,
            podcastCleanupInput: podcastCleanupInput,
            podcastFormatting: podcastFormatting,
            allowsShorterTranscript: allowsShorterTranscript
        )
        scheduleCloudKitSync()
        NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
    }

    /// Move a podcast episode onto its public Apple Podcasts identity. See
    /// `KnowledgeStore.rebindPodcastEpisodeIdentity`.
    func rebindPodcastEpisodeIdentity(
        _ sourceId: String,
        toPublicURL publicURL: String,
        webPageURL: String?
    ) throws {
        try knowledgeStore().rebindPodcastEpisodeIdentity(
            sourceId,
            toPublicURL: publicURL,
            webPageURL: webPageURL
        )
        scheduleCloudKitSync()
        removeFromSearchIndexes(sourceId)
    }

    /// Fold a podcast row into the row that already holds its public identity.
    func archivePodcastEpisodeDuplicate(
        _ duplicateID: String,
        replacingWith canonicalID: String
    ) throws {
        try knowledgeStore().archivePodcastEpisodeDuplicate(
            duplicateID,
            replacingWith: canonicalID
        )
        scheduleCloudKitSync(.immediate)
        removeFromSearchIndexes(duplicateID)
    }

    func savePodcastYouTubeTranscript(
        _ sourceId: String,
        _ text: String,
        youtubeURL: String?,
        cleanupInput: String? = nil
    ) throws {
        try knowledgeStore().savePodcastYouTubeTranscript(
            sourceId,
            text,
            youtubeURL: youtubeURL,
            cleanupInput: cleanupInput
        )
        scheduleCloudKitSync()
        NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
    }

    /// Save raw TTML for an existing source_content row.
    func saveRawTTML(_ sourceId: String, _ ttml: String) throws {
        try knowledgeStore().saveRawTTML(sourceId, ttml)
    }

    /// Load the original Apple Podcasts TTML for display-only transcript rendering.
    func loadPodcastRawTTML(_ sourceId: String) throws -> String? {
        try knowledgeStore().loadPodcastRawTTML(sourceId)
    }

    /// Return the set of Apple Podcasts track IDs that already have transcript content in the DB.
    func podcastTrackIdsWithContent() -> Set<Int64> {
        guard let store = try? knowledgeStore() else { return [] }
        return store.podcastTrackIdsWithContent()
    }

    /// Look up an existing source row by its normalized URL.
    func sourceRecordByNormalizedURL(_ normalizedURL: String) -> (id: String, status: SourceStatus)? {
        guard let store = try? knowledgeStore() else { return nil }
        return store.sourceExistsByNormalizedURL(normalizedURL)
    }

    /// Which of a doc's web references the library already holds, as address →
    /// active source id. An address with no active source is left out. The
    /// library is the Doc's: nil asks My Library, a team id asks that team's
    /// copies and nothing else.
    func librarySourceIDs(forReferenceURLs urls: [String], teamID: String? = nil) -> [String: String] {
        guard !urls.isEmpty, let store = try? knowledgeStore() else { return [:] }
        var matches: [String: String] = [:]
        for url in urls {
            if let id = store.activeSourceID(forReferenceURL: url, teamID: teamID) { matches[url] = id }
        }
        return matches
    }

    /// Look up an existing source row by its persisted URL.
    func sourceRecordByURL(_ url: String) -> (id: String, status: SourceStatus)? {
        guard let store = try? knowledgeStore() else { return nil }
        return store.sourceExistsByURL(url)
    }

    /// Resolve an imported book chapter to an existing source row, even when only
    /// the normalized URL or local file path matches.
    func existingImportedChapterRecord(for article: StudioArticle) -> (id: String, status: SourceStatus)? {
        guard let store = try? knowledgeStore() else { return nil }
        let normalizedURL = article.normalizedURL ?? URLNormalizer.normalize(article.url)
        if let match = store.sourceExistsByURL(article.url) { return match }
        if let match = store.sourceExistsByNormalizedURL(normalizedURL) { return match }
        if let localFilePath = article.localFilePath,
           let match = store.sourceExistsByBookLocalFilePath(localFilePath) {
            return match
        }
        // A chapter of a book kept as one file is addressed by its first page, so a re-import that
        // moved the chapter's start, or one of a book split into chapter files before, finds it by
        // its title among the chapters the re-import just archived: it keeps its id, and with it
        // its highlights, reading position and notebooks.
        if article.bookPages != nil, let bookID = article.parentGroup,
           let match = store.archivedBookChapter(bookID: bookID, title: article.title) {
            return match
        }
        return nil
    }

    func isSourceDismissed(url: String) -> Bool {
        guard let store = try? knowledgeStore() else { return false }
        return store.isSourceDismissed(url: url)
    }

    /// Persist the learner's explicit re-add intent before inserting the source.
    /// This writes a synced DismissedSource deletion even when this Mac has not
    /// received an older dismissal yet, preventing delayed CloudKit delivery
    /// from silently archiving the newly added row.
    func prepareExplicitSourceReAdd(_ url: String) throws {
        try ensureStoreExists()
        _ = try knowledgeStore().undismissSource(url: url)
        scheduleCloudKitSync(.immediate)
    }

    /// Bring back a source that a feed mirror had archived, for feeds where
    /// archived-ness is derived from the feed rather than chosen by the user —
    /// the YouTube Liked mirror archives on unlike, so a re-like has to be able
    /// to undo that. Without this, `insertSourceIfNew` refuses the re-insert
    /// (the row still exists) while every later lookup goes through
    /// `loadActiveSources`, which cannot see it: the video is dropped silently
    /// and never returns.
    ///
    /// Returns the revived source id, or nil when there is nothing to revive —
    /// no row, or already active.
    ///
    /// Pass `clearingDismissal: true` when the caller mirrors an explicit user
    /// action upstream rather than passive re-discovery. A dismissal normally
    /// blocks the revive, which is right for a feed that merely re-suggests a
    /// URL — but it made a re-liked video permanently unreachable, because
    /// dismissal also blocks `insertSourceIfNew`, so neither revive nor insert
    /// could bring the row back no matter how often the user liked it again.
    /// The caller owns the freshness check: it must pass `true` only after
    /// establishing that the upstream action is *newer* than the dismissal (the
    /// liked sync compares each entry's `likedAt` against `dismissed_at`). A
    /// video merely still liked from before an in-app removal must never clear
    /// the tombstone — that would resurrect the removal on every sync.
    func unarchiveSourceMatchingURL(_ url: String, clearingDismissal: Bool = false) throws -> String? {
        try ensureStoreExists()
        let store = try knowledgeStore()
        var clearedDismissal = false
        if store.isSourceDismissed(url: url) {
            guard clearingDismissal else { return nil }
            clearedDismissal = try !store.undismissSource(url: url).isEmpty
        }
        let normalizedURL = URLNormalizer.normalize(url)
        guard let match = store.sourceExistsByNormalizedURL(normalizedURL) ?? store.sourceExistsByURL(url),
              match.status == .archived else {
            // No row survived to revive, but a cleared tombstone is itself a
            // change worth syncing — and it unblocks the caller's re-insert.
            if clearedDismissal { scheduleCloudKitSync() }
            return nil
        }
        try store.unarchiveSource(match.id)
        scheduleCloudKitSync()
        return match.id
    }

    /// Update a source's parent_group (set to NULL if group is nil).
    func updateParentGroup(_ sourceId: String, _ group: String?) throws {
        try knowledgeStore().updateParentGroup(sourceId, group)
        scheduleCloudKitSync()
    }

    func mergeMeetingGroup(_ sourceGroupID: String, into targetGroupID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().mergeMeetingGroup(sourceGroupID, into: targetGroupID)
        scheduleCloudKitSync(.immediate)
    }

    // MARK: - One sitting, one session

    /// Fold the named sessions of one series into the one that started first
    /// (`KnowledgeStore.mergeMeetingSessions`), then take the absorbed rows out
    /// of the search indexes and queue the sync, the way a removed session
    /// leaves. The survivor's new text is re-embedded by the derived-work drain.
    func mergeMeetingSessions(_ ids: [String]) throws -> MeetingSessionMergeOutcome? {
        try ensureStoreExists()
        guard let outcome = try knowledgeStore().mergeMeetingSessions(ids) else { return nil }
        finishMeetingSessionMerge(outcome)
        return outcome
    }

    /// The explicit rule: every day of the series that holds more than one
    /// finished session becomes one session, or only `date` (`YYYY-MM-DD`)
    /// does. Idempotent — a series already at one session a day does nothing.
    func mergeSameDayMeetingSessions(groupID: String, date: String? = nil) throws -> [MeetingSessionMergeOutcome] {
        try ensureStoreExists()
        let store = try knowledgeStore()
        let canonical = try store.canonicalMeetingGroupID(groupID)
        var outcomes: [MeetingSessionMergeOutcome] = []
        for run in try store.sameDayMeetingSessionRuns(groupID: canonical, date: date) {
            guard let outcome = try store.mergeMeetingSessions(run) else { continue }
            finishMeetingSessionMerge(outcome)
            outcomes.append(outcome)
        }
        return outcomes
    }

    /// The automatic rule, run when a session's transcript has landed
    /// (`MeetingActionItemExtractor.noteTranscriptReady`, the one funnel every
    /// ingest route ends in): when another ready session of the series began
    /// on the same day within `MeetingSessionContinuation.window`, the two —
    /// or more — become one. Nil when the session stands alone.
    func absorbMeetingSessionContinuation(sourceID: String) throws -> MeetingSessionMergeOutcome? {
        try ensureStoreExists()
        let store = try knowledgeStore()
        guard let run = try store.meetingSessionContinuationRun(for: sourceID),
              let outcome = try store.mergeMeetingSessions(run) else { return nil }
        finishMeetingSessionMerge(outcome)
        return outcome
    }

    private func finishMeetingSessionMerge(_ outcome: MeetingSessionMergeOutcome) {
        for id in outcome.absorbedIDs {
            removeFromSearchIndexes(id)
        }
        scheduleCloudKitSync(.immediate)
        NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
    }

    @discardableResult
    func updateCourseSortIndex(_ sourceId: String, _ sortIndex: Int) throws -> Bool {
        let changed = try knowledgeStore().updateCourseSortIndex(sourceId, sortIndex)
        if changed { scheduleCloudKitSync() }
        return changed
    }

    @discardableResult
    func updateVideoFeedDates(_ sourceId: String, likedAt: Date?, videoPublishedAt: Date?) throws -> Bool {
        let changed = try knowledgeStore().updateVideoFeedDates(
            sourceID: sourceId,
            likedAt: likedAt,
            videoPublishedAt: videoPublishedAt
        )
        if changed { scheduleCloudKitSync() }
        return changed
    }

    /// Update course_sort_index for multiple sources in a single transaction.
    func updateCourseSortOrder(_ ordering: [(String, Int)]) throws {
        try knowledgeStore().updateCourseSortOrder(ordering)
        scheduleCloudKitSync(.immediate)
    }

    func updateBookSortOrder(_ ordering: [(String, Int)]) throws {
        try knowledgeStore().updateBookSortOrder(ordering)
        scheduleCloudKitSync(.immediate)
    }

    func updateSourceReadingPosition(sourceID: String, page: Int?) throws {
        try ensureStoreExists()
        try knowledgeStore().updateSourceReadingPosition(sourceID: sourceID, page: page)
        scheduleCloudKitSync(.coalesced)
    }

    func updateSourceReadingLocator(sourceID: String, locator: String?) throws {
        try ensureStoreExists()
        try knowledgeStore().updateSourceReadingLocator(sourceID: sourceID, locator: locator)
        scheduleCloudKitSync(.coalesced)
    }

    func updateSourceReadAt(sourceID: String, readAt: Date?) throws {
        try ensureStoreExists()
        try knowledgeStore().updateSourceReadAt(sourceID: sourceID, readAt: readAt)
        scheduleCloudKitSync(.coalesced)
    }

    /// The narration's resume point in the source's ReadingState (generation 2; nil, and no write,
    /// under generation 1, where it rides `listen.position.*`).
    func loadListenPosition(sourceID: String) throws -> ArticleSpeechPlaybackPosition? {
        try ensureStoreExists()
        return try knowledgeStore().loadListenPosition(sourceID: sourceID)
    }

    func saveListenPosition(_ position: ArticleSpeechPlaybackPosition?, sourceID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().saveListenPosition(position, sourceID: sourceID)
    }

    /// Mark as Watched / Mark as Not Watched; see `KnowledgeStore.setVideoWatched`.
    @discardableResult
    func setVideoWatched(sourceID: String, watched: Bool) throws -> VideoWatchedMark {
        try ensureStoreExists()
        let mark = try knowledgeStore().setVideoWatched(sourceID: sourceID, watched: watched)
        if mark.changed { scheduleCloudKitSync(.coalesced) }
        return mark
    }

    /// Persist a single source (full upsert). Use for write-through after
    /// mutating an article's fields in the view model.
    func saveSource(_ article: StudioArticle, syncImmediately: Bool = false) throws {
        try ensureStoreExists()
        try knowledgeStore().saveSource(article)
        if (article.sourceType == .paper
                && (article.paperContentPreparationForPersistence != nil
                    || (article.state != .ready && article.content != nil)))
            || article.articleContentPreparationForPersistence != nil {
            removeFromSearchIndexes(article.id)
        }
        refreshTeamCopiesAwaitingText(of: [article])
        scheduleCloudKitSync(syncImmediately ? .immediate : .coalesced)
        NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
    }

    /// Merge deterministic paper metadata into the freshest persisted source.
    ///
    /// This stays on the storage actor so a slow metadata lookup cannot save the
    /// whole `StudioArticle` snapshot it captured before a concurrent PDF
    /// attachment. Only compare-and-swap metadata fields are eligible to change.
    func mergePaperMetadataBackfill(_ patch: PaperMetadataBackfillPatch) throws -> StudioArticle? {
        try ensureStoreExists()
        let store = try knowledgeStore()
        guard var current = try store.loadSourceForSync(patch.sourceID),
              patch.apply(to: &current) else {
            return nil
        }
        try store.saveSource(current)
        scheduleCloudKitSync(.coalesced)
        return current
    }

    /// Persist multiple sources individually. Useful after batch mutations.
    func saveSourcesBatchOnly(_ articles: [StudioArticle]) throws {
        try ensureStoreExists()
        let ks = try knowledgeStore()
        for article in articles {
            try ks.saveSource(article)
        }
        refreshTeamCopiesAwaitingText(of: articles)
        scheduleCloudKitSync()
        NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
    }
}

// MARK: - Errors

enum StorageError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpError(Int, String)
    case decodingError(String)
    case rateLimited
    case iCloudUnavailable(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL(let path): return "Invalid URL: \(path)"
        case .invalidResponse: return "Invalid server response"
        case .httpError(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .decodingError(let context): return "Decoding error: \(context)"
        case .rateLimited: return "Rate limited — try again later"
        case .iCloudUnavailable(let message): return message
        }
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
