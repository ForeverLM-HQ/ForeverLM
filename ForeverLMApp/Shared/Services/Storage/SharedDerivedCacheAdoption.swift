import Foundation
import OSLog

/// Moves this profile's content-addressed audio caches into the
/// profile-independent cache folder, once, without re-deriving anything.
///
/// The production and Dev apps keep separate Application Support folders so a
/// Dev schema migration can never lock the installed release out of
/// `knowledge.db`. That split also duplicated the audio caches, which carry no
/// identity at all: entries are named by a SHA-256 of the request that produced
/// them, so both profiles were paying to generate byte-identical files. This
/// walks each old per-profile directory and renames its entries into the
/// matching folder under `ForeverLM Shared`.
///
/// Both apps can run at once, so every step assumes the other one is running:
///
/// - It is a rename within one volume, never a copy. A reader that already
///   opened an entry keeps its file descriptor; a reader that opens by path
///   after the rename gets `ENOENT`, which the cache already treats as a miss
///   and re-derives. There is no window in which a partially written file is
///   visible under a final name.
/// - A destination that already exists is the *same content* under a
///   content-addressed name, so the source is dropped rather than overwritten.
///   Overwriting would pull the file out from under a concurrent reader for no
///   gain.
/// - Two processes adopting the same entry race harmlessly: one rename wins,
///   the loser finds its source gone and moves on.
/// - Nothing here is authoritative. The worst outcome of any failure is a cache
///   miss and a re-billed TTS request.
///
/// `ArticleMarkers/` stays behind. A marker asserts that this profile's library
/// has a finished export in its own iCloud document root, which the two
/// profiles deliberately do not share.
enum SharedDerivedCacheAdoption {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
        category: "StorageMigration"
    )

    /// A cache is listed here only if every entry is named by a hash of what
    /// produced it, so the two profiles cannot disagree about what a name means,
    /// and only if losing an entry costs a re-derivation rather than data.
    struct Cache: Equatable, Sendable {
        /// Same directory name on both sides; only the parent folder differs.
        let directoryName: String
        /// Extensions that are content-addressed entries. Anything else in the
        /// directory — and every subdirectory, such as `ArticleMarkers` — is
        /// left where it is.
        let fileExtensions: Set<String>
    }

    static let caches: [Cache] = [
        Cache(directoryName: "TTSAudioCache", fileExtensions: ["mp3"]),
        // The catalog picks mp3 or m4a per model's response format.
        Cache(directoryName: "ReadAloudVoicePreviews", fileExtensions: ["mp3", "m4a"]),
    ]

    struct Report: Equatable, Sendable {
        /// Entries renamed into the shared folder.
        var movedEntries = 0
        /// Entries the other profile had already contributed, dropped as duplicates.
        var discardedDuplicates = 0
        /// Entries left where they were. They stay readable to nothing, and the
        /// next launch tries again.
        var failedEntries = 0
    }

    private static let adoptionRunOnce: Bool = {
        adoptIfNeeded()
        return true
    }()

    /// Runs the adoption at most once per process, on whichever code path
    /// reaches it first — a `StorageService` construction at launch, or the
    /// first read of either cache. Reading a shared directory before its
    /// entries have been moved in would re-bill audio already on disk, so the
    /// caches call this rather than trusting launch order.
    static func adoptOnce() {
        _ = adoptionRunOnce
    }

    /// Production entry point. Tests call `adopt(profileCache:sharedCache:)`
    /// directly so they never touch the developer's real caches.
    static func adoptIfNeeded() {
        guard !ForeverLMRuntimeIdentity.isTestHost else { return }
        var report = Report()
        for cache in caches {
            let one = adopt(
                profileCache: profileCacheURL(for: cache),
                sharedCache: ForeverLMRuntimeIdentity.sharedDerivedCacheURL(named: cache.directoryName),
                fileExtensions: cache.fileExtensions
            )
            report.movedEntries += one.movedEntries
            report.discardedDuplicates += one.discardedDuplicates
            report.failedEntries += one.failedEntries
        }
        if report.movedEntries > 0 || report.discardedDuplicates > 0 {
            logger.notice(
                """
                Adopted derived caches into \(ForeverLMRuntimeIdentity.sharedProductFolderName, privacy: .public): \
                \(report.movedEntries, privacy: .public) moved, \
                \(report.discardedDuplicates, privacy: .public) already shared
                """
            )
        }
        if report.failedEntries > 0 {
            logger.error(
                "Left \(report.failedEntries, privacy: .public) cache entries in the per-profile folder"
            )
        }
    }

    static func profileCacheURL(named name: String) -> URL {
        ForeverLMRuntimeIdentity.applicationSupportRootURL
            .appendingPathComponent(name, isDirectory: true)
    }

    static func profileCacheURL(for cache: Cache) -> URL {
        profileCacheURL(named: cache.directoryName)
    }

    /// The pre-sharing location. Still the home of `ArticleMarkers`, so this is
    /// the directory the markers live under rather than a path kept only for
    /// migration.
    static var profileTTSAudioCacheURL: URL {
        profileCacheURL(named: "TTSAudioCache")
    }

    /// Idempotent: after a successful pass the source directory holds no `mp3`
    /// entries, so the next launch costs one directory listing. Deliberately
    /// keyed off what is actually on disk rather than a "did this once" flag —
    /// an older build writing to the per-profile folder again self-heals.
    ///
    /// Only ever reads this profile's own folder. The other profile's leftovers
    /// are its own to adopt on its next launch; reaching across would put one
    /// app's writes inside the other's library, which is the thing the folder
    /// split exists to prevent.
    @discardableResult
    static func adopt(
        profileCache: URL,
        sharedCache: URL,
        fileExtensions: Set<String> = ["mp3"],
        fileManager: FileManager = .default
    ) -> Report {
        var report = Report()

        guard let entries = try? fileManager.contentsOfDirectory(
            at: profileCache,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return report }

        let audioEntries = entries.filter { fileExtensions.contains($0.pathExtension) }
        guard !audioEntries.isEmpty else { return report }

        do {
            try fileManager.createDirectory(at: sharedCache, withIntermediateDirectories: true)
        } catch {
            logger.error(
                "Could not create the shared TTS cache: \(error.localizedDescription, privacy: .public)"
            )
            report.failedEntries = audioEntries.count
            return report
        }

        for source in audioEntries {
            guard (try? source.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let destination = sharedCache.appendingPathComponent(source.lastPathComponent)
            do {
                try fileManager.moveItem(at: source, to: destination)
                report.movedEntries += 1
            } catch {
                if fileManager.fileExists(atPath: destination.path) {
                    // Content-addressed: the other profile already contributed
                    // these exact bytes. Drop ours instead of replacing a file
                    // something may be reading right now.
                    try? fileManager.removeItem(at: source)
                    if fileManager.fileExists(atPath: source.path) {
                        report.failedEntries += 1
                    } else {
                        report.discardedDuplicates += 1
                    }
                } else if fileManager.fileExists(atPath: source.path) {
                    report.failedEntries += 1
                }
                // Source gone and no destination: the other app moved it between
                // our listing and our rename. Nothing was lost.
            }
        }

        return report
    }
}
