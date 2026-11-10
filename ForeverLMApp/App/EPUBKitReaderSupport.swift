#if os(macOS)
import Foundation
import SwiftUI
import WebKit

/// A per-device, non-evictable mirror of archived article HTML and images.
///
/// New canonical archives live in local Application Support and travel between
/// devices through the source's CloudKit reader asset. Optimize Mac Storage can
/// leave dataless placeholders for a file in an iCloud root. In either case the
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
            guard isRecordedFile(canonicalHTML) else {
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

struct BookNavigationItem: Identifiable, Equatable {
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

struct BookNavigation: Equatable {
    let items: [BookNavigationItem]
    let currentIndex: Int?
    /// The section of the current chapter the reader is in, when the chapter
    /// has sections and the reader has reached the first of them.
    var currentSectionID: String? = nil

    var currentItem: BookNavigationItem? {
        guard let currentIndex, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    var nextItem: BookNavigationItem? {
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
    @Published private(set) var navigation: BookNavigation?
    /// Set by a reader whose document is one run of pages; an EPUB has
    /// chapters but no page count and leaves this `nil`.
    @Published private(set) var pageNavigation: ReaderPageNavigation?
    /// Whether the reader can turn a page (a PDF the learner may rotate), for
    /// the ⋯ menu's Rotate Page items.
    @Published private(set) var canTurnPage = false
    private var navigateHandler: ((BookNavigationItem) -> Void)?
    private var goToPageHandler: ((Int) -> Void)?
    private var turnPageHandler: ((Int) -> Void)?

    func update(
        navigation: BookNavigation?,
        navigate: @escaping (BookNavigationItem) -> Void
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

    /// `turnPage` receives a quarter turn in degrees (90 clockwise, -90 back)
    /// for the page on screen; nil when the document has no pages to turn.
    func update(turnPage: ((Int) -> Void)?) {
        if canTurnPage != (turnPage != nil) {
            canTurnPage = turnPage != nil
        }
        turnPageHandler = turnPage
    }

    func clear() {
        navigation = nil
        navigateHandler = nil
        pageNavigation = nil
        goToPageHandler = nil
        canTurnPage = false
        turnPageHandler = nil
    }

    func navigate(to item: BookNavigationItem) {
        navigateHandler?(item)
    }

    func goToPage(_ pageIndex: Int) {
        goToPageHandler?(pageIndex)
    }

    func turnPage(by degrees: Int) {
        turnPageHandler?(degrees)
    }
}

// `EPUBReadingPositionLocator` lives in `Models.swift` alongside
// `ArticleReadingPositionLocator` and `VideoWatchProgress` — the other two
// encodings of `sources.reading_position_locator`.

enum EPUBKitReaderSupport {
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

    /// Base URL for `loadHTMLString` when opening combined chapter files.
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

    /// Combined chapter files use an HTML5 doctype, which makes `.xhtml`
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
}
#endif
