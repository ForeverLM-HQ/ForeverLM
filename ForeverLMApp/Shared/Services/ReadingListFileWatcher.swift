#if os(macOS)
import CoreServices
import Foundation
import os

/// FSEvents-based watcher for local plugin storage.
///
/// Browsers rewrite their bookmark files atomically (temp file + rename, which
/// changes the inode), and Apple Podcasts persists iCloud play-state updates in
/// a SQLite WAL. FSEvents is path-based — immune to inode churn — and sees both
/// shapes, so callers watch enclosing directories and select the paths their
/// plugin actually reads.
///
/// Bursts are debounced (atomic replaces emit several events) and fires are
/// cooldown-limited (sync LevelDB directories churn while a browser is open).
/// The caller's modification-snapshot comparison remains the final no-op gate.
///
/// Threading: all mutable state is confined to `queue`; FSEvents callbacks are
/// delivered on `queue` via `FSEventStreamSetDispatchQueue`. Safe to construct
/// and drive from any executor — never does main-actor work.
final class LocalSourceFileWatcher: @unchecked Sendable {
    enum Content: Sendable {
        case browserReadingLists
        case applePodcasts
        /// The caption transcripts Zoom's desktop client saves beside its
        /// local recordings (`~/Documents/Zoom/<topic> <date> <time>(GMT…).txt`),
        /// and the recording folders themselves.
        case zoomLocalTranscripts

        fileprivate var logCategory: String {
            switch self {
            case .browserReadingLists: return "ReadingListWatcher"
            case .applePodcasts: return "PodcastLibraryWatcher"
            case .zoomLocalTranscripts: return "ZoomTranscriptWatcher"
            }
        }

        fileprivate var queueLabel: String {
            switch self {
            case .browserReadingLists: return "com.foreverlm.reading-list-watcher"
            case .applePodcasts: return "com.foreverlm.podcast-library-watcher"
            case .zoomLocalTranscripts: return "com.foreverlm.zoom-transcript-watcher"
            }
        }

        fileprivate var cooldownInterval: TimeInterval {
            switch self {
            case .browserReadingLists: return 45
            case .applePodcasts: return 15
            case .zoomLocalTranscripts: return 10
            }
        }

        nonisolated func isRelevantPath(_ path: String) -> Bool {
            switch self {
            case .browserReadingLists:
                if path.hasSuffix("/Bookmarks.plist") { return true }
                if path.hasSuffix("/Bookmarks") { return true }
                return path.contains("/Sync Data/LevelDB")
            case .applePodcasts:
                let name = (path as NSString).lastPathComponent
                return name == "MTLibrary.sqlite" || name == "MTLibrary.sqlite-wal"
            case .zoomLocalTranscripts:
                // The caption file, and what a recording folder gains as Zoom
                // records (`.zoom`) and converts (`recording.conf`, media).
                let lowered = path.lowercased()
                let name = (lowered as NSString).lastPathComponent
                return name == "recording.conf"
                    || [".txt", ".zoom", ".m4a", ".mp4"].contains { lowered.hasSuffix($0) }
            }
        }
    }

    private let logger: Logger
    private let queue: DispatchQueue

    /// Quiet period after the first relevant event before firing, so one save
    /// (temp write + rename + backup) collapses into a single sync.
    private let debounceInterval: TimeInterval = 2
    /// Minimum spacing between fires while events keep streaming.
    private let cooldownInterval: TimeInterval

    private let content: Content
    private let onRelevantChange: @Sendable () -> Void

    // Confined to `queue`.
    private var stream: FSEventStreamRef?
    private var watchedRoots: [String] = []
    private var pendingFire: DispatchWorkItem?
    private var lastFiredAt: Date?

    init(content: Content, onRelevantChange: @escaping @Sendable () -> Void) {
        self.content = content
        self.cooldownInterval = content.cooldownInterval
        self.onRelevantChange = onRelevantChange
        self.logger = Logger(subsystem: "com.foreverlm", category: content.logCategory)
        self.queue = DispatchQueue(label: content.queueLabel, qos: .utility)
    }

    /// Replace the set of watched root directories. No-op if unchanged; the
    /// stream is recreated when roots appear or disappear (e.g. a browser is
    /// installed mid-session or toggled in settings).
    func setWatchedRoots(_ roots: [String]) {
        queue.async { [self] in
            let normalized = Array(Set(roots)).sorted()
            guard normalized != watchedRoots else { return }
            watchedRoots = normalized
            stopStreamOnQueue()
            startStreamOnQueue()
        }
    }

    /// Stop watching and drop any pending debounced fire.
    func cancel() {
        queue.async { [self] in
            pendingFire?.cancel()
            pendingFire = nil
            stopStreamOnQueue()
        }
    }

    // MARK: - Queue-confined internals

    private func startStreamOnQueue() {
        guard stream == nil, !watchedRoots.isEmpty else { return }

        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<LocalSourceFileWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            let paths = (cfPaths as NSArray).compactMap { $0 as? String }
            watcher.handleEventPathsOnQueue(paths)
        }

        // The stream retains `self` via the info pointer until it is released
        // in stopStreamOnQueue(), so callbacks can never see a dangling watcher.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            watchedRoots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(flags)
        ) else {
            Unmanaged.passUnretained(self).release()
            logger.warning("FSEventStreamCreate failed for roots \(self.watchedRoots.joined(separator: ", "))")
            return
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            Unmanaged.passUnretained(self).release()
            logger.warning("FSEventStreamStart failed for roots \(self.watchedRoots.joined(separator: ", "))")
            return
        }

        stream = created
        logger.info("Watching local source roots: \(self.watchedRoots.joined(separator: ", "))")
    }

    private func stopStreamOnQueue() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        Unmanaged.passUnretained(self).release()
    }

    private func handleEventPathsOnQueue(_ paths: [String]) {
        guard paths.contains(where: content.isRelevantPath) else { return }
        scheduleFireOnQueue()
    }

    /// Trailing fire with bounded latency: the first relevant event schedules a
    /// fire after the debounce (or the remaining cooldown, whichever is later);
    /// further events while one is pending are absorbed, so a continuous event
    /// stream can never starve the fire.
    private func scheduleFireOnQueue() {
        guard pendingFire == nil else { return }

        var delay = debounceInterval
        if let lastFiredAt {
            delay = max(delay, cooldownInterval - Date().timeIntervalSince(lastFiredAt))
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingFire = nil
            self.lastFiredAt = Date()
            self.onRelevantChange()
        }
        pendingFire = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
#endif
