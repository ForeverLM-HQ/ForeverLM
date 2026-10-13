import SwiftUI
import Combine
import UniformTypeIdentifiers
import PDFKit
import WebKit
import AppKit

/// Renders a local book/document preview as a small thumbnail.
/// PDFs use the first page; EPUB chapter XHTML uses a local image or a WebKit snapshot.
struct BookCoverThumbnail: View {
    let pdfPath: String
    let size: CGSize
    let placeholderSystemImage: String
    let tint: Color

    init(
        pdfPath: String,
        size: CGSize = CGSize(width: 36, height: 48),
        placeholderSystemImage: String = "book.closed",
        tint: Color = .green
    ) {
        self.pdfPath = pdfPath
        self.size = size
        self.placeholderSystemImage = placeholderSystemImage
        self.tint = tint
        let resolvedPath = Self.resolvedCoverPath(pdfPath)
        let cacheKey = Self.cacheKey(for: resolvedPath, size: size)
        self._thumbnail = State(initialValue: ImageCache.shared.image(for: cacheKey))
    }

    @State private var thumbnail: NSImage?

    var body: some View {
        bookCoverContent
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .task(id: cacheKey) { await renderThumbnail() }
            .onReceive(NotificationCenter.default.publisher(for: .syncedArtworkDidInstall)) { _ in
                // A cover or meeting icon recovered from CloudKit lands at the
                // path it was published with, so `cacheKey` is unchanged and the
                // task above never re-runs — a row that rendered the placeholder
                // would keep it until the view was rebuilt. Only placeholders retry.
                guard thumbnail == nil else { return }
                Task { await renderThumbnail() }
            }
    }

    private var resolvedPath: String {
        Self.resolvedCoverPath(pdfPath)
    }

    private var cacheKey: String {
        Self.cacheKey(for: resolvedPath, size: size)
    }

    @ViewBuilder
    private var bookCoverContent: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: placeholderSystemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func renderThumbnail() async {
        let path = resolvedPath
        let key = cacheKey
        if thumbnail != nil, ImageCache.shared.image(for: key) == nil {
            thumbnail = nil
        }

        // Only check in-memory cache on main thread — no file I/O
        if let cached = ImageCache.shared.image(for: key) {
            thumbnail = cached
            return
        }

        let lower = path.lowercased()
        let isImage = lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
            || lower.hasSuffix(".png") || lower.hasSuffix(".gif")
        let isEPUBChapter = lower.hasSuffix(".htm") || lower.hasSuffix(".html") || lower.hasSuffix(".xhtml")

        let rendered: (image: NSImage?, resolvedPath: String?) = await Task.detached {
            // Check disk cache in background
            if let diskCached = ThumbnailDiskCache.shared.cachedImage(for: key) {
                ImageCache.shared.set(diskCached, for: key)
                return (diskCached, nil)
            }

            // Use the canonical source-file candidate list. Besides the current
            // and historical roots, it preserves the exact input path and adds
            // numbered iCloud conflict forks ("ForeverLM 2", etc.). Rebuilding
            // a partial candidate list here stranded every thumbnail whose PDF
            // `StudioArticle` had correctly resolved into one of those forks.
            // First existing/downloadable candidate wins.
            // A book chapter's thumbnail is its first page of the book's file.
            let location = SourcePDFPages(stored: path)
            let candidates = Self.candidatePaths(for: location.path)
            // A chapter of an EPUB book kept as one file is an entry of it (`EPUBBookFiles`).
            guard let filePath = candidates.first(where: { Self.ensureICloudFileAvailable(at: $0) || EPUBBookFiles.exists(atPath: $0) })
            else { return (nil, nil) }
            if isImage {
                return (NSImage(contentsOfFile: filePath), filePath)
            }
            if isEPUBChapter, let imagePath = EPUBParser.firstImagePath(inXHTMLAt: filePath) {
                return (EPUBBookFiles.contents(atPath: imagePath).flatMap(NSImage.init(data:)), filePath)
            }
            if isEPUBChapter {
                return (nil, filePath)
            }
            guard let doc = PDFDocument(url: URL(fileURLWithPath: filePath)),
                  let page = doc.page(at: location.pages?.lowerBound ?? 0) else { return (nil, filePath) }
            let bounds = page.bounds(for: .mediaBox)
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            let thumbnailSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            return (page.thumbnail(of: thumbnailSize, for: .mediaBox), filePath)
        }.value

        let image: NSImage?
        if let renderedImage = rendered.image {
            image = renderedImage
        } else if isEPUBChapter {
            image = await EPUBChapterSnapshotRenderer.snapshot(path: rendered.resolvedPath ?? path, size: size)
        } else {
            image = nil
        }
        if let image {
            ImageCache.shared.set(image, for: key, toDisk: true)
            thumbnail = image
        }
    }

    private static func resolvedCoverPath(_ path: String) -> String {
        if let url = URL(string: path), url.isFileURL {
            return url.path
        }
        if path.hasPrefix("/") || path.contains("://") {
            return path
        }
        return StorageService.absoluteSourcePath(path)
    }

    /// Keep thumbnail lookup identical to Reader, import reconciliation, and
    /// source availability. This does only lexical/cached root discovery; the
    /// detached renderer performs every filesystem probe.
    nonisolated static func candidatePaths(for path: String) -> [String] {
        StorageService.sourceFileCandidatePaths(for: path)
    }

    private static func cacheKey(for path: String, size: CGSize) -> String {
        "book-cover:\(path):\(Int(size.width))x\(Int(size.height))"
    }

    nonisolated private static func ensureICloudFileAvailable(at path: String) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            return true
        }
        let url = URL(fileURLWithPath: path)
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        guard fm.fileExists(atPath: placeholder.path) else {
            return false
        }
        try? fm.startDownloadingUbiquitousItem(at: placeholder)
        for _ in 0..<6 {
            usleep(500_000)
            if fm.fileExists(atPath: path) {
                return true
            }
        }
        return false
    }
}

@MainActor
final class EPUBChapterSnapshotRenderer: NSObject, WKNavigationDelegate {
    private let path: String
    private let snapshotSize: CGSize
    private let webView: WKWebView
    private var continuation: CheckedContinuation<NSImage?, Never>?
    private var didComplete = false

    static func snapshot(path: String, size: CGSize) async -> NSImage? {
        let width = max(320, size.width * 8)
        let height = max(420, width * size.height / max(size.width, 1))
        // A chapter of an EPUB book kept as one file is drawn from it (`EPUBBookScheme`).
        let bookURL = await Task.detached(priority: .utility) { () -> URL? in
            guard !FileManager.default.fileExists(atPath: path), EPUBBookFiles.location(ofPath: path) != nil else { return nil }
            return EPUBBookScheme.url(forPath: path)
        }.value
        let renderer = EPUBChapterSnapshotRenderer(path: path, snapshotSize: CGSize(width: width, height: height))
        return await renderer.render(bookURL: bookURL)
    }

    private init(path: String, snapshotSize: CGSize) {
        self.path = path
        self.snapshotSize = snapshotSize
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(EPUBBookScheme.handler, forURLScheme: EPUBBookScheme.name)
        self.webView = WKWebView(frame: CGRect(origin: .zero, size: snapshotSize), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    private func render(bookURL: URL?) async -> NSImage? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            if let bookURL {
                webView.load(URLRequest(url: bookURL))
            } else {
                let fileURL = URL(fileURLWithPath: path)
                webView.loadFileURL(fileURL, allowingReadAccessTo: Self.readAccessRoot(for: fileURL))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                Task { @MainActor in
                    self?.complete(nil)
                }
            }
        }
    }

    private static func readAccessRoot(for fileURL: URL) -> URL {
        let components = fileURL.pathComponents
        if let chaptersIndex = components.lastIndex(of: "Chapters"), chaptersIndex < components.count {
            let rootComponents = Array(components[0...chaptersIndex])
            return URL(fileURLWithPath: NSString.path(withComponents: rootComponents), isDirectory: true)
        }
        return fileURL.deletingLastPathComponent()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: snapshotSize)
        config.snapshotWidth = NSNumber(value: Double(snapshotSize.width))
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            Task { @MainActor in
                self?.complete(image)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        complete(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        complete(nil)
    }

    private func complete(_ image: NSImage?) {
        guard !didComplete else { return }
        didComplete = true
        continuation?.resume(returning: image)
        continuation = nil
        webView.navigationDelegate = nil
    }
}

struct ArticleStateBadge: View {
    let state: StudioArticleState
    var errorMessage: String? = nil
    var errorLabel: String? = nil

    private var statusFlag: SourceStatusFlag? {
        errorMessage.flatMap(SourceStatusFlag.init(rawValue:))
    }

    var body: some View {
        switch state {
        case .queued:
            Label("New", systemImage: "circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .fetching:
            ProgressView()
                .controlSize(.mini)
        case .ready:
            // Ready is the norm, not news. A row reaches this badge at all only
            // because it carries a paywall marker, and `isPaywalled` is a durable
            // fact about the source rather than a task: it stays set for good once
            // the text is attached. So the badge speaks only while the paywall is
            // still unresolved — otherwise the row goes quiet like every other
            // ready source, instead of claiming a distinction it doesn't have.
            if statusFlag == .paywall {
                Label("Paywalled", systemImage: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        case .error:
            if statusFlag == .confirmPodcast {
                Label("Confirm Match", systemImage: "questionmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if statusFlag == .needsTranscript {
                Label("Fetch Transcript", systemImage: "text.bubble")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                Label(errorLabel ?? errorMessage ?? "Error", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(errorMessage ?? "An error occurred")
                    // Selectable text cannot carry its own AX label on macOS;
                    // see AGENTS.md, "Text that speaks for itself".
                    .textSelection(.disabled)
                    .accessibilityLabel(errorMessage ?? errorLabel ?? "Error")
            }
        }
    }
}

// MARK: - Drag Helpers

/// Prepare a file URL for dragging a single article to an external app.
/// Papers / book chapters with a local PDF return the real file; other source types
/// with text content write a temporary .txt.  Returns nil when there's nothing useful to drag.
func dragFileURL(for article: StudioArticle) -> URL? {
    let sanitized = String(article.title
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: " -")
        .prefix(80))

    // Local PDF — return directly; a book chapter is its pages of the book,
    // written to a file of their own.
    if let path = article.localFilePath,
       path.lowercased().hasSuffix(".pdf"),
       let resolved = SourceService.resolveLocalFileURL(path),
       FileManager.default.fileExists(atPath: resolved.path) {
        guard let pages = article.bookPages else { return resolved }
        let chapterURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(sanitized).pdf")
        if let chapter = SourcePDFPages(path: resolved.path, pages: pages).document(), chapter.write(to: chapterURL) {
            return chapterURL
        }
    }

    // Try stored content
    var content = article.content

    // Extract from local file on the fly if no stored content
    if content == nil || content?.isEmpty == true,
       let path = article.localFilePath ?? (article.url.hasPrefix("/") ? article.url : nil),
       let resolved = SourceService.resolveLocalFileURL(path) {
        if resolved.path.lowercased().hasSuffix(".pdf") {
            content = try? SourceService().extractTextFromPDF(at: resolved.path)
        } else {
            content = try? String(contentsOf: resolved, encoding: .utf8)
        }
    }

    // Export as .txt if we have content
    if let content, !content.isEmpty {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sanitized).txt")
        try? content.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }

    // Web articles/videos without local content — export URL as .webloc
    let url = article.url
    if url.hasPrefix("http://") || url.hasPrefix("https://") {
        let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n\t<key>URL</key>\n\t<string>\(url)</string>\n</dict>\n</plist>"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sanitized).webloc")
        try? plist.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }

    return nil
}

func reviewSessionDragProvider(for transfer: ReviewSessionTransfer) -> NSItemProvider {
    let provider = NSItemProvider()
    if let data = try? JSONEncoder().encode(transfer) {
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.reviewSession.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
    }
    provider.suggestedName = transfer.title
    return provider
}

func groupDragProvider(for transfer: StudioGroupTransfer) -> NSItemProvider {
    let provider = NSItemProvider()
    if let data = try? JSONEncoder().encode(transfer) {
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.studioGroup.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
    }
    provider.suggestedName = transfer.groupName
    return provider
}

func sidebarTabDragProvider(for tab: StudioSidebarTab) -> NSItemProvider {
    let provider = NSItemProvider()
    let data = Data(tab.rawValue.utf8)
    provider.registerDataRepresentation(
        forTypeIdentifier: UTType.studioSidebarTab.identifier,
        visibility: .all
    ) { completion in
        completion(data, nil)
        return nil
    }
    provider.suggestedName = tab.rawValue
    return provider
}

/// Build an NSItemProvider for dragging a single article.
/// Includes the internal StudioArticleTransfer (for in-app drops) plus a file
/// representation visible to external apps (browsers, Claude, ChatGPT).
/// All file I/O is deferred to the load handler so multi-select stays responsive.
func articleDragProvider(for article: StudioArticle, selectedArticleIds: [String]? = nil) -> NSItemProvider {
    let draggedIDs = selectedArticleIds?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? [article.id]
    StudioDragVisibility.shared.begin(articleIDs: draggedIDs)
    let provider = NSItemProvider()

    // Internal transfer (tabs, MCP context tray, course groups)
    let transfer = StudioArticleTransfer.dragging(article, draggedIDs: draggedIDs)
    if let data = try? JSONEncoder().encode(transfer) {
        provider.registerDataRepresentation(forTypeIdentifier: UTType.studioArticle.identifier,
                                            visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
    }
    provider.registerDataRepresentation(forTypeIdentifier: UTType.studioSourceID.identifier,
                                        visibility: .all) { completion in
        completion(article.id.data(using: .utf8), nil)
        return nil
    }

    // Determine which file type to offer without doing any I/O yet.
    let hasPDF: Bool = {
        guard let path = article.localFilePath, path.lowercased().hasSuffix(".pdf") else { return false }
        return true
    }()
    let hasText = !hasPDF && article.sourceType != .paper
        && !(article.content ?? "").isEmpty

    if hasPDF {
        let path = article.localFilePath!
        provider.suggestedName = URL(fileURLWithPath: path).lastPathComponent
        provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier,
                                            fileOptions: [],
                                            visibility: .all) { completion in
            Task.detached(priority: .userInitiated) {
                let resolvedURL: URL?
                if let resolved = SourceService.resolveLocalFileURL(path),
                   FileManager.default.fileExists(atPath: resolved.path) {
                    resolvedURL = resolved
                } else {
                    resolvedURL = nil
                }
                completion(resolvedURL, false, nil)
            }
            return nil
        }
    } else if hasText {
        let title = article.title
        let content = article.content!
        let sanitized = String(title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
            .prefix(80))
        provider.suggestedName = "\(sanitized).txt"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.plainText.identifier,
                                            fileOptions: [],
                                            visibility: .all) { completion in
            Task.detached(priority: .userInitiated) {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(sanitized).txt")
                try? content.write(to: tempURL, atomically: true, encoding: .utf8)
                completion(tempURL, false, nil)
            }
            return nil
        }
    } else if article.url.hasPrefix("http://") || article.url.hasPrefix("https://") {
        let title = article.title
        let sanitized = String(title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
            .prefix(80))
        provider.suggestedName = "\(sanitized).webloc"
        provider.registerFileRepresentation(forTypeIdentifier: "com.apple.web-internet-location",
                                            fileOptions: [],
                                            visibility: .all) { completion in
            Task.detached(priority: .userInitiated) {
                let fileURL = dragFileURL(for: article)
                completion(fileURL, false, nil)
            }
            return nil
        }
    }

    return provider
}

/// An NSView that initiates a multi-file drag session, like dragging multiple
/// files from Finder.  Used by the MCP context tray to drag all sources at once.
struct MultiFileDragSource: NSViewRepresentable {
    /// Called lazily when the drag starts — avoids writing temp files on every body evaluation.
    let fileURLProvider: () -> [URL]

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.fileURLProvider = fileURLProvider
        return view
    }

    func updateNSView(_ nsView: DragSourceView, context: Context) {
        nsView.fileURLProvider = fileURLProvider
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var fileURLProvider: (() -> [URL])?

        override func mouseDown(with event: NSEvent) {
            // Needed so mouseDragged fires on this view.
        }

        override func mouseDragged(with event: NSEvent) {
            guard let urls = fileURLProvider?(), !urls.isEmpty else { return }
            let items = urls.map { url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                item.setDraggingFrame(self.bounds,
                                      contents: NSImage(systemSymbolName: "doc.on.doc.fill",
                                                        accessibilityDescription: "files"))
                return item
            }
            beginDraggingSession(with: items, event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }
    }
}

// MARK: - Tab Drop Delegate

/// Handles drops on sidebar tab buttons — supports both article-to-tab moves and tab reordering.
struct TabDropDelegate: DropDelegate {
    let tab: StudioSidebarTab
    let vm: StudioViewModel
    /// The source type currently being dragged, and the tab under the pointer.
    /// The reorder reads the first rather than the drop's payload, which only
    /// ever arrives asynchronously, and writes the second so the row can show
    /// where the drag would land.
    @Binding var draggedTab: StudioSidebarTab?
    @Binding var dropTarget: StudioSidebarTab?

    func validateDrop(info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: [.studioSidebarTab]) { return true }
        // Article moves: only allow drops on the articles and papers tabs.
        if info.hasItemsConforming(to: [.studioArticle]) {
            return tab == .articles || tab == .papers
        }
        return false
    }

    func performDrop(info: DropInfo) -> Bool {
        StudioDragVisibility.shared.endSoon()
        // Try article transfer first
        if info.hasItemsConforming(to: [.studioArticle]) {
            let providers = info.itemProviders(for: [.studioArticle])
            for provider in providers {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.studioArticle.identifier) { data, _ in
                    guard let data, let transfer = try? JSONDecoder().decode(StudioArticleTransfer.self, from: data) else { return }
                    Task { @MainActor in
                        if let type = tab.sourceType {
                            for id in transfer.draggedSourceIDs {
                                vm.moveArticle(id: id, to: type)
                            }
                        }
                    }
                }
            }
            return true
        }

        // Try tab reorder. The live drag state is authoritative when it is set:
        // it names the dragged type at drop time, where the pasteboard payload
        // only resolves in a later callback.
        dropTarget = nil
        if let source = draggedTab {
            draggedTab = nil
            vm.reorderTab(from: source, to: tab)
            return true
        }
        let providers = info.itemProviders(for: [.studioSidebarTab])
        for provider in providers {
            StudioSidebarTabDrop.loadString(from: provider) { raw in
                guard let draggedTab = StudioSidebarTab(rawValue: raw) else { return }
                Task { @MainActor in
                    vm.reorderTab(from: draggedTab, to: tab)
                }
            }
        }
        return !providers.isEmpty
    }

    func dropEntered(info: DropInfo) {
        // Switch to this tab when an article is dragged over it
        if info.hasItemsConforming(to: [.studioArticle]),
           tab == .articles || tab == .papers {
            vm.switchTab(to: tab)
        }
        if info.hasItemsConforming(to: [.studioSidebarTab]) {
            dropTarget = tab
        }
    }

    func dropExited(info: DropInfo) {
        if dropTarget == tab { dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // A reorder moves the tab; without this the pointer shows a copy badge.
        guard info.hasItemsConforming(to: [.studioSidebarTab]) else { return nil }
        return DropProposal(operation: .move)
    }
}

enum StudioSidebarTabDrop {
    static func loadString(from provider: NSItemProvider, completion: @escaping (String) -> Void) {
        guard provider.hasItemConformingToTypeIdentifier(UTType.studioSidebarTab.identifier) else {
            return
        }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.studioSidebarTab.identifier) { data, _ in
            guard let data,
                  let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return }
            completion(raw)
        }
    }
}

extension StudioSidebarTab {
    var minimumLabeledTabWidth: CGFloat {
        switch self {
        case .articles: return 34
        case .papers: return 31
        case .books: return 27
        case .meetings: return 48
        case .podcasts: return 42
        case .videos: return 31
        case .xPosts: return 18
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Toggles the ⇧⌘K ForeverLM Assistant command bar in Studio.
    static let toggleStudioAssistant = Notification.Name("toggleStudioAssistant")
    /// ⌘R: reveals the docked reader column in Studio.
    static let openStudioReader = Notification.Name("openStudioReader")
    /// Opens Studio Settings, optionally to a specific pane passed as the notification `object`
    /// (a `SettingsPane?`). Posted by the chat composer's `/settings` slash command.
    static let requestOpenStudioSettings = Notification.Name("requestOpenStudioSettings")
    /// A `foreverlm://doc/…` or `foreverlm://notebook/…` link followed from a
    /// surface without the Studio model at hand — the chat transcript's web
    /// view — carried as a `StudioEntityLink` for `ContentView` to open.
    static let requestOpenStudioEntityLink = Notification.Name("requestOpenStudioEntityLink")
    /// A `foreverlm://cards?…` link (`ChatSavedCards`) followed from the chat
    /// transcript's web view, carried for `ContentView` to open in To Check.
    static let requestOpenChatSavedCards = Notification.Name("requestOpenChatSavedCards")
    /// Posted after a mutating MCP tool call (from the ⇧⌘K bar, the docked Chat column,
    /// or an external MCP client) so open Studio views reload instead of going stale.
    static let foreverLMDataDidChange = Notification.Name("foreverLMDataDidChange")
    /// Posted after listening has durably recorded completion. One source ID or
    /// a completed chapter range is carried as `object` (`String` or `[String]`).
    static let sourceListeningCompletionDidChange = Notification.Name("sourceListeningCompletionDidChange")
    /// Opens the Edit Details sheet for the source ID passed as the notification
    /// `object` (a `String`), in the window its userInfo names
    /// (`SourceDetailsEditRequest`). Posted by an attention row whose fix is
    /// the learner supplying metadata the extractor could not find, and by
    /// the Sources list's Edit Details….
    static let requestEditSourceDetails = Notification.Name("requestEditSourceDetails")
}

/// A request for the Edit Details sheet, which each Studio window hosts once
/// (`StudioView`), whether it shows the library list or a notebook: an
/// attention row in a notebook's Sources column asks for it too.
enum SourceDetailsEditRequest {
    static let windowIDKey = "windowID"

    /// Asks `windowID`'s window for the editor; nil asks the key window.
    static func post(sourceID: String, windowID: UUID?) {
        NotificationCenter.default.post(
            name: .requestEditSourceDetails,
            object: sourceID,
            userInfo: windowID.map { [windowIDKey: $0] }
        )
    }

    /// Whether the request `note` is for the window `windowID`: the window it
    /// names, or the key window when it names none.
    static func isFor(_ note: Notification, windowID: UUID, isKeyWindow: Bool) -> Bool {
        if let target = note.userInfo?[windowIDKey] as? UUID { return target == windowID }
        return isKeyWindow
    }
}

// MARK: - Rough Time Ago

extension Date {
    var roughTimeAgo: String {
        let seconds = -timeIntervalSinceNow
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hr ago" }
        let days = hours / 24
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }
}
