import AppKit
import Darwin
import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import WebKit

struct RemotePDFReaderView: View {
    let articleId: String
    let url: URL
    /// The paper's landing/abstract page, when it differs from the PDF URL. A
    /// paywalled publisher will serve this page to a signed-in browser even
    /// when it refuses the PDF to us, so it is the useful escape hatch.
    var landingPageURL: URL? = nil
    let initialPageIndex: Int?
    @Binding var selectedText: String
    let findState: ReaderFindState
    let findRevision: Int
    let zoomScale: CGFloat
    /// Page index the learner landed on, with the document's page count so the
    /// view model can turn "page 9 of 10" into a depth for the activity ledger.
    let pageChanged: (Int, Int) -> Void
    let zoomScaleChanged: (CGFloat) -> Void
    let zoomInAction: () -> Void
    let zoomOutAction: () -> Void
    let resetZoomAction: () -> Void
    @Environment(StudioViewModel.self) private var vm
    @State private var document: PDFDocument?
    /// The bytes `document` was read from, for the reader's citation preview.
    @State private var documentData: Data?
    @State private var isLoading = true
    @State private var loadFailure: RemotePDFLoadFailure?
    @State private var isPersistingPDF = false
    @State private var persistedPDFURL: URL?
    @State private var loadRevision = 0

    private var loadTaskID: String {
        "\(url.absoluteString)#\(loadRevision)"
    }

    var body: some View {
        Group {
            if let document {
                PDFKitInlineView(
                    document: document,
                    sourceID: articleId,
                    selectedText: $selectedText,
                    findState: findState,
                    findRevision: findRevision,
                    zoomScale: zoomScale,
                    initialPageIndex: initialPageIndex,
                    pageChanged: pageChanged,
                    zoomScaleChanged: zoomScaleChanged,
                    zoomInAction: zoomInAction,
                    zoomOutAction: zoomOutAction,
                    resetZoomAction: resetZoomAction,
                    documentData: documentData
                )
            } else if isLoading {
                ReaderLoadingView(
                    title: "Loading PDF…",
                    subtitle: "The document will appear here in a moment."
                )
            } else if let loadFailure {
                RemotePDFFailureView(
                    failure: loadFailure,
                    articleId: articleId,
                    pdfURL: url,
                    landingPageURL: landingPageURL,
                    retry: { loadRevision += 1 }
                )
            }
        }
        .task(id: loadTaskID) { await loadRemotePDF() }
    }

    @MainActor
    private func loadRemotePDF() async {
        isLoading = true
        loadFailure = nil
        document = nil
        documentData = nil

        // A paper just added is already having its PDF fetched by the
        // pipeline. A second request for the same file from here does not
        // arrive sooner, and at a publisher that counts requests — medRxiv,
        // bioRxiv — it is the one that tips the count into 429 (2026-09-21:
        // the reader showed "medrxiv.org returned HTTP 429" while the pipeline's
        // copy of the same file landed in Papers). Wait for that fetch; when it
        // attaches the file, the routing above swaps this view for the local
        // PDF, and only when it ends without one does the reader ask itself.
        await waitForPipelineDownload()
        guard !Task.isCancelled else { return }
        guard vm.articles.first(where: { $0.id == articleId })?.cachedResolvedPDFPath == nil else {
            // The pipeline landed the file: the panel re-routes to it.
            isLoading = false
            return
        }

        let result = await RemotePDFLoader.fetch(url)
        guard !Task.isCancelled else { return }

        switch result {
        case .failure(let failure):
            isLoading = false
            // A paper whose PDF the publisher will not hand over is not a
            // paper with nothing to read. Its text may already be stored, and
            // its page is one a subscriber can read on the publisher's site —
            // that is what a subscription without a PDF download is. Show
            // whichever exists rather than a lock: on the page, the learner
            // signs in if they have not, and ForeverLM saves what it renders.
            if failure.isPaywall,
               vm.readerShouldAbandonRemotePDF(articleId) {
                vm.abandonRemotePDFInReader(articleId)
                return
            }
            loadFailure = failure
        case .success(let data):
            guard let doc = await AsyncPDFDocumentLoader.load(data: data) else {
                guard !Task.isCancelled else { return }
                isLoading = false
                loadFailure = .unreadable
                return
            }
            guard !Task.isCancelled else { return }
            document = doc
            documentData = data
            isLoading = false
            await persistPDFDataIfNeeded(data)
        }
    }

    /// Polls while the pipeline is fetching this paper, up to a bound that
    /// covers a slow download plus the reader-session fallback; a fetch still
    /// running after that is left to finish on its own.
    @MainActor
    private func waitForPipelineDownload() async {
        let deadline = ContinuousClock.now + .seconds(120)
        while vm.sourceFetchIsInFlight(articleId),
              vm.articles.first(where: { $0.id == articleId })?.cachedResolvedPDFPath == nil,
              ContinuousClock.now < deadline,
              !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    @MainActor
    private func persistPDFDataIfNeeded(_ data: Data) async {
        guard persistedPDFURL != url, !isPersistingPDF else { return }
        // Keeping the file attaches it as a paper — its text becomes the whole
        // PDF's. Only a paper may be filed that way on the reader's say-so; a
        // document or an excerpt handed in with a PDF URL keeps its type and
        // its text (2026-09-23: one abstract became the whole abstracts page).
        guard vm.articles.first(where: { $0.id == articleId })?.sourceType == .paper else { return }
        isPersistingPDF = true
        defer { isPersistingPDF = false }

        do {
            try await vm.attachDownloadedPDFData(to: articleId, data: data, sourceURL: url)
            persistedPDFURL = url
        } catch {
            print("[RemotePDFReaderView] Failed to save remote PDF for \(articleId): \(error.localizedDescription)")
        }
    }
}

// MARK: - Remote PDF Loading

/// Why a remote PDF could not be shown.
///
/// The reader keeps these apart because they need different responses from the
/// reader: a paywalled paper is not broken and retrying it forever will never
/// work — the user needs the publisher page and a way to attach the PDF they
/// download there. Collapsing everything into "Could not load PDF" hid that.
enum RemotePDFLoadFailure: Error, Equatable {
    /// The publisher refused the file (401/402/403), or answered 200 with an
    /// HTML login/interstitial page instead of a PDF.
    case paywalled(host: String?)
    /// The link no longer resolves to a file (404/410).
    case notFound(host: String?)
    /// The server answered, but with an error status.
    case serverError(status: Int, host: String?)
    /// HTTP 429: the publisher's edge is counting requests from this Mac and
    /// has had too many in a short time. medRxiv and bioRxiv sit behind
    /// Cloudflare rate limits that a paper being added trips easily — the
    /// page for its metadata, the PDF for the pipeline and the PDF again for
    /// the reader all leave within seconds (2026-09-21). Not a refusal of the
    /// file: the same request succeeds a little later.
    case rateLimited(host: String?)
    /// The host could not be reached at all.
    case unreachable(host: String?, message: String)
    /// Bytes arrived and looked like a PDF, but PDFKit could not open them.
    case unreadable

    var isPaywall: Bool {
        if case .paywalled = self { return true }
        return false
    }

    /// Whether attaching a manually downloaded PDF is the realistic fix.
    var suggestsManualAttachment: Bool {
        switch self {
        case .paywalled, .notFound, .unreadable: return true
        case .serverError, .rateLimited, .unreachable: return false
        }
    }

    /// Whether the same request is worth sending again after a pause: the
    /// publisher answered 429, which is about timing, not about the file.
    var isRateLimit: Bool {
        if case .rateLimited = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .paywalled: return "This PDF is paywalled"
        case .notFound: return "This PDF is no longer there"
        case .serverError: return "The publisher couldn't serve this PDF"
        case .rateLimited(let host): return "\(Self.publisher(host)) is asking for a pause"
        case .unreachable(let host, _): return "Couldn't reach \(Self.publisher(host, fallback: "the publisher"))"
        case .unreadable: return "This file isn't a readable PDF"
        }
    }

    var symbol: String {
        switch self {
        case .paywalled: return "lock.fill"
        case .notFound: return "doc.questionmark"
        case .rateLimited: return "hourglass"
        case .serverError, .unreachable: return "exclamationmark.triangle.fill"
        case .unreadable: return "doc.text.fill"
        }
    }

    var message: String {
        switch self {
        case .paywalled(let host):
            return "\(Self.publisher(host)) wants a subscription or institutional sign-in before handing over the file. Open the page in your browser — if you have access there, you can download the PDF and attach it here."
        case .notFound(let host):
            return "\(Self.publisher(host)) returned nothing for this link. The paper may have been moved or withdrawn."
        case .serverError(let status, let host):
            return "\(Self.publisher(host)) returned HTTP \(status). This is usually temporary."
        case .rateLimited(let host):
            return "\(Self.publisher(host)) answered HTTP 429: too many requests from this Mac in a short time. ForeverLM tried again after a pause and was still turned away; give it a minute and retry."
        case .unreachable(_, let message):
            return "\(message) Check your connection and try again."
        case .unreadable:
            return "The download finished, but the file isn't something PDFKit can open."
        }
    }

    private static func publisher(_ host: String?, fallback: String = "The publisher") -> String {
        guard let host, !host.isEmpty else { return fallback }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Fetches a remote PDF and classifies what went wrong.
///
/// Uses the same browser headers as the import pipeline's `downloadPDF`: a bare
/// `URLSession.data(from:)` gets turned away by publishers that serve the file
/// fine to a normal browser, which produced "Could not load PDF" for papers that
/// were not actually paywalled. It also carries the in-app session's cookies, so
/// a publisher the learner signed in to in the reader serves the file here too.
enum RemotePDFLoader {
    /// How long the reader waits before asking again after a 429, per attempt
    /// already made. Two retries, so a paper whose publisher is counting
    /// requests gets three chances over about ten seconds; beyond that the
    /// failure view says what happened and offers Retry.
    static let rateLimitRetryDelays: [Duration] = [.seconds(3), .seconds(7)]

    /// What an HTTP status means for the reader.
    static func failure(forStatus status: Int, host: String?) -> RemotePDFLoadFailure? {
        switch status {
        case 200...299: return nil
        case 401, 402, 403, 407: return .paywalled(host: host)
        case 404, 410: return .notFound(host: host)
        case 429: return .rateLimited(host: host)
        default: return .serverError(status: status, host: host)
        }
    }

    /// Fetches the PDF, asking again after a pause when the publisher answers
    /// 429 (`rateLimitRetryDelays`). Everything else is answered at once.
    static func fetch(_ url: URL) async -> Result<Data, RemotePDFLoadFailure> {
        var attempt = 0
        while true {
            let result = await fetchOnce(url)
            guard case .failure(let failure) = result, failure.isRateLimit,
                  attempt < rateLimitRetryDelays.count else { return result }
            try? await Task.sleep(for: rateLimitRetryDelays[attempt])
            if Task.isCancelled { return result }
            attempt += 1
        }
    }

    static func fetchOnce(_ url: URL) async -> Result<Data, RemotePDFLoadFailure> {
        let host = url.host
        let request = await SourceService.authenticatedBrowserRequest(for: url, timeout: 60)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                // Non-HTTP (file:, data:) — let PDFKit be the judge.
                return .success(data)
            }

            if let failure = failure(forStatus: http.statusCode, host: host) {
                return .failure(failure)
            }

            // A 200 that isn't a PDF at a paper's PDF URL is a login wall or a
            // publisher interstitial, not a corrupt file.
            guard SourceService.looksLikePDFData(data) else {
                return .failure(.paywalled(host: host))
            }

            return .success(data)
        } catch {
            return .failure(.unreachable(host: host, message: error.localizedDescription))
        }
    }
}

// MARK: - Remote PDF Failure View

/// The reader's failure state for a remote PDF. Explains what the publisher
/// actually did and offers the recovery that matches it, rather than a Retry
/// button that cannot succeed.
struct RemotePDFFailureView: View {
    let failure: RemotePDFLoadFailure
    let articleId: String
    let pdfURL: URL
    let landingPageURL: URL?
    let retry: () -> Void

    @Environment(StudioViewModel.self) private var vm
    @State private var isAttachingPDF = false

    private var browserURL: URL { landingPageURL ?? pdfURL }

    /// The AI browser recovery only applies to papers, and it toasts about
    /// papers, so don't offer it for anything else.
    private var isPaper: Bool {
        vm.articles.first(where: { $0.id == articleId })?.sourceType == .paper
    }

    /// A paper the publisher will not hand the PDF over for can still be read
    /// on the publisher's page, in this reader, where signing in is possible
    /// and the rendered text is saved as the paper's content.
    private var offersPublisherPageInReader: Bool {
        failure.isPaywall && isPaper && landingPageURL != nil
    }

    /// Whether ForeverLM already holds this paper's text, in which case the
    /// reader has something to show without the publisher's page at all.
    private var hasStoredText: Bool {
        guard let article = vm.articles.first(where: { $0.id == articleId }) else { return false }
        return StudioViewModel.sourceHasReadableContent(article)
    }

    private var openInBrowserButton: some View {
        Button {
            NSWorkspace.shared.open(browserURL)
        } label: {
            Label(failure.isPaywall ? "Open Publisher Page" : "Open in Browser", systemImage: "safari")
        }
    }

    var body: some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: failure.symbol)
        } description: {
            Text(failure.message)
        } actions: {
            VStack(spacing: 10) {
                if offersPublisherPageInReader {
                    Button {
                        vm.abandonRemotePDFInReader(articleId)
                    } label: {
                        Label(
                            hasStoredText ? "Read the Saved Text" : "Read the Page Here",
                            systemImage: hasStoredText ? "doc.text" : "doc.richtext"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .help(hasStoredText
                          ? "Read the text ForeverLM already holds for this paper"
                          : "Open the publisher's page in ForeverLM's reader, where you can sign in and the text is saved")

                    openInBrowserButton
                        .buttonStyle(.bordered)
                } else {
                    openInBrowserButton
                        .buttonStyle(.borderedProminent)
                }

                if failure.isPaywall && isPaper {
                    Button("Try with AI Browser") {
                        Task { await vm.tryPaperPDFDownloadWithAIBrowser(for: articleId) }
                    }
                }

                if failure.suggestsManualAttachment {
                    Button {
                        attachPDFFile()
                    } label: {
                        if isAttachingPDF {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Opening…")
                            }
                        } else {
                            Text("Attach PDF File…")
                        }
                    }
                    .disabled(isAttachingPDF)
                }

                Button("Retry", action: retry)
                    .buttonStyle(.hoverWash(tint: Color(nsColor: .linkColor)))
                    .hoverHighlight()
            }
        }
    }

    private func attachPDFFile() {
        guard !isAttachingPDF else { return }
        isAttachingPDF = true
        Task {
            defer { isAttachingPDF = false }
            let urls = await FilePanel.open { panel in
                panel.allowedContentTypes = [.pdf]
                panel.message = "Select the PDF for this source"
            }
            guard let fileURL = urls.first else { return }
            do {
                try await vm.attachPDF(to: articleId, pdfURL: fileURL)
            } catch {
                vm.showToast("Could not attach PDF: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Reader Loading View

/// Polished loading state for the reader pane. Shows a shimmering document
/// skeleton with a contextual title/subtitle instead of a bare spinner, so a
/// source that is still fetching reads as "a page is on its way" rather than
/// an empty pane with a spinner floating in it.
struct ReaderLoadingView: View {
    var title: String
    var subtitle: String? = nil

    @State private var animating = false

    var body: some View {
        VStack(spacing: 24) {
            DocumentSkeletonView(animating: animating)
                .frame(width: 240, height: 196)
            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .onAppear { animating = true }
    }
}

private struct DocumentSkeletonView: View {
    let animating: Bool
    private let lineWidths: [CGFloat] = [0.9, 0.75, 0.82, 0.5, 0.88, 0.7, 0.6]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .frame(width: 104, height: 13)
                .padding(.bottom, 18)
            VStack(alignment: .leading, spacing: 11) {
                ForEach(lineWidths.indices, id: \.self) { index in
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .frame(width: geo.size.width * lineWidths[index], height: 9)
                    }
                    .frame(height: 9)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.tertiary)
        .opacity(0.55)
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .overlay(shimmer)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 14, y: 6)
    }

    private var shimmer: some View {
        GeometryReader { geo in
            let width = geo.size.width
            LinearGradient(
                colors: [.clear, .white.opacity(0.5), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: width * 0.55)
            .offset(x: animating ? width * 1.2 : -width * 0.7)
            .animation(.linear(duration: 1.5).repeatForever(autoreverses: false), value: animating)
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Inline PDF Reader

/// A source's pages within a document assembled from more than one source.
struct PDFDocumentSection: Equatable {
    let sourceID: String
    let pageRange: Range<Int>
}

/// A request to scroll a PDF view to a page; a new token is a new request.
struct PDFPageJump: Equatable {
    let pageIndex: Int
    let token: Int
}

/// A PDF-imported book, read as one document.
///
/// A PDF book is one file and each chapter a run of its pages, so the reader
/// shows that file (`BookPDFAssembly`): the whole book scrolls and searches as
/// one and the Contents menu is a list of places to jump to, rather than a
/// list of documents to swap in. A book an older build split into chapter
/// files, until it is merged, has its chapters copied end to end instead.
/// Chapters stay the unit everything is stored in — the resume page, the depth
/// reached, every highlight — so each page the view reports is translated back
/// through the book's page map before it leaves this view.
struct PDFBookReaderView: View {
    @Environment(StudioViewModel.self) private var vm
    let initialArticle: StudioArticle
    let chapterArticles: [StudioArticle]
    @Binding var selectedText: String
    let findState: ReaderFindState
    let findRevision: Int
    let zoomScale: CGFloat
    var bookNavigationBridge: ReaderBookNavigationBridge?
    /// The chapter on screen changed, so the panel's selection can follow.
    let chapterChanged: (StudioArticle) -> Void
    /// A page was reached, in the chapter's own numbering and page count.
    let pageChanged: (StudioArticle, Int, Int) -> Void
    let zoomScaleChanged: (CGFloat) -> Void
    let zoomInAction: () -> Void
    let zoomOutAction: () -> Void
    let resetZoomAction: () -> Void

    /// The chapter whose pages are on screen.
    @State private var currentArticle: StudioArticle
    @State private var assembly: BookPDFAssembly?
    @State private var loadPhase: LoadPhase = .loading
    @State private var loadRevision = 0
    /// The page of the book the reader opened on, for the view's first layout.
    @State private var initialBookPage: Int?
    @State private var currentBookPage: Int?
    @State private var pageJump: PDFPageJump?
    /// The pages the learner turned, applied to the assembled document and
    /// remembered per source (`PDFPageRotationController`).
    @State private var pageTurns: PDFPageRotationController?
    /// The page on screen, for the pill at the foot of the view.
    @State private var pageIndicator = ReaderPageIndicator()
    /// Each chapter's sections, for the Contents menu; found after the book
    /// opens, since reading every page's fonts takes a few seconds.
    @State private var chapterSections: [String: [BookChapterSection]] = [:]
    /// Chapters this view told the panel about that the panel has yet to echo
    /// back through `initialArticle`. Those echoes are not navigation.
    @State private var reportedChapterIDs: Set<String> = []

    private enum LoadPhase {
        case loading
        case downloading
        case failed(LocalPDFLoadFailure)
    }

    private struct ChapterFile {
        let article: StudioArticle
        let path: String
        var url: URL { URL(fileURLWithPath: path) }
        /// The chapter's pages of the file; nil when the file is the chapter.
        var pages: Range<Int>? { article.bookPages }
    }

    init(
        initialArticle: StudioArticle,
        chapterArticles: [StudioArticle],
        selectedText: Binding<String>,
        findState: ReaderFindState,
        findRevision: Int,
        zoomScale: CGFloat,
        bookNavigationBridge: ReaderBookNavigationBridge? = nil,
        chapterChanged: @escaping (StudioArticle) -> Void = { _ in },
        pageChanged: @escaping (StudioArticle, Int, Int) -> Void,
        zoomScaleChanged: @escaping (CGFloat) -> Void,
        zoomInAction: @escaping () -> Void,
        zoomOutAction: @escaping () -> Void,
        resetZoomAction: @escaping () -> Void
    ) {
        self.initialArticle = initialArticle
        self.chapterArticles = chapterArticles
        self._selectedText = selectedText
        self.findState = findState
        self.findRevision = findRevision
        self.zoomScale = zoomScale
        self.bookNavigationBridge = bookNavigationBridge
        self.chapterChanged = chapterChanged
        self.pageChanged = pageChanged
        self.zoomScaleChanged = zoomScaleChanged
        self.zoomInAction = zoomInAction
        self.zoomOutAction = zoomOutAction
        self.resetZoomAction = resetZoomAction
        self._currentArticle = State(initialValue: initialArticle)
    }

    var body: some View {
        Group {
            if let assembly {
                PDFKitInlineView(
                    document: assembly.document,
                    sourceID: currentArticle.id,
                    selectedText: $selectedText,
                    findState: findState,
                    findRevision: findRevision,
                    zoomScale: zoomScale,
                    initialPageIndex: initialBookPage,
                    pageChanged: { page, _ in bookPageChanged(to: page, in: assembly.map) },
                    zoomScaleChanged: zoomScaleChanged,
                    zoomInAction: zoomInAction,
                    zoomOutAction: zoomOutAction,
                    resetZoomAction: resetZoomAction,
                    sections: assembly.map.sections,
                    pageJump: pageJump,
                    chapterFiles: assembly.map.chapters,
                    pageTurns: pageTurns,
                    pageViewed: { page in pageIndicator.current = page },
                    pointerNearFootChanged: { near in pageIndicator.pointerNearFoot = near }
                )
                .overlay(alignment: .bottom) {
                    ReaderPagePill(
                        indicator: pageIndicator,
                        pageCount: assembly.map.pageCount,
                        goToPage: goToPage(_:)
                    )
                }
            } else {
                switch loadPhase {
                case .loading:
                    ReaderLoadingView(title: isBook ? "Loading book…" : "Loading PDF…")
                case .downloading:
                    ReaderLoadingView(title: "Downloading from iCloud…")
                case .failed(let failure):
                    ContentUnavailableView {
                        Label(failure.title, systemImage: failure.symbol)
                    } description: {
                        if let message = failure.message {
                            Text(message)
                        }
                    } actions: {
                        Button("Retry") { loadRevision += 1 }
                    }
                }
            }
        }
        .onChange(of: initialArticle.id) { _, _ in
            externalSelectionChanged()
        }
        .onAppear {
            syncBookNavigationBridge()
        }
        .onDisappear {
            bookNavigationBridge?.clear()
        }
        .task(id: "\(bookKey)#\(loadRevision)") {
            await loadBook()
        }
    }

    /// Stable per-book key, so the book is assembled once when it opens and
    /// not again as the selection moves between its chapters.
    private var bookKey: String {
        initialArticle.parentGroup ?? initialArticle.id
    }

    /// Every local PDF opens through this view, so a lone paper is "a book" of
    /// one chapter here. Its loading label should not call it one.
    private var isBook: Bool {
        initialArticle.parentGroup != nil || chapterArticles.count > 1
    }

    // MARK: Loading

    @MainActor
    private func loadBook() async {
        assembly = nil
        pageTurns = nil
        chapterSections = [:]
        loadPhase = .loading
        bookNavigationBridge?.clear()

        // Resolving chapter paths stats the filesystem once per chapter, and
        // `.task` inherits the view's main actor, so the resolution runs off-main
        // over raw path strings (`StudioArticle` is not Sendable).
        let candidates = chapterArticles.isEmpty ? [initialArticle] : chapterArticles
        let rawPaths = candidates.flatMap { article -> [String] in
            var paths = [article.url]
            if let localFilePath = article.localFilePath { paths.append(localFilePath) }
            return paths
        }
        _ = await Task.detached(priority: .userInitiated) {
            StudioArticle.warmResolvedLocalPathCache(forRawPaths: rawPaths)
        }.value
        guard !Task.isCancelled else { return }

        var chapters = candidates.compactMap { article in
            article.cachedResolvedPDFPath.map { ChapterFile(article: article, path: $0) }
        }
        if chapters.isEmpty, let path = initialArticle.cachedResolvedPDFPath {
            chapters = [ChapterFile(article: initialArticle, path: path)]
        }
        guard !chapters.isEmpty else {
            loadPhase = .failed(.unreadable)
            return
        }

        // An evicted iCloud chapter read through PDFDocument would block for
        // many seconds on a silent on-demand fault-in. Find those up front,
        // show a real "downloading" state, and pull the bytes down through the
        // proper iCloud API instead.
        var evicted: [URL] = []
        for url in Set(chapters.map(\.url)) where !(await AsyncPDFDocumentLoader.isLocallyAvailable(url: url)) {
            evicted.append(url)
        }
        guard !Task.isCancelled else { return }
        var downloadFailures: [URL: ICloudDownload.Failure] = [:]
        if !evicted.isEmpty {
            loadPhase = .downloading
            downloadFailures = await withTaskGroup(of: (URL, ICloudDownload.Failure?).self) { group in
                for url in evicted {
                    group.addTask {
                        if case .failure(let failure) = await AsyncPDFDocumentLoader.ensureDownloaded(url: url) {
                            return (url, failure)
                        }
                        return (url, nil)
                    }
                }
                var failures: [URL: ICloudDownload.Failure] = [:]
                for await (url, failure) in group {
                    if let failure { failures[url] = failure }
                }
                return failures
            }
            guard !Task.isCancelled else { return }
        }
        // The chapter being opened has to be there; another chapter that could
        // not be fetched is left out of the book rather than blocking it.
        if let opening = chapters.first(where: { $0.article.id == currentArticle.id }),
           let failure = downloadFailures[opening.url] {
            loadPhase = .failed(.iCloud(failure))
            return
        }

        // A book kept as one file is shown as that file, opened here rather than
        // taken from the loader's cache, since the view paints its notes onto it.
        let isOneFile = chapters.allSatisfy { $0.pages != nil } && Set(chapters.map(\.path)).count == 1
        var documents: [String: PDFDocument] = [:]
        var inputs: [BookPDFAssembly.Input] = []
        for chapter in chapters where downloadFailures[chapter.url] == nil {
            var document = documents[chapter.path]
            if document == nil {
                let url = chapter.url
                document = isOneFile
                    ? await Task.detached(priority: .userInitiated) { PDFDocument(url: url) }.value
                    : await AsyncPDFDocumentLoader.load(url: url)
                documents[chapter.path] = document
            }
            guard let document else { continue }
            guard !Task.isCancelled else { return }
            inputs.append(BookPDFAssembly.Input(
                sourceID: chapter.article.id,
                title: chapter.article.title,
                path: chapter.path,
                document: document,
                pages: chapter.pages
            ))
        }
        let assembled = await Task.detached(priority: .userInitiated) {
            BookPDFAssembly.assemble(inputs)
        }.value
        guard !Task.isCancelled else { return }
        guard let assembled else {
            loadPhase = .failed(.unreadable)
            return
        }

        let opening = resumeArticle(for: currentArticle.id)
        let resume = assembled.map.page(forSourceID: opening.id, chapterPage: opening.readingPositionPage)
        initialBookPage = resume
        currentBookPage = resume ?? 0
        pageIndicator.current = resume ?? 0
        // The learner's turned pages go onto the document before the view
        // first lays it out.
        pageTurns = PDFPageRotationController(
            document: assembled.document,
            runs: assembled.map.chapters.map {
                PDFPageRotationOwner.Run(sourceID: $0.sourceID, firstPage: $0.pageRange.lowerBound)
            }
        )
        assembly = assembled
        syncBookNavigationBridge()
        assembled.warmPageText()
        // Notes from every chapter paint onto the one document.
        for chapter in assembled.map.chapters {
            await vm.loadReaderHighlightsIfNeeded(for: chapter.sourceID)
        }
        // Sections are read from the chapter files or the book's outline, not
        // a copy, so a split book's run beside the text warm-up rather than on
        // the same pages.
        let indexing = Task.detached(priority: .utility) { [inputs] in
            BookSectionIndex.sections(for: inputs)
        }
        let sections = await withTaskCancellationHandler {
            await indexing.value
        } onCancel: {
            indexing.cancel()
        }
        guard !Task.isCancelled else { return }
        chapterSections = sections
        syncBookNavigationBridge()
    }

    /// The chapter as the panel knows it, with its current reading progress.
    private func resumeArticle(for sourceID: String) -> StudioArticle {
        chapterArticles.first { $0.id == sourceID }
            ?? (initialArticle.id == sourceID ? initialArticle : currentArticle)
    }

    // MARK: Position

    /// The view reached a page of the book. Reported onward in the chapter's
    /// own numbering; a page in a different chapter also moves the selection.
    private func bookPageChanged(to page: Int, in map: BookPageMap) {
        currentBookPage = page
        guard let position = map.position(ofPage: page) else { return }
        let chapter = resumeArticle(for: position.chapter.sourceID)
        pageChanged(chapter, position.pageInChapter, position.chapter.pageCount)
        if chapter.id != currentArticle.id {
            currentArticle = chapter
            reportChapter(chapter)
        }
        syncBookNavigationBridge()
    }

    private func reportChapter(_ chapter: StudioArticle) {
        reportedChapterIDs.insert(chapter.id)
        chapterChanged(chapter)
    }

    /// `initialArticle` moved: either the panel echoing a chapter this view
    /// reported, which changes nothing on screen, or a chapter chosen outside
    /// the reader — the sidebar, a schedule, Back — which the book scrolls to,
    /// at that chapter's saved page.
    private func externalSelectionChanged() {
        let wasReported = reportedChapterIDs.contains(initialArticle.id)
        // Whichever chapter comes back, every earlier report is superseded.
        reportedChapterIDs.removeAll()
        guard !wasReported, initialArticle.id != currentArticle.id else { return }
        currentArticle = initialArticle
        selectedText = ""
        guard let map = assembly?.map else { return }
        let opening = resumeArticle(for: initialArticle.id)
        guard let page = map.page(forSourceID: opening.id, chapterPage: opening.readingPositionPage) else { return }
        jump(to: page)
        syncBookNavigationBridge()
    }

    /// The Contents menu and the chapter chevrons: a chapter's first page.
    private func navigate(to item: BookNavigationItem) {
        guard let map = assembly?.map, let chapter = map.chapter(forSourceID: item.id) else { return }
        jump(to: chapter.pageRange.lowerBound)
        selectedText = ""
        let article = resumeArticle(for: chapter.sourceID)
        if article.id != currentArticle.id {
            currentArticle = article
            reportChapter(article)
        }
        syncBookNavigationBridge()
    }

    private func jump(to page: Int) {
        currentBookPage = page
        pageJump = PDFPageJump(pageIndex: page, token: (pageJump?.token ?? 0) + 1)
    }

    private func syncBookNavigationBridge() {
        guard let map = assembly?.map else {
            bookNavigationBridge?.clear()
            return
        }
        // Contents is a list of chapters, so a one-chapter book has none; the
        // page position and Go to Page stand whatever the chapter count.
        bookNavigationBridge?.update(
            navigation: map.navigation(currentPage: currentBookPage, sections: chapterSections),
            navigate: navigate(to:)
        )
        bookNavigationBridge?.update(
            pageNavigation: ReaderPageNavigation(
                currentPage: min(max(currentBookPage ?? 0, 0), max(map.pageCount - 1, 0)),
                pageCount: map.pageCount
            ),
            goToPage: goToPage(_:)
        )
        bookNavigationBridge?.update(turnPage: pageTurns.map { turner in { turner.turnCurrentPage(by: $0) } })
    }

    /// Go to Page: a page of the book by its own numbering. The chapter the
    /// page belongs to follows once the view reports landing there.
    private func goToPage(_ page: Int) {
        guard let map = assembly?.map, page >= 0, page < map.pageCount else { return }
        jump(to: page)
        selectedText = ""
        syncBookNavigationBridge()
    }
}

private enum LocalPDFLoadFailure {
    case unreadable
    case iCloud(ICloudDownload.Failure)

    var title: String {
        switch self {
        case .unreadable:
            "Could not load PDF"
        case .iCloud(.insufficientStorage):
            "Not enough storage"
        case .iCloud(.timedOut):
            "iCloud download timed out"
        case .iCloud(.requestFailed):
            "Could not download from iCloud"
        }
    }

    var message: String? {
        switch self {
        case .unreadable, .iCloud(.timedOut):
            nil
        case .iCloud(.insufficientStorage):
            "Free some space on this Mac, then retry."
        case .iCloud(.requestFailed(let message)):
            message
        }
    }

    var symbol: String {
        switch self {
        case .unreadable:
            "doc.text.fill"
        case .iCloud:
            "icloud.slash"
        }
    }
}

enum AsyncPDFDocumentLoader {
    private final class CacheEntry: NSObject {
        let document: PDFDocument

        init(document: PDFDocument) {
            self.document = document
        }
    }

    private nonisolated(unsafe) static let documentCache: NSCache<NSString, CacheEntry> = {
        let cache = NSCache<NSString, CacheEntry>()
        cache.countLimit = 6
        cache.totalCostLimit = 600
        return cache
    }()

    static func load(url: URL) async -> PDFDocument? {
        let key = await cacheKey(for: url)
        if let cached = documentCache.object(forKey: key)?.document {
            return cached
        }

        return await Task.detached(priority: .userInitiated) {
            PDFDocument(url: url)
        }.value.map { document in
            documentCache.setObject(
                CacheEntry(document: document),
                forKey: key,
                cost: max(1, document.pageCount)
            )
            return document
        }
    }

    static func load(data: Data) async -> PDFDocument? {
        await Task.detached(priority: .userInitiated) {
            PDFDocument(data: data)
        }.value
    }

    static func preload(urls: [URL]) async {
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask {
                    if !(await isLocallyAvailable(url: url)) {
                        guard case .success = await ensureDownloaded(url: url) else { return }
                    }
                    _ = await load(url: url)
                }
            }
        }
    }

    private static func cacheKey(for url: URL) async -> NSString {
        let key = await Task.detached(priority: .utility) {
            let path = url.standardizedFileURL.path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let modifiedAt = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return "\(path)#\(modifiedAt)#\(size)"
        }.value
        return key as NSString
    }

    /// Whether the file's bytes are present on this device. Regular (non-iCloud)
    /// files always count as available; iCloud files only count once they've
    /// been materialized locally (not an evicted dataless placeholder).
    static func isLocallyAvailable(url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            ICloudDownload.isLocallyAvailable(url)
        }.value
    }

    /// Materialize an evicted iCloud file, waiting until its bytes are local.
    /// Returns a concrete failure instead of leaving the reader in an
    /// open-ended loading state.
    static func ensureDownloaded(url: URL) async -> Result<Void, ICloudDownload.Failure> {
        await ICloudDownload.ensureDownloaded(url: url)
    }
}

/// Shared iCloud download helpers for reader documents. Modern iCloud eviction
/// leaves a "dataless" file: the path still exists and reports its logical size,
/// but `st_blocks == 0` and reading it triggers a slow on-demand fault-in. The
/// legacy `.<name>.icloud` sidecar stub is not created in that case, so download
/// state must be read from the file's ubiquitous resource values instead.
enum ICloudDownload {
    enum Failure: Error, Sendable, Equatable {
        case insufficientStorage
        case timedOut
        case requestFailed(String)
    }

    // A large PDF can legitimately take longer than ten seconds to materialize.
    // Keep the reader in its honest loading state while File Provider works,
    // rather than turning normal contention into a terminal error.
    private static let foregroundWaitLimit: Duration = .seconds(120)
    private static let requestRetryDelays: [Duration] = [.zero, .seconds(1), .seconds(3)]
    private static let minimumDownloadHeadroom: Int64 = 2 * 1_024 * 1_024 * 1_024

    private enum LocalAvailability: Equatable {
        case available
        case unavailable
        case unknown
    }

    static func isLocallyAvailable(_ url: URL) -> Bool {
        localAvailability(url) == .available
    }

    private static func localAvailability(_ url: URL) -> LocalAvailability {
        // On current File Provider-backed iCloud containers, Foundation can
        // report `isUbiquitousItem == false` for an evicted file even though
        // its inode is explicitly marked dataless. Treating that as available
        // sends the placeholder straight to PDFKit: the read starts the
        // materialization, PDFKit returns nil first, and the reader gets stuck
        // on "Could not load PDF" even after the bytes arrive.
        if isDatalessFile(url) { return .unavailable }

        // URL caches resource values. Reusing the same value while CloudDocs
        // materializes a dataless file can otherwise keep returning the initial
        // `.notDownloaded` state after the bytes have arrived.
        var refreshedURL = url
        refreshedURL.removeAllCachedResourceValues()
        let values: URLResourceValues
        do {
            values = try refreshedURL.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
            ])
        } catch {
            return .unknown
        }
        guard values.isUbiquitousItem == true else { return .available }
        guard let status = values.ubiquitousItemDownloadingStatus else { return .unknown }
        // `.current` and `.downloaded` both mean the bytes are present locally.
        return status == .notDownloaded ? .unavailable : .available
    }

    private static func isDatalessFile(_ url: URL) -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        return isDatalessFileMetadata(
            size: metadata.st_size,
            blocks: metadata.st_blocks,
            flags: metadata.st_flags,
            path: url.path
        )
    }

    /// Kept separate from `lstat` so the File Provider edge cases are covered
    /// without needing to evict a real iCloud document in a unit test.
    static func isDatalessFileMetadata(
        size: Int64,
        blocks: Int64,
        flags: UInt32,
        path: String
    ) -> Bool {
        if flags & UInt32(SF_DATALESS) != 0 { return true }

        // Some File Provider versions expose the placeholder shape (logical
        // bytes but no allocated blocks) without SF_DATALESS. Limit that
        // fallback to cloud-managed roots so an intentional local sparse file
        // is not sent through the iCloud download API.
        let isCloudManagedPath = path.contains("/Library/Mobile Documents/")
            || path.contains("/Library/CloudStorage/")
        return isCloudManagedPath && size > 0 && blocks == 0
    }

    static func ensureDownloaded(url: URL) async -> Result<Void, Failure> {
        let task = Task.detached(priority: .userInitiated) { () -> Result<Void, Failure> in
            if isLocallyAvailable(url) { return .success(()) }
            // File Provider needs working room beyond the document's own size.
            // When the data volume is effectively full it may fail to launch its
            // per-domain service at all, yielding only a generic plug-in error.
            // Detect that condition before asking it to materialize anything.
            if availableCapacity(at: url).map({ $0 < minimumDownloadHeadroom }) == true {
                return .failure(.insufficientStorage)
            }

            // File Provider can reject an otherwise valid request while it is
            // under load (including the unhelpful "plug-in returned an error").
            // Such a rejection is not proof that materialization failed: the
            // provider may already be servicing the same file, or may accept a
            // retry a moment later. Treat request errors as provisional and only
            // surface one after bounded retries and the full materialization wait.
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: foregroundWaitLimit)
            var requestAttempt = 0
            var nextRequestAt = clock.now
            var lastRequestError: Error?

            while clock.now < deadline {
                if Task.isCancelled { return .failure(.timedOut) }
                if localAvailability(url) == .available { return .success(()) }

                let now = clock.now
                if requestAttempt < requestRetryDelays.count, now >= nextRequestAt {
                    do {
                        try FileManager.default.startDownloadingUbiquitousItem(at: url)
                        lastRequestError = nil
                        // A successful request is asynchronous. Do not keep
                        // resubmitting it while File Provider downloads the bytes.
                        requestAttempt = requestRetryDelays.count
                    } catch {
                        lastRequestError = error
                        requestAttempt += 1
                        if requestAttempt < requestRetryDelays.count {
                            nextRequestAt = now.advanced(by: requestRetryDelays[requestAttempt])
                        }
                    }
                    // The provider can materialize the file even when the request
                    // API races and reports an error, so always re-check state.
                    if localAvailability(url) == .available { return .success(()) }
                }

                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else { break }
                var backstop = min(.seconds(1), remaining)
                if requestAttempt < requestRetryDelays.count {
                    let untilRetry = clock.now.duration(to: nextRequestAt)
                    if untilRetry > .zero {
                        backstop = min(backstop, untilRetry)
                    }
                }
                await ICloudFileChangeMonitor.waitForChangeOrBackstop(at: url, timeout: backstop)
            }
            if localAvailability(url) == .available { return .success(()) }
            if let lastRequestError {
                return .failure(classifiedFailure(
                    for: lastRequestError,
                    availableCapacity: availableCapacity(at: url)
                ))
            }
            return .failure(.timedOut)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Preserve the useful cause hidden underneath File Provider's generic
    /// Cocoa error. macOS can omit the underlying POSIX error from the value
    /// returned to the app, so low real free space is a deliberate fallback.
    static func classifiedFailure(for error: Error, availableCapacity: Int64?) -> Failure {
        let nsError = error as NSError
        if containsNoSpaceError(nsError)
            || availableCapacity.map({ $0 < minimumDownloadHeadroom }) == true {
            return .insufficientStorage
        }
        return .requestFailed(nsError.localizedDescription)
    }

    private static func availableCapacity(at url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    private static func containsNoSpaceError(_ error: NSError) -> Bool {
        var pending = [error]
        var visited = Set<ObjectIdentifier>()

        while let candidate = pending.popLast() {
            guard visited.insert(ObjectIdentifier(candidate)).inserted else { continue }
            if candidate.domain == NSPOSIXErrorDomain, candidate.code == Int(ENOSPC) {
                return true
            }
            if let underlying = candidate.userInfo[NSUnderlyingErrorKey] as? NSError {
                pending.append(underlying)
            }
            for key in ["NSMultipleUnderlyingErrors", "NSDetailedErrors"] {
                if let errors = candidate.userInfo[key] as? [NSError] {
                    pending.append(contentsOf: errors)
                }
            }
        }
        return false
    }
}

/// Watches a File Provider item instead of repeatedly querying CloudDocs. The
/// one-second race keeps this robust on volumes that do not publish vnode
/// changes for dataless-file materialization.
final class ICloudFileChangeMonitor: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    private init?(url: URL) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        source.setEventHandler { [weak self] in
            self?.finish()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
    }

    static func waitForChangeOrBackstop(at url: URL, timeout: Duration) async {
        guard let monitor = ICloudFileChangeMonitor(url: url) else {
            try? await Task.sleep(for: timeout)
            return
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await monitor.waitForChange()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            _ = await group.next()
            group.cancelAll()
            monitor.finish()
        }
    }

    private func waitForChange() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if finished {
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            finish()
        }
    }

    private func finish() {
        let pendingContinuation: CheckedContinuation<Void, Never>?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        pendingContinuation = continuation
        continuation = nil
        lock.unlock()

        source.cancel()
        pendingContinuation?.resume()
    }

    deinit {
        finish()
    }
}

struct PDFKitInlineView: NSViewRepresentable {
    @Environment(StudioViewModel.self) private var vm
    let document: PDFDocument
    /// The source this document belongs to, so notes taken here are filed
    /// against the right chapter of a book rather than the book as a whole.
    let sourceID: String
    @Binding var selectedText: String
    let findState: ReaderFindState
    let findRevision: Int
    let zoomScale: CGFloat
    let initialPageIndex: Int?
    /// Page index the learner landed on, with the document's page count so the
    /// view model can turn "page 9 of 10" into a depth for the activity ledger.
    let pageChanged: (Int, Int) -> Void
    let zoomScaleChanged: (CGFloat) -> Void
    let zoomInAction: () -> Void
    let zoomOutAction: () -> Void
    let resetZoomAction: () -> Void
    /// The sources that make up the document, by page range, when it is a
    /// book assembled from chapter PDFs: notes are filed against, and painted
    /// from, the section a page belongs to. `nil` means the whole document is
    /// `sourceID`.
    var sections: [PDFDocumentSection]? = nil
    /// A page to scroll to, applied once per token.
    var pageJump: PDFPageJump? = nil
    /// The bytes of a document opened from memory rather than from a file,
    /// which the citation preview reads its own copy from.
    var documentData: Data? = nil
    /// The chapter files a document assembled from them was copied from, which
    /// the citation preview reads a page's links from instead.
    var chapterFiles: [BookPDFChapterRange] = []
    /// Turns single pages of the document and remembers which; nil where the
    /// document is not one a source's pages are kept for.
    var pageTurns: PDFPageRotationController? = nil
    /// The page on screen changed, the moment PDFKit says so: the page pill
    /// follows this, and the debounced `pageChanged` is what saves progress.
    var pageViewed: ((Int) -> Void)? = nil
    /// The pointer went to or left the foot of the view.
    var pointerNearFootChanged: ((Bool) -> Void)? = nil
    /// A PDF has no stylesheet to restyle, so Dark Mode inverts it. Read from
    /// the environment so an open paper repaints when the Mac switches rather
    /// than waiting for the next reopen.
    @Environment(\.colorScheme) private var colorScheme
    /// The reader's opt-out, for a paper whose figures are worth reading the way
    /// they were published.
    @SyncedStorage(ReaderDarkMode.originalPageColorsKey) private var originalPageColors = false
    @Environment(\.readerOpensCitedSource) private var opensCitedSource

    private var darkensPage: Bool {
        ReaderDarkMode.darkensPage(in: colorScheme, originalPageColors: originalPageColors)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = FindablePDFView()
        pdfView.findState = findState
        pdfView.zoomInAction = zoomInAction
        pdfView.zoomOutAction = zoomOutAction
        pdfView.resetZoomAction = resetZoomAction
        pdfView.cursorForAnnotation = Coordinator.cursorForAnnotation
        pdfView.pageTurner = pageTurns
        pdfView.pointerNearFootChanged = pointerNearFootChanged
        pageTurns?.pdfView = pdfView
        // Before the document, so every page PDFKit lays out asks for one.
        pdfView.pageOverlayViewProvider = context.coordinator.questionLayer
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        ReaderDarkMode.apply(darkensPage, to: pdfView)
        context.coordinator.applyInitialPageIfNeeded(in: pdfView)
        context.coordinator.callout.attach(toPDFView: pdfView)
        context.coordinator.referencePreview.attach(to: pdfView)
        configureReferencePreview(context.coordinator.referencePreview)
        context.coordinator.installNoteHandling(in: pdfView, vm: vm)
        context.coordinator.clipTool.attach(to: pdfView, vm: vm, host: context.coordinator.clipHost(for: pdfView))

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.selectionChanged(_:)),
            name: .PDFViewSelectionChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.annotationHit(_:)),
            name: .PDFViewAnnotationHit,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scaleChanged(_:)),
            name: .PDFViewScaleChanged,
            object: pdfView
        )

        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        context.coordinator.parent = self
        configureReferencePreview(context.coordinator.referencePreview)
        if let pdfView = nsView as? FindablePDFView {
            pdfView.findState = findState
            pdfView.zoomInAction = zoomInAction
            pdfView.zoomOutAction = zoomOutAction
            pdfView.resetZoomAction = resetZoomAction
            pdfView.pageTurner = pageTurns
            pdfView.pointerNearFootChanged = pointerNearFootChanged
            pageTurns?.pdfView = pdfView
        }
        if nsView.document !== document {
            nsView.document = document
            context.coordinator.resetInitialPage()
            context.coordinator.resetFindCache()
            context.coordinator.resetZoomTracking()
            context.coordinator.resetHighlightPainting()
            context.coordinator.walkthroughSpotlight.reset()
            context.coordinator.questionLayer.reset()
            context.coordinator.referencePreview.documentChanged()
            context.coordinator.clipTool.reset()
        }
        ReaderDarkMode.apply(darkensPage, to: nsView)
        context.coordinator.clipTool.update(host: context.coordinator.clipHost(for: nsView))
        context.coordinator.clipTool.viewChanged()
        context.coordinator.applyInitialPageIfNeeded(in: nsView)
        context.coordinator.applyPageJumpIfNeeded(in: nsView)
        context.coordinator.applyZoomIfNeeded(zoomScale, in: nsView)
        context.coordinator.performFindIfNeeded(in: nsView, revision: findRevision, state: findState)
        context.coordinator.repaintHighlightsIfNeeded(in: nsView, vm: vm)
        context.coordinator.applyPassageTargetIfNeeded(in: nsView, vm: vm)
        context.coordinator.applyWalkthroughFocusIfNeeded(in: nsView, vm: vm)
        context.coordinator.applyQuestionLayerIfNeeded(in: nsView, vm: vm)
    }

    /// A citation card opens its paper where this reader lives: a Source
    /// Reader window hands its own route down; the Studio's Reader moves to it.
    private func configureReferencePreview(_ preview: ReaderPDFReferencePreview) {
        preview.documentData = documentData
        preview.chapterFiles = chapterFiles
        preview.library = vm
        preview.configureHighlighting(viewModel: vm, sourceID: sourceID, sections: sections)
        preview.referenceForEntry = { [weak vm] entry in
            guard let vm, let sourceID = entry.sourceID else { return nil }
            return await vm.storedReference(number: entry.number, entryText: entry.text, inSource: sourceID)
        }
        preview.openSource = opensCitedSource ?? { [weak vm] sourceID in
            Task { await vm?.revealSourceInReader(sourceID) }
        }
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        coordinator.tearDownNoteHandling(in: nsView)
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewSelectionChanged, object: nsView)
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewAnnotationHit, object: nsView)
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewPageChanged, object: nsView)
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewScaleChanged, object: nsView)
        coordinator.callout.detach()
        coordinator.referencePreview.detach()
        coordinator.walkthroughSpotlight.clear()
        coordinator.questionLayer.detach()
        coordinator.clipTool.detach()
        coordinator.flushPendingPageChange()
    }

    class Coordinator: NSObject {
        var parent: PDFKitInlineView
        private var debounceWork: DispatchWorkItem?
        private var pageDebounceWork: DispatchWorkItem?
        private var lastPageIndex: Int?
        /// Retained beside the index so a flush on teardown can still report
        /// depth: by then the PDFView is gone and the document with it.
        private var lastPageCount: Int?
        private var didApplyInitialPage = false
        private var lastFindRevision = 0
        private var lastQuery = ""
        private var lastIndex = -1
        private var cachedMatches: [PDFSelection] = []
        private var lastRequestedZoomScale: CGFloat?
        private var lastObservedZoomScale: CGFloat?
        private var lastPageJumpToken: Int?
        private let programmaticSelection = ReaderProgrammaticSelection()
        /// The floating "Chat about this" / "Note" bar anchored to the PDF selection.
        let callout = ReaderSelectionCalloutOverlay()
        /// The selection as it stood when the callout appeared. Pressing Note
        /// can collapse the live selection, so the anchor is built from this
        /// rather than from whatever `currentSelection` is at click time.
        private var markedSelection: PDFSelection?
        /// What is currently painted, so a SwiftUI update that changed
        /// something else does not rebuild every annotation.
        private var paintedHighlightIDs: [String] = []
        private var paintedAnnotations: [PDFAnnotation] = []
        /// The document's own marks that painted highlights brought in from
        /// the file stand in for, off the page while those are painted.
        private var hiddenDocumentMarks: [(annotation: PDFAnnotation, page: PDFPage)] = []
        /// The source each painted highlight belongs to, for opening its note.
        private var paintedHighlightSources: [String: String] = [:]
        private weak var notePDFView: PDFView?
        private weak var noteViewModel: StudioViewModel?
        /// Which citation passage this reader has already flashed.
        private let passageTracker = ReaderPassageTargetTracker()
        /// The walkthrough's outline around the current step's figure or
        /// passage, kept while the step is current.
        let walkthroughSpotlight = ReaderWalkthroughSpotlight()
        /// The reading questions drawn on this PDF, from the mnemonic
        /// readings grounded on the sources it shows. One store per PDF view:
        /// two Readers on two papers each carry their own.
        let questionLayer = ReaderQuestionLayer()
        /// The Clip tool: a box round part of a page, dragged to the Canvas.
        let clipTool = ReaderClipTool()
        let questions = ReaderQuestionsModel()
        private var questionsRevision: UInt?
        private var questionsMemoryRevision: Int?
        /// What a citation link's reference entry says, under the pointer.
        let referencePreview = ReaderPDFReferencePreview()

        init(parent: PDFKitInlineView) {
            self.parent = parent
        }

        /// The walkthrough panel is on a step of a source this document shows:
        /// scroll to what the step points at and outline it. Nothing pending
        /// for any section takes the outline down.
        @MainActor
        func applyWalkthroughFocusIfNeeded(in pdfView: PDFView, vm: StudioViewModel) {
            guard let document = pdfView.document else { return }
            if let focus = vm.readerWalkthroughFocus {
                for section in sections(in: document) where section.sourceID == focus.sourceID {
                    walkthroughSpotlight.apply(focus, in: pdfView, pageRange: section.pageRange)
                    return
                }
            }
            walkthroughSpotlight.clear()
        }

        /// Draws the questions of the mnemonic readings grounded on the
        /// sources this document shows, at the passages they follow
        /// (`ReaderQuestionLayer`), reading them again when a reading changed
        /// or a card was answered elsewhere.
        @MainActor
        func applyQuestionLayerIfNeeded(in pdfView: PDFView, vm: StudioViewModel) {
            guard let document = pdfView.document else { return }
            let documentSections = sections(in: document)
            let sourceIDs = documentSections.map(\.sourceID)
            let storage = vm.storage
            let store = questions
            if questionsRevision != vm.readerQuestionsRevision {
                questionsRevision = vm.readerQuestionsRevision
                store.invalidate()
            }
            if questionsMemoryRevision != vm.memoryCardRevision {
                let first = questionsMemoryRevision == nil
                questionsMemoryRevision = vm.memoryCardRevision
                if !first { Task { @MainActor in await store.refreshMemory(storage: storage) } }
            }
            if store.needsLoad(for: sourceIDs) {
                Task { @MainActor in await store.load(sourceIDs: sourceIDs, storage: storage) }
            }
            questionLayer.apply(
                markers: store.markers(),
                visible: store.isVisible,
                sections: documentSections,
                in: pdfView,
                store: store,
                storage: storage
            )
        }

        @objc func selectionChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView else { return }
            debounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.programmaticSelection.isActive {
                    self.parent.selectedText = ""
                    self.markedSelection = nil
                    self.callout.hide()
                    return
                }
                let text = pdfView.currentSelection?.string ?? ""
                self.parent.selectedText = text
                self.markedSelection = text.isEmpty ? nil : pdfView.currentSelection
                self.callout.refresh()
            }
            debounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }

        // MARK: Notes

        @MainActor
        func installNoteHandling(in pdfView: PDFView, vm: StudioViewModel) {
            notePDFView = pdfView
            noteViewModel = vm
            noteOpenRequest = { [weak self, weak vm] highlightID, markOnScreen in
                guard let self, let vm else { return }
                vm.openReaderHighlight(
                    highlightID: highlightID,
                    sourceID: self.paintedHighlightSources[highlightID] ?? self.parent.sourceID,
                    markOnScreen: markOnScreen
                )
            }
            callout.onHighlight = { [weak self, weak pdfView, weak vm] in
                guard let self, let pdfView, let vm,
                      let document = pdfView.document,
                      let selection = self.markedSelection ?? pdfView.currentSelection,
                      let section = self.section(of: selection, in: document),
                      let anchors = ReaderPDFHighlightSupport.anchors(
                        for: selection,
                        in: document,
                        pageRange: section.pageRange
                      )
                else { return }
                // Where the passage is, read before the selection standing in
                // for it is cleared: the card hangs below it.
                let markOnScreen = self.callout.selectionOnScreen()
                self.callout.hide()
                // The mark is what the reader should see once it lands, not the
                // selection that stood in for it; the anchors are already made.
                pdfView.clearSelection()
                Task { await vm.highlightReaderSelection(
                    sourceID: section.sourceID,
                    quote: selection.string ?? "",
                    anchor: anchors.text,
                    pdfAnchor: anchors.pdf,
                    markOnScreen: markOnScreen
                ) }
            }
            // The side chat hangs off the passage, which stays selected, as
            // Chat leaves it.
            callout.onSideChat = { [weak self, weak pdfView, weak vm] in
                guard let self, let pdfView, let vm,
                      let document = pdfView.document,
                      let selection = self.markedSelection ?? pdfView.currentSelection,
                      let section = self.section(of: selection, in: document)
                else { return }
                let markOnScreen = self.callout.selectionOnScreen()
                self.callout.hide()
                vm.openReaderSideChat(
                    sourceID: section.sourceID,
                    passage: selection.string ?? "",
                    markOnScreen: markOnScreen,
                    windowNumber: pdfView.window?.windowNumber
                )
            }

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(revealHighlight(_:)),
                name: .revealReaderHighlight,
                object: nil
            )
        }

        @MainActor
        func tearDownNoteHandling(in pdfView: PDFView) {
            callout.onHighlight = nil
            callout.onSideChat = nil
            NotificationCenter.default.removeObserver(
                self,
                name: .revealReaderHighlight,
                object: nil
            )
            notePDFView = nil
            noteViewModel = nil
            ReaderPDFHighlightSupport.remove(paintedAnnotations)
            paintedAnnotations = []
            ReaderPDFHighlightSupport.restoreDocumentMarks(hiddenDocumentMarks)
            hiddenDocumentMarks = []
        }

        @MainActor
        @objc private func revealHighlight(_ notification: Notification) {
            guard let pdfView = notePDFView,
                  let vm = noteViewModel,
                  let document = pdfView.document,
                  let request = notification.object as? ReaderHighlightRevealRequest,
                  let section = sections(in: document).first(where: { $0.sourceID == request.sourceID }),
                  let highlight = vm.highlight(
                    id: request.highlightID,
                    sourceID: request.sourceID
                  ) else { return }
            ReaderPDFHighlightSupport.reveal(highlight, in: pdfView, pageRange: section.pageRange)
        }

        /// Clicking the walkthrough's outline shows the outlined figure or
        /// panel enlarged; clicking a painted highlight opens its note.
        @MainActor
        @objc func annotationHit(_ notification: Notification) {
            guard let annotation = notification.userInfo?["PDFAnnotationHit"] as? PDFAnnotation else { return }
            if let pick = ReaderWalkthroughSpotlight.pickedPanel(annotation) {
                noteViewModel?.readerPanelPickHandler?(pick.sourceID, pick.panel)
                return
            }
            if let figure = walkthroughSpotlight.figure(outlinedBy: annotation) {
                enlargeWalkthroughFigure(figure, in: notification.object as? PDFView)
                return
            }
            guard let highlightID = ReaderPDFHighlightSupport.highlightID(for: annotation) else { return }
            noteOpenRequest?(highlightID, markFrameOnScreen(highlightID: highlightID, near: annotation))
        }

        /// The painted mark's frame on screen: every annotation of the same
        /// highlight on the clicked page, together — a mark that wraps lines
        /// is one annotation per line, and its card belongs below the last.
        @MainActor
        private func markFrameOnScreen(highlightID: String, near annotation: PDFAnnotation) -> CGRect? {
            guard let pdfView = notePDFView, let page = annotation.page else { return nil }
            let bounds = page.annotations
                .filter { ReaderPDFHighlightSupport.highlightID(for: $0) == highlightID }
                .map(\.bounds)
                .reduce(annotation.bounds) { $0.union($1) }
            return pdfView.screenFrame(of: pdfView.convert(bounds, from: page))
        }

        /// The pointer over a mark that a click opens: the walkthrough's
        /// outline enlarges its figure, a saved highlight opens its note. Nil
        /// for the document's own annotations, which do nothing here.
        @MainActor
        static func cursorForAnnotation(_ annotation: PDFAnnotation) -> NSCursor? {
            if ReaderWalkthroughSpotlight.isOutline(annotation) { return ReaderWalkthroughSpotlight.outlineCursor }
            if ReaderWalkthroughSpotlight.pickedPanel(annotation) != nil { return .pointingHand }
            if ReaderPDFHighlightSupport.highlightID(for: annotation) != nil { return .pointingHand }
            return nil
        }

        /// The outlined figure in the lightbox a chat picture opens in, over
        /// the Reader's window, titled by the figure's printed title (product owner,
        /// 2026-09-20: "click this highlighted panel and then make it show up
        /// bigger, so that I can really focus on that"). The chat beside the
        /// Reader shows no lens while the page has the figure, so the outline
        /// is where enlarging lives. Rendered off the main actor.
        @MainActor
        private func enlargeWalkthroughFigure(_ figure: ReaderWalkthroughSpotlight.PaintedFigure, in pdfView: PDFView?) {
            guard let pdfView, let document = pdfView.document else { return }
            let window = pdfView.window
            let spotlight = walkthroughSpotlight
            let title = PaperFigureCaptionTitle.title(from: figure.caption)
            // Sized to the screen the lightbox will fill, so the picture is as
            // sharp as the page beside it (the lightbox draws a pixel a point).
            let pixelSize = ReaderWalkthroughSpotlight.lightboxLensPixelSize(for: window?.screen)
            Task { @MainActor in
                guard let data = await spotlight.lens(for: figure, in: document, pixelSize: pixelSize) else { return }
                ChatImageLightbox.present(
                    ChatSourceImage(data: data, mediaType: "image/png"),
                    title: title,
                    over: window
                )
            }
        }

        /// Set by `installNoteHandling` so the annotation-hit callback can reach
        /// the view model without the coordinator retaining it.
        private var noteOpenRequest: ((_ highlightID: String, _ markOnScreen: CGRect?) -> Void)?

        @MainActor
        func repaintHighlightsIfNeeded(in pdfView: PDFView, vm: StudioViewModel) {
            guard let document = pdfView.document else { return }
            let documentSections = sections(in: document)
            let highlightsBySection = documentSections.map { vm.highlights(for: $0.sourceID) }
            // Colour and note text ride in the annotation, so the fingerprint
            // has to change when either does — an ID list alone would leave a
            // recoloured note painted in its old colour.
            let fingerprint = zip(documentSections, highlightsBySection).flatMap { section, highlights in
                highlights.map {
                    "\(section.sourceID)|\($0.id)|\($0.color.rawValue)|\($0.updatedAt.timeIntervalSince1970)"
                }
            }
            guard fingerprint != paintedHighlightIDs else { return }
            paintedHighlightIDs = fingerprint
            ReaderPDFHighlightSupport.remove(paintedAnnotations)
            paintedAnnotations = []
            ReaderPDFHighlightSupport.restoreDocumentMarks(hiddenDocumentMarks)
            hiddenDocumentMarks = []
            paintedHighlightSources = [:]
            for (section, highlights) in zip(documentSections, highlightsBySection) {
                paintedAnnotations += ReaderPDFHighlightSupport.paint(
                    highlights,
                    into: document,
                    pageRange: section.pageRange
                )
                for highlight in highlights {
                    paintedHighlightSources[highlight.id] = section.sourceID
                }
            }
            // Only pages that carry a painted mark are looked at, so a PDF
            // with no highlights costs nothing here.
            let notes = Set(highlightsBySection.joined().compactMap { highlight -> String? in
                let words = ReaderTextAnchor.normalize(highlight.note).text
                return words.isEmpty ? nil : words
            })
            hiddenDocumentMarks = ReaderPDFHighlightSupport.hideDocumentMarks(
                coveredBy: paintedAnnotations,
                notes: notes
            )
        }

        /// A chat citation asked for a passage of a source this document shows:
        /// scroll to it within that source's pages and flash it. Book chapters
        /// are sections of one document, so the request is matched against
        /// every section's source rather than the document's alone. A citation
        /// that also names a page (`?page=7`, counted within the source) opens
        /// that page when the passage is not found on the source's pages — the
        /// excerpt straddled a page, or the reply cited a page and no words.
        @MainActor
        func applyPassageTargetIfNeeded(in pdfView: PDFView, vm: StudioViewModel) {
            guard let document = pdfView.document else { return }
            for section in sections(in: document) {
                guard let target = passageTracker.pending(for: section.sourceID, in: vm) else { continue }
                passageTracker.finish(target, in: vm)
                ReaderPassageFlash.whenLaidOut(pdfView) { pdfView in
                    let found = target.passage.map {
                        ReaderPassageFlash.flash($0, in: pdfView, pageRange: section.pageRange)
                    } ?? false
                    guard !found, let page = target.page,
                          let document = pdfView.document else { return }
                    let index = section.pageRange.lowerBound + page - 1
                    guard section.pageRange.contains(index), index < document.pageCount,
                          let pdfPage = document.page(at: index) else { return }
                    pdfView.go(to: pdfPage)
                }
                return
            }
        }

        /// The document's sections: the chapters of a book, or the one source
        /// the whole document is.
        private func sections(in document: PDFDocument) -> [PDFDocumentSection] {
            parent.sections ?? [PDFDocumentSection(sourceID: parent.sourceID, pageRange: 0..<document.pageCount)]
        }

        /// What the Clip tool asks of this reader: the chapter a page belongs
        /// to and the page's place in that chapter's own PDF, as highlights
        /// are filed.
        func clipHost(for pdfView: PDFView) -> ReaderClipTool.Host {
            ReaderClipTool.Host(
                sourcePage: { [weak self, weak pdfView] page in
                    guard let self, let document = pdfView?.document else { return nil }
                    let index = document.index(for: page)
                    guard index >= 0, let section = self.sections(in: document).first(where: { $0.pageRange.contains(index) }) else { return nil }
                    return (section.sourceID, index - section.pageRange.lowerBound)
                },
                sourceIDs: { [weak self, weak pdfView] in
                    guard let self, let document = pdfView?.document else { return [] }
                    return self.sections(in: document).map(\.sourceID)
                }
            )
        }

        /// The section a selection was made in, by the page it starts on.
        private func section(of selection: PDFSelection, in document: PDFDocument) -> PDFDocumentSection? {
            guard let page = selection.pages.first else { return nil }
            let index = document.index(for: page)
            return sections(in: document).first { $0.pageRange.contains(index) }
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let document = pdfView.document,
                  let page = pdfView.currentPage else { return }
            let index = document.index(for: page)
            guard index >= 0, lastPageIndex != index else { return }
            lastPageIndex = index
            let pageCount = document.pageCount
            lastPageCount = pageCount
            parent.pageViewed?(index)
            pageDebounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.lastPageIndex == index else { return }
                self.parent.pageChanged(index, pageCount)
            }
            pageDebounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }

        @MainActor
        @objc func scaleChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let normalized = normalizedZoomScale(in: pdfView),
                  ArticleReaderZoom.differs(normalized, lastObservedZoomScale ?? -1) else {
                return
            }
            lastObservedZoomScale = normalized
            callout.refreshIfVisible()
            lastRequestedZoomScale = normalized
            parent.zoomScaleChanged(normalized)
        }

        @MainActor
        func applyInitialPageIfNeeded(in pdfView: PDFView) {
            guard !didApplyInitialPage,
                  let initialPageIndex = parent.initialPageIndex,
                  initialPageIndex > 0,
                  let document = pdfView.document,
                  initialPageIndex < document.pageCount,
                  let page = document.page(at: initialPageIndex) else {
                didApplyInitialPage = true
                return
            }
            didApplyInitialPage = true
            lastPageIndex = initialPageIndex
            pdfView.go(to: page)
        }

        /// Scrolls to a requested page, once per request. A book's Contents
        /// menu and chapter chevrons jump this way, as does a chapter chosen
        /// outside the reader while the book is already open.
        @MainActor
        func applyPageJumpIfNeeded(in pdfView: PDFView) {
            guard let jump = parent.pageJump, jump.token != lastPageJumpToken else { return }
            lastPageJumpToken = jump.token
            guard let document = pdfView.document,
                  jump.pageIndex >= 0, jump.pageIndex < document.pageCount,
                  let page = document.page(at: jump.pageIndex) else { return }
            pdfView.go(to: page)
        }

        func resetInitialPage() {
            didApplyInitialPage = false
            lastPageIndex = nil
            lastPageCount = nil
        }

        func flushPendingPageChange() {
            pageDebounceWork?.cancel()
            if let lastPageIndex, let lastPageCount {
                parent.pageChanged(lastPageIndex, lastPageCount)
            }
        }

        @MainActor
        func performFindIfNeeded(in pdfView: PDFView, revision: Int, state: ReaderFindState) {
            guard revision > 0, revision != lastFindRevision else { return }
            lastFindRevision = revision
            debounceWork?.cancel()
            // Called inside the SwiftUI render pass — writing selectedText/statusText
            // here is "Modifying state during view update".
            Task { @MainActor [weak self, weak pdfView] in
                guard let self, let pdfView else { return }
                parent.selectedText = ""
                ReaderFindPerformer.performPDFFind(
                    in: pdfView,
                    state: state,
                    query: state.query,
                    backwards: state.searchesBackward,
                    lastQuery: &lastQuery,
                    lastIndex: &lastIndex,
                    cachedMatches: &cachedMatches,
                    programmaticSelection: programmaticSelection
                )
            }
        }

        /// A new document carries none of the previous one's annotations, so
        /// the next update must repaint from scratch.
        func resetHighlightPainting() {
            ReaderPDFHighlightSupport.remove(paintedAnnotations)
            paintedAnnotations = []
            paintedHighlightIDs = []
        }

        func resetFindCache() {
            lastQuery = ""
            lastIndex = -1
            cachedMatches = []
        }

        @MainActor
        func applyZoomIfNeeded(_ zoomScale: CGFloat, in pdfView: PDFView) {
            let clamped = ArticleReaderZoom.clamped(zoomScale)
            guard lastRequestedZoomScale.map({ ArticleReaderZoom.differs($0, clamped) }) ?? true else {
                return
            }
            lastRequestedZoomScale = clamped
            applyZoom(clamped, in: pdfView)
        }

        func resetZoomTracking() {
            lastRequestedZoomScale = nil
            lastObservedZoomScale = nil
        }

        @MainActor
        private func applyZoom(_ clamped: CGFloat, in pdfView: PDFView) {
            // A pinch zooms about the spot under the pointer.
            let pinchAnchor = ReaderPinchPDFAnchor(pdfView: pdfView)
            defer { pinchAnchor?.restore() }
            if clamped == ArticleReaderZoom.defaultScale {
                if !pdfView.autoScales {
                    pdfView.autoScales = true
                }
                return
            }
            let fitScale = pdfView.scaleFactorForSizeToFit
            guard fitScale > 0 else { return }
            let targetScale = fitScale * clamped
            guard pdfView.autoScales || ArticleReaderZoom.differs(pdfView.scaleFactor, targetScale) else { return }
            pdfView.autoScales = false
            pdfView.scaleFactor = targetScale
        }

        @MainActor
        private func normalizedZoomScale(in pdfView: PDFView) -> CGFloat? {
            if pdfView.autoScales {
                return ArticleReaderZoom.defaultScale
            }
            let fitScale = pdfView.scaleFactorForSizeToFit
            guard fitScale > 0 else { return nil }
            return ArticleReaderZoom.clamped(pdfView.scaleFactor / fitScale)
        }
    }
}

// MARK: - Inline Text Reader
