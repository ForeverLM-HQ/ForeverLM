#if os(macOS)
import AppKit
import Observation
import SwiftUI
import WebKit

/// What a card on the home's Docs tab shows above its title: a photograph of
/// the hosted page for a Site, and for a Doc the opening lines of its body,
/// drawn as a small page.
///
/// Pictures are made once per record revision and kept in
/// `ThumbnailDiskCache` beside the source thumbnails, so a home that lists
/// thirty animations photographs each page the first time it is scrolled past
/// and reads the JPEG from then on. Pages are photographed a few at a time in
/// web views no pane shows — one at a time made a home of 28 animations wait
/// ~90 s, each page ~3 s in line (measured) — and a card scrolled
/// away before its turn leaves the line, so the cards on screen go first. A
/// page that fails or takes too long is left with its kind's glyph for the
/// rest of the session rather than retried on every scroll.
@MainActor
@Observable
final class ArtifactPreviewStore {
    static let shared = ArtifactPreviewStore()

    /// How a card's picture is made.
    enum Request: Hashable, Sendable {
        /// A hosted page photographed at its address.
        case page(url: URL, kind: LinkedPageKind?)
        /// A picture already on this Mac: an explainer film's poster frame.
        case file(path: String)
    }

    /// Pictures by cache key, for the cards that are drawn now.
    private(set) var images: [String: NSImage] = [:]
    /// Doc excerpts by cache key.
    private(set) var excerpts: [String: String] = [:]

    private var failed: Set<String> = []
    private var queued: Set<String> = []
    private var queue: [(key: String, request: Request)] = []
    private var running = 0
    private var excerptLoads: Set<String> = []

    private let diskCache: ThumbnailDiskCache
    private let snapshotter: (Request) async -> NSImage?
    /// How many pictures are made at once. Most of a page's ~3 s is waiting —
    /// the load, the settle before the photograph — so a few side by side
    /// cost little more than one.
    private let maximumConcurrent: Int

    static let defaultMaximumConcurrent = 4

    private init() {
        self.diskCache = .shared
        self.snapshotter = { await ArtifactPagePhotographer.shared.image(for: $0) }
        self.maximumConcurrent = Self.defaultMaximumConcurrent
    }

    /// Test-only: a store with its own cache directory and picture maker.
    init(
        diskCache: ThumbnailDiskCache,
        maximumConcurrent: Int = ArtifactPreviewStore.defaultMaximumConcurrent,
        snapshotter: @escaping (Request) async -> NSImage?
    ) {
        self.diskCache = diskCache
        self.snapshotter = snapshotter
        self.maximumConcurrent = max(1, maximumConcurrent)
    }

    // MARK: Keys

    /// One key per record revision: a republished site or a re-saved
    /// animation gets a fresh picture; an untouched one keeps its JPEG.
    nonisolated static func cacheKey(id: String, updatedAt: Date) -> String {
        "artifact-preview:v1:\(id):\(Int(updatedAt.timeIntervalSince1970))"
    }

    // MARK: Pictures

    /// The picture for `key`, if one is ready. Reads only, so a card may ask
    /// while it is drawn; `request` is what consults the disk cache and fills
    /// this in, and a relaunch draws the home from JPEGs without
    /// photographing anything.
    func image(for key: String) -> NSImage? {
        images[key]
    }

    /// Asks for `key`'s picture to be made from `request` if it is not ready,
    /// failed or already waiting. Returns at once; the card redraws when
    /// `images` gains the key.
    func request(_ request: Request, for key: String) {
        guard images[key] == nil, !failed.contains(key), !queued.contains(key) else { return }
        if let cached = diskCache.cachedImage(for: key) {
            images[key] = cached
            return
        }
        queued.insert(key)
        queue.append((key, request))
        drain()
    }

    /// Takes `key` out of the line if its picture has not been started: its
    /// card left the screen, and the cards still on it should not wait
    /// behind it. The card asks again when it comes back.
    func withdraw(_ key: String) {
        guard let index = queue.firstIndex(where: { $0.key == key }) else { return }
        queue.remove(at: index)
        queued.remove(key)
    }

    private func drain() {
        while running < maximumConcurrent, !queue.isEmpty {
            let job = queue.removeFirst()
            running += 1
            Task { [weak self] in
                guard let self else { return }
                let image = await self.snapshotter(job.request)
                self.running -= 1
                self.queued.remove(job.key)
                if let image {
                    self.images[job.key] = image
                    self.diskCache.store(image, for: job.key)
                } else {
                    self.failed.insert(job.key)
                }
                self.drain()
            }
        }
    }

    // MARK: Excerpts

    /// Loads a Doc's opening lines once per revision through `loader`, which
    /// reads the body; the card redraws when `excerpts` gains the key. A body
    /// that cannot be read leaves the card with its title alone.
    func requestExcerpt(for key: String, title: String, loader: @escaping @Sendable () async throws -> String) {
        guard excerpts[key] == nil, !excerptLoads.contains(key) else { return }
        excerptLoads.insert(key)
        Task { [weak self] in
            let markdown = try? await loader()
            guard let self else { return }
            self.excerptLoads.remove(key)
            self.excerpts[key] = ArtifactPreviewExcerpt.make(markdown: markdown ?? "", title: title)
        }
    }
}

// MARK: - Excerpt

/// The opening lines of a Doc as its card shows them: the prose with the
/// Markdown marks taken out, the title's own heading dropped, the first few
/// hundred characters.
enum ArtifactPreviewExcerpt {
    static let maximumLength = 360

    nonisolated static func make(markdown: String, title: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        var inFence = false
        for rawLine in markdown.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if line.isEmpty { continue }
            // Front matter, comments, images, tables and rules carry nothing
            // a card should show.
            if line.hasPrefix("<!--") || line.hasPrefix("![") || line.hasPrefix("|") { continue }
            if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" || $0 == "=" }) { continue }
            // Headings: the one that names the doc is the title already.
            if line.hasPrefix("#") {
                line = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if line.caseInsensitiveCompare(trimmedTitle) == .orderedSame { continue }
            }
            if line.hasPrefix(">") { line = line.dropFirst().trimmingCharacters(in: .whitespaces) }
            line = stripListMarker(line)
            line = stripInlineMarks(line)
            if line.isEmpty { continue }
            lines.append(line)
            if lines.joined(separator: " ").count >= maximumLength { break }
        }
        let joined = lines.joined(separator: " ")
        if joined.count <= maximumLength { return joined }
        let cut = joined.index(joined.startIndex, offsetBy: maximumLength)
        return String(joined[..<cut]).trimmingCharacters(in: .whitespaces) + "…"
    }

    private nonisolated static func stripListMarker(_ line: String) -> String {
        var line = line
        for marker in ["- [ ] ", "- [x] ", "- ", "* ", "+ "] where line.hasPrefix(marker) {
            line = String(line.dropFirst(marker.count))
            break
        }
        // "1. " / "12) "
        let digits = line.prefix(while: { $0.isNumber })
        if !digits.isEmpty, digits.count <= 3 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                line = String(rest.dropFirst(2))
            }
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    private nonisolated static func stripInlineMarks(_ line: String) -> String {
        // Tags a linked doc's export or a pasted page left in the body.
        var text = line.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
        // [label](address) → label; images were dropped above.
        while let open = text.range(of: "["),
              let close = text.range(of: "](", range: open.upperBound..<text.endIndex),
              let end = text.range(of: ")", range: close.upperBound..<text.endIndex) {
            let label = text[open.upperBound..<close.lowerBound]
            text.replaceSubrange(open.lowerBound..<end.upperBound, with: label)
        }
        for mark in ["**", "__", "`", "*", "_", "~~"] {
            text = text.replacingOccurrences(of: mark, with: "")
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Photographer

/// Photographs hosted pages, each in its own web view held by a window no one
/// sees, and reads poster files off disk.
@MainActor
final class ArtifactPagePhotographer {
    static let shared = ArtifactPagePhotographer()

    /// The page is laid out at a laptop's width and photographed at card
    /// width: text stays legible in the picture and the JPEG stays small.
    static let viewportSize = CGSize(width: 1120, height: 700)
    static let snapshotWidth: CGFloat = 560
    /// How long a page may take to load before its card keeps the glyph.
    static let loadTimeout: Duration = .seconds(20)
    /// How long after the load to let scripts draw before the photograph:
    /// an animation's first frame, a site's web fonts.
    static let settleDelay: Duration = .milliseconds(1400)

    private init() {}

    func image(for request: ArtifactPreviewStore.Request) async -> NSImage? {
        switch request {
        case .file(let path):
            return await Task.detached(priority: .utility) { NSImage(contentsOfFile: path) }.value
        case .page(let url, let kind):
            return await photograph(url: url, kind: kind)
        }
    }

    private func photograph(url: URL, kind: LinkedPageKind?) async -> NSImage? {
        let configuration = WKWebViewConfiguration()
        SharedWebKit.applySharedProcessPool(to: configuration)
        // The reader's own cookie jar, so a Codex site or a Claude artifact
        // the learner has signed in to photographs as its page and not as
        // the product's sign-in gate.
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        LocalSiteSchemeHandler.install(on: configuration)
        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: Self.viewportSize),
            configuration: configuration
        )
        webView.customUserAgent = SharedWebKit.desktopSafariUserAgent
        let loader = PageLoadObserver()
        webView.navigationDelegate = loader
        webView.uiDelegate = loader
        ArtifactPreviewHostWindow.shared.host(webView)
        defer { ArtifactPreviewHostWindow.shared.release(webView) }

        let request = URLRequest(url: url)
        let loaded = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { @MainActor in await loader.finished(loading: request, in: webView) }
            group.addTask {
                try? await Task.sleep(for: Self.loadTimeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard loaded else { return nil }
        try? await Task.sleep(for: Self.settleDelay)

        let snapshot = WKSnapshotConfiguration()
        snapshot.snapshotWidth = NSNumber(value: Double(Self.snapshotWidth))
        snapshot.afterScreenUpdates = true
        return try? await webView.takeSnapshot(configuration: snapshot)
    }

    /// Resolves once, with whether the page loaded, when the navigation
    /// finishes or fails.
    private final class PageLoadObserver: NSObject, WKNavigationDelegate, WKUIDelegate {
        private var continuation: CheckedContinuation<Bool, Never>?

        @MainActor
        func finished(loading request: URLRequest, in webView: WKWebView) async -> Bool {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                webView.load(request)
            }
        }

        private func resume(_ loaded: Bool) {
            continuation?.resume(returning: loaded)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resume(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resume(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { resume(false) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { resume(false) }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? { nil }
    }
}

// MARK: - Host window

/// A transparent, mouse-transparent window at the main screen's corner that
/// holds the web view being photographed. It has to be on a screen: WebKit
/// treats a window entirely off-screen as occluded and stops drawing the page
/// (measured for the chat's browser tools), and a page that never
/// draws photographs blank. Ordered out again once nothing is being made.
@MainActor
final class ArtifactPreviewHostWindow {
    static let shared = ArtifactPreviewHostWindow()

    private var window: NSWindow?

    private init() {}

    func host(_ webView: WKWebView) {
        let window = window ?? makeWindow()
        guard let content = window.contentView else { return }
        webView.frame = CGRect(origin: .zero, size: ArtifactPagePhotographer.viewportSize)
        webView.autoresizingMask = []
        content.addSubview(webView)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            window.setFrameOrigin(NSPoint(x: screen.frame.minX, y: screen.frame.minY))
        }
        if !window.isVisible {
            window.orderBack(nil)
        }
    }

    func release(_ webView: WKWebView) {
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
        if let window, window.contentView?.subviews.isEmpty ?? true {
            window.orderOut(nil)
        }
    }

    private func makeWindow() -> NSWindow {
        let size = ArtifactPagePhotographer.viewportSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary, .transient]
        window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
        window.setAccessibilityElement(false)
        self.window = window
        return window
    }
}
#endif
