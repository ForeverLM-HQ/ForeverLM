// StorageService: the store, content and library root paths and where a source file lives.
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

extension StorageService {

    // MARK: - Paths

    var storeRoot: URL {
        overrideStoreRoot ?? localAppSupportRoot
    }

    /// The one directory this install stores content in. It does not change at
    /// runtime, and it is not in iCloud — see `libraryRootPath` for why.
    ///
    /// Depending on the live container lookup would be its own bug
    /// class: any momentary nil from `url(forUbiquityContainerIdentifier:)`
    /// silently redirected writes to `fallbackRoot`, and the failure was cached
    /// for only a second, so a brief hiccup mid-download dropped that one file
    /// into a different root — no error, no trace, and a knowledge base split
    /// across two locations from then on. A single unconditional local path
    /// retires the whole question.
    var contentRoot: URL {
        if let overrideStoreRoot { return overrideStoreRoot }
        #if targetEnvironment(simulator)
        return simulatorUbiquityPath(relativePath: "Documents/ForeverLM")
        #else
        // Local, always, and identical to the static `libraryRootPath` — an
        // instance root that disagrees with the static one is how the app ends up
        // writing files where it cannot later find them. No ubiquity lookup: the
        // container is not a write target, so there is no
        // momentary-nil hazard to guard against here.
        return URL(fileURLWithPath: Self.libraryRootPath, isDirectory: true)
        #endif
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
    /// It is not `~/Documents/ForeverLM`, which is not local at all: with
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

    /// The iCloud Documents folder's document-scope root. This is where most
    /// existing content sits, so it stays resolvable — but
    /// the app does not write documents here. See `libraryRootPath`. A fixed
    /// folder name read by plain path, never a container the app resolves:
    /// `ForeverLMRuntimeIdentity.iCloudDocumentsFolderName` says why.
    static let ubiquityContentRootPath: String = (contentHomeDirectory as NSString)
        .appendingPathComponent(
            "Library/Mobile Documents/\(ForeverLMRuntimeIdentity.iCloudDocumentsFolderName)/Documents/\(ForeverLMRuntimeIdentity.productFolderName)"
        )

    /// Where this app writes content: a local directory that iCloud never
    /// touches.
    ///
    /// It is not the ubiquity container's `Documents/ForeverLM`, which kept
    /// forking the library into `ForeverLM 2`, `ForeverLM 3`, …
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
    /// New writes land here. The private container's root stays readable
    /// because it holds the `Audio/` folder the phone reads.
    static let libraryRootPath: String = localContentRootPath

    /// Every content root this app reads files from, current first. A stored
    /// relative path is tried against each, which is what lets a KB survive
    /// moving between the private container and local storage. Resolving by root
    /// beats rewriting path segments: a root that is added here is searched
    /// everywhere, with nothing to keep in sync.
    ///
    /// Only the first entry is written to. The private container's root stays
    /// because it still holds the `Audio/` folder the phone reads.
    static let knownContentRoots: [String] = [
        libraryRootPath,
        localContentRootPath,
        ubiquityContentRootPath,
    ]

    /// The two shapes `normalizedRelativeSourcePath` recognizes, compiled once.
    /// `String.range(of:options: .regularExpression)` builds a fresh
    /// `NSRegularExpression` on every call, which is what put ICU's compiler
    /// in the transcript's scroll path (see `contentHomeDirectory`).
    private static let libraryRootFolderNamePattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: "^(ForeverLM First Run|ForeverLM Dev|ForeverLM)(?: [0-9]+)?$")
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
        // the inbound PDF install refuses to install the PDF bytes
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
        // that could never converge.
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

    // MARK: - Source file location (single source of truth)

    /// Every place a stored source path could point to on this Mac, most likely
    /// first. Pure string work.
    ///
    /// This is deliberately the ONLY list of relocation rules in the app. It used
    /// to be three: `StudioArticle.locateLocalPath` knew about re-homing, the
    /// simulator prefix, container swaps and the Knowledge→ForeverLM rename;
    /// `SourceService.resolveLocalFileURL` knew about `file://`, `~`, iCloud
    /// placeholders; `reconcileLocalFiles` had a third partial
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

        // Anything under a content root — the private container or local
        // storage — reduces to the same relative path. Resolve that relative
        // path against every root we know of.
        let relative = relativeSourcePath(input)
        let relativeForm = relative.hasPrefix("/") ? nil : relative
        if let relativeForm {
            for root in knownContentRoots {
                add((root as NSString).appendingPathComponent(relativeForm))
            }
        }

        // A "/Documents/…" path that lost its home prefix.
        if input.hasPrefix("/Documents/") {
            add(home + input)
        }

        return candidates
    }

    /// Where a stored source path's file actually is, or nil when no candidate
    /// exists. A file that iCloud has not downloaded yet counts as present: an
    /// evicted file can leave a `.name.ext.icloud` placeholder beside it,
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

    func ensureStoreExists() throws {
        try ensureICloudUbiquityAvailable()
        try fileManager.createDirectory(at: storeRoot, withIntermediateDirectories: true)
    }

}
