import AppKit
import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import WebKit

enum ReaderLinkHoverFeedback {
    /// Publisher pages and archived HTML often color links without changing
    /// their hover appearance. Keep their authored colors, but make the
    /// interaction explicit when a pointer is over a real destination.
    static let injectionScript = """
    (function() {
        if (document.getElementById('foreverlm-link-hover-feedback')) { return; }
        var style = document.createElement('style');
        style.id = 'foreverlm-link-hover-feedback';
        style.textContent = `
            a[href], area[href] {
                cursor: pointer !important;
            }
            a[href]:hover, a[href]:focus-visible {
                text-decoration-line: underline !important;
                text-decoration-thickness: from-font;
                text-underline-offset: 0.12em;
            }
        `;
        (document.head || document.documentElement).appendChild(style);
    })();
    """
}

/// The learner's reading version of an article (`ArticleReadingView`): the
/// pieces of text a model named are hidden on the page. Nothing is removed — each
/// piece stays in the document inside a hidden span — so saved highlights, Find
/// and the text the app reads keep their offsets, and switching back to the
/// original is one class on the body.
enum ReaderReadingView {
    /// Hand the page its reading view. Pending state is parked on `window` too:
    /// the injected script is not guaranteed to have run when this arrives, and
    /// whichever comes second finds the other's value and applies it.
    static func push(_ view: ArticleReadingView?, to webView: WKWebView) {
        let payload: String
        if let view, let data = try? JSONEncoder().encode(view.removals),
           let json = String(data: data, encoding: .utf8) {
            payload = "{\"strings\":\(json),\"shown\":\(view.isShown)}"
        } else {
            payload = "{\"strings\":[],\"shown\":false}"
        }
        webView.evaluateJavaScript(
            """
            window.__flmReadingViewPending = \(payload);
            if (window.__flmReadingView) { window.__flmReadingView.apply(window.__flmReadingViewPending); }
            """
        )
    }

    static let injectionScript = #"""
    (function() {
        if (window.__flmReadingView) { return; }
        var style = document.createElement('style');
        style.textContent = '.flm-rv-hidden { display: none !important; } body.flm-rv-off .flm-rv-hidden { display: inline !important; }';
        (document.head || document.documentElement).appendChild(style);
        var signature = '';

        function unwrap() {
            var spans = document.querySelectorAll('span.flm-rv-hidden');
            Array.prototype.forEach.call(spans, function(span) {
                var parent = span.parentNode;
                if (!parent) { return; }
                while (span.firstChild) { parent.insertBefore(span.firstChild, span); }
                parent.removeChild(span);
                parent.normalize();
            });
        }

        function wrapAll(strings) {
            var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
                acceptNode: function(node) {
                    var parent = node.parentElement;
                    if (!parent || parent.closest('script,style,noscript,.flm-rv-hidden')) { return NodeFilter.FILTER_REJECT; }
                    return NodeFilter.FILTER_ACCEPT;
                }
            });
            var nodes = [];
            while (walker.nextNode()) { nodes.push(walker.currentNode); }
            nodes.forEach(function(node) {
                var text = node.data, spans = [];
                strings.forEach(function(piece) {
                    var from = 0, at;
                    while ((at = text.indexOf(piece, from)) >= 0) {
                        spans.push([at, at + piece.length]);
                        from = at + piece.length;
                    }
                });
                if (!spans.length) { return; }
                spans.sort(function(a, b) { return a[0] - b[0] || b[1] - a[1]; });
                var merged = [];
                spans.forEach(function(span) {
                    var last = merged[merged.length - 1];
                    if (last && span[0] <= last[1]) { last[1] = Math.max(last[1], span[1]); }
                    else { merged.push([span[0], span[1]]); }
                });
                // From the end, so earlier offsets stay valid as the node is split.
                for (var i = merged.length - 1; i >= 0; i--) {
                    var middle = node.splitText(merged[i][0]);
                    middle.splitText(merged[i][1] - merged[i][0]);
                    var span = document.createElement('span');
                    span.className = 'flm-rv-hidden';
                    middle.parentNode.insertBefore(span, middle);
                    span.appendChild(middle);
                }
            });
        }

        window.__flmReadingView = {
            apply: function(state) {
                if (!state || !document.body) { return; }
                var strings = state.strings || [];
                var next = strings.join('\u0001');
                if (next !== signature) {
                    unwrap();
                    if (strings.length) { wrapAll(strings); }
                    signature = next;
                }
                document.body.classList.toggle('flm-rv-off', !state.shown);
            }
        };
        if (window.__flmReadingViewPending) { window.__flmReadingView.apply(window.__flmReadingViewPending); }
    })();
    """#
}

/// Reports what the pointer was over the moment a context menu is raised.
///
/// WebKit builds its menu in the web process and hands the UI process a menu
/// whose link commands are answered back in the web process — the reader never
/// sees the link, so it cannot make those commands do anything. The DOM's own
/// `contextmenu` event fires first, on the same connection, so the reader knows
/// the destination before `willOpenMenu(_:with:)` runs.
enum ReaderContextLinkTracking {
    static func injectionScript(handlerName: String) -> String {
        """
        (function() {
            if (window.__foreverlmContextLinkInstalled) { return; }
            window.__foreverlmContextLinkInstalled = true;
            document.addEventListener('contextmenu', function(event) {
                var anchor = null;
                var node = event.target;
                if (node && node.closest) {
                    anchor = node.closest('a[href], area[href]');
                }
                var href = '';
                var raw = '';
                if (anchor) {
                    // `href` is already resolved against the document; the raw
                    // attribute survives so an archived page can re-resolve it
                    // against the URL it was saved from.
                    try { href = anchor.href || ''; } catch (e) { href = ''; }
                    try { raw = anchor.getAttribute('href') || ''; } catch (e) { raw = ''; }
                }
                var selection = window.getSelection();
                var hasSelection = !!(selection && !selection.isCollapsed &&
                    selection.toString().trim().length > 0);
                window.webkit.messageHandlers.\(handlerName).postMessage({
                    type: 'contextLink',
                    href: href,
                    raw: raw,
                    hasSelection: hasSelection
                });
            }, true);
        })();
        """
    }

    /// Hand a `contextLink` message to the web view that sent it, so its link
    /// commands act on the destination the pointer was actually over.
    ///
    /// `fallbackBase` is the URL the page was originally published at, used when
    /// the page is being read from disk — see `resolvedURL(href:raw:fallbackBase:)`.
    static func apply(_ message: WKScriptMessage, fallbackBase: String?) {
        guard let body = message.body as? [String: Any] else { return }
        let href = (body["href"] as? String) ?? ""
        let raw = (body["raw"] as? String) ?? ""
        let hasSelection = (body["hasSelection"] as? NSNumber)?.boolValue ?? false
        let url = resolvedURL(href: href, raw: raw, fallbackBase: fallbackBase)
        let webView = message.webView as? ForeverLMWebView
        DispatchQueue.main.async {
            webView?.noteContextLink(url: url, hasSelection: hasSelection)
        }
    }

    /// What the link commands should act on. A page read from disk — an archived
    /// article, an unpacked chapter — resolves a site-relative link against
    /// `file:`, landing on a path that does not exist; WebKit then drops the
    /// navigation without reporting an error, which is why those links looked
    /// dead. Re-resolve them against the URL the page was published at.
    static func resolvedURL(href: String, raw: String, fallbackBase: String?) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let resolved = URL(string: trimmed) else { return nil }
        guard resolved.isFileURL,
              !FileManager.default.fileExists(atPath: resolved.path) else { return resolved }

        let rawHref = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawHref.isEmpty,
              !rawHref.hasPrefix("#"),
              let fallbackBase,
              let base = URL(string: fallbackBase),
              base.scheme == "http" || base.scheme == "https",
              let rerooted = URL(string: rawHref, relativeTo: base)?.absoluteURL else {
            return resolved
        }
        return rerooted
    }
}

/// Saves a link the learner asked for to the Downloads folder and reveals it,
/// the way a browser's "Download Linked File" does.
///
/// WebKit answers that command in its web process, where it never becomes a
/// `WKDownload` without WebKit SPI, so readers start the download themselves —
/// through the web view, so the page's cookies come along — and hand it here.
final class ReaderLinkDownloader: NSObject, WKDownloadDelegate {
    private var destinations: [ObjectIdentifier: URL] = [:]
    private let report: (String) -> Void

    /// - Parameter report: shows a message to the learner (a toast, typically).
    init(report: @escaping (String) -> Void) {
        self.report = report
    }

    func start(_ url: URL, in webView: WKWebView) {
        guard FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first != nil else {
            report("Could not reach the Downloads folder")
            return
        }
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            download.delegate = self
        }
    }

    /// A free path in Downloads, since `WKDownload` refuses a destination that
    /// already exists.
    private static func destination(for suggestedFilename: String) -> URL? {
        guard let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        else { return nil }
        let name = suggestedFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = directory.appendingPathComponent(name.isEmpty ? "download" : name)
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var attempt = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(attempt)" : "\(base) \(attempt).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            attempt += 1
        }
        return candidate
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let destination = Self.destination(for: suggestedFilename)
        destinations[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let saved = destinations.removeValue(forKey: ObjectIdentifier(download)) else {
            report("Could not save the linked file")
            return
        }
        let report = report
        Task { @MainActor in
            NSWorkspace.shared.activateFileViewerSelecting([saved])
            report("Saved \(saved.lastPathComponent) to Downloads")
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        report("Download failed: \(error.localizedDescription)")
    }
}

enum ReaderScrollPreservation {
    /// Keeps the reader anchored to the same scroll fraction when the viewport
    /// width changes (e.g. collapsing a side panel widens the reader and reflows text).
    ///
    /// Only the viewport width counts. This used to watch the document element
    /// for any resize, and a document grows many times while it loads: on the
    /// way back from a link the article reloads, the first growth was measured
    /// at the top, and that "top" was re-applied 50ms later — after WebKit had
    /// already restored the reading position. Height changes never need this
    /// anyway: text does not reflow when only the height moves.
    static let injectionScript = """
    (function() {
        if (window.foreverLMScrollPreserveInstalled) { return; }
        window.foreverLMScrollPreserveInstalled = true;

        function scrollFraction() {
            var doc = document.documentElement;
            var body = document.body;
            var height = Math.max(
                doc ? doc.scrollHeight : 0,
                body ? body.scrollHeight : 0
            );
            var viewport = window.innerHeight || (doc ? doc.clientHeight : 0) || 0;
            var maxScroll = Math.max(0, height - viewport);
            if (maxScroll <= 0) { return 0; }
            var y = window.scrollY || window.pageYOffset || 0;
            return Math.max(0, Math.min(1, y / maxScroll));
        }

        function restore(fraction) {
            var doc = document.documentElement;
            var body = document.body;
            var height = Math.max(
                doc ? doc.scrollHeight : 0,
                body ? body.scrollHeight : 0
            );
            var viewport = window.innerHeight || (doc ? doc.clientHeight : 0) || 0;
            var maxScroll = Math.max(0, height - viewport);
            window.scrollTo(0, maxScroll * fraction);
        }

        var savedFraction = null;
        var restoreTimer = null;

        function scheduleRestore() {
            if (restoreTimer) { clearTimeout(restoreTimer); }
            restoreTimer = setTimeout(function() {
                restoreTimer = null;
                if (savedFraction === null) { return; }
                var fraction = savedFraction;
                savedFraction = null;
                restore(fraction);
            }, 50);
        }

        var lastWidth = window.innerWidth;
        window.addEventListener('resize', function() {
            var width = window.innerWidth;
            if (width === lastWidth) { return; }
            lastWidth = width;
            // A book read as one document keeps its place by chapter
            // (`EPUBReaderStyles.bookScript`): a fraction of the whole book
            // drifts by pages when only some of it reflows.
            if (window.__flmBookOwnsScroll) { return; }
            if (savedFraction === null) {
                savedFraction = scrollFraction();
            }
            scheduleRestore();
        });
    })();
    """
}

// `ArticleReadingPositionLocator` — the web encoding of
// `sources.reading_position_locator` — lives in `Models.swift` beside
// `EPUBReadingPositionLocator` and `VideoWatchProgress`, the other two
// encodings of that same column.

/// Shared user-scroll reporting for live and archived web articles. The message
/// always includes ordinary scroll progress, plus a completion signal scoped to
/// the main article element. Completion is tagged as user-initiated so a restored
/// scroll position, viewport resize, or late image layout cannot mark a source read.
/// A page restored from the back/forward cache also says so (`pageRestored`,
/// no `fraction`, so a handler reading only progress ignores it).
enum ArticleScrollTracking {
    static func injectionScript(handlerName: String) -> String {
        """
        (function() {
            var timer = null;
            var userScrollPending = false;
            function scrollFraction() {
                var doc = document.documentElement;
                var body = document.body;
                var height = Math.max(
                    doc ? doc.scrollHeight : 0,
                    body ? body.scrollHeight : 0
                );
                var viewport = window.innerHeight || (doc ? doc.clientHeight : 0) || 0;
                var maxScroll = Math.max(0, height - viewport);
                if (maxScroll <= 0) { return 0; }
                var y = window.scrollY || window.pageYOffset || 0;
                return Math.max(0, Math.min(1, y / maxScroll));
            }
            function articleRoot() {
                var selectors = ['article', 'main', '[role="main"]', '.post-content', '.article-content'];
                for (var i = 0; i < selectors.length; i++) {
                    var node = document.querySelector(selectors[i]);
                    if (node && (node.innerText || '').trim().length > 400) { return node; }
                }
                return document.body || document.documentElement;
            }
            function reachedArticleEnd() {
                var root = articleRoot();
                if (!root) { return false; }
                var viewport = window.innerHeight || document.documentElement.clientHeight || 0;
                return root.getBoundingClientRect().bottom <= viewport + Math.max(40, viewport * 0.08);
            }
            function post(userInitiated) {
                try {
                    window.webkit.messageHandlers.\(handlerName).postMessage({
                        type: 'scrollPosition',
                        fraction: scrollFraction(),
                        offset: window.scrollY || window.pageYOffset || 0,
                        href: location.href,
                        reachedArticleEnd: reachedArticleEnd(),
                        userInitiated: userInitiated
                    });
                } catch (e) {}
            }
            function noteUserScroll() {
                userScrollPending = true;
            }
            window.addEventListener('wheel', noteUserScroll, { passive: true });
            window.addEventListener('touchstart', noteUserScroll, { passive: true });
            window.addEventListener('mousedown', noteUserScroll, { passive: true });
            window.addEventListener('keydown', function(event) {
                if (['ArrowDown', 'PageDown', 'End', ' '].indexOf(event.key) >= 0) {
                    noteUserScroll();
                }
            }, true);
            window.addEventListener('scroll', function() {
                if (timer) { clearTimeout(timer); }
                timer = setTimeout(function() {
                    var userInitiated = userScrollPending;
                    userScrollPending = false;
                    post(userInitiated);
                }, 450);
            }, { passive: true });
            window.addEventListener('beforeunload', function() { post(false); });
            // A page Back brings out of the back/forward cache is the same
            // document, so no load finishes and the reader never hears it has
            // returned. A page that sets `history.scrollRestoration` to manual
            // — every Substack post — comes back at the top.
            window.addEventListener('pageshow', function(event) {
                if (!event.persisted) { return; }
                try {
                    window.webkit.messageHandlers.\(handlerName).postMessage({
                        type: 'pageRestored',
                        href: location.href
                    });
                } catch (e) {}
            });
        })();
        """
    }
}

/// Tracks programmatic text selection (find-in-page, search jump) so readers
/// don't surface the "Chat about this" affordance for non-user highlights.
final class ReaderProgrammaticSelection {
    private var depth = 0
    private var suppressUntil: Date?

    var isActive: Bool {
        depth > 0 || (suppressUntil.map { Date() < $0 } ?? false)
    }

    func whileActive<T>(_ work: () throws -> T) rethrows -> T {
        depth += 1
        defer {
            depth -= 1
            if depth == 0 {
                suppressUntil = Date().addingTimeInterval(0.5)
            }
        }
        return try work()
    }
}

/// Reports text selection only after explicit user gestures (mouseup / keyboard
/// selection), not when find-in-page or search navigation highlights a match,
/// draws the "Chat about this" / "Note" bar next to the selection, and paints
/// saved notes back into the page.
///
/// The two halves ship as one script because every reader that wants one wants
/// the other, and they share the message channel.
enum ReaderUserSelectionJavaScript {
    static let injectionScript = [
        ReaderSelectionCalloutJavaScript.injectionScript(handlerName: "selectionChanged"),
        ReaderWebHighlightSupport.installerScript(handlerName: "selectionChanged"),
        ReaderPassageFlash.webInstallerScript,
    ].joined(separator: "\n")
}

@MainActor
@Observable
final class ReaderFindState {
    var isVisible = false
    var query = ""
    var statusText = ""
    var searchRevision = 0
    var searchesBackward = false
    var focusRevision = 0
    /// The transcript readers on screen that draw this find's bar inside the
    /// transcript (`TranscriptFindBar`), under a video's player or above a
    /// podcast's turns. While one is, the Reader's own bar over the source
    /// (`ReaderFindBar`) stands down, so ⌘F opens one bar, not two.
    private(set) var inlineBarHosts: Set<UUID> = []

    var hasInlineBar: Bool { !inlineBarHosts.isEmpty }

    func show() {
        isVisible = true
        focusRevision += 1
    }

    func registerInlineBar(_ host: UUID) {
        inlineBarHosts.insert(host)
    }

    func unregisterInlineBar(_ host: UUID) {
        inlineBarHosts.remove(host)
    }

    /// Undoes what the last find left on the page. Every reader's find selects
    /// its match so the learner can see it, and once the bar closes that
    /// selection lingers as an inactive gray box over the word — and over any
    /// saved highlight beneath it. The performer that made the match registers
    /// how to take it back, and only that match is taken back: a selection the
    /// learner has made since is theirs and stays.
    @ObservationIgnored private var clearMatch: (() -> Void)?

    func registerMatchClearing(_ clear: @escaping () -> Void) {
        clearMatch = clear
    }

    func close() {
        isVisible = false
        query = ""
        statusText = ""
        takeBackMatch()
    }

    /// Takes back what the last find left on the page, once, and leaves the
    /// bar as it is. A find run with no bar open — a search's jump into the
    /// Reader — has no close to do it.
    func takeBackMatch() {
        let clear = clearMatch
        clearMatch = nil
        clear?()
    }

    func search(backwards: Bool = false) {
        searchesBackward = backwards
        searchRevision += 1
    }

    func resetForDocumentChange() {
        query = ""
        statusText = ""
        searchRevision = 0
        searchesBackward = false
        isVisible = false
        // The match belonged to the document that is leaving.
        clearMatch = nil
    }
}

struct LocalTextFileContentView<LoadedContent: View>: View {
    let path: String
    @ViewBuilder var loadedContent: (String) -> LoadedContent

    @State private var content: String?
    @State private var didFail = false

    var body: some View {
        Group {
            if let content, !content.isEmpty {
                loadedContent(content)
            } else if didFail {
                Text("Unable to load text.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading text…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: path) {
            await loadContent()
        }
    }

    @MainActor
    private func loadContent() async {
        content = nil
        didFail = false
        let path = self.path
        // A file on disk, or a chapter of an EPUB book kept as one file.
        let loaded = await Task.detached(priority: .userInitiated) {
            EPUBBookFiles.text(atPath: path)
        }.value
        if let loaded, !loaded.isEmpty {
            content = loaded
        } else {
            didFail = true
        }
    }
}

/// A book chapter whose file is not on this Mac — the book was imported on
/// another device and its EPUB folder never arrived here — still has its text
/// in the library. WebKit draws a blank page for a missing file, so the file
/// is checked off the main actor first and the stored text is read instead.
struct BookChapterFileGate<FileReader: View, TextReader: View>: View {
    private static var storage: StorageService { StorageService() }

    let path: String
    let sourceID: String
    let inMemoryText: String?
    @ViewBuilder var fileReader: () -> FileReader
    @ViewBuilder var textReader: (String) -> TextReader

    private enum Phase: Equatable {
        case checking
        case file
        case storedText(String)
        case missing
    }

    @State private var phase: Phase = .checking
    /// Bumped when sync installs source documents, so a chapter showing its
    /// stored text looks again for the file that may just have arrived.
    @State private var documentInstallRevision = 0

    var body: some View {
        Group {
            switch phase {
            case .file:
                fileReader()
            case .storedText(let text):
                textReader(text)
            case .missing:
                Text("This chapter's file is not on this Mac.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .checking:
                ReaderLoadingView(title: "Loading chapter…")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sourceDocumentsDidInstall)) { _ in
            if phase != .file { documentInstallRevision += 1 }
        }
        .task(id: "\(path)|\(documentInstallRevision)") {
            let path = self.path
            // A chapter of a book kept as one file is there when its entry is.
            let exists = await Task.detached(priority: .userInitiated) {
                EPUBBookFiles.exists(atPath: path)
            }.value
            guard !Task.isCancelled else { return }
            // The book reader moves between chapter files by itself; while the
            // files are here it stays the same view instead of being rebuilt.
            if exists {
                if phase != .file { phase = .file }
                return
            }
            let sourceID = self.sourceID
            let text = await ArchivedArticleFallback.resolve(
                inMemory: inMemoryText,
                loadPersisted: { await Self.storage.loadSourceContent(sourceID) }
            )
            guard !Task.isCancelled else { return }
            phase = text.map { .storedText($0) } ?? .missing
        }
    }
}

struct ReaderFindBar: View {
    @Bindable var state: ReaderFindState
    var prompt = "Find in reader"
    @FocusState private var isFocused: Bool

    var body: some View {
        // A transcript that draws the bar inside itself has it there instead.
        if state.isVisible && !state.hasInlineBar {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField(prompt, text: $state.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit { state.search() }
                    .onChange(of: state.query) {
                        state.statusText = ""
                    }

                if !state.statusText.isEmpty {
                    Text(state.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(minWidth: 72, alignment: .trailing)
                }

                Button {
                    state.search(backwards: true)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.hoverWash(inset: -3))
                .disabled(state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Previous match")

                Button {
                    state.search()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.hoverWash(inset: -3))
                .disabled(state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Next match")

                Button("Search") {
                    state.search()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Search next match")

                Button {
                    state.close()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.hoverWash(inset: -3))
                .help("Close find")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            .onAppear { isFocused = true }
            .onChange(of: state.focusRevision) { _, _ in
                isFocused = true
            }
            .onExitCommand {
                state.close()
            }
        }
    }
}

/// The find bar inside a transcript, under a video's player or above a
/// podcast's or meeting's turns. Like `ReaderFindBar` it shows only once
/// asked for, by ⌘F or the ⋯'s Find in Reader, and Escape or its × closes it
/// (Quiet chrome, docs/ui-design.md, 2026-10-06: it was a search field over
/// every transcript at all times). While it is on screen the Reader's own bar
/// stands down (`ReaderFindState.hasInlineBar`).
struct TranscriptFindBar: View {
    @Bindable var state: ReaderFindState
    @FocusState private var isFocused: Bool
    @State private var host = UUID()

    private var hasQuery: Bool {
        !state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Always mounted, closed or open, so the transcript keeps its
            // claim on the find for as long as it is on screen.
            Color.clear
                .frame(height: 0)
                .onAppear { state.registerInlineBar(host) }
                .onDisappear { state.unregisterInlineBar(host) }
            if state.isVisible {
                bar
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search transcript", text: $state.query)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .frame(maxWidth: 260)
                .onSubmit { state.search() }
                .onChange(of: state.query) {
                    state.statusText = ""
                }

            Button {
                state.search(backwards: true)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.hoverWash(inset: -3))
            .disabled(!hasQuery)
            .help("Previous match")

            Button {
                state.search()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.hoverWash(inset: -3))
            .disabled(!hasQuery)
            .help("Next match")

            if !state.statusText.isEmpty {
                Text(state.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(minWidth: 72, alignment: .leading)
            }

            Spacer()

            Button {
                state.close()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.hoverWash(inset: -3))
            .help("Close find")
            .accessibilityLabel("Close find")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .onAppear { isFocused = true }
        .onChange(of: state.focusRevision) { _, _ in
            isFocused = true
        }
        .onExitCommand {
            state.close()
        }
    }
}

extension NSEvent {
    var isReaderFindShortcut: Bool {
        guard charactersIgnoringModifiers?.lowercased() == "f" else { return false }
        let activeModifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        return activeModifiers == .command || activeModifiers == .control
    }

    /// Cmd+F only. Ctrl+F is excluded here because it doubles as the emacs-style
    /// "move forward" binding inside text fields and must not be swallowed globally.
    var isCommandFindShortcut: Bool {
        guard charactersIgnoringModifiers?.lowercased() == "f" else { return false }
        return modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
    }

    /// Shift+Cmd+F — always searches the sources list, regardless of focus.
    var isSourcesFindShortcut: Bool {
        guard charactersIgnoringModifiers?.lowercased() == "f" else { return false }
        return modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift]
    }

    var readerZoomShortcut: ReaderZoomShortcut? {
        let activeModifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard activeModifiers == .control else { return nil }
        switch charactersIgnoringModifiers {
        case "+", "=": return .zoomIn
        case "-": return .zoomOut
        case "0": return .reset
        default: return nil
        }
    }
}

enum ReaderZoomShortcut {
    case zoomIn
    case zoomOut
    case reset
}

extension NSWindow {
    /// The pointer position to use when routing trackpad gestures. AppKit only
    /// defines `NSEvent.locationInWindow` for mouse events; `.magnify` is a
    /// gesture event, so reading its location can route a pinch to a neighboring
    /// panel. The window supplies the live pointer in the same base coordinates
    /// used by the registered reader and chat anchors.
    var gesturePointerLocation: CGPoint {
        mouseLocationOutsideOfEventStream
    }
}

// MARK: - Pinch zoom anchoring

/// Where the pinch now zooming a reader points.
///
/// A reader zooms by laying its document out again at the new size. Left to
/// that, it kept the top of the view where it was, so the words under the
/// fingers slid away and every pinch ended in a scroll to find them. The product owner
/// (2026-09-29): "when i pinch, on a piece of text, i want the zoom to actually
/// 'go there' where the cursor is". The router notes the pointer as it hands a
/// pinch to a reader. Each reader asks here while it applies the new zoom and,
/// when the pinch points into it, puts what was under the pointer back under
/// it. Keyboard zoom notes nothing and zooms as it always has.
@MainActor
enum ReaderPinchAnchor {
    private static weak var window: NSWindow?
    private static var windowPoint: CGPoint = .zero
    private static var notedAt: TimeInterval = -.infinity
    /// Counts pinches, so a reader can tell the next step of one pinch from
    /// the start of another.
    private static var gesture = 0

    /// How long a noted pinch stays the reason for a zoom. The reader applies
    /// it within a turn or two of the run loop; this only has to outlast that,
    /// and lapse before the next keyboard zoom.
    private static let lifetime: TimeInterval = 0.25
    /// How long after a pinch's last step a reader laid out by SwiftUI still
    /// puts its words back. An hour's transcript takes a few hundred
    /// milliseconds to lay out at a new size.
    static let settleTime: TimeInterval = 1

    /// A trackpad marks where a pinch begins. From a device that sends no
    /// phases, a pause of `lifetime` starts a new one; a trackpad pinch stays
    /// one pinch across a pause, which a long transcript's layout at each new
    /// size can make.
    static func note(_ point: CGPoint, in window: NSWindow, phase: NSEvent.Phase) {
        let now = ProcessInfo.processInfo.systemUptime
        if phase.contains(.began) || (phase.isEmpty && now - notedAt >= lifetime) || self.window !== window {
            gesture += 1
        }
        self.window = window
        windowPoint = point
        notedAt = now
    }

    /// The pinch point in `view`'s coordinates, while a pinch that just
    /// arrived points at the part of `view` on screen; nil otherwise.
    ///
    /// Both rects are checked: a view SwiftUI hosts in a scroll view reports
    /// the scroll view's whole visible area as its `visibleRect`, well past
    /// its own bounds, so every transcript paragraph took itself for the one
    /// under the pointer.
    static func point(in view: NSView) -> CGPoint? {
        guard let window, view.window === window,
              ProcessInfo.processInfo.systemUptime - notedAt < lifetime else { return nil }
        let point = view.convert(windowPoint, from: nil)
        return view.bounds.contains(point) && view.visibleRect.contains(point) ? point : nil
    }

    /// Scrolls `scrollView` so what it draws at `from` is drawn at `to`, both
    /// in window coordinates. Only vertically unless `horizontally`: reflowed
    /// text moves along its line, and following it sideways would scroll a
    /// page that does not scroll that way.
    static func scroll(_ scrollView: NSScrollView, movingContentAt from: CGPoint, to: CGPoint, horizontally: Bool) {
        let clip = scrollView.contentView
        let content = clip.convert(from, from: nil)
        let pointer = clip.convert(to, from: nil)
        var origin = clip.bounds.origin
        origin.y += content.y - pointer.y
        if horizontally {
            origin.x += content.x - pointer.x
        }
        let target = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        guard abs(target.x - clip.bounds.origin.x) > 0.5 || abs(target.y - clip.bounds.origin.y) > 0.5 else { return }
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Text

    private static var heldTextAnchor: ReaderPinchTextAnchor?
    private static var heldTextGesture = -1

    /// The anchor this pinch holds in `textView`: taken on the first step
    /// that reaches it and kept for the rest, so every step goes back to the
    /// words the pinch started on rather than to wherever the last step left
    /// them. Nil unless a pinch now points into `textView`. Call before the
    /// font changes, while the layout is still the one being looked at.
    static func textAnchor(in textView: NSTextView) -> ReaderPinchTextAnchor? {
        guard point(in: textView) != nil else { return nil }
        if heldTextGesture == gesture, let held = heldTextAnchor, held.isAnchored(in: textView) {
            return held
        }
        guard let anchor = ReaderPinchTextAnchor(textView: textView) else { return nil }
        heldTextAnchor = anchor
        heldTextGesture = gesture
        return anchor
    }

    /// Whether `anchor` is the one the latest pinch holds, and that pinch
    /// ended under `settleTime` ago. A paragraph whose anchor a later step
    /// took elsewhere leaves the scrolling to that one.
    fileprivate static func isSettling(_ anchor: ReaderPinchTextAnchor) -> Bool {
        guard heldTextGesture == gesture, let held = heldTextAnchor, let view = anchor.textView,
              held.isAnchored(in: view) else { return false }
        return ProcessInfo.processInfo.systemUptime - notedAt < settleTime
    }

    // MARK: Web pages

    private static let webWorld = WKContentWorld.world(name: "ForeverLMPinchZoom")
    /// The page holding this pinch's anchor. The anchor is taken once per
    /// pinch and every step goes back to it: taken afresh at each step, the
    /// pixel WebKit rounds off each scroll added up to lines over one pinch.
    private static weak var anchoredWebView: WKWebView?
    private static var anchoredGesture = -1

    /// Sets a web reader's page zoom about the pinch point.
    ///
    /// A page reflows at a new zoom, so the anchor is the character under the
    /// pointer rather than a position: one script finds it before the pinch's
    /// first zoom and a second scrolls it back under the pointer after each.
    /// WebKit runs the scripts and the zoom between them in the order they are
    /// sent, and lays the page out at the new zoom before the next script.
    static func setPageZoom(_ zoom: CGFloat, of webView: WKWebView) {
        guard let point = point(in: webView) else {
            webView.pageZoom = zoom
            return
        }
        let fromTop = webView.isFlipped ? point.y : webView.bounds.height - point.y
        if anchoredWebView !== webView || anchoredGesture != gesture {
            anchoredWebView = webView
            anchoredGesture = gesture
            let before = webView.pageZoom * webView.magnification
            webView.evaluateJavaScript(
                "(\(captureScript))(\(point.x / before), \(fromTop / before));",
                in: nil,
                in: webWorld,
                completionHandler: nil
            )
        }
        webView.pageZoom = zoom
        webView.evaluateJavaScript(
            "(\(restoreScript))(\(fromTop / (zoom * webView.magnification)));",
            in: nil,
            in: webWorld,
            completionHandler: nil
        )
    }

    /// Holds the character under a viewport point, or the element there when
    /// the point is on no text, with where the point sat down its height.
    private static let captureScript = """
    function (x, y) {
        window.__foreverLMPinchAnchor = null;
        var target = null;
        var caret = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
        if (caret && caret.startContainer.nodeType === Node.TEXT_NODE && caret.startContainer.length > 0) {
            var text = caret.startContainer;
            var start = Math.min(caret.startOffset, text.length - 1);
            target = document.createRange();
            target.setStart(text, start);
            target.setEnd(text, start + 1);
        }
        var rect = target ? target.getBoundingClientRect() : null;
        if (!rect || rect.height <= 0) {
            target = document.elementFromPoint(x, y);
            rect = target ? target.getBoundingClientRect() : null;
        }
        if (!rect || rect.height <= 0) { return; }
        window.__foreverLMPinchAnchor = { target: target, fraction: (y - rect.top) / rect.height };
    }
    """

    /// Scrolls the held anchor back to viewport height `y`, in whichever box
    /// scrolls it: an inner scroller where the page has one, else the page.
    ///
    /// The scroll goes to an absolute offset. A relative `scrollBy` lands
    /// right inside the script and is then re-applied by WebKit's scrolling
    /// layer at the asked distance divided by the page zoom (measured
    /// 2026-09-29: 2,355 px asked at 1.4 settled 1,682 px down).
    private static let restoreScript = """
    function (y) {
        var anchor = window.__foreverLMPinchAnchor;
        if (!anchor) { return; }
        var node = anchor.target.startContainer || anchor.target;
        if (!node.isConnected) { return; }
        var rect = anchor.target.getBoundingClientRect();
        if (rect.height <= 0) { return; }
        var delta = rect.top + anchor.fraction * rect.height - y;
        if (Math.abs(delta) < 0.5) { return; }
        var element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
        for (; element && element !== document.body && element !== document.documentElement; element = element.parentElement) {
            var overflow = getComputedStyle(element).overflowY;
            if ((overflow === 'auto' || overflow === 'scroll' || overflow === 'overlay')
                && element.scrollHeight > element.clientHeight) {
                element.scrollTo({ top: element.scrollTop + delta, behavior: 'instant' });
                return;
            }
        }
        window.scrollTo({ top: window.scrollY + delta, behavior: 'instant' });
    }
    """
}

/// The character a pinch points at in a text view, held across the re-layout
/// a new font size brings so it can be put back under the pointer. Taken
/// through `ReaderPinchAnchor.textAnchor(in:)`.
@MainActor
struct ReaderPinchTextAnchor {
    fileprivate private(set) weak var textView: NSTextView?
    private let characterIndex: Int
    /// Where the pointer sat on that character's line: 0 at its top, 1 at its
    /// foot. Kept as a fraction because the line grows with the font.
    private let lineFraction: CGFloat
    private let windowPoint: CGPoint

    fileprivate init?(textView: NSTextView) {
        guard let point = ReaderPinchAnchor.point(in: textView),
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let storage = textView.textStorage, storage.length > 0 else { return nil }
        Self.fitContainer(of: textView)
        let origin = textView.textContainerOrigin
        let inContainer = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyphIndex = layoutManager.glyphIndex(for: inContainer, in: container)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        guard line.height > 0 else { return nil }
        self.textView = textView
        characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        lineFraction = (inContainer.y - line.minY) / line.height
        windowPoint = textView.convert(point, to: nil)
    }

    fileprivate func isAnchored(in view: NSTextView) -> Bool {
        textView === view
    }

    /// Whether the pinch this belongs to may still move the text.
    var isSettling: Bool {
        ReaderPinchAnchor.isSettling(self)
    }

    /// Scrolls the enclosing scroll view so the anchored character's line is
    /// back under the pointer. Safe to repeat: once it is there, nothing moves.
    func restore() {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let storage = textView.textStorage, characterIndex < storage.length,
              let scrollView = textView.enclosingScrollView else { return }
        Self.fitContainer(of: textView)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        layoutManager.ensureLayout(forGlyphRange: NSRange(location: glyphIndex, length: 1))
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        // A text view is only as tall as the text laid out so far, and one
        // that ends at the anchor would stop the scroll short of it.
        if let container = textView.textContainer {
            let below = NSRect(x: 0, y: line.minY, width: container.size.width, height: scrollView.contentView.bounds.height)
            layoutManager.ensureLayout(forBoundingRect: below, in: container)
        }
        let origin = textView.textContainerOrigin
        let spot = CGPoint(x: line.minX + origin.x, y: line.minY + origin.y + lineFraction * line.height)
        ReaderPinchAnchor.scroll(
            scrollView,
            movingContentAt: textView.convert(spot, to: nil),
            to: windowPoint,
            horizontally: false
        )
    }

    /// Lays the text out at the width the view draws it at. SwiftUI leaves a
    /// transcript paragraph's container at whatever width it last measured
    /// (one unbounded line among them), and the anchor must read the lines
    /// the reader sees.
    private static func fitContainer(of textView: NSTextView) {
        guard let container = textView.textContainer, container.widthTracksTextView else { return }
        let width = textView.bounds.width - 2 * textView.textContainerInset.width
        guard width > 0, abs(container.size.width - width) > 0.5 else { return }
        container.size = NSSize(width: width, height: container.size.height)
    }
}

/// The spot on a PDF page a pinch points at, held across a scale change so
/// it can be put back under the pointer. A page does not reflow, so the spot
/// is exact in both directions.
@MainActor
struct ReaderPinchPDFAnchor {
    private weak var pdfView: PDFView?
    private weak var page: PDFPage?
    private let pagePoint: CGPoint
    private let windowPoint: CGPoint

    /// Nil unless a pinch now points into `pdfView`. Call before the scale
    /// changes.
    init?(pdfView: PDFView) {
        guard let point = ReaderPinchAnchor.point(in: pdfView),
              let page = pdfView.page(for: point, nearest: true) else { return nil }
        self.pdfView = pdfView
        self.page = page
        pagePoint = pdfView.convert(point, to: page)
        windowPoint = pdfView.convert(point, to: nil)
    }

    func restore() {
        guard let pdfView, let page, let scrollView = pdfView.documentView?.enclosingScrollView else { return }
        pdfView.layoutDocumentView()
        let spot = pdfView.convert(pdfView.convert(pagePoint, from: page), to: nil)
        ReaderPinchAnchor.scroll(scrollView, movingContentAt: spot, to: windowPoint, horizontally: true)
    }
}

// MARK: - Reader keyboard shortcut routing

/// Routes window-level reader shortcuts (Cmd+F, Cmd+=/-/0) to the reader panel
/// currently visible in that window. Readers register while they display
/// content; the app-wide key monitor consults this before falling back to UI
/// zoom, and reader document views use the same geometry for pinch-to-zoom.
@MainActor
final class ReaderShortcutRouter {
    /// Every handler is optional, and a surface registers only what it owns.
    /// A Doc scales with the app's UI zoom, so it registers for Cmd+F alone and
    /// leaves Cmd+=/- to fall through to the app; a linked Google Doc has
    /// Google's own find on the page, so it registers zoom alone and leaves
    /// Cmd+F to fall through to the web view.
    struct Handlers {
        var find: (() -> Void)?
        var zoomIn: (() -> Void)?
        var zoomOut: (() -> Void)?
        var resetZoom: (() -> Void)?
        var magnify: ((CGFloat) -> Void)?
    }

    static let shared = ReaderShortcutRouter()

    private struct Entry {
        let id: UUID
        weak var window: NSWindow?
        weak var anchor: NSView?
        /// Asked at dispatch time, so an entry registered once per window keeps
        /// answering for whatever the surface displays now — including whether
        /// it currently supports zoom at all.
        var handlers: () -> Handlers
        /// False for a surface that finds only when focus or a click is in it
        /// (Chat's find): it is never the window's primary reader.
        var isPrimaryCandidate = true
    }

    private var entries: [Entry] = []

    /// The reader the last click in a window landed on. A click is the plainest
    /// "I'm working here" there is, and it does not always move keyboard focus:
    /// a reader surface that takes no first responder leaves focus in the
    /// sources list the source was opened from. The product owner (2026-09-25): "if i
    /// click on the reader window, even if the right side bar with sources is
    /// open, i want to be able to ctrl F". The claim holds until keyboard focus
    /// moves on from where that click left it, or another click lands elsewhere.
    private struct ClickClaim {
        weak var window: NSWindow?
        let entryID: UUID
        weak var responder: NSResponder?
        /// False until the click has been dispatched and its responder read.
        var responderSettled = false
    }

    private var clickClaim: ClickClaim?

    func register(
        id: UUID,
        window: NSWindow,
        anchor: NSView,
        isPrimaryCandidate: Bool = true,
        handlers: @escaping () -> Handlers
    ) {
        entries.removeAll { $0.window == nil || $0.anchor == nil }
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].window = window
            entries[index].anchor = anchor
            entries[index].handlers = handlers
            entries[index].isPrimaryCandidate = isPrimaryCandidate
        } else {
            entries.append(Entry(
                id: id, window: window, anchor: anchor, handlers: handlers, isPrimaryCandidate: isPrimaryCandidate
            ))
        }
    }

    func unregister(id: UUID) {
        entries.removeAll { $0.id == id || $0.window == nil || $0.anchor == nil }
    }

    /// First match wins so the primary reader takes precedence over a secondary
    /// reader registered later in the same window.
    func handlers(for window: NSWindow?) -> Handlers? {
        guard let window else { return nil }
        return entries.first { $0.window === window && $0.anchor != nil && $0.isPrimaryCandidate }?.handlers()
    }

    /// Cmd+F goes to the surface that has keyboard focus when one does — a Doc
    /// open beside a Reader searches the doc while the writer is typing in it —
    /// and otherwise to the window's primary reader, so a visible reader still
    /// owns the shortcut while focus sits in Chat or a sidebar. A focused
    /// surface with no find of its own claims the keystroke for the page under
    /// it rather than handing it to a neighbour: the answer is then nil and the
    /// event reaches the focused view.
    func findHandler(for window: NSWindow?) -> (() -> Void)? {
        (clickedHandlers(for: window) ?? focusedHandlers(for: window) ?? handlers(for: window))?.find
    }

    /// Records the reader under a mouse-down, or ends the claim when the click
    /// landed anywhere else in that window. Called before the click is
    /// dispatched; the responder it leaves behind is read once it has been.
    func noteMouseDown(at windowPoint: CGPoint, in window: NSWindow?) {
        guard let window else { return }
        guard let entryID = entry(at: windowPoint, in: window)?.id else {
            if clickClaim?.window === window { clickClaim = nil }
            return
        }
        clickClaim = ClickClaim(window: window, entryID: entryID)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.clickClaim?.window === window,
                  self.clickClaim?.entryID == entryID,
                  self.clickClaim?.responderSettled == false else { return }
            self.clickClaim?.responder = window.firstResponder
            self.clickClaim?.responderSettled = true
        }
    }

    /// Settles a pending click claim now rather than on the next main-queue
    /// turn. Tests use it; the app lets the dispatched click settle it.
    func settleClickClaim() {
        guard let window = clickClaim?.window, clickClaim?.responderSettled == false else { return }
        clickClaim?.responder = window.firstResponder
        clickClaim?.responderSettled = true
    }

    /// The reader the last click in `window` landed on, while keyboard focus
    /// is still where that click left it. Focus seen anywhere else ends the
    /// claim for good, so tabbing away and back does not revive it.
    func clickedHandlers(for window: NSWindow?) -> Handlers? {
        guard let window, let claim = clickClaim, claim.window === window else { return nil }
        guard !claim.responderSettled || claim.responder === window.firstResponder else {
            clickClaim = nil
            return nil
        }
        guard let entry = entries.first(where: { $0.id == claim.entryID && $0.window === window }),
              let anchor = entry.anchor, anchor.window === window else { return nil }
        return entry.handlers()
    }

    /// Ctrl+F reaches the clicked reader's find too, as it does inside a
    /// focused reader view — except where Ctrl+F is "move forward": an
    /// editable text view (a field's editor included) and a Browser tab's page.
    func clickedControlFindHandler(for window: NSWindow?) -> (() -> Void)? {
        guard let window, let find = clickedHandlers(for: window)?.find else { return nil }
        if let textView = window.firstResponder as? NSTextView, textView.isEditable { return nil }
        var view = window.firstResponder as? NSView
        while let current = view {
            if let webView = current as? ForeverLMWebView, !webView.findTakesControlF { return nil }
            view = current.superview
        }
        return find
    }

    /// The reader beneath a window-space point. Reader magnification is
    /// pointer-routed, so only a pinch over the document changes its zoom.
    func handlers(at windowPoint: CGPoint, in window: NSWindow?) -> Handlers? {
        entry(at: windowPoint, in: window)?.handlers()
    }

    /// Hands a pinch to the reader under the pointer, noting where it points
    /// so the reader zooms about that spot (`ReaderPinchAnchor`). False when
    /// no reader there takes pinches, and the view magnifies as it would.
    func magnify(with event: NSEvent, in window: NSWindow) -> Bool {
        let point = window.gesturePointerLocation
        guard let magnify = handlers(at: point, in: window)?.magnify else { return false }
        ReaderPinchAnchor.note(point, in: window, phase: event.phase)
        magnify(event.magnification)
        return true
    }

    private func entry(at windowPoint: CGPoint, in window: NSWindow?) -> Entry? {
        guard let window else { return nil }
        for entry in entries where entry.window === window {
            guard let anchor = entry.anchor, anchor.window === window else { continue }
            let anchorRect = anchor.convert(anchor.bounds, to: nil)
            if !anchorRect.isEmpty, anchorRect.contains(windowPoint) {
                return entry
            }
        }
        return nil
    }

    /// The reader containing the current first responder, if any. A visible
    /// reader no longer takes Cmd+=/- away from a neighboring sidebar or panel;
    /// document zoom wins only while keyboard focus is actually in the reader.
    func focusedHandlers(for window: NSWindow?) -> Handlers? {
        guard let window,
              let responderView = window.firstResponder as? NSView,
              responderView.window === window else { return nil }
        let responderRect = responderView.convert(responderView.bounds, to: nil)
        guard !responderRect.isEmpty else { return nil }
        let responderCenter = CGPoint(x: responderRect.midX, y: responderRect.midY)
        return handlers(at: responderCenter, in: window)
    }
}

/// Zero-size helper that registers reader find/zoom handlers for the window it
/// lands in. Attach as a `.background` of a reader while it displays content.
struct ReaderShortcutTarget: NSViewRepresentable {
    var find: (() -> Void)? = nil
    var zoomIn: (() -> Void)? = nil
    var zoomOut: (() -> Void)? = nil
    var resetZoom: (() -> Void)? = nil
    var magnify: ((CGFloat) -> Void)? = nil
    /// False for a surface that takes ⌘F only while focus or the last click
    /// is in it, never as the window's primary reader (Chat's find).
    var isPrimaryCandidate = true

    private var currentHandlers: ReaderShortcutRouter.Handlers {
        .init(find: find, zoomIn: zoomIn, zoomOut: zoomOut, resetZoom: resetZoom, magnify: magnify)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnchorView {
        let coordinator = context.coordinator
        coordinator.handlers = currentHandlers
        let view = AnchorView(frame: .zero)
        let isPrimaryCandidate = isPrimaryCandidate
        view.onWindowChange = { [weak view] window in
            if let window, let view {
                // Registered once per window; the router asks the coordinator
                // at dispatch time so the entry stays valid as the displayed
                // article changes.
                ReaderShortcutRouter.shared.register(
                    id: coordinator.id,
                    window: window,
                    anchor: view,
                    isPrimaryCandidate: isPrimaryCandidate,
                    handlers: { [weak coordinator] in
                        coordinator?.handlers ?? .init()
                    }
                )
            } else {
                ReaderShortcutRouter.shared.unregister(id: coordinator.id)
            }
        }
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        context.coordinator.handlers = currentHandlers
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: Coordinator) {
        ReaderShortcutRouter.shared.unregister(id: coordinator.id)
        nsView.onWindowChange = nil
    }

    @MainActor
    final class Coordinator {
        let id = UUID()
        var handlers = ReaderShortcutRouter.Handlers()
    }

    final class AnchorView: NSView {
        var onWindowChange: (@MainActor (NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}

/// Routes Cmd+F to the sources list's search field when keyboard focus sits
/// inside the sources column, and Shift+Cmd+F to it unconditionally. The
/// sidebar registers an anchor view spanning its area; the app-wide key
/// monitor asks whether the window's first responder falls inside that area
/// before letting the reader claim Cmd+F.
@MainActor
final class SourceSearchShortcutRouter {
    static let shared = SourceSearchShortcutRouter()

    private struct Entry {
        let id: UUID
        weak var window: NSWindow?
        weak var anchor: NSView?
        var reveal: () -> Void
    }

    private var entries: [Entry] = []

    /// Clicking a source-type tab doesn't move keyboard focus into the sources
    /// column, but it is an unambiguous "I'm working in sources" signal. The
    /// tab bar reports the click here; Cmd+F honors the claim until keyboard
    /// focus moves somewhere else (a changed first responder voids it).
    private weak var claimedWindow: NSWindow?
    private weak var claimedResponder: NSResponder?

    func noteSourcesInteraction() {
        // A click inside a popover lands in the popover's child window; walk up
        // to the window that actually hosts a registered sidebar.
        var window = NSApp.keyWindow
        while let current = window,
              !entries.contains(where: { $0.window === current && $0.anchor != nil }),
              let parent = current.parent {
            window = parent
        }
        claimedWindow = window
        claimedResponder = window?.firstResponder
    }

    /// A click outside the sources column ends a tab click's claim, even when
    /// it leaves keyboard focus where it was: clicking back into a reader that
    /// already had focus did not, and Cmd+F kept opening the sources search.
    /// Column, not rect, so the tab bar hung in the titlebar band counts as
    /// inside. A click in another window (a popover) leaves the claim alone.
    func noteMouseDown(at windowPoint: CGPoint, in window: NSWindow?) {
        guard let window, claimedWindow === window else { return }
        let insideSources = entries.contains { entry in
            guard entry.window === window, let anchor = entry.anchor, anchor.window === window else { return false }
            let anchorRect = anchor.convert(anchor.bounds, to: nil)
            return !anchorRect.isEmpty && windowPoint.x >= anchorRect.minX && windowPoint.x <= anchorRect.maxX
        }
        if !insideSources {
            claimedWindow = nil
            claimedResponder = nil
        }
    }

    func register(id: UUID, window: NSWindow, anchor: NSView, reveal: @escaping () -> Void) {
        entries.removeAll { $0.window == nil || $0.anchor == nil }
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].window = window
            entries[index].anchor = anchor
            entries[index].reveal = reveal
        } else {
            entries.append(Entry(id: id, window: window, anchor: anchor, reveal: reveal))
        }
    }

    func unregister(id: UUID) {
        entries.removeAll { $0.id == id || $0.window == nil }
    }

    /// The sidebar registered in `window`, regardless of focus (Shift+Cmd+F).
    func handler(for window: NSWindow?) -> (() -> Void)? {
        guard let window else { return nil }
        return entries.first { $0.window === window && $0.anchor != nil }?.reveal
    }

    /// The sidebar registered in `window`, only when the window's first
    /// responder currently sits inside the sidebar's on-screen area (Cmd+F),
    /// or when a source-type tab click claimed the shortcut and keyboard focus
    /// hasn't moved since.
    func focusedHandler(for window: NSWindow?) -> (() -> Void)? {
        guard let window else { return nil }
        for entry in entries where entry.window === window {
            guard let anchor = entry.anchor, anchor.window === window else { continue }
            if firstResponderIsInside(anchor: anchor, window: window) {
                return entry.reveal
            }
        }
        if claimedWindow === window, claimedResponder === window.firstResponder {
            return handler(for: window)
        }
        return nil
    }

    /// Geometry rather than view ancestry: SwiftUI hosts the sidebar's List and
    /// this anchor as sibling subtrees, so descendant checks can't relate them.
    /// A responder counts as "inside" when its horizontal center falls within
    /// the anchor's column and their window rects overlap (a table's document
    /// view can be taller than the window, so pure point containment fails).
    private func firstResponderIsInside(anchor: NSView, window: NSWindow) -> Bool {
        guard let responderView = window.firstResponder as? NSView,
              responderView.window === window else { return false }
        let anchorRect = anchor.convert(anchor.bounds, to: nil)
        let responderRect = responderView.convert(responderView.bounds, to: nil)
        guard !anchorRect.isEmpty, !responderRect.isEmpty else { return false }
        return responderRect.midX >= anchorRect.minX
            && responderRect.midX <= anchorRect.maxX
            && responderRect.intersects(anchorRect)
    }
}

/// Anchor that registers the sources sidebar with `SourceSearchShortcutRouter`.
/// Attach as a `.background` of the sidebar so the view spans its full area —
/// the router uses that frame to decide whether keyboard focus is in the column.
struct SourceSearchShortcutTarget: NSViewRepresentable {
    var reveal: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ReaderShortcutTarget.AnchorView {
        let coordinator = context.coordinator
        coordinator.reveal = reveal
        let view = ReaderShortcutTarget.AnchorView(frame: .zero)
        view.onWindowChange = { [weak view, weak coordinator] window in
            guard let coordinator else { return }
            if let window, let view {
                SourceSearchShortcutRouter.shared.register(
                    id: coordinator.id,
                    window: window,
                    anchor: view,
                    reveal: { [weak coordinator] in coordinator?.reveal() }
                )
            } else {
                SourceSearchShortcutRouter.shared.unregister(id: coordinator.id)
            }
        }
        return view
    }

    func updateNSView(_ nsView: ReaderShortcutTarget.AnchorView, context: Context) {
        context.coordinator.reveal = reveal
    }

    static func dismantleNSView(_ nsView: ReaderShortcutTarget.AnchorView, coordinator: Coordinator) {
        SourceSearchShortcutRouter.shared.unregister(id: coordinator.id)
        nsView.onWindowChange = nil
    }

    @MainActor
    final class Coordinator {
        let id = UUID()
        var reveal: () -> Void = {}
    }
}

// MARK: - Chat zoom routing

/// Marks a chat panel's on-screen area so a trackpad pinch can be told apart
/// from one over a reader or the rest of the window, and carries that panel's
/// own zoom. Magnification follows the pointer, not keyboard focus: the
/// app-wide monitor asks this for the panel under the pointer and moves only
/// that panel's offset. Every other chat — in the same window, or in the one
/// on the other display — keeps the size it had, and so do the panels beside
/// chat, Sources above all. The product owner (2026-09-10), with a chat window on each
/// of two screens: "I want only to zoom in on that one, not the other one on
/// the other display."
@MainActor
final class ChatZoomShortcutRouter {
    /// One chat panel's zoom, asked at dispatch time like a reader's handlers
    /// so the entry keeps answering for whatever the panel shows now.
    struct Handlers {
        /// Moves the panel one step; false at the end of the range, so the
        /// pinch stops accumulating.
        var step: (Int) -> Bool = { _ in false }
        /// Drops the panel back onto the app-wide step.
        var reset: () -> Void = {}
    }

    static let shared = ChatZoomShortcutRouter()

    private struct Entry {
        let id: UUID
        weak var window: NSWindow?
        weak var anchor: NSView?
        var handlers: () -> Handlers
    }

    private var entries: [Entry] = []

    func register(id: UUID, window: NSWindow, anchor: NSView, handlers: @escaping () -> Handlers = { .init() }) {
        entries.removeAll { $0.window == nil || $0.anchor == nil }
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].window = window
            entries[index].anchor = anchor
            entries[index].handlers = handlers
        } else {
            entries.append(Entry(id: id, window: window, anchor: anchor, handlers: handlers))
        }
    }

    func unregister(id: UUID) {
        entries.removeAll { $0.id == id || $0.window == nil || $0.anchor == nil }
    }

    /// Whether a window-space point falls inside a registered chat panel.
    func contains(windowPoint: CGPoint, in window: NSWindow?) -> Bool {
        handlers(at: windowPoint, in: window) != nil
    }

    /// The chat panel beneath a window-space point, or nil when the pointer is
    /// over none. A pinch moves the zoom of this panel alone.
    func handlers(at windowPoint: CGPoint, in window: NSWindow?) -> Handlers? {
        guard let window else { return nil }
        for entry in entries where entry.window === window {
            guard let anchor = entry.anchor, anchor.window === window else { continue }
            let anchorRect = anchor.convert(anchor.bounds, to: nil)
            if !anchorRect.isEmpty, anchorRect.contains(windowPoint) {
                return entry.handlers()
            }
        }
        return nil
    }

    /// Resets every chat panel in one window — ⌘0 there — leaving the chats in
    /// other windows at whatever they were pinched to.
    func resetAll(in window: NSWindow?) {
        guard let window else { return }
        for entry in entries where entry.window === window {
            guard let anchor = entry.anchor, anchor.window === window else { continue }
            entry.handlers().reset()
        }
    }
}

/// Zero-size helper that registers a chat panel's area and its zoom for pinch
/// routing. Attach as a `.background` spanning the panel.
struct ChatZoomShortcutTarget: NSViewRepresentable {
    var step: (Int) -> Bool = { _ in false }
    var reset: () -> Void = {}

    private var currentHandlers: ChatZoomShortcutRouter.Handlers {
        .init(step: step, reset: reset)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ReaderShortcutTarget.AnchorView {
        let coordinator = context.coordinator
        coordinator.handlers = currentHandlers
        let view = ReaderShortcutTarget.AnchorView(frame: .zero)
        view.onWindowChange = { [weak view] window in
            if let window, let view {
                ChatZoomShortcutRouter.shared.register(
                    id: coordinator.id,
                    window: window,
                    anchor: view,
                    handlers: { [weak coordinator] in
                        coordinator?.handlers ?? .init()
                    }
                )
            } else {
                ChatZoomShortcutRouter.shared.unregister(id: coordinator.id)
            }
        }
        return view
    }

    func updateNSView(_ nsView: ReaderShortcutTarget.AnchorView, context: Context) {
        context.coordinator.handlers = currentHandlers
    }

    static func dismantleNSView(_ nsView: ReaderShortcutTarget.AnchorView, coordinator: Coordinator) {
        ChatZoomShortcutRouter.shared.unregister(id: coordinator.id)
        nsView.onWindowChange = nil
    }

    @MainActor
    final class Coordinator {
        let id = UUID()
        var handlers = ChatZoomShortcutRouter.Handlers()
    }
}

enum ReaderColorTheme: String {
    case light
    case system
    /// A page pinned dark. The raw value matches the
    /// `html[data-flm-reader-theme="dark"]` block in `EPUBReaderStyles`, which is
    /// where every reader whose page ForeverLM composes gets its dark tokens.
    case dark

    var cssColorScheme: String {
        switch self {
        case .light: "light"
        case .system: "light dark"
        case .dark: "dark"
        }
    }

    /// Fixed-light readers opt into Aqua; system-themed readers inherit the app.
    /// A fixed-dark reader has to say so too, since a publisher page's
    /// `prefers-color-scheme` resolves against the web view's appearance rather
    /// than against any attribute we inject.
    var nsAppearanceOverride: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .system: nil
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// SwiftUI readers likewise inherit the app unless they need a fixed page.
    var colorSchemeOverride: ColorScheme? {
        switch self {
        case .light: .light
        case .system: nil
        case .dark: .dark
        }
    }

    /// The colour a reader has to paint for itself behind a transparent page.
    ///
    /// The composed web readers run with `drawsBackground` off and a page whose
    /// `html` is transparent, so the pane behind them shows through. That is
    /// fine for the themes that follow the app — but a page pinned dark while
    /// the app around it is light would put light text on a light canvas.
    var opaqueReaderCanvas: NSColor? {
        switch self {
        case .light, .system: nil
        case .dark: NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        }
    }
}

final class FindablePDFView: PDFView {
    weak var findState: ReaderFindState?
    var zoomInAction: (() -> Void)?
    var zoomOutAction: (() -> Void)?
    var resetZoomAction: (() -> Void)?
    /// The pointer for a mark on the page that a click opens — the
    /// walkthrough's outline, a saved highlight — so the click is invited
    /// rather than discovered; nil for a mark that does nothing.
    var cursorForAnnotation: ((PDFAnnotation) -> NSCursor?)?
    /// The link annotation under the pointer, and nil once it leaves one or
    /// the link is clicked.
    var linkHoverChanged: ((PDFAnnotation?) -> Void)?
    /// A click on a link inside the document; true when the handler took it,
    /// so PDFKit does not also jump to where the link lands.
    var linkClicked: ((PDFAnnotation) -> Bool)?
    /// The click `linkClicked` took, so its drag and release stay away from
    /// PDFKit too.
    private var swallowingLinkClick = false
    /// ⌥-press on a page: the Reader's Clip tool takes it to draw a box
    /// (`ReaderClipTool`), and answers the view the rest of the drag goes to;
    /// nil leaves the press to PDFKit.
    var optionDragStarted: ((NSEvent) -> NSView?)?
    private var forwardingPointer: NSView?
    private var linkHoverTrackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let linkHoverTrackingArea {
            removeTrackingArea(linkHoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        linkHoverTrackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateCursor(for: event)
        linkHoverChanged?(linkAnnotation(under: event))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        linkHoverChanged?(nil)
    }

    private func linkAnnotation(under event: NSEvent) -> PDFAnnotation? {
        guard linkHoverChanged != nil || linkClicked != nil else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false),
              let annotation = page.annotation(at: convert(point, to: page)),
              annotation.type == "Link" else { return nil }
        return annotation
    }

    /// PDFKit performs cursor updates separately from mouse-move delivery. If
    /// only `mouseMoved` sets the hand, that later update immediately restores
    /// the arrow even though the pointer is still over the link.
    override func cursorUpdate(with event: NSEvent) {
        updateCursor(for: event)
    }

    private func updateCursor(for event: NSEvent) {
        let area = areaOfInterest(forMouse: event)
        if area.contains(.linkArea) || isOverQuestionMarker(event) {
            NSCursor.pointingHand.set()
        } else if let cursor = annotationCursor(under: event) {
            cursor.set()
        } else {
            setCursorFor(area)
        }
    }

    /// A reading question's marker is a view laid over the page
    /// (`ReaderQuestionLayer`), not an annotation, and a click opens it.
    private func isOverQuestionMarker(_ event: NSEvent) -> Bool {
        guard let superview else { return false }
        return hitTest(superview.convert(event.locationInWindow, from: nil)) is ReaderQuestionMarkerView
    }

    /// The cursor `cursorForAnnotation` gives the mark under the pointer.
    func annotationCursor(under event: NSEvent) -> NSCursor? {
        guard let cursorForAnnotation else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false),
              let annotation = page.annotation(at: convert(point, to: page)) else { return nil }
        return cursorForAnnotation(annotation)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 1, event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),
           let linkClicked, let link = linkAnnotation(under: event), linkClicked(link) {
            swallowingLinkClick = true
            return
        }
        if event.clickCount == 1, event.modifierFlags.contains(.option),
           event.modifierFlags.isDisjoint(with: [.command, .control, .shift]),
           let target = optionDragStarted?(event) {
            forwardingPointer = target
            return
        }
        linkHoverChanged?(nil)
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let forwardingPointer { return forwardingPointer.mouseDragged(with: event) }
        if swallowingLinkClick { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let target = forwardingPointer {
            forwardingPointer = nil
            return target.mouseUp(with: event)
        }
        if swallowingLinkClick {
            swallowingLinkClick = false
            return
        }
        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.isReaderFindShortcut {
            findState?.show()
            return
        }
        if let shortcut = event.readerZoomShortcut {
            switch shortcut {
            case .zoomIn: zoomInAction?()
            case .zoomOut: zoomOutAction?()
            case .reset: resetZoomAction?()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func magnify(with event: NSEvent) {
        guard let window, ReaderShortcutRouter.shared.magnify(with: event, in: window) else {
            super.magnify(with: event)
            return
        }
    }
}

class FindableTextView: NSTextView {
    weak var findState: ReaderFindState?
    var zoomInAction: (() -> Void)?
    var zoomOutAction: (() -> Void)?
    var resetZoomAction: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.isReaderFindShortcut {
            findState?.show()
            return
        }
        if let shortcut = event.readerZoomShortcut {
            switch shortcut {
            case .zoomIn: zoomInAction?()
            case .zoomOut: zoomOutAction?()
            case .reset: resetZoomAction?()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func magnify(with event: NSEvent) {
        guard let window, ReaderShortcutRouter.shared.magnify(with: event, in: window) else {
            super.magnify(with: event)
            return
        }
    }
}

/// ForeverLM's one web view. A Browser tab, a source in the reader, an EPUB
/// chapter and a linked Doc or Site are all this class, so the click that
/// brings a window forward, Cmd+F, keyboard zoom, pinch and the link menu work
/// the same on every page. Three subclasses used to split this between them,
/// and a fix to one — first-mouse, a link command, a menu target — kept
/// missing the other two.
///
/// What differs is only what the owner hands in: a reader sets its commands
/// and link handlers, a linked page its source-card actions, and a Browser tab
/// leaves both unset and keeps WebKit's own menu.
final class ForeverLMWebView: WKWebView {
    weak var findState: ReaderFindState?
    /// Whether Ctrl+F opens the find bar as well as Cmd+F. A Browser tab turns
    /// it off: its pages have text fields where Ctrl+F is "move forward".
    var findTakesControlF = true
    var canTextToSpeech = false
    var textToSpeechAction: (() -> Void)?
    var explainSelectionAction: (() -> Void)?
    var openInSafariAction: (() -> Void)?
    var markPaywalledAction: (() -> Void)?
    var zoomInAction: (() -> Void)?
    var zoomOutAction: (() -> Void)?
    var resetZoomAction: (() -> Void)?

    /// A live page is an interactive surface, not a passive preview. Without
    /// first-mouse acceptance, macOS spends the click that reactivates this
    /// window (or moves focus back from Chat) on focus alone, so links and page
    /// controls appear dead until the learner clicks again.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// No Apple Intelligence badge on a reader's selection; a Browser tab keeps
    /// WebKit's answer (`SharedWebKit.allowsWritingToolsAffordance(in:)`).
    @objc(allowsWritingToolsAffordance)
    var allowsWritingToolsAffordance: Bool { SharedWebKit.allowsWritingToolsAffordance(in: self) }

    override func keyDown(with event: NSEvent) {
        let isFind = findTakesControlF ? event.isReaderFindShortcut : event.isCommandFindShortcut
        if isFind, let findState {
            findState.show()
            return
        }
        if let shortcut = event.readerZoomShortcut {
            let action: (() -> Void)?
            switch shortcut {
            case .zoomIn: action = zoomInAction
            case .zoomOut: action = zoomOutAction
            case .reset: action = resetZoomAction
            }
            if let action {
                action()
                return
            }
        }
        super.keyDown(with: event)
    }

    /// A pinch over a reader or a linked page is that document's zoom, routed
    /// by pointer position so a pinch over a neighbouring panel never scales
    /// it. Where nothing claims the point — a Browser tab — WebKit magnifies.
    override func magnify(with event: NSEvent) {
        guard let window, ReaderShortcutRouter.shared.magnify(with: event, in: window) else {
            super.magnify(with: event)
            return
        }
    }

    // MARK: Link menu

    /// What a source card's link commands do on a linked page, handed in by
    /// the view that owns the page. Set, the link menu speaks in sources;
    /// unset, it uses the reader's link handlers below.
    struct SourceLinkActions {
        let openBeside: (ChatSourceLink) -> Void
        let openInNewWindow: (ChatSourceLink) -> Void
        let windowTargets: @MainActor () -> [LinkedDocWebView.SourceWindowTarget]
        /// The source a web address names when the library answered for it
        /// on this page (`Coordinator.webSourceLink(for:)`); nil otherwise.
        var webSourceLink: (URL) -> ChatSourceLink? = { _ in nil }
    }

    var sourceLinkActions: SourceLinkActions?

    /// Handlers for WebKit's link commands. A view that leaves these nil keeps
    /// WebKit's own (largely inert) versions.
    var openLinkAction: ((URL) -> Void)?
    /// Offered as "Open Link in New Tab" beside "Open Link" when set; WebKit
    /// has no such command of its own.
    var openLinkInNewTabAction: ((URL) -> Void)?
    var openLinkExternallyAction: ((URL) -> Void)?
    var downloadLinkAction: ((URL) -> Void)?

    /// The link the pointer was over when the open menu was raised, and whether
    /// the page had a selection, both reported by `ReaderContextLinkTracking`.
    private var contextLink: (url: URL, reportedAt: TimeInterval)?
    private var contextHasSelection = false
    /// On a linked page: the source card the pointer was over, or whether it
    /// was an ordinary link.
    private var contextSourceLink: (link: ChatSourceLink, reportedAt: TimeInterval)?
    private var contextIsOrdinaryLink = false
    /// `NSMenuItem.target` is weak, so the closures behind the adopted link
    /// commands have to be held — until the *next* menu opens, not until this
    /// one closes. AppKit sends the chosen item's action after `didCloseMenu`,
    /// so a target released there is gone by the time the action is sent and
    /// the item does nothing: build 93's "Open in Window 1" on a Site's source
    /// card left the other window on what it was reading. (Measured with a
    /// popUpContextMenu harness on 2026-09-10: didCloseMenu, then the action
    /// 0.6 ms later, both before popUpContextMenu returns.) The reader's own
    /// items survive because they target the view itself.
    private var linkMenuTargets: [MenuActionTarget] = []

    /// Drop every hook the reader handed this view, on the way into
    /// `ReaderWebViewPark`. A parked page outlives the reader that loaded it, and
    /// these closures would otherwise keep that reader's whole torn-down view
    /// graph alive alongside it. Whoever adopts the page installs its own.
    func prepareForParking() {
        findState = nil
        canTextToSpeech = false
        textToSpeechAction = nil
        explainSelectionAction = nil
        openInSafariAction = nil
        markPaywalledAction = nil
        zoomInAction = nil
        zoomOutAction = nil
        resetZoomAction = nil
        openLinkAction = nil
        openLinkInNewTabAction = nil
        openLinkExternallyAction = nil
        downloadLinkAction = nil
        sourceLinkActions = nil
        linkMenuTargets.removeAll()
        contextLink = nil
        contextSourceLink = nil
        contextIsOrdinaryLink = false
    }

    /// Records the destination the web process just reported for a right-click.
    /// Also drives whether selection-only reader commands are offered.
    func noteContextLink(url: URL?, hasSelection: Bool = false) {
        contextHasSelection = hasSelection
        contextLink = url.map { ($0, ProcessInfo.processInfo.systemUptime) }
        if let url, let link = ChatMarkdownView.sourceLink(from: url) ?? sourceLinkActions?.webSourceLink(url) {
            contextSourceLink = (link, ProcessInfo.processInfo.systemUptime)
            contextIsOrdinaryLink = false
        } else {
            contextSourceLink = nil
            contextIsOrdinaryLink = url != nil
        }
    }

    /// WKWebView never consults `menu(for:)` — WebKit builds the context menu in
    /// the web process and offers it here — so this is the only place reader
    /// commands can be added, and the only place WebKit's own link commands can
    /// be replaced with ones the owner can actually carry out.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        linkMenuTargets.removeAll()
        if sourceLinkActions != nil {
            adoptSourceLinkItems(in: menu)
        } else {
            adoptLinkItems(in: menu)
        }
        insertReaderItems(into: menu)
    }

    /// Deliberately leaves `linkMenuTargets` alone: the chosen item's action
    /// has not been sent yet when this runs.
    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        contextLink = nil
        contextSourceLink = nil
        contextIsOrdinaryLink = false
    }

    /// WebKit answers "Open Link", "Open Link in New Window" and "Download
    /// Linked File" back in the web process, where the reader's navigation and
    /// download handling is out of reach: the download never becomes a
    /// `WKDownload` at all without WebKit SPI, and the new window is one the
    /// reader has no way to open. Point them at the reader instead, but only
    /// when the click that raised this menu reported a link — otherwise leave
    /// WebKit's items exactly as they came.
    private func adoptLinkItems(in menu: NSMenu) {
        guard let contextLink,
              ProcessInfo.processInfo.systemUptime - contextLink.reportedAt < 2 else { return }
        let url = contextLink.url

        for item in menu.items {
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierOpenLink":
                guard let action = openLinkAction else { continue }
                retarget(item) { action(url) }
            case "WKMenuItemIdentifierOpenLinkInNewWindow":
                guard let action = openLinkExternallyAction else { continue }
                // The reader has no second reader window to open a bare URL in;
                // name the destination it does have.
                item.title = "Open Link in Browser"
                retarget(item) { action(url) }
            case "WKMenuItemIdentifierDownloadLinkedFile":
                guard let action = downloadLinkAction else { continue }
                retarget(item) { action(url) }
            default:
                continue
            }
        }

        if let action = openLinkInNewTabAction {
            let item = NSMenuItem(title: "Open Link in New Tab", action: nil, keyEquivalent: "")
            retarget(item) { action(url) }
            let openLinkIndex = menu.items.firstIndex {
                $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink"
            }
            menu.insertItem(item, at: openLinkIndex.map { $0 + 1 } ?? 0)
        }
    }

    /// What WebKit's link command becomes for the link the pointer was over
    /// on a linked page. On a source card the commands are the app's — Reader
    /// beside the site, a window of its own — and "Download Linked File" goes,
    /// since there is no file at a foreverlm:// address. An ordinary link
    /// keeps WebKit's commands; its "new window" already lands in the default
    /// browser (`createWebViewWith`), so the item says so.
    enum LinkMenuDisposition: Equatable {
        case keep, openInReader, openInNewWindow, openInBrowser, remove
    }

    nonisolated static func linkMenuDisposition(identifier: String?, isSourceLink: Bool) -> LinkMenuDisposition {
        switch identifier {
        case "WKMenuItemIdentifierOpenLink": return isSourceLink ? .openInReader : .keep
        case "WKMenuItemIdentifierOpenLinkInNewWindow": return isSourceLink ? .openInNewWindow : .openInBrowser
        case "WKMenuItemIdentifierDownloadLinkedFile": return isSourceLink ? .remove : .keep
        default: return .keep
        }
    }

    private func adoptSourceLinkItems(in menu: NSMenu) {
        let sourceLink: ChatSourceLink?
        if let contextSourceLink, ProcessInfo.processInfo.systemUptime - contextSourceLink.reportedAt < 2 {
            sourceLink = contextSourceLink.link
        } else if contextIsOrdinaryLink {
            sourceLink = nil
        } else {
            return
        }
        for item in menu.items {
            switch Self.linkMenuDisposition(identifier: item.identifier?.rawValue, isSourceLink: sourceLink != nil) {
            case .keep:
                continue
            case .remove:
                menu.removeItem(item)
            case .openInBrowser:
                item.title = "Open Link in Browser"
            case .openInReader:
                guard let sourceLink, let actions = sourceLinkActions else { continue }
                item.title = "Open in Reader"
                retarget(item) { actions.openBeside(sourceLink) }
            case .openInNewWindow:
                guard let sourceLink, let actions = sourceLinkActions else { continue }
                item.title = "Open in New Window"
                retarget(item) { actions.openInNewWindow(sourceLink) }
                let index = menu.index(of: item)
                for (offset, target) in actions.windowTargets().enumerated() {
                    let other = NSMenuItem(title: "Open in \(target.label)", action: #selector(MenuActionTarget.fire), keyEquivalent: "")
                    let handler = MenuActionTarget { target.open(sourceLink) }
                    linkMenuTargets.append(handler)
                    other.target = handler
                    menu.insertItem(other, at: index + 1 + offset)
                }
            }
        }
    }

    private func retarget(_ item: NSMenuItem, with run: @escaping () -> Void) {
        let target = MenuActionTarget(run: run)
        linkMenuTargets.append(target)
        item.target = target
        item.action = #selector(MenuActionTarget.fire)
        item.representedObject = nil
    }

    private func insertReaderItems(into menu: NSMenu) {
        var insertionIndex = 0

        func insert(_ title: String, symbol: String, action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            item.target = self
            menu.insertItem(item, at: insertionIndex)
            insertionIndex += 1
        }

        if explainSelectionAction != nil, contextHasSelection {
            insert("Chat About Selection", symbol: "text.bubble", action: #selector(explainSelectionFromMenu))
        }
        if markPaywalledAction != nil {
            insert("Mark Paper as Paywalled", symbol: "lock.doc", action: #selector(markPaywalledFromMenu))
        }
        if canTextToSpeech {
            insert("Text to Speech", symbol: "speaker.wave.2", action: #selector(textToSpeechFromMenu))
        }
        if openInSafariAction != nil {
            insert("Open in Safari", symbol: "safari", action: #selector(openInSafariFromMenu))
        }

        guard insertionIndex > 0, menu.items.count > insertionIndex else { return }
        menu.insertItem(.separator(), at: insertionIndex)
    }

    @objc private func explainSelectionFromMenu() {
        explainSelectionAction?()
    }

    @objc private func markPaywalledFromMenu() {
        markPaywalledAction?()
    }

    @objc private func textToSpeechFromMenu() {
        textToSpeechAction?()
    }

    @objc private func openInSafariFromMenu() {
        openInSafariAction?()
    }
}

/// Menu items hold their target weakly, so an adopted WebKit item needs an
/// owner the web view keeps alive for as long as the menu is on screen.
final class MenuActionTarget: NSObject {
    private let run: () -> Void

    init(run: @escaping () -> Void) {
        self.run = run
    }

    @objc func fire() {
        run()
    }
}

@MainActor
enum ReaderFindPerformer {
    static func performTextFind(
        in textView: NSTextView,
        state: ReaderFindState,
        query: String,
        backwards: Bool,
        programmaticSelection: ReaderProgrammaticSelection? = nil
    ) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            state.statusText = ""
            return
        }

        let haystack = textView.string as NSString
        guard haystack.length > 0 else {
            state.statusText = "No matches"
            return
        }

        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let allMatches = textMatches(in: haystack, query: needle, options: options)
        guard !allMatches.isEmpty else {
            state.statusText = "No matches"
            return
        }

        let selectedRange = textView.selectedRange()
        let searchStart = backwards ? selectedRange.location : selectedRange.location + selectedRange.length
        let selectedIndex: Int
        if backwards {
            selectedIndex = allMatches.lastIndex { $0.location < searchStart } ?? allMatches.count - 1
        } else {
            selectedIndex = allMatches.firstIndex { $0.location >= searchStart } ?? 0
        }

        let match = allMatches[selectedIndex]
        let applySelection = {
            textView.setSelectedRange(match)
            textView.scrollRangeToVisible(match)
            textView.window?.makeFirstResponder(textView)
        }
        if let programmaticSelection {
            programmaticSelection.whileActive(applySelection)
        } else {
            applySelection()
        }
        state.registerMatchClearing { [weak textView] in
            guard let textView, textView.selectedRange() == match else { return }
            let collapse = {
                textView.setSelectedRange(NSRange(location: match.location, length: 0))
            }
            if let programmaticSelection {
                programmaticSelection.whileActive(collapse)
            } else {
                collapse()
            }
        }
        state.statusText = "\(selectedIndex + 1) of \(allMatches.count)"
    }

    static func performPDFFind(
        in pdfView: PDFView,
        state: ReaderFindState,
        query: String,
        backwards: Bool,
        lastQuery: inout String,
        lastIndex: inout Int,
        cachedMatches: inout [PDFSelection],
        programmaticSelection: ReaderProgrammaticSelection? = nil
    ) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            cachedMatches = []
            lastQuery = ""
            lastIndex = -1
            pdfView.currentSelection = nil
            state.statusText = ""
            return
        }

        guard let document = pdfView.document else {
            state.statusText = "No matches"
            return
        }

        if needle != lastQuery {
            cachedMatches = document.findString(needle, withOptions: [.caseInsensitive, .diacriticInsensitive])
            lastQuery = needle
            lastIndex = backwards ? cachedMatches.count : -1
        }

        guard !cachedMatches.isEmpty else {
            lastIndex = -1
            pdfView.currentSelection = nil
            state.statusText = "No matches"
            return
        }

        if backwards {
            lastIndex = lastIndex <= 0 ? cachedMatches.count - 1 : lastIndex - 1
        } else {
            lastIndex = (lastIndex + 1) % cachedMatches.count
        }

        let selection = cachedMatches[lastIndex]
        let applySelection = {
            pdfView.currentSelection = selection
            pdfView.go(to: selection)
            pdfView.window?.makeFirstResponder(pdfView)
        }
        if let programmaticSelection {
            programmaticSelection.whileActive(applySelection)
        } else {
            applySelection()
        }
        state.registerMatchClearing { [weak pdfView] in
            guard let pdfView, let current = pdfView.currentSelection,
                  current.string == selection.string,
                  current.pages.first === selection.pages.first else { return }
            pdfView.currentSelection = nil
        }
        state.statusText = "\(lastIndex + 1) of \(cachedMatches.count)"
    }

    static func performWebFind(
        in webView: WKWebView,
        state: ReaderFindState,
        query: String,
        backwards: Bool
    ) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            state.statusText = ""
            return
        }

        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true

        webView.find(needle, configuration: configuration) { [weak webView] result in
            state.statusText = result.matchFound ? "" : "No matches"
            guard result.matchFound, let webView else { return }
            state.registerMatchClearing { [weak webView] in
                guard let webView else { return }
                webView.evaluateJavaScript(clearMatchSelectionScript(matching: needle))
                hideFindMatch(in: webView)
            }
        }
    }

    /// WebKit also paints its match in the find colour, a yellow box that is
    /// neither the selection nor anything a page script can reach, and the box
    /// stays after the selection goes (measured 2026-10-10 on macOS 27 with
    /// the configuration above). `_hideFindUI` takes it away and leaves any
    /// selection alone. A WebKit without it gets a find that cannot match,
    /// which clears the box too but drops whatever is selected with it.
    static func hideFindMatch(in webView: WKWebView) {
        let hideFindUI = Selector(("_hideFindUI"))
        if webView.responds(to: hideFindUI) {
            webView.perform(hideFindUI)
        } else {
            webView.find(unmatchableFindString, configuration: WKFindConfiguration()) { _ in }
        }
    }

    /// Invisible separators, three in a row, which no page carries.
    static let unmatchableFindString = "\u{2063}\u{2063}\u{2063}"

    /// WebKit's find selects its match, so a closed find bar would leave the
    /// word sitting in an inactive selection. Drop that selection, and only
    /// that one: if the learner has selected something else since, keep it.
    static func clearMatchSelectionScript(matching needle: String) -> String {
        let literal = (try? JSONEncoder().encode([needle]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return """
        (function() {
            var selection = window.getSelection();
            if (!selection || selection.rangeCount === 0) { return; }
            var needle = \(literal)[0];
            if (selection.toString().trim().toLowerCase() !== needle.toLowerCase()) { return; }
            selection.removeAllRanges();
        })();
        """
    }

    private static func textMatches(
        in haystack: NSString,
        query: String,
        options: NSString.CompareOptions
    ) -> [NSRange] {
        var matches: [NSRange] = []
        var searchRange = NSRange(location: 0, length: haystack.length)

        while searchRange.length > 0 {
            let match = haystack.range(of: query, options: options, range: searchRange)
            guard match.location != NSNotFound else { break }
            matches.append(match)

            let nextLocation = match.location + max(match.length, 1)
            guard nextLocation < haystack.length else { break }
            searchRange = NSRange(location: nextLocation, length: haystack.length - nextLocation)
        }

        return matches
    }
}

struct ReaderDropZoneOverlay: View {
    let isActive: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(
                Color.accentColor.opacity(isActive ? 0.85 : 0),
                style: StrokeStyle(lineWidth: 2, dash: [7, 5])
            )
            .background(
                Color.accentColor.opacity(isActive ? 0.08 : 0),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                if isActive {
                    Label("Open source here", systemImage: "doc.text.magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .padding(6)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.12), value: isActive)
    }
}

struct SourceReaderBestMatchBanner: View {
    let bestMatch: SourceSearchBestMatch
    let onJump: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "scope")
                .font(.caption)
                .foregroundStyle(.blue)
                .frame(width: 18, height: 18)

            // No score beside the heading: the ranking's number says nothing
            // the excerpt does not (Quiet chrome, 2026-10-06).
            VStack(alignment: .leading, spacing: 3) {
                Text("Best match")
                    .font(.caption.weight(.semibold))
                Text(bestMatch.excerpt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer(minLength: 8)

            Button(action: onJump) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.hoverWash)
            .help("Find this passage")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.07))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

/// The Reader's overflow item that adds its source to the notebook in scope:
/// the one its window holds, else the one its window's chat is filed in
/// (`notebookInScope(for:)`) — never the active Notebook, which says nothing
/// about what is on screen, and never a new "Notebook N". "Add to <Notebook>",
/// "In <Notebook>" once the source is a member, and nothing at all with no
/// notebook in scope. A pop-out Reader belongs to no Studio window and asks
/// for the Studio window used last (`windowState` nil).
struct ReaderNotebookMembershipButton: View {
    @Environment(StudioViewModel.self) private var vm
    let article: StudioArticle
    let windowState: StudioWindowState?

    var body: some View {
        if let notebook = vm.notebookInScope(for: windowState ?? vm.activeWindowState) {
            let isMember = vm.notebookMembership(of: [vm.canonicalSourceID(article.id)], in: notebook.id) == .all
            Button {
                Task { _ = await vm.addSourcesToNotebookContext([article.id], notebookID: notebook.id) }
            } label: {
                Label(
                    isMember ? "In \u{201C}\(notebook.title)\u{201D}" : "Add to \u{201C}\(notebook.title)\u{201D}",
                    systemImage: "folder.badge.plus"
                )
            }
            .disabled(isMember)
        }
    }
}
