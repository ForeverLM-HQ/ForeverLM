#if os(macOS)
import EPUBKit
import Foundation
import SwiftUI
import WebKit

/// A per-device, non-evictable mirror of archived article HTML and images.
///
/// New canonical archives live in local Application Support and travel between
/// devices through the source's CloudKit reader asset. Historical archives may
/// still be found in an iCloud Documents root (including conflict forks), where
/// Optimize Mac Storage can leave dataless placeholders. In either case the
/// reader copies the archive into this separate local cache before WebKit opens
/// it, so rendering never faults an iCloud file on the main actor.
actor ArticleArchiveCache {
    struct WarmResult: Equatable, Sendable {
        var discovered = 0
        var alreadyCached = 0
        var newlyCached = 0
        var failed = 0
    }

    enum Failure: Error, Equatable, Sendable {
        case invalidSourceID
        case archiveMissing
        case insufficientStorage
        case downloadTimedOut
        case downloadFailed(String)
        case cacheWriteFailed(String)

        var title: String {
            switch self {
            case .invalidSourceID, .archiveMissing:
                return "Article Archive Missing"
            case .insufficientStorage:
                return "Not Enough Storage"
            case .downloadTimedOut, .downloadFailed:
                return "Could Not Download Article"
            case .cacheWriteFailed:
                return "Could Not Cache Article"
            }
        }

        var message: String {
            switch self {
            case .invalidSourceID:
                return "This article has an invalid local archive identifier."
            case .archiveMissing:
                return "The saved article could not be found locally or in iCloud."
            case .insufficientStorage:
                return "Free some storage, then try downloading the article again."
            case .downloadTimedOut:
                return "iCloud did not finish downloading the saved article. Try again when the connection is stable."
            case .downloadFailed(let message):
                return message
            case .cacheWriteFailed(let message):
                return message
            }
        }

        var symbol: String {
            switch self {
            case .insufficientStorage:
                return "internaldrive"
            case .downloadTimedOut, .downloadFailed:
                return "icloud.slash"
            case .invalidSourceID, .archiveMissing, .cacheWriteFailed:
                return "doc.text.magnifyingglass"
            }
        }
    }

    static let shared = ArticleArchiveCache()

    private let rootURL: URL
    private let fileManager: FileManager
    private let materializationConcurrency = 6

    init() {
        self.rootURL = Self.defaultRootURL
        self.fileManager = .default
    }

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    private static var defaultRootURL: URL {
        return ForeverLMRuntimeIdentity.applicationSupportRootURL
            .appendingPathComponent("ArticleArchives", isDirectory: true)
    }

    /// Returns a local Application Support copy of the complete archive.
    /// Existing local copies never touch iCloud. A missing copy materializes
    /// every canonical file before copying so `copyItem` cannot silently fault a
    /// dataless file in on this actor and strand the reader without progress.
    func prepare(
        canonicalHTMLPath: String,
        sourceID: String,
        refresh: Bool = false
    ) async throws -> String {
        let destinationDirectory = try destinationDirectory(for: sourceID)
        let destinationHTML = destinationDirectory.appendingPathComponent("article.html")
        if !refresh, isReadableRegularFile(destinationHTML) {
            try repairMojibakeIfNeeded(in: destinationHTML)
            return destinationHTML.path
        }

        let canonicalHTML = URL(fileURLWithPath: canonicalHTMLPath).standardizedFileURL
        guard isRecordedFile(canonicalHTML) else {
            throw Failure.archiveMissing
        }
        let canonicalDirectory = canonicalHTML.deletingLastPathComponent()
        let files = try archiveFiles(htmlURL: canonicalHTML, directory: canonicalDirectory)
        try await materialize(files)
        guard !Task.isCancelled else { throw CancellationError() }

        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let stagingDirectory = rootURL.appendingPathComponent(
                ".\(sourceID).\(UUID().uuidString).staging",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: stagingDirectory) }
            try fileManager.copyItem(at: canonicalDirectory, to: stagingDirectory)
            guard isReadableRegularFile(stagingDirectory.appendingPathComponent("article.html")) else {
                throw Failure.archiveMissing
            }
            if fileManager.fileExists(atPath: destinationDirectory.path) {
                _ = try fileManager.replaceItemAt(
                    destinationDirectory,
                    withItemAt: stagingDirectory
                )
            } else {
                try fileManager.moveItem(at: stagingDirectory, to: destinationDirectory)
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.cacheWriteFailed(error.localizedDescription)
        }

        guard isReadableRegularFile(destinationHTML) else {
            throw Failure.cacheWriteFailed("The local article cache was not created.")
        }
        do {
            try repairMojibakeIfNeeded(in: destinationHTML)
        } catch {
            throw Failure.cacheWriteFailed(error.localizedDescription)
        }
        return destinationHTML.path
    }

    /// Repair only the disposable local mirror. The canonical archive and its
    /// CloudKit asset remain untouched, while existing saved articles render
    /// correctly immediately after the app update.
    private func repairMojibakeIfNeeded(in htmlURL: URL) throws {
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        let repaired = html.repairingUTF8Mojibake()
        guard repaired != html else { return }
        try repaired.write(to: htmlURL, atomically: true, encoding: .utf8)
    }

    /// Incrementally migrates historical iCloud-only article archives into the
    /// durable device-local mirror. The app calls this from its existing
    /// throttled, off-main foreground sweep; completed archives are skipped, so
    /// subsequent activations only inspect directory metadata.
    func warmExistingArchives(canonicalArticlesRoot: URL) async -> WarmResult {
        guard let sourceDirectories = try? fileManager.contentsOfDirectory(
            at: canonicalArticlesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return WarmResult()
        }

        var result = WarmResult()
        for sourceDirectory in sourceDirectories.sorted(by: { $0.path < $1.path }) {
            guard !Task.isCancelled else { break }
            guard (try? sourceDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            let canonicalHTML = sourceDirectory.appendingPathComponent("article.html")
            let legacyPlaceholder = sourceDirectory.appendingPathComponent(".article.html.icloud")
            guard isRecordedFile(canonicalHTML) || isRecordedFile(legacyPlaceholder) else {
                continue
            }

            result.discovered += 1
            let sourceID = sourceDirectory.lastPathComponent
            guard let destinationDirectory = try? destinationDirectory(for: sourceID) else {
                result.failed += 1
                continue
            }
            if isReadableRegularFile(destinationDirectory.appendingPathComponent("article.html")) {
                result.alreadyCached += 1
                continue
            }

            do {
                if !isRecordedFile(canonicalHTML), isRecordedFile(legacyPlaceholder) {
                    try await materializeLegacyPlaceholder(
                        legacyPlaceholder,
                        expectedHTML: canonicalHTML
                    )
                }
                _ = try await prepare(
                    canonicalHTMLPath: canonicalHTML.path,
                    sourceID: sourceID
                )
                result.newlyCached += 1
            } catch is CancellationError {
                break
            } catch {
                result.failed += 1
            }
        }
        return result
    }

    private func destinationDirectory(for sourceID: String) throws -> URL {
        guard !sourceID.isEmpty,
              sourceID != ".",
              sourceID != "..",
              !sourceID.contains("/"),
              !sourceID.contains(":") else {
            throw Failure.invalidSourceID
        }
        return rootURL.appendingPathComponent(sourceID, isDirectory: true)
    }

    /// `fileExists` is intentionally enough for canonical iCloud files: modern
    /// dataless placeholders exist under their real name and are materialized in
    /// the next step. Local cache hits additionally require allocated bytes.
    private func isRecordedFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private func isReadableRegularFile(_ url: URL) -> Bool {
        guard isRecordedFile(url),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
    }

    private func archiveFiles(htmlURL: URL, directory: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            throw Failure.archiveMissing
        }

        var files = [htmlURL]
        for case let url as URL in enumerator where url.standardizedFileURL != htmlURL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            files.append(url.standardizedFileURL)
        }
        return files
    }

    private func materialize(_ files: [URL]) async throws {
        var iterator = files.makeIterator()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<min(materializationConcurrency, files.count) {
                guard let url = iterator.next() else { break }
                group.addTask { try await Self.materialize(url) }
            }
            while try await group.next() != nil {
                guard !Task.isCancelled else { throw CancellationError() }
                if let url = iterator.next() {
                    group.addTask { try await Self.materialize(url) }
                }
            }
        }
    }

    private func materializeLegacyPlaceholder(
        _ placeholder: URL,
        expectedHTML: URL
    ) async throws {
        try await Self.materialize(placeholder)
        guard isRecordedFile(expectedHTML) else {
            throw Failure.archiveMissing
        }
    }

    private static func materialize(_ url: URL) async throws {
        guard !Task.isCancelled else { throw CancellationError() }
        switch await ICloudDownload.ensureDownloaded(url: url) {
        case .success:
            return
        case .failure(.insufficientStorage):
            throw Failure.insufficientStorage
        case .failure(.timedOut):
            throw Failure.downloadTimedOut
        case .failure(.requestFailed(let message)):
            throw Failure.downloadFailed(message)
        }
    }
}

struct EPUBKitBookNavigationItem: Identifiable, Equatable {
    let id: String
    let title: String
    let path: String
    var isArchived: Bool = false
    /// The chapter's own sections, in reading order, for the Contents menu to
    /// list under it. Empty when the chapter has none the reader could find.
    var sections: [BookNavigationSection] = []
}

/// A section inside a chapter — "What is the energy of a hydrogen bond?" in
/// a chapter of Cell Biology by the Numbers — and the page it opens on.
struct BookNavigationSection: Identifiable, Equatable {
    let id: String
    let title: String
    /// Zero-based, in the numbering of the document on screen: for a PDF book
    /// read as one document, a page of the whole book.
    let pageIndex: Int
}

struct EPUBKitBookNavigation: Equatable {
    let items: [EPUBKitBookNavigationItem]
    let currentIndex: Int?
    /// The section of the current chapter the reader is in, when the chapter
    /// has sections and the reader has reached the first of them.
    var currentSectionID: String? = nil

    var currentItem: EPUBKitBookNavigationItem? {
        guard let currentIndex, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    var previousItem: EPUBKitBookNavigationItem? {
        guard let currentIndex, items.indices.contains(currentIndex - 1) else { return nil }
        return items[currentIndex - 1]
    }

    var nextItem: EPUBKitBookNavigationItem? {
        guard let currentIndex, items.indices.contains(currentIndex + 1) else { return nil }
        return items[currentIndex + 1]
    }

    var positionLabel: String? {
        guard let currentIndex else { return nil }
        return "\(currentIndex + 1) of \(items.count)"
    }
}

/// Where the reader stands in a document that is counted in pages — a PDF
/// book read as one document — for the toolbar's position label and the
/// Go to Page control. The numbering is the document's own page order, shown
/// one-based and typed back one-based, so what the label says is what a
/// learner asks for; a 1,500-page textbook has no other number both sides
/// agree on.
struct ReaderPageNavigation: Equatable {
    /// Zero-based index of the page on screen.
    let currentPage: Int
    let pageCount: Int

    /// "130 of 1532". The word "Page" is left off on purpose: the toolbar
    /// truncates this from the right, and in a narrow reader the number is
    /// the part worth keeping — "Page 1…" said nothing.
    var label: String {
        "\(currentPage + 1) of \(pageCount)"
    }

    /// The page index a typed number names, or `nil` when it is not a page of
    /// this document. Whitespace and a thousands separator are tolerated —
    /// "1,379" is how the number is often read off a page — anything else in
    /// the field is not a page.
    func pageIndex(forEntry entry: String) -> Int? {
        let digits = entry.filter { !$0.isWhitespace && $0 != "," }
        guard let number = Int(digits), number >= 1, number <= pageCount else { return nil }
        return number - 1
    }
}

@MainActor
final class ReaderBookNavigationBridge: ObservableObject {
    @Published private(set) var navigation: EPUBKitBookNavigation?
    /// Set by a reader whose document is one run of pages; an EPUB has
    /// chapters but no page count and leaves this `nil`.
    @Published private(set) var pageNavigation: ReaderPageNavigation?
    private var navigateHandler: ((EPUBKitBookNavigationItem) -> Void)?
    private var goToPageHandler: ((Int) -> Void)?

    func update(
        navigation: EPUBKitBookNavigation?,
        navigate: @escaping (EPUBKitBookNavigationItem) -> Void
    ) {
        self.navigation = navigation
        self.navigateHandler = navigate
    }

    /// `goToPage` receives a zero-based page index the reader scrolls to.
    func update(
        pageNavigation: ReaderPageNavigation?,
        goToPage: @escaping (Int) -> Void
    ) {
        if self.pageNavigation != pageNavigation {
            self.pageNavigation = pageNavigation
        }
        self.goToPageHandler = goToPage
    }

    func clear() {
        navigation = nil
        navigateHandler = nil
        pageNavigation = nil
        goToPageHandler = nil
    }

    func navigate(to item: EPUBKitBookNavigationItem) {
        navigateHandler?(item)
    }

    func goToPage(_ pageIndex: Int) {
        goToPageHandler?(pageIndex)
    }
}

// `EPUBReadingPositionLocator` lives in `Models.swift` alongside
// `ArticleReadingPositionLocator` and `VideoWatchProgress` — the other two
// encodings of `sources.reading_position_locator`.

enum EPUBKitReaderSupport {
    /// Builds the reader's chapter navigation.
    ///
    /// When `sourceChapterPaths` is provided (path relative to the extracted
    /// `Chapters` directory → isArchived), navigation is filtered down to files that
    /// exist as ingested chapter sources, so the Contents menu matches the app's
    /// study model: never-ingested front/back matter (cover, copyright, ads) is
    /// dropped and archived chapters are flagged. When it is nil, the full EPUB spine
    /// or extracted file list is used unchanged so navigation is never lost.
    static func navigation(
        containing chapterPath: String,
        sourceChapterPaths: [String: Bool]? = nil
    ) -> EPUBKitBookNavigation? {
        let standardizedChapterPath = URL(fileURLWithPath: chapterPath).standardizedFileURL.path
        guard let chaptersURL = chaptersDirectory(containing: standardizedChapterPath) else { return nil }

        let sourceChapterPaths = sourceChapterPaths?.isEmpty == false ? sourceChapterPaths : nil
        if let sourceChapterPaths {
            if let navigation = navigationFromEPUBKit(chaptersURL: chaptersURL, currentPath: standardizedChapterPath, sourceChapterPaths: sourceChapterPaths) {
                return navigation
            }

            if let navigation = navigationFromExtractedChapterFiles(chaptersURL: chaptersURL, currentPath: standardizedChapterPath, sourceChapterPaths: sourceChapterPaths) {
                return navigation
            }
        }

        return navigationFromEPUBKit(chaptersURL: chaptersURL, currentPath: standardizedChapterPath, sourceChapterPaths: nil)
            ?? navigationFromExtractedChapterFiles(chaptersURL: chaptersURL, currentPath: standardizedChapterPath, sourceChapterPaths: nil)
    }

    /// Restricts spine-derived items to ingested chapter sources and marks archived
    /// ones. If a source map was provided but nothing matches, returns nil so callers
    /// can try another navigation source before falling back to unfiltered navigation.
    private static func applySourceFilter(
        _ items: [EPUBKitBookNavigationItem],
        sourceChapterPaths: [String: Bool]?
    ) -> [EPUBKitBookNavigationItem]? {
        guard let sourceChapterPaths, !sourceChapterPaths.isEmpty else { return items }
        let filtered = items.compactMap { item -> EPUBKitBookNavigationItem? in
            guard let relativePath = relativeChapterPath(for: item.path),
                  let isArchived = sourceChapterPaths[relativePath]
                    ?? sourceChapterPaths[URL(fileURLWithPath: item.path).lastPathComponent] else { return nil }
            return EPUBKitBookNavigationItem(id: item.id, title: item.title, path: item.path, isArchived: isArchived)
        }
        return filtered.isEmpty ? nil : filtered
    }

    private static func navigationFromEPUBKit(chaptersURL: URL, currentPath: String, sourceChapterPaths: [String: Bool]?) -> EPUBKitBookNavigation? {
        guard let document = EPUBDocument(url: chaptersURL) else { return nil }

        let tocTitles = flattenedTOCTitles(document.tableOfContents)
        var items: [EPUBKitBookNavigationItem] = []
        var seenPaths = Set<String>()

        for spineItem in document.spine.items where spineItem.linear {
            guard let manifestItem = document.manifest.items[spineItem.idref],
                  isReadableContent(manifestItem.mediaType) else { continue }

            let fileURL = document.contentDirectory
                .appendingPathComponent(manifestItem.path)
                .standardizedFileURL
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  seenPaths.insert(fileURL.path).inserted else { continue }

            let key = normalizedEPUBResourceKey(manifestItem.path)
            let title = readerChapterTitle(at: fileURL.path, tocTitle: tocTitles[key])
            items.append(EPUBKitBookNavigationItem(
                id: fileURL.path,
                title: title,
                path: fileURL.path
            ))
        }

        guard let resolvedItems = applySourceFilter(items, sourceChapterPaths: sourceChapterPaths) else { return nil }
        guard resolvedItems.count > 1 else { return nil }
        let currentIndex = bestCurrentIndex(in: resolvedItems, currentPath: currentPath)
        return EPUBKitBookNavigation(items: resolvedItems, currentIndex: currentIndex)
    }

    private static func navigationFromExtractedChapterFiles(chaptersURL: URL, currentPath: String, sourceChapterPaths: [String: Bool]?) -> EPUBKitBookNavigation? {
        guard let enumerator = FileManager.default.enumerator(
            at: chaptersURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard isReadableContentExtension(url.pathExtension),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let components = Set(url.standardizedFileURL.pathComponents.map { $0.lowercased() })
            if components.contains("meta-inf") { continue }
            let name = url.lastPathComponent.lowercased()
            if name.contains("nav") || name.contains("toc") || name.hasSuffix(".opf") || name.hasSuffix(".ncx") { continue }
            urls.append(url.standardizedFileURL)
        }

        let sorted = urls.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        guard sorted.count > 1 else { return nil }

        let items = sorted.map { url in
            EPUBKitBookNavigationItem(
                id: url.path,
                title: readerChapterTitle(at: url.path, tocTitle: nil),
                path: url.path
            )
        }
        guard let resolvedItems = applySourceFilter(items, sourceChapterPaths: sourceChapterPaths) else { return nil }
        guard resolvedItems.count > 1 else { return nil }
        let currentIndex = bestCurrentIndex(in: resolvedItems, currentPath: currentPath)
        return EPUBKitBookNavigation(items: resolvedItems, currentIndex: currentIndex)
    }

    static func chaptersDirectory(containing path: String) -> URL? {
        var current = URL(fileURLWithPath: path).deletingLastPathComponent()
        while current.path != "/" {
            let name = current.lastPathComponent
            if name == "Chapters" || name.hasSuffix("_Chapters") {
                return current.standardizedFileURL
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    static func relativeChapterPath(for path: String) -> String? {
        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        guard let chaptersURL = chaptersDirectory(containing: fileURL.path) else { return nil }
        let chaptersPath = chaptersURL.path
        guard fileURL.path.hasPrefix(chaptersPath + "/") else { return nil }
        return String(fileURL.path.dropFirst(chaptersPath.count + 1))
    }

    static func resolvedChapterPath(relativePath: String, fallbackPath: String) -> String? {
        guard !relativePath.isEmpty,
              let chaptersURL = chaptersDirectory(containing: fallbackPath) else { return nil }
        let resolved = chaptersURL.appendingPathComponent(relativePath).standardizedFileURL
        return resolved.path
    }

    /// Base URL for `loadHTMLString` when opening legacy combined chapter files.
    /// Combined chapter assets are rebased relative to `ForeverLMCombinedChapters`,
    /// not the parent `Chapters` directory.
    static func htmlDocumentBaseURL(for chapterPath: String) -> URL {
        URL(fileURLWithPath: chapterPath).deletingLastPathComponent()
    }

    /// Loads an extracted EPUB chapter into WebKit with read access to the full
    /// `Chapters` tree and a document base URL that matches combined chapter paths.
    ///
    /// Chapter files live in iCloud Drive, so a synchronous read can stall for
    /// seconds while CloudDocs downloads an evicted file. The read happens off the
    /// main actor; only the WebKit load hops back.
    @MainActor
    static func loadChapter(into webView: WKWebView, filePath: String) async {
        let html = await Task.detached(priority: .userInitiated) {
            normalizedXHTMLContent(for: filePath)
        }.value
        guard !Task.isCancelled else { return }
        if let html {
            webView.loadHTMLString(html, baseURL: htmlDocumentBaseURL(for: filePath))
        } else {
            let fileURL = URL(fileURLWithPath: filePath)
            let accessURL = chaptersDirectory(containing: filePath)?.standardizedFileURL
                ?? fileURL.deletingLastPathComponent()
            webView.loadFileURL(fileURL, allowingReadAccessTo: accessURL)
        }
    }

    /// Legacy combined chapter files used an HTML5 doctype, which makes `.xhtml`
    /// fail strict XML parsing in WKWebView. Returns normalized HTML when that fix
    /// is needed, otherwise nil so callers can load the file directly.
    static func normalizedXHTMLContent(for path: String) -> String? {
        guard path.lowercased().hasSuffix(".xhtml"),
              var html = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("<!doctype html>") else { return nil }
        if let newline = html.firstIndex(of: "\n") {
            html.removeSubrange(html.startIndex...newline)
        } else {
            html = html.replacingOccurrences(
                of: "<!doctype html>",
                with: "",
                options: [.caseInsensitive, .anchored]
            )
        }
        return html
    }

    private static func bestCurrentIndex(in items: [EPUBKitBookNavigationItem], currentPath: String) -> Int? {
        let currentURL = URL(fileURLWithPath: currentPath).standardizedFileURL
        if let exact = items.firstIndex(where: { $0.path == currentURL.path }) {
            return exact
        }

        let currentName = currentURL.lastPathComponent.lowercased()
        return items.firstIndex {
            URL(fileURLWithPath: $0.path).lastPathComponent.lowercased() == currentName
        }
    }

    private static func flattenedTOCTitles(_ toc: EPUBTableOfContents) -> [String: String] {
        var titles: [String: String] = [:]

        func walk(_ entries: [EPUBTableOfContents]?) {
            for entry in entries ?? [] {
                if let item = entry.item {
                    let key = normalizedEPUBResourceKey(item)
                    let title = entry.label.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !key.isEmpty, !title.isEmpty, titles[key] == nil {
                        titles[key] = title
                    }
                }
                walk(entry.subTable)
            }
        }

        walk(toc.subTable)
        return titles
    }

    private static func normalizedEPUBResourceKey(_ value: String) -> String {
        var path = value.removingPercentEncoding ?? value
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        return URL(fileURLWithPath: path).lastPathComponent.lowercased()
    }

    private static func isReadableContent(_ mediaType: EPUBMediaType) -> Bool {
        switch mediaType {
        case .xHTML, .svg:
            return true
        default:
            return false
        }
    }

    private static func isReadableContentExtension(_ ext: String) -> Bool {
        switch ext.lowercased() {
        case "xhtml", "html", "htm":
            return true
        default:
            return false
        }
    }

    private static func readerChapterTitle(at path: String, tocTitle: String?) -> String {
        if let tocTitle {
            let normalized = normalizeReaderChapterTitle(tocTitle)
            if !normalized.isEmpty, !EPUBParser.isGenericChapterLabel(tocTitle) { return normalized }
        }
        if let raw = try? String(contentsOfFile: path, encoding: .utf8),
           let heading = EPUBParser.extractHeadingFromHTML(raw) {
            let normalized = normalizeReaderChapterTitle(heading)
            if !normalized.isEmpty { return normalized }
        }
        return normalizeReaderChapterTitle(
            (URL(fileURLWithPath: path).lastPathComponent as NSString).deletingPathExtension
        )
    }

    /// Strips ForeverLM combined-chapter sort prefixes (`02 1) Title` → `1) Title`)
    /// and normalizes numbered labels to match imported source titles.
    private static func normalizeReaderChapterTitle(_ raw: String) -> String {
        var name = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.range(of: #"^\d{2}\s+"#, options: .regularExpression) != nil {
            name = name.replacingOccurrences(of: #"^\d{2}\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let normalized = EPUBParser.normalizeChapterTitle(name)
        return normalized.isEmpty ? "Chapter" : normalized
    }
}
#endif
