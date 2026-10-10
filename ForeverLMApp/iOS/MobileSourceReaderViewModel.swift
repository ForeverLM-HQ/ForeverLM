import CloudKit
import Combine
import Foundation
import os

// Readable text for transcript/article surfaces and source-grounded chat. Paper
// visuals are handled by MobileSourcePDFView so the reader shows the original
// document; its extracted text still loads here in the background for Ask.

/// Reader preferences that live in UserDefaults. They sit outside the view model
/// so the off-main document build can read them without hopping to the main actor.
enum MobileReaderPreferences {
    static let fontScaleRange: ClosedRange<Double> = 0.85...1.6
    static let fontScaleStep = 0.15
    static let defaultFontScale = 1.0

    fileprivate static let fontScaleKey = "ios.reader.fontScale"

    static func clampedFontScale(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return defaultFontScale }
        return min(max(value, fontScaleRange.lowerBound), fontScaleRange.upperBound)
    }

    /// The place saved for a source in the member's `ReadingState` (§3.5.18), which every device reads;
    /// nil before it was read, or when the session cannot start.
    static func savedFraction(sourceID: String) async -> Double? {
        guard let writer = await MobileRecordWriter.current() else { return nil }
        return try? await writer.readingFraction(of: sourceID)
    }
}

/// Everything the reader needs to render, assembled off the main actor.
private struct MobileReaderDocument: Sendable {
    let body: String
    let html: String
    let truncated: Bool
    let fontScale: Double
    let scrollFraction: Double
}

private struct MobileReaderChatContext: Sendable {
    let body: String
    let truncated: Bool
}

/// One chapter of a book read whole, fetched and prepared off the main actor.
private struct MobileBookChapterContent: Sendable {
    /// The reflowed text, for Ask and text-to-speech context, like `sourceText`.
    let text: String
    let bodyHTML: String
}

/// What the reader should record after the page reported where the reader is in
/// a book. The view records it, since the activity ledger lives in the audio model.
struct MobileBookReadingOutcome: Equatable {
    /// Chapters read to their end with this report.
    var reachedEnd: [String] = []
    /// How far through the chapter on screen, when it did not just reach its end.
    var depth: MobileBookReadingPoint?
}

@MainActor
final class MobileSourceReaderViewModel: ObservableObject {
    enum State: Equatable {
        case loading
        case ready(html: String)
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var fontScale = MobileReaderPreferences.defaultFontScale
    @Published private(set) var isTruncated = false
    @Published private(set) var initialScrollFraction: Double = 0
    @Published private(set) var highlights: [SourceHighlight] = []
    /// A chat's CloudKit save is kicked off as its sheet is dismissed, so the
    /// sheet is gone before the save can fail. The reader outlives it and shows
    /// the failure instead — a silent one would be a lie about what synced.
    @Published var sessionSaveError: String?

    /// The reflowed source text, kept so the chat sheet never refetches it.
    /// Always the plain text, even when the reader is showing a chapter document:
    /// Ask must not be handed base64 image data. In a book read whole, the text
    /// of the chapter on screen.
    private(set) var sourceText = ""

    /// The synced chapter document, when this source has one — an EPUB chapter's
    /// own markup with its figures inlined. Kept so a font-size change can rebuild
    /// the page without re-fetching it.
    private var readerBodyHTML: String?

    private var source: MobileCloudSource?
    private var latestScrollFraction: Double = 0
    private var progressSaveTask: Task<Void, Never>?
    private var htmlRebuildTask: Task<Void, Never>?
    private var highlightRefreshTasks: [String: Task<Void, Never>] = [:]
    /// Bumped by every save and delete made in this reader. A background
    /// refresh that started before one of them carries a list without it, so
    /// it must not replace what the learner just did.
    private var highlightEditGeneration = 0
    private var didReportReadingCompletion = false

    // MARK: Whole book

    /// The book as one scroll, when the opened source is an EPUB chapter of a book
    /// with other chapters (`MobileSourceGrouping.bookReadingOrder`); nil for every
    /// other source, which reads exactly as it always has.
    @Published private(set) var bookPage: MobileBookPage?
    /// The chapter under the reading line. Everything the reader does to "this
    /// source" — the title, Ask, Listen, Talk, progress — is done to it.
    @Published private(set) var currentChapterID: String?
    /// A Contents jump to a chapter not on the page is fetching it.
    @Published private(set) var isOpeningChapter = false
    /// The book's chapters in reading order, for Contents.
    private(set) var bookChapters: [MobileCloudSource] = []
    private var bookChaptersByID: [String: MobileCloudSource] = [:]
    private var bookWindow: MobileBookWindow?
    private var bookEnds = MobileBookEndTracker()
    private var bookGeneration = 0
    private var chapterTexts: [String: String] = [:]
    private var highlightsByChapter: [String: [SourceHighlight]] = [:]
    private var bookEdgeTasks: [MobileBookEdge: Task<Void, Never>] = [:]
    private var chapterOpenTask: Task<Void, Never>?
    /// Chapter positions waiting for the debounced write, and the last written.
    private var pendingChapterProgress: [String: Double] = [:]
    private var writtenChapterProgress: [String: Double] = [:]

    private static let progressDebounce: UInt64 = 400_000_000
    private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "SourceReader")

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    var isReadingBook: Bool { bookPage != nil }

    /// The chapter on screen while reading a book whole; nil otherwise.
    var currentChapter: MobileCloudSource? {
        guard bookPage != nil, let currentChapterID else { return nil }
        return bookChaptersByID[currentChapterID]
    }

    /// The reflowed text of a chapter on the page, for Ask about a selection in it.
    func text(ofChapter chapterID: String) -> String? {
        chapterTexts[chapterID]
    }

    var canIncreaseFontSize: Bool {
        isReady && fontScale < MobileReaderPreferences.fontScaleRange.upperBound - 0.0001
    }

    var canDecreaseFontSize: Bool {
        isReady && fontScale > MobileReaderPreferences.fontScaleRange.lowerBound + 0.0001
    }

    // MARK: - Loading

    /// `catalog` is the phone's library: an EPUB book chapter opened from it is
    /// read with the rest of its book (`loadBook`).
    func load(source: MobileCloudSource, catalog: [MobileCloudSource] = []) async {
        if self.source?.id == source.id, isReady { return }
        self.source = source
        // The view model cannot see Schedule state. Report one real end reach
        // per reader lifetime even for a legacy readAt-only source; the shared
        // completion writer cheaply no-ops when both synced records already exist.
        didReportReadingCompletion = false
        readerBodyHTML = nil
        resetBook()
        state = .loading

        let bookChapters = MobileSourceGrouping.bookReadingOrder(for: source, in: catalog)
        if !bookChapters.isEmpty {
            await loadBook(opening: source, chapters: bookChapters)
            return
        }

        // Highlights are already on the phone, in the catalog's mirror of the
        // Knowledge zone, so the reader shows them at once and never waits on
        // CloudKit for them. It used to run a zone delta first, ahead of even
        // the text fetch, and a dropped connection became "Highlights could
        // not be loaded … (CKErrorDomain error 4.)" over highlights that were
        // sitting on the phone the whole time.
        highlights = await MobileCloudSourceCatalog.shared.currentSourceHighlights(sourceID: source.id)
        refreshHighlights(sourceID: source.id)

        let sourceID = source.id
        let sourceType = source.sourceType
        let sourceTitle = source.title
        // EPUB-backed chapters and archived articles publish rich reader HTML.
        // A PDF-split chapter reads its own PDF, so asking for HTML would be a
        // round trip that finds nothing.
        let expectsReaderDocument = (sourceType == "book" && !source.isPDFBackedBookChapter)
            || source.isArchivedArticle

        do {
            // Rich source images live in a second asset because synced source
            // text has had every `<img>` stripped out. Start that fetch before
            // the text so an illustrated source costs no extra serial round trip.
            let readerTask: Task<String?, Never>? = expectsReaderDocument
                ? Task { await MobileSourceFileStore.shared.fetchReaderHTML(sourceID: sourceID) }
                : nil

            // The store reads a CKAsset off disk synchronously inside its actor,
            // so this must never be awaited from a render path.
            let raw = try await MobileCloudSourceTextStore.shared.loadSourceText(sourceID: sourceID)

            // A paper renders its original PDF. Prepare only the extracted text
            // that Ask needs instead of building a large, invisible HTML page.
            if sourceType == "paper" {
                let prepared = await Task.detached(priority: .userInitiated) {
                    let body = MobileReaderText.reflowed(raw, sourceType: sourceType)
                    return MobileReaderChatContext(
                        body: body,
                        truncated: false
                    )
                }.value
                guard !Task.isCancelled else { return }

                sourceText = prepared.body
                isTruncated = prepared.truncated
                state = .ready(html: "")
                return
            }

            var fetchedReaderBody: String?
            if let readerTask {
                fetchedReaderBody = await readerTask.value
            }
            guard !Task.isCancelled else { return }
            let readerBody = fetchedReaderBody
            readerBodyHTML = readerBody

            let saved = await MobileReaderPreferences.savedFraction(sourceID: sourceID)
            let document = await Task.detached(priority: .userInitiated) {
                Self.buildDocument(
                    raw: raw,
                    readerBodyHTML: readerBody,
                    sourceType: sourceType,
                    sourceTitle: sourceTitle,
                    sourceID: sourceID,
                    savedFraction: saved
                )
            }.value
            guard !Task.isCancelled else { return }

            sourceText = document.body
            isTruncated = document.truncated
            fontScale = document.fontScale
            initialScrollFraction = document.scrollFraction
            latestScrollFraction = document.scrollFraction
            state = .ready(html: document.html)
        } catch is CancellationError {
            return
        } catch {
            // A source with no synced text is a real failure the user has to act
            // on (open it on the Mac), not something to paper over with an empty
            // reader or placeholder copy.
            state = .failed(MobileCloudKitRetry.describe(error))
        }
    }

    /// Brings in highlights made on another device since the last sync. The
    /// catalog already retries transient CloudKit failures; one that outlasts
    /// the retries leaves the phone's copy on screen, and the library's own
    /// sync status is where an unreachable iCloud is reported — not an alert
    /// on every source opened. Anything else means the phone's copy itself
    /// could not be read, and that is said here.
    private func refreshHighlights(sourceID: String) {
        highlightRefreshTasks[sourceID]?.cancel()
        let generation = highlightEditGeneration
        highlightRefreshTasks[sourceID] = Task { [weak self] in
            do {
                let refreshed = try await MobileCloudSourceCatalog.shared.loadSourceHighlights(sourceID: sourceID)
                guard let self, !Task.isCancelled,
                      self.showsHighlights(of: sourceID),
                      self.highlightEditGeneration == generation else { return }
                self.setHighlights(refreshed, of: sourceID)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.showsHighlights(of: sourceID) else { return }
                if error is CKError {
                    Self.logger.error(
                        "Highlight refresh for \(sourceID, privacy: .private) did not reach iCloud: \(error.localizedDescription, privacy: .public)"
                    )
                } else {
                    self.sessionSaveError = "Highlights could not be loaded: \(error.localizedDescription)"
                }
            }
        }
    }

    func reportSessionSaveError(_ message: String) {
        sessionSaveError = message
    }

    /// Saved under its own source: in a book, the chapter the highlight is in.
    func saveHighlight(_ highlight: SourceHighlight) async -> Bool {
        let owner = bookChaptersByID.isEmpty ? source : bookChaptersByID[highlight.sourceID]
        guard let owner else { return false }
        highlightEditGeneration += 1
        do {
            try await MobileCloudMutationService.shared.saveSourceHighlight(highlight, source: owner)
            var list = currentHighlights(of: highlight.sourceID)
            if let index = list.firstIndex(where: { $0.id == highlight.id }) {
                list[index] = highlight
            } else {
                list.append(highlight)
            }
            list.sort {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id < $1.id
            }
            setHighlights(list, of: highlight.sourceID)
            return true
        } catch {
            sessionSaveError = "Highlight could not be saved: \(MobileCloudKitRetry.describe(error))"
            return false
        }
    }

    func deleteHighlight(id: String) async -> Bool {
        highlightEditGeneration += 1
        do {
            try await MobileCloudMutationService.shared.deleteSourceHighlight(id: id)
            if bookChaptersByID.isEmpty {
                highlights.removeAll { $0.id == id }
            } else {
                for chapterID in highlightsByChapter.keys {
                    highlightsByChapter[chapterID]?.removeAll { $0.id == id }
                }
                publishBookHighlights()
            }
            return true
        } catch {
            sessionSaveError = "Highlight could not be deleted: \(MobileCloudKitRetry.describe(error))"
            return false
        }
    }

    /// Whether this reader shows `sourceID`'s highlights: the opened source's,
    /// or in a book every chapter's.
    private func showsHighlights(of sourceID: String) -> Bool {
        bookChaptersByID.isEmpty ? source?.id == sourceID : bookChaptersByID[sourceID] != nil
    }

    private func currentHighlights(of sourceID: String) -> [SourceHighlight] {
        bookChaptersByID.isEmpty ? highlights : highlightsByChapter[sourceID] ?? []
    }

    private func setHighlights(_ list: [SourceHighlight], of sourceID: String) {
        guard !bookChaptersByID.isEmpty else {
            highlights = list
            return
        }
        highlightsByChapter[sourceID] = list
        publishBookHighlights()
    }

    /// Every chapter's highlights the reader has seen; the page paints those of
    /// the chapters it holds, each within its own chapter.
    private func publishBookHighlights() {
        highlights = bookChapters.flatMap { highlightsByChapter[$0.id] ?? [] }
    }

    func retry() async {
        guard let source else { return }
        await load(source: source, catalog: bookChapters)
    }

    /// Reflow, preference reads and the HTML build all happen here, off the main
    /// actor — escaping and templating a 50k-character document is not cheap.
    private nonisolated static func buildDocument(
        raw: String,
        readerBodyHTML: String?,
        sourceType: String,
        sourceTitle: String,
        sourceID: String,
        savedFraction: Double?
    ) -> MobileReaderDocument {
        let defaults = UserDefaults.standard
        let scale = MobileReaderPreferences.clampedFontScale(
            defaults.object(forKey: MobileReaderPreferences.fontScaleKey) as? Double
                ?? MobileReaderPreferences.defaultFontScale
        )
        let fraction = min(max(savedFraction ?? 0, 0), 1)

        let body = MobileReaderText.reflowed(raw, sourceType: sourceType)
        let truncated = false

        return MobileReaderDocument(
            body: body,
            html: renderedHTML(
                body: body,
                readerBodyHTML: readerBodyHTML,
                sourceType: sourceType,
                sourceTitle: sourceTitle,
                fontScale: scale,
                truncated: truncated
            ),
            truncated: truncated,
            fontScale: scale,
            scrollFraction: fraction
        )
    }

    /// A synced chapter document renders as itself — that markup is where the
    /// book's figures are. Everything else is escaped plain text, as before.
    private nonisolated static func renderedHTML(
        body: String,
        readerBodyHTML: String?,
        sourceType: String,
        sourceTitle: String,
        fontScale: Double,
        truncated: Bool
    ) -> String {
        if let readerBodyHTML, !readerBodyHTML.isEmpty {
            return MobileReaderText.documentHTML(
                bodyHTML: readerBodyHTML,
                fontScale: fontScale,
                truncated: truncated
            )
        }
        return MobileReaderText.html(
            body: body,
            sourceType: sourceType,
            sourceTitle: sourceTitle,
            fontScale: fontScale,
            truncated: truncated
        )
    }

    // MARK: - Font size

    func increaseFontSize() {
        setFontScale(fontScale + MobileReaderPreferences.fontScaleStep)
    }

    func decreaseFontSize() {
        setFontScale(fontScale - MobileReaderPreferences.fontScaleStep)
    }

    private func setFontScale(_ value: Double) {
        let next = MobileReaderPreferences.clampedFontScale(value)
        guard abs(next - fontScale) > 0.0001 else { return }
        fontScale = next

        Task.detached(priority: .utility) {
            UserDefaults.standard.set(next, forKey: MobileReaderPreferences.fontScaleKey)
        }
        if var page = bookPage {
            // A book page resizes its text in place, keeping every chapter it
            // holds and the words at the reading line.
            page.fontScale = next
            bookPage = page
            return
        }
        rebuildDocument()
    }

    private func rebuildDocument() {
        guard isReady else { return }
        let body = sourceText
        let truncated = isTruncated
        let scale = fontScale
        let sourceType = source?.sourceType ?? ""
        let sourceTitle = source?.title ?? ""
        let readerBody = readerBodyHTML

        htmlRebuildTask?.cancel()
        htmlRebuildTask = Task { [weak self] in
            let html = await Task.detached(priority: .userInitiated) {
                Self.renderedHTML(
                    body: body,
                    readerBodyHTML: readerBody,
                    sourceType: sourceType,
                    sourceTitle: sourceTitle,
                    fontScale: scale,
                    truncated: truncated
                )
            }.value
            guard !Task.isCancelled else { return }
            self?.state = .ready(html: html)
        }
    }

    // MARK: - Reading position

    /// Called from the web view's scroll observer. Writes are debounced and
    /// latest-wins so a flick doesn't turn into a burst of UserDefaults writes.
    @discardableResult
    func recordScrollFraction(_ fraction: Double) -> Bool {
        guard let sourceID = source?.id, fraction.isFinite else { return false }
        let clamped = min(max(fraction, 0), 1)
        let reachedEnd = !didReportReadingCompletion
            && MobileReadingCompletion.reachedEnd(clamped)
        if reachedEnd {
            didReportReadingCompletion = true
        }
        guard abs(clamped - latestScrollFraction) > 0.0005 else { return reachedEnd }
        latestScrollFraction = clamped

        progressSaveTask?.cancel()
        progressSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.progressDebounce)
            guard !Task.isCancelled else { return }
            self?.writeProgress(sourceID: sourceID)
        }
        return reachedEnd
    }

    /// Persists immediately — for leaving the reader or backgrounding the app,
    /// where the debounce window would otherwise swallow the last position.
    func flushProgress() {
        progressSaveTask?.cancel()
        progressSaveTask = nil
        if bookPage != nil {
            writePendingChapterProgress()
            return
        }
        guard let sourceID = source?.id, isReady else { return }
        writeProgress(sourceID: sourceID)
    }

    private func writeProgress(sourceID: String) {
        writeProgress(latestScrollFraction, sourceID: sourceID)
    }

    private func writeProgress(_ value: Double, sourceID: String) {
        Task.detached(priority: .utility) {
            // The member's ReadingState, sent after its 30-second debounce (§6.6).
            do {
                try await MobileRecordWriter.required().saveReadingPosition(sourceID, fraction: value)
            } catch {
                Logger(subsystem: "com.foreverlm.mobile", category: "SourceReader")
                    .error("The reading position was not saved: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Whole book

    /// Reads `source` with the rest of its book: the chapter first, at the place
    /// it was left, and the chapters either side as the reader nears them.
    private func loadBook(opening source: MobileCloudSource, chapters: [MobileCloudSource]) async {
        guard let window = MobileBookWindow(chapterIDs: chapters.map(\.id), openingAt: source.id) else { return }
        bookChapters = chapters
        bookChaptersByID = Dictionary(chapters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // As for a single source: the phone's copy of the highlights at once,
        // then whatever another device has added.
        highlightsByChapter[source.id] = await MobileCloudSourceCatalog.shared.currentSourceHighlights(sourceID: source.id)
        publishBookHighlights()
        refreshHighlights(sourceID: source.id)

        do {
            let content = try await Self.fetchBookChapter(source)
            let sourceID = source.id
            let saved = await MobileReaderPreferences.savedFraction(sourceID: sourceID)
            let opening = await Task.detached(priority: .userInitiated) {
                Self.bookOpening(sourceID: sourceID, savedFraction: saved)
            }.value
            guard !Task.isCancelled else { return }
            fontScale = opening.fontScale
            presentBook(
                opening: source,
                content: content,
                window: window,
                fraction: opening.fraction,
                shell: opening.shell
            )
        } catch is CancellationError {
            return
        } catch {
            // The chapter the learner opened has no synced text: the same real
            // failure as a single source, with the same Try Again.
            state = .failed(MobileCloudKitRetry.describe(error))
        }
    }

    /// The page's report of where the reader is. The chapter on screen, its
    /// saved position and fetching the chapters either side are handled here;
    /// what belongs in the activity ledger comes back for the view to record.
    func recordBookReading(_ report: MobileBookReadingReport) -> MobileBookReadingOutcome {
        guard bookPage != nil, let window = bookWindow, bookChaptersByID[report.chapterID] != nil else {
            return MobileBookReadingOutcome()
        }
        if currentChapterID != report.chapterID {
            currentChapterID = report.chapterID
            sourceText = chapterTexts[report.chapterID] ?? ""
        }
        recordChapterProgress(report.fraction, chapterID: report.chapterID)

        var outcome = MobileBookReadingOutcome()
        for chapter in report.visible where bookEnds.observe(chapter.chapterID, fraction: chapter.fraction) {
            outcome.reachedEnd.append(chapter.chapterID)
        }
        if !outcome.reachedEnd.contains(report.chapterID) {
            outcome.depth = report.point
        }

        // More of the book, once the page holds what it was last given: a report
        // from before the last chapter went in would otherwise fetch another.
        if report.isNearEnd, report.lastChapterID == window.loadedIDs.last {
            extendBook(.end)
        }
        if report.isNearStart, report.firstChapterID == window.loadedIDs.first {
            extendBook(.start)
        }
        return outcome
    }

    /// Try Again at an end whose chapter did not load.
    func retryBookEdge(_ edge: MobileBookEdge) {
        guard bookPage?.state(at: edge) == .failed else { return }
        setBookEdge(.idle, at: edge)
        extendBook(edge)
    }

    /// Contents. A chapter already on the page is scrolled to; any other is
    /// fetched and becomes the page's opening chapter, read from its top, with
    /// the book growing from there as it does when a chapter is opened.
    func openChapter(_ chapterID: String) {
        guard var page = bookPage, let window = bookWindow, let chapter = bookChaptersByID[chapterID] else { return }
        flushProgress()
        chapterOpenTask?.cancel()
        isOpeningChapter = false
        bookEnds.begin(chapterID)

        if window.contains(chapterID) {
            page.scrollRequest = MobileBookPage.ScrollRequest(
                token: (page.scrollRequest?.token ?? 0) + 1,
                chapterID: chapterID
            )
            bookPage = page
            currentChapterID = chapterID
            sourceText = chapterTexts[chapterID] ?? ""
            return
        }

        guard let reopened = MobileBookWindow(chapterIDs: window.chapterIDs, openingAt: chapterID) else { return }
        isOpeningChapter = true
        let scale = fontScale
        chapterOpenTask = Task { [weak self] in
            do {
                let content = try await Self.fetchBookChapter(chapter)
                let chapterHighlights = await MobileCloudSourceCatalog.shared.currentSourceHighlights(sourceID: chapterID)
                let shell = await Task.detached(priority: .userInitiated) {
                    MobileReaderText.bookDocumentHTML(fontScale: scale)
                }.value
                guard let self, !Task.isCancelled else { return }
                self.cancelBookEdgeTasks()
                self.highlightsByChapter[chapterID] = chapterHighlights
                self.publishBookHighlights()
                self.presentBook(opening: chapter, content: content, window: reopened, fraction: 0, shell: shell)
                self.isOpeningChapter = false
                self.refreshHighlights(sourceID: chapterID)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isOpeningChapter = false
                self.sessionSaveError = "\(chapter.title) could not be opened: \(MobileCloudKitRetry.describe(error))"
            }
        }
    }

    /// A fresh page holding `chapter` alone: when the reader opens, and after a
    /// Contents jump off the page.
    private func presentBook(
        opening chapter: MobileCloudSource,
        content: MobileBookChapterContent,
        window: MobileBookWindow,
        fraction: Double,
        shell: String
    ) {
        bookGeneration += 1
        bookWindow = window
        bookEnds.begin(chapter.id)
        chapterTexts[chapter.id] = content.text
        writtenChapterProgress[chapter.id] = fraction
        currentChapterID = chapter.id
        sourceText = content.text
        isTruncated = false
        bookPage = MobileBookPage(
            generation: bookGeneration,
            restore: MobileBookReadingPoint(chapterID: chapter.id, fraction: fraction),
            chapters: [MobileBookPage.Chapter(
                id: chapter.id,
                bodyHTML: content.bodyHTML,
                isBookStart: window.isBookStart(chapter.id)
            )],
            startState: window.reachesStart ? .bookEnd : .idle,
            endState: window.reachesEnd ? .bookEnd : .idle,
            fontScale: fontScale,
            scrollRequest: nil
        )
        state = .ready(html: shell)
    }

    /// Fetches the chapter next to the page at `edge`. An end already fetching,
    /// failed (it waits for Try Again), or at the book's own end does nothing.
    private func extendBook(_ edge: MobileBookEdge) {
        guard var page = bookPage, let window = bookWindow,
              page.state(at: edge) == .idle,
              let chapterID = window.neighbor(at: edge),
              let chapter = bookChaptersByID[chapterID] else { return }
        page.setState(.loading, at: edge)
        bookPage = page
        let generation = bookGeneration
        bookEdgeTasks[edge] = Task { [weak self] in
            do {
                let content = try await Self.fetchBookChapter(chapter)
                let chapterHighlights = await MobileCloudSourceCatalog.shared.currentSourceHighlights(sourceID: chapterID)
                guard let self, !Task.isCancelled, self.bookGeneration == generation else { return }
                self.addBookChapter(chapter, content: content, highlights: chapterHighlights, at: edge)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, self.bookGeneration == generation else { return }
                Self.logger.error(
                    "Book chapter \(chapterID, privacy: .private) did not load: \(error.localizedDescription, privacy: .public)"
                )
                self.bookEdgeTasks[edge] = nil
                self.setBookEdge(.failed, at: edge)
            }
        }
    }

    private func addBookChapter(
        _ chapter: MobileCloudSource,
        content: MobileBookChapterContent,
        highlights chapterHighlights: [SourceHighlight],
        at edge: MobileBookEdge
    ) {
        bookEdgeTasks[edge] = nil
        guard var page = bookPage, var window = bookWindow else { return }
        guard window.neighbor(at: edge) == chapter.id else {
            // The page moved on while this chapter was fetched; the next report
            // asks for whichever chapter is next to it now.
            setBookEdge(.idle, at: edge)
            return
        }
        window.extend(edge)
        chapterTexts[chapter.id] = content.text
        let entry = MobileBookPage.Chapter(
            id: chapter.id,
            bodyHTML: content.bodyHTML,
            isBookStart: window.isBookStart(chapter.id)
        )
        if edge == .start {
            page.chapters.insert(entry, at: 0)
        } else {
            page.chapters.append(entry)
        }
        page.setState(window.reaches(edge) ? .bookEnd : .idle, at: edge)

        // Far behind the reader a chapter's pictures are only memory; it comes
        // back from the phone's cache when the reader turns back to it.
        let farEdge: MobileBookEdge = edge == .start ? .end : .start
        let dropped = window.trim(keeping: currentChapterID, after: edge)
        if !dropped.isEmpty {
            page.chapters.removeAll { dropped.contains($0.id) }
            bookEdgeTasks[farEdge]?.cancel()
            bookEdgeTasks[farEdge] = nil
            page.setState(.idle, at: farEdge)
        }
        bookWindow = window
        highlightsByChapter[chapter.id] = chapterHighlights
        publishBookHighlights()
        bookPage = page
        refreshHighlights(sourceID: chapter.id)
    }

    private func setBookEdge(_ state: MobileBookEdgeState, at edge: MobileBookEdge) {
        guard var page = bookPage else { return }
        page.setState(state, at: edge)
        bookPage = page
    }

    private func cancelBookEdgeTasks() {
        bookEdgeTasks.values.forEach { $0.cancel() }
        bookEdgeTasks = [:]
    }

    private func resetBook() {
        cancelBookEdgeTasks()
        chapterOpenTask?.cancel()
        chapterOpenTask = nil
        bookPage = nil
        currentChapterID = nil
        isOpeningChapter = false
        bookChapters = []
        bookChaptersByID = [:]
        bookWindow = nil
        bookEnds = MobileBookEndTracker()
        chapterTexts = [:]
        highlightsByChapter = [:]
        pendingChapterProgress = [:]
        writtenChapterProgress = [:]
    }

    /// Only the chapter on screen moves its saved position, debounced like a
    /// single source's; each chapter keeps its own device-local key.
    private func recordChapterProgress(_ fraction: Double, chapterID: String) {
        let clamped = min(max(fraction, 0), 1)
        let last = pendingChapterProgress[chapterID] ?? writtenChapterProgress[chapterID]
        guard last.map({ abs($0 - clamped) > 0.0005 }) ?? true else { return }
        pendingChapterProgress[chapterID] = clamped
        progressSaveTask?.cancel()
        progressSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.progressDebounce)
            guard !Task.isCancelled else { return }
            self?.writePendingChapterProgress()
        }
    }

    private func writePendingChapterProgress() {
        let pending = pendingChapterProgress
        pendingChapterProgress = [:]
        for (chapterID, value) in pending {
            writtenChapterProgress[chapterID] = value
            writeProgress(value, sourceID: chapterID)
        }
    }

    /// One chapter as the single-chapter reader fetches it — its illustrated
    /// document started first, then its synced text, which Ask needs and a
    /// missing document falls back to — prepared for the book page off the main
    /// actor. Sanitizing a chapter with its pictures inlined is megabytes of work.
    private nonisolated static func fetchBookChapter(_ chapter: MobileCloudSource) async throws -> MobileBookChapterContent {
        let sourceID = chapter.id
        let sourceType = chapter.sourceType
        let readerTask = Task { await MobileSourceFileStore.shared.fetchReaderHTML(sourceID: sourceID) }
        let raw = try await MobileCloudSourceTextStore.shared.loadSourceText(sourceID: sourceID)
        let readerBody = await readerTask.value
        return await Task.detached(priority: .userInitiated) {
            let text = MobileReaderText.reflowed(raw, sourceType: sourceType)
            return MobileBookChapterContent(
                text: text,
                bodyHTML: MobileReaderText.bookChapterBodyHTML(readerBodyHTML: readerBody, plainText: text)
            )
        }.value
    }

    /// The reader's text size, the opened chapter's saved position, and the
    /// empty book page built at that size.
    private nonisolated static func bookOpening(sourceID: String, savedFraction: Double?) -> (fontScale: Double, fraction: Double, shell: String) {
        let defaults = UserDefaults.standard
        let scale = MobileReaderPreferences.clampedFontScale(
            defaults.object(forKey: MobileReaderPreferences.fontScaleKey) as? Double
                ?? MobileReaderPreferences.defaultFontScale
        )
        let fraction = min(max(savedFraction ?? 0, 0), 1)
        return (scale, fraction, MobileReaderText.bookDocumentHTML(fontScale: scale))
    }
}
