// StudioArticle local-path, PDF and web-location members, moved out of Models.swift.

import Foundation

extension StudioArticle {
    /// Record that a caller has already verified a local file at `rawPath`.
    ///
    /// Paper attachment first checks the destination PDF off-main, then publishes
    /// its path to the article. The same path may already be in the negative cache
    /// from the pre-attachment "needs PDF" check. Promote it synchronously before
    /// publishing the article so the sidebar, reader, and metadata pipeline all see
    /// the verified PDF in the same state change instead of waiting for the
    /// debounced cache revalidation pass.
    static func recordExistingLocalPath(_ rawPath: String) {
        let absolute = StorageService.absoluteSourcePath(rawPath)
        guard absolute.hasPrefix("/") else { return }
        resolvedPathCacheLock.lock()
        let wasMissing = negativeResolvedPathCache.remove(absolute) != nil
        let previous = resolvedPathCache.updateValue(absolute, forKey: absolute)
        if wasMissing || previous != absolute { resolvedPathCacheGenerationValue &+= 1 }
        resolvedPathCacheLock.unlock()
    }

    /// Whether this source is a local PDF file.
    /// Falls back to checking the URL itself — for books/courses/papers, the URL IS the local file path.
    var isPDF: Bool {
        if let path = localFilePath, path.lowercased().hasSuffix(".pdf") { return true }
        return url.lowercased().hasSuffix(".pdf") && url.hasPrefix("/")
    }

    /// Resolved local file path: uses explicit `localFilePath`, or the URL if it's a local path.
    /// Automatically resolves known directory renames (e.g. Knowledge → ForeverLM).
    var resolvedLocalPath: String? {
        // This accessor predates the cache-only UI API and still has many
        // call sites. Make the safety boundary intrinsic: an accidental use
        // from a SwiftUI/main-actor path can never issue an iCloud-backed stat.
        if Thread.isMainThread { return cachedResolvedLocalPath }
        if let path = localFilePath {
            let absolutePath = StorageService.absoluteSourcePath(path)
            if absolutePath.hasPrefix("/") {
                return Self.resolveLocalPath(absolutePath)
            }
        }
        let absoluteURLPath = StorageService.absoluteSourcePath(url)
        if absoluteURLPath.hasPrefix("/") {
            return Self.resolveLocalPath(absoluteURLPath)
        }
        return nil
    }

    /// Resolved local file path for PDFs specifically. Returns nil when the stored
    /// path points at a missing file so papers with stale `localFilePath` values
    /// still appear in the "needs PDF" flows instead of showing "File not found."
    var resolvedPDFPath: String? {
        if Thread.isMainThread { return cachedResolvedPDFPath }
        guard let path = existingResolvedLocalPath, path.lowercased().hasSuffix(".pdf") else { return nil }
        return path
    }

    /// Resolved local path only when the file exists on disk.
    private var existingResolvedLocalPath: String? {
        if let path = localFilePath {
            let absolutePath = StorageService.absoluteSourcePath(path)
            if absolutePath.hasPrefix("/"), let existing = Self.existingLocalPath(absolutePath) {
                return existing
            }
        }
        let absoluteURLPath = StorageService.absoluteSourcePath(url)
        if absoluteURLPath.hasPrefix("/"), let existing = Self.existingLocalPath(absoluteURLPath) {
            return existing
        }
        return nil
    }

    /// Whether this source is a local EPUB chapter file (extracted as .txt or .html during import).
    var isEPUBChapter: Bool {
        guard let path = resolvedLocalPath else { return false }
        return Self.pathLooksLikeEPUBChapter(path)
    }

    private static func pathLooksLikeEPUBChapter(_ path: String) -> Bool {
        let lower = path.lowercased()
        return (lower.hasSuffix(".txt") || lower.hasSuffix(".htm") || lower.hasSuffix(".html") || lower.hasSuffix(".xhtml"))
            && (path.contains("/Chapters/") || path.contains("_Chapters"))
    }

    /// Whether this source is an archived web article (HTML saved locally with images).
    var isArchivedArticle: Bool {
        guard let path = resolvedLocalPath else { return false }
        return Self.pathLooksLikeArchivedArticle(path)
    }

    private static func pathLooksLikeArchivedArticle(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let lower = normalized.lowercased()
        return lower.hasSuffix(".html")
            && (lower.hasPrefix("articles/") || lower.contains("/articles/"))
    }

    /// Whether this source is a local document (PDF or EPUB chapter) that doesn't need web fetching.
    var isLocalDocument: Bool {
        isPDF || isEPUBChapter || isArchivedArticle
    }

    /// `resolvedLocalPath` answered from the memoization tables alone, never
    /// touching the filesystem. SwiftUI evaluates a row's `.contextMenu` builder
    /// eagerly as part of the row body, so the sidebar menus resolve local paths
    /// on the main actor during render — and a cold `stat()` against an evicted
    /// iCloud file blocks for seconds, which is exactly the beachball captured in
    /// the UI stall samples. A path that has never been statted answers as itself,
    /// the same result `locateLocalPath` gives for a file it can't find; the
    /// debounced background pass in `scheduleResolvedPathRevalidation()` stats it
    /// for real and re-publishes, so the row re-renders against a cache hit.
    var cachedResolvedLocalPath: String? {
        if let path = localFilePath {
            let absolutePath = StorageService.absoluteSourcePath(path)
            if absolutePath.hasPrefix("/") {
                return Self.cachedResolveLocalPath(absolutePath)
            }
        }
        let absoluteURLPath = StorageService.absoluteSourcePath(url)
        if absoluteURLPath.hasPrefix("/") {
            return Self.cachedResolveLocalPath(absoluteURLPath)
        }
        return nil
    }

    /// `isEPUBChapter` without the stat — see `cachedResolvedLocalPath`.
    var cachedIsEPUBChapter: Bool {
        guard let path = cachedResolvedLocalPath else { return false }
        return Self.pathLooksLikeEPUBChapter(path)
    }

    /// `isArchivedArticle` without the stat — see `cachedResolvedLocalPath`.
    var cachedIsArchivedArticle: Bool {
        guard let path = cachedResolvedLocalPath else { return false }
        return Self.pathLooksLikeArchivedArticle(path)
    }

    /// Main-actor-safe counterpart to `isLocalDocument`. Classification only
    /// needs the stored path shape; whether the file is currently present is
    /// checked later by the off-main local-document loading path. Never use the
    /// filesystem-touching accessors merely to decide whether content is local.
    var cachedIsLocalDocument: Bool {
        isPDF || cachedIsEPUBChapter || cachedIsArchivedArticle
    }

    /// `resolvedPDFPath` without the stat — see `cachedResolvedLocalPath`. Existence
    /// is unknowable without touching disk, so a path that has not been resolved yet
    /// answers `nil` (no thumbnail) instead of blocking; the background warm
    /// re-publishes and the row picks it up.
    var cachedResolvedPDFPath: String? {
        guard let path = cachedExistingResolvedLocalPath,
              path.lowercased().hasSuffix(".pdf") else { return nil }
        return path
    }

    /// Cache-only availability used by render-time paper partitions and badges.
    /// An unvalidated recorded PDF is treated as present until the background
    /// path warmer proves it missing. That keeps a cold cache from both touching
    /// iCloud on the main actor and briefly flashing every recorded paper as
    /// missing during launch. Once warmed, a cached miss returns `false` and the
    /// normal missing-PDF UI appears on the next publication.
    var cachedHasUsablePDF: Bool {
        let rawPaths = [localFilePath, url]
        for rawPath in rawPaths.compactMap({ $0 }) {
            let absolutePath = StorageService.absoluteSourcePath(rawPath)
            guard absolutePath.hasPrefix("/"), absolutePath.lowercased().hasSuffix(".pdf") else {
                continue
            }
            switch Self.cachedLocalPathAvailability(absolutePath) {
            case .present:
                return true
            case .unknown:
                return true
            case .missing:
                continue
            }
        }
        return false
    }

    private var cachedExistingResolvedLocalPath: String? {
        if let path = localFilePath {
            let absolutePath = StorageService.absoluteSourcePath(path)
            if absolutePath.hasPrefix("/"), let existing = Self.cachedExistingLocalPath(absolutePath) {
                return existing
            }
        }
        let absoluteURLPath = StorageService.absoluteSourcePath(url)
        if absoluteURLPath.hasPrefix("/"), let existing = Self.cachedExistingLocalPath(absoluteURLPath) {
            return existing
        }
        return nil
    }

    /// In-memory memoization of local-path resolutions, both polarities. The
    /// existence checks below are synchronous filesystem stats (often against
    /// iCloud-backed, possibly-evicted files), and `resolvedLocalPath`/
    /// `resolvedPDFPath` are read from SwiftUI render paths — the sidebar filters
    /// and the always-evaluated Papers tab badge — once per source per render.
    /// Both hits AND misses are memoized for the whole session, so the main actor
    /// stats any unique path at most once ever (and `warmResolvedLocalPathCache`
    /// usually takes even that first stat off-main). Files that appear later
    /// (iCloud download, background fetch) are picked up by
    /// `revalidateMissingResolvedPaths()`, which re-stats misses off the main
    /// actor; files that are deleted are dropped via
    /// `invalidateResolvedPathCache(forRawPaths:)` by the deletion flows.
    private static let resolvedPathCacheLock = NSLock()

    nonisolated(unsafe) private static var resolvedPathCache: [String: String] = [:]

    /// Negative half of the resolved-path cache: paths that statted as missing.
    nonisolated(unsafe) private static var negativeResolvedPathCache: Set<String> = []

    nonisolated(unsafe) private static var resolvedPathCacheGenerationValue = 0

    /// Moves whenever the tables above change what they hold: a path statted
    /// for the first time, a miss promoted, entries dropped. The cache-only
    /// accessors (`cachedHasUsablePDF` above all) can answer differently
    /// afterwards with no source having changed, so a memo built from them
    /// across the library — the Papers lists' share of it
    /// (`StudioViewModel.paperLibraryIndex`) — keys on this beside the articles
    /// revision. Read under the lock; written only by the mutators below.
    static var resolvedPathCacheGeneration: Int {
        resolvedPathCacheLock.lock()
        defer { resolvedPathCacheLock.unlock() }
        return resolvedPathCacheGenerationValue
    }

    private enum CachedLocalPathAvailability {
        case present(String)
        case missing
        case unknown
    }

    /// Re-stat every cached miss, promoting entries whose file has since appeared
    /// (iCloud download, background fetch, attach). Returns true when at least one
    /// path was promoted so the caller can re-publish UI state. Stats the
    /// filesystem — never call on the main actor.
    static func revalidateMissingResolvedPaths() -> Bool {
        resolvedPathCacheLock.lock()
        let misses = Array(negativeResolvedPathCache)
        resolvedPathCacheLock.unlock()
        guard !misses.isEmpty else { return false }

        var promoted: [String: String] = [:]
        for path in misses {
            let (resolved, found) = locateLocalPath(path)
            if found { promoted[path] = resolved }
        }
        guard !promoted.isEmpty else { return false }

        resolvedPathCacheLock.lock()
        for (path, resolved) in promoted {
            negativeResolvedPathCache.remove(path)
            resolvedPathCache[path] = resolved
        }
        resolvedPathCacheGenerationValue &+= 1
        resolvedPathCacheLock.unlock()
        return true
    }

    /// Drop cached entries (hit and miss) for specific raw stored paths — e.g.
    /// after deleting a source's file — so only the affected sources re-stat on
    /// their next resolution instead of the whole library.
    static func invalidateResolvedPathCache(forRawPaths rawPaths: [String]) {
        let absolutes = rawPaths
            .map { StorageService.absoluteSourcePath($0) }
            .filter { $0.hasPrefix("/") }
        guard !absolutes.isEmpty else { return }
        resolvedPathCacheLock.lock()
        var dropped = false
        for path in absolutes {
            if resolvedPathCache.removeValue(forKey: path) != nil { dropped = true }
            if negativeResolvedPathCache.remove(path) != nil { dropped = true }
        }
        if dropped { resolvedPathCacheGenerationValue &+= 1 }
        resolvedPathCacheLock.unlock()
    }

    /// A batch of file moves can relocate thousands of files while the app is
    /// open. Cached values store the previously located absolute path, so clear
    /// both polarities once the batch has changed anything; subsequent UI reads
    /// remain cache-only and the off-main warmer repopulates them against the
    /// canonical root.
    ///
    /// Sync clears it too, whenever another Mac's source files or text land.
    /// Until the warmer runs again, every local PDF answers "unknown", and the
    /// Reader shows a paper's stored text instead of its PDF. The warmer runs
    /// on a source change a row can see, and text arriving is not one, so the
    /// clear says so (`resolvedPathCacheDidClear`) and the view model warms the
    /// cache again.
    static func invalidateAllResolvedPathCaches() {
        resolvedPathCacheLock.lock()
        resolvedPathCache.removeAll(keepingCapacity: true)
        negativeResolvedPathCache.removeAll(keepingCapacity: true)
        resolvedPathCacheGenerationValue &+= 1
        resolvedPathCacheLock.unlock()
        NotificationCenter.default.post(name: .resolvedPathCacheDidClear, object: nil)
    }

    /// Resolve a stored absolute path only when the file exists, memoizing hits
    /// and (per revision) misses.
    private static func existingLocalPath(_ path: String) -> String? {
        resolvedPathCacheLock.lock()
        if let cached = resolvedPathCache[path] {
            resolvedPathCacheLock.unlock()
            return cached
        }
        if negativeResolvedPathCache.contains(path) {
            resolvedPathCacheLock.unlock()
            return nil
        }
        resolvedPathCacheLock.unlock()

        let (resolved, found) = locateLocalPath(path)
        guard found else {
            resolvedPathCacheLock.lock()
            if negativeResolvedPathCache.insert(path).inserted { resolvedPathCacheGenerationValue &+= 1 }
            resolvedPathCacheLock.unlock()
            return nil
        }
        resolvedPathCacheLock.lock()
        if resolvedPathCache.updateValue(resolved, forKey: path) != resolved { resolvedPathCacheGenerationValue &+= 1 }
        resolvedPathCacheLock.unlock()
        return resolved
    }

    /// Resolve a stored absolute path to where the file actually lives, memoizing
    /// both outcomes so the filesystem is touched at most once per unique path per
    /// session. A cached miss resolves to the input path unchanged (matching what
    /// `locateLocalPath` returns for a file it can't find) without touching disk.
    private static func resolveLocalPath(_ path: String) -> String {
        resolvedPathCacheLock.lock()
        if let cached = resolvedPathCache[path] {
            resolvedPathCacheLock.unlock()
            return cached
        }
        if negativeResolvedPathCache.contains(path) {
            resolvedPathCacheLock.unlock()
            return path
        }
        resolvedPathCacheLock.unlock()

        let (resolved, found) = locateLocalPath(path)
        resolvedPathCacheLock.lock()
        if found {
            if resolvedPathCache.updateValue(resolved, forKey: path) != resolved { resolvedPathCacheGenerationValue &+= 1 }
        } else if negativeResolvedPathCache.insert(path).inserted {
            resolvedPathCacheGenerationValue &+= 1
        }
        resolvedPathCacheLock.unlock()
        return resolved
    }

    /// Resolve a stored raw path (a source's `localFilePath` or `url`) to where the
    /// file actually lives, for callers that already run off the main actor. Stats
    /// the filesystem on a cache miss — never call this while rendering.
    static func resolvedLocalPath(forRawPath rawPath: String) -> String? {
        let absolute = StorageService.absoluteSourcePath(rawPath)
        guard absolute.hasPrefix("/") else { return nil }
        return resolveLocalPath(absolute)
    }

    /// Cached-only counterpart to `resolveLocalPath`: answers from the memoization
    /// tables and never stats, so it is safe to call while rendering. Falls back to
    /// the path unchanged when nothing is cached yet.
    private static func cachedResolveLocalPath(_ path: String) -> String {
        resolvedPathCacheLock.lock()
        defer { resolvedPathCacheLock.unlock() }
        return resolvedPathCache[path] ?? path
    }

    /// Cached-only counterpart to `existingLocalPath`: a path that has not been
    /// statted answers `nil`, same as one statted and found missing.
    private static func cachedExistingLocalPath(_ path: String) -> String? {
        guard case .present(let resolved) = cachedLocalPathAvailability(path) else { return nil }
        return resolved
    }

    /// Tri-state cache lookup that never touches the filesystem. Keeping
    /// `unknown` distinct from `missing` lets render-time counts conservatively
    /// trust a recorded PDF until the off-main warmer has checked it.
    private static func cachedLocalPathAvailability(_ path: String) -> CachedLocalPathAvailability {
        resolvedPathCacheLock.lock()
        defer { resolvedPathCacheLock.unlock() }
        if let resolved = resolvedPathCache[path] { return .present(resolved) }
        if negativeResolvedPathCache.contains(path) { return .missing }
        return .unknown
    }

    /// Warm the resolved-path cache off the main actor for a batch of stored raw
    /// paths (a source's `localFilePath` and `url`). Callers snapshot the raw
    /// strings on the main actor and run this on a background task, so the first
    /// Library render is a cache hit — for hits AND misses — instead of a
    /// synchronous stat storm. Returns true when at least one path was statted for
    /// the first time, so the caller can re-publish for rows that rendered against
    /// the cached-only accessors before the cache was populated.
    @discardableResult
    static func warmResolvedLocalPathCache(forRawPaths rawPaths: [String]) -> Bool {
        var statted = false
        for raw in rawPaths {
            let absolute = StorageService.absoluteSourcePath(raw)
            guard absolute.hasPrefix("/") else { continue }
            resolvedPathCacheLock.lock()
            let known = resolvedPathCache[absolute] != nil || negativeResolvedPathCache.contains(absolute)
            resolvedPathCacheLock.unlock()
            guard !known else { continue }
            _ = existingLocalPath(absolute)
            statted = true
        }
        return statted
    }

    /// Where this stored path's file actually lives, and whether one was found.
    ///
    /// Every relocation rule (re-homing across Macs, the simulator prefix, iCloud
    /// container swaps, the Knowledge→ForeverLM rename, conflict forks, iCloud
    /// placeholders) lives in `StorageService.sourceFileCandidatePaths`, which is
    /// the single list the whole app resolves against. A partial copy of those
    /// rules here would let an iCloud conflict fork read as hundreds of papers
    /// losing their PDFs.
    private static func locateLocalPath(_ path: String) -> (path: String, found: Bool) {
        if let located = StorageService.locateSourceFile(path) { return (located, true) }
        return (path, false)  // return original if nothing found
    }

    /// A YouTube lecture that was imported from a course folder.
    /// Course membership itself lives in course_lecture_items, not in discoveryOrigin.
    var isCourseLecture: Bool {
        discoveryOrigin == .localCourses && sourceType == .video
    }

    /// Whether this source is a YouTube URL (any source type).
    ///
    /// Every address ForeverLM plays as a YouTube video counts, a livestream's
    /// and an embed's included: the web views hand those to the Reader's
    /// player (`YouTubeContainment`), so a saved one shown as a web page would
    /// be handed straight back to itself.
    var isYouTubeURL: Bool {
        let lower = url.lowercased()
        if lower.contains("youtube.com/watch") || lower.contains("youtu.be/")
            || lower.contains("youtube.com/embed/") || lower.contains("youtube.com/shorts/") {
            return true
        }
        return lower.contains("youtu") && YouTubeURLMetadata.watchURL(for: url) != nil
    }

    /// YouTube video ID extracted from the URL.
    var youtubeVideoId: String? {
        Self.youtubeVideoId(from: url)
    }

    static func youtubeVideoId(from url: String) -> String? {
        ForeverLMCore.youtubeVideoID(from: url)
    }

    /// YouTube thumbnail URL derived from the video ID.
    var youtubeThumbnailURL: String? {
        Self.youtubeThumbnailURL(for: url)
    }

    static func youtubeThumbnailURL(for url: String) -> String? {
        ForeverLMCore.youtubeThumbnailURL(for: url)
    }

    /// Whether this source is a web URL that should be shown in the in-app WebView reader.
    /// Returns true for HTTP(S) URLs that aren't local files or podcasts with local transcripts.
    /// Papers without a local PDF also get the WebView reader so the user can browse + download.
    var isWebArticle: Bool {
        isWebArticle(archived: isArchivedArticle)
    }

    /// `isWebArticle` without the stat — see `cachedResolvedLocalPath`. The reader
    /// bodies branch on this once per render, so it must not resolve local paths.
    var cachedIsWebArticle: Bool {
        isWebArticle(archived: cachedIsArchivedArticle)
    }

    /// Whether an archived web article should render its live page rather than
    /// the document saved at fetch time.
    ///
    /// The archive is the offline snapshot, not the preferred rendering.
    /// `SourceService.readerHTML` keeps no stylesheet and only an allow list of
    /// tags, so the saved file is a reconstruction of the page rather than a
    /// copy of it — nav links lose their layout, hidden elements become visible,
    /// and the site's own typography is gone. Whenever the page is still
    /// reachable, the learner should read the page; the archive answers only
    /// when the live load fails, and keeps carrying the text everything
    /// downstream derives from.
    ///
    /// Two captures keep the saved document as their primary rendering, because
    /// for them it holds text the live URL will not produce: a paywalled
    /// article, and a local HTML import, whose identity is a file path rather
    /// than an HTTP URL. A source whose URL resolves to a publisher PDF keeps
    /// its existing reader too, which is the PDF itself.
    var cachedPrefersLiveWebPage: Bool {
        guard cachedIsArchivedArticle else { return false }
        guard !isPaywalled, !cachedHasRemotePDFURL else { return false }
        return cachedIsWebArticle
    }

    private func isWebArticle(archived: Bool) -> Bool {
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return false }
        if isPDF { return false }
        // Archived articles (HTML cached in /Articles/) still have an HTTP URL and should
        // render the live webpage; the cached HTML is only used as an offline fallback.
        if localFilePath != nil && !archived { return false }
        // Podcasts must never be shown in the web reader — only local transcripts are valid
        if sourceType == .podcast { return false }
        // Course lectures get a dedicated YouTube player view, not the generic web reader
        if isCourseLecture { return false }
        return true
    }

    /// Whether this paper has a resolvable direct PDF URL (arXiv, bioRxiv, Nature, etc.).
    var hasRemotePDFURL: Bool {
        hasRemotePDFURL(localPDFPath: resolvedPDFPath)
    }

    /// `hasRemotePDFURL` without the stat — see `cachedResolvedLocalPath`. Until the
    /// background warm has statted the source, an attached local PDF reads as absent
    /// and the reader offers the remote copy; it re-renders against the cache the
    /// moment the warm re-publishes.
    var cachedHasRemotePDFURL: Bool {
        hasRemotePDFURL(localPDFPath: cachedResolvedPDFPath)
    }

    private func hasRemotePDFURL(localPDFPath: String?) -> Bool {
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return false }
        guard localPDFPath == nil else { return false }
        return PaperService.paperPDFURL(from: url) != nil
    }

    /// Whether the reader shows this source's stored text rather than the PDF
    /// at its URL.
    ///
    /// A non-paper source only reaches a PDF URL with no file on record when
    /// its text was handed in with it: the app's own fetch of a PDF-URL
    /// article downloads the file (`downloadDocumentPDF` records
    /// `localFilePath`). That text is the source — `add_source` promises it is
    /// shown verbatim — and it is often a part of the file, such as one
    /// abstract from a conference book's page, so streaming the whole PDF
    /// shows something other than what was added. A paper's text is an
    /// extraction of its PDF, so a paper keeps the PDF.
    ///
    /// Judged on `wordCount`, not `content`: a loaded row carries no text until
    /// `hydrateStoredContent` puts it there, and deciding on `content` sent the
    /// reader to the PDF in that gap — whose save then made the source a paper
    /// holding the whole file.
    var readsStoredTextOverRemotePDF: Bool {
        guard sourceType != .paper, localFilePath == nil, state == .ready else { return false }
        let hasText = (wordCount ?? 0) > 0
            || content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard hasText else { return false }
        return PaperService.paperPDFURL(from: url) != nil
    }

    /// The resolved direct PDF download URL for this paper, if available.
    var remotePDFURL: URL? {
        guard let pdfURLString = PaperService.paperPDFURL(from: url) else { return nil }
        return URL(string: pdfURLString)
    }
}

extension Notification.Name {
    /// Posted by `StudioArticle.invalidateAllResolvedPathCaches()`, on whatever
    /// thread cleared the cache. The view model answers by warming it again.
    static let resolvedPathCacheDidClear = Notification.Name("ForeverLM.resolvedPathCacheDidClear")
}
