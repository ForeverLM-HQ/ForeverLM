import AppKit
import Foundation
import OSLog
import WebKit

/// The Browser as a chat drives it: one tab of the chat's own in the front
/// Studio window's Browser pane, acted on with real mouse and key events,
/// pictured after every step.
///
/// The tab renders whether or not anything shows it. A web view without a
/// window is a page WebKit treats as hidden — timers throttle, animation
/// frames stop, scripts that wait for a frame never run — so while no pane
/// holds the tab, `ChatBrowserHostWindow` does: an on-screen, fully
/// transparent window that WebKit counts as visible (measured 2026-09-10:
/// off-screen or occluded windows report `document.hidden`; a transparent
/// window at the screen's corner does not, and clicks and keys land in it).
/// When the learner opens the tab in the Browser pane the pane's host takes
/// the view; when the pane lets it go, the next step brings it back here.
@MainActor
final class StudioChatBrowserAgent: ChatBrowserAgent {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "ChatBrowser")

    private var workspace: BrowserWorkspace?
    private var tab: BrowserTab?

    /// How long a step waits for a navigation it started to finish.
    static let loadTimeout: TimeInterval = 15
    /// How long a step lets a page's scripts settle after a load or an input.
    static let defaultSettleDelay: TimeInterval = 0.6
    /// This agent's settle delay: the default unless a test driving a
    /// script-free page of its own shortens it.
    private let settleDelay: TimeInterval

    init(settleDelay: TimeInterval = StudioChatBrowserAgent.defaultSettleDelay) {
        self.settleDelay = settleDelay
    }
    /// Widest text browser_type accepts in one call.
    static let typingLimit = 2_000
    /// Characters of outline an action step returns; the full read is a call away.
    static let actionOutlineLimit = 3_000

    var hasTab: Bool { liveTab != nil }

    /// The Studio window whose Browser pane holds the chat's tab.
    var tabWindowID: UUID? {
        guard liveTab != nil, let workspace else { return nil }
        return BrowserWorkspace.windowID(of: workspace)
    }

    /// The tab, only while it still has a page and is still in its workspace:
    /// a tab the learner closed in the pane is gone for the chat too.
    private var liveTab: BrowserTab? {
        guard let tab, let workspace, workspace.tabs.contains(where: { $0.id == tab.id }), tab.webView != nil else {
            return nil
        }
        return tab
    }

    func revealTab() {
        guard let tab = liveTab, let workspace else { return }
        workspace.select(tab)
    }

    // MARK: - Running tools

    func run(
        tool name: String,
        arguments: [String: Any],
        onPreview: @escaping @MainActor (Data) -> Void
    ) async -> ChatBrowserToolOutcome {
        switch name {
        case "browser_open":
            return await open(arguments: arguments, onPreview: onPreview)
        case "browser_read_page":
            return await readPage(arguments: arguments, onPreview: onPreview)
        case "browser_click":
            return await click(arguments: arguments, onPreview: onPreview)
        case "browser_type":
            return await type(arguments: arguments, onPreview: onPreview)
        case "browser_press_key":
            return await pressKey(arguments: arguments, onPreview: onPreview)
        case "browser_scroll":
            return await scroll(arguments: arguments, onPreview: onPreview)
        case "browser_screenshot":
            return await screenshot(arguments: arguments, onPreview: onPreview)
        default:
            return ChatBrowserToolOutcome(text: "Error: \(name) is not a browser tool.", isError: true)
        }
    }

    private func open(arguments: [String: Any], onPreview: @escaping @MainActor (Data) -> Void) async -> ChatBrowserToolOutcome {
        let raw = (arguments["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = BrowserWorkspace.resolveAddress(raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else {
            return ChatBrowserToolOutcome(text: "Error: browser_open needs an http or https URL.", isError: true)
        }
        // The Browser never shows YouTube (`YouTubeContainment`), and a chat's
        // tab previews would put its feed in front of the learner.
        if YouTubeContainment.decision(for: url) != .notYouTube {
            return ChatBrowserToolOutcome(
                text: "Error: YouTube does not open in ForeverLM's Browser. The learner's app shows YouTube one video at a time, in the Reader; read a video through its transcript instead.",
                isError: true
            )
        }
        let profiles = BrowserProfileStore.shared
        var profile = BrowserProfile.library
        if let requested = (arguments["profile"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            guard let match = profiles.profiles.first(where: { $0.name.caseInsensitiveCompare(requested) == .orderedSame }) else {
                let names = profiles.profiles.map(\.name).joined(separator: ", ")
                return ChatBrowserToolOutcome(
                    text: "Error: There is no Browser profile named “\(requested)”. The learner's profiles are: \(names). Use one of these, or omit profile for Library; the learner makes profiles in the Browser pane.",
                    isError: true
                )
            }
            profile = match
        }

        let workspace = self.workspace ?? BrowserWorkspace.forChatTabs()
        self.workspace = workspace
        var tab = liveTab
        if let existing = tab, existing.profileID != profile.id {
            workspace.close(existing)
            tab = nil
        }
        if tab == nil {
            let opened = workspace.openTab(url: nil, profileID: profile.id, activate: false)
            opened.isDrivenByChat = true
            tab = opened
            self.tab = opened
        }
        guard let tab else { return ChatBrowserToolOutcome(text: "Error: The Browser tab could not be opened.", isError: true) }
        let webView = workspace.webView(for: tab)
        host(webView)
        workspace.load(url, in: tab)
        await waitForLoad(webView: webView)
        if let preview = await preview(of: webView) { onPreview(preview) }
        if let failure = tab.loadErrorMessage {
            return ChatBrowserToolOutcome(
                text: "Error: The page could not be loaded. \(failure)",
                isError: true,
                preview: await preview(of: webView)
            )
        }
        let outline = await outline(of: webView)
        var text = "Opened \(pageHeading(DrivenPage(webView: webView, tab: tab), outline: outline))"
        if !profile.isLibrary { text += " under the \(profile.name) profile" }
        text += ".\n\n" + outlineText(outline, limit: ChatBrowsing.outlineCharacterLimit, query: nil)
        if tab.passkeyRequestURL != nil {
            text += "\n\nThe page asked for a passkey, which ForeverLM's browser cannot answer; the learner can sign in another way in the Browser pane."
        }
        return ChatBrowserToolOutcome(text: text, isError: false, preview: await preview(of: webView))
    }

    private func readPage(arguments: [String: Any], onPreview: @escaping @MainActor (Data) -> Void) async -> ChatBrowserToolOutcome {
        let page: DrivenPage
        switch drivenPage(arguments) {
        case .failed(let outcome): return outcome
        case .found(let found): page = found
        }
        let webView = page.webView
        host(webView)
        let outline = await outline(of: webView)
        let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = page.lead + pageHeading(page, outline: outline) + "\n\n"
            + outlineText(outline, limit: ChatBrowsing.outlineCharacterLimit, query: query.flatMap { $0.isEmpty ? nil : $0 })
        return ChatBrowserToolOutcome(text: text, isError: false, preview: await preview(of: webView))
    }

    private func click(arguments: [String: Any], onPreview: @escaping @MainActor (Data) -> Void) async -> ChatBrowserToolOutcome {
        let page: DrivenPage
        switch drivenPage(arguments) {
        case .failed(let outcome): return outcome
        case .found(let found): page = found
        }
        let webView = page.webView
        guard let target = ChatBrowsing.Target.parse(arguments) else {
            return ChatBrowserToolOutcome(text: "Error: browser_click needs a ref from browser_read_page, or both x and y.", isError: true)
        }
        host(webView)
        let before = webView.url
        switch await resolve(target, in: webView) {
        case .failure(let message):
            return ChatBrowserToolOutcome(text: message, isError: true)
        case .success(let point):
            ChatBrowserInput.click(at: point, in: webView)
        }
        await settle(webView: webView, navigatedFrom: before)
        if let preview = await preview(of: webView) { onPreview(preview) }
        return await actionOutcome(verb: "Clicked", page: page, navigatedFrom: before)
    }

    private func type(arguments: [String: Any], onPreview: @escaping @MainActor (Data) -> Void) async -> ChatBrowserToolOutcome {
        let page: DrivenPage
        switch drivenPage(arguments) {
        case .failed(let outcome): return outcome
        case .found(let found): page = found
        }
        let webView = page.webView
        guard let text = arguments["text"] as? String, !text.isEmpty else {
            return ChatBrowserToolOutcome(text: "Error: browser_type needs text.", isError: true)
        }
        guard text.count <= Self.typingLimit else {
            return ChatBrowserToolOutcome(text: "Error: browser_type takes at most \(Self.typingLimit) characters per call.", isError: true)
        }
        host(webView)
        let before = webView.url
        if let target = ChatBrowsing.Target.parse(arguments) {
            switch await resolve(target, in: webView) {
            case .failure(let message):
                return ChatBrowserToolOutcome(text: message, isError: true)
            case .success(let point):
                ChatBrowserInput.click(at: point, in: webView)
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        for press in ChatBrowsing.KeyPress.typing(text) {
            ChatBrowserInput.press(press, in: webView)
            try? await Task.sleep(for: .milliseconds(4))
        }
        if arguments["submit"] as? Bool == true, let enter = ChatBrowsing.KeyPress.parse(key: "Enter") {
            try? await Task.sleep(for: .milliseconds(80))
            ChatBrowserInput.press(enter, in: webView)
        }
        await settle(webView: webView, navigatedFrom: before)
        if let preview = await preview(of: webView) { onPreview(preview) }
        return await actionOutcome(verb: "Typed", page: page, navigatedFrom: before)
    }

    private func pressKey(arguments: [String: Any], onPreview: @escaping @MainActor (Data) -> Void) async -> ChatBrowserToolOutcome {
        let page: DrivenPage
        switch drivenPage(arguments) {
        case .failed(let outcome): return outcome
        case .found(let found): page = found
        }
        let webView = page.webView
        let key = (arguments["key"] as? String) ?? ""
        let modifierNames = (arguments["modifiers"] as? [Any])?.compactMap { $0 as? String } ?? []
        guard let press = ChatBrowsing.KeyPress.parse(key: key, modifierNames: modifierNames) else {
            return ChatBrowserToolOutcome(
                text: "Error: browser_press_key needs one key: a name such as ArrowRight, Enter or Escape, or a single character. Longer text is typed with browser_type.",
                isError: true
            )
        }
        let times = min(50, max(1, (arguments["times"] as? NSNumber)?.intValue ?? 1))
        host(webView)
        let before = webView.url
        for index in 0..<times {
            ChatBrowserInput.press(press, in: webView)
            if index < times - 1 { try? await Task.sleep(for: .milliseconds(250)) }
        }
        await settle(webView: webView, navigatedFrom: before)
        if let preview = await preview(of: webView) { onPreview(preview) }
        let verb = times > 1 ? "Pressed \(key.trimmingCharacters(in: .whitespaces)) \(times) times" : "Pressed \(key.trimmingCharacters(in: .whitespaces))"
        return await actionOutcome(verb: verb, page: page, navigatedFrom: before)
    }

    private func scroll(arguments: [String: Any], onPreview: @escaping @MainActor (Data) -> Void) async -> ChatBrowserToolOutcome {
        let page: DrivenPage
        switch drivenPage(arguments) {
        case .failed(let outcome): return outcome
        case .found(let found): page = found
        }
        let webView = page.webView
        host(webView)
        let request = ChatBrowsing.ScrollRequest.parse(arguments)
        let script: String
        switch request.direction {
        case .down: script = "window.scrollBy(0, window.innerHeight * \(request.amount)); true"
        case .up: script = "window.scrollBy(0, -window.innerHeight * \(request.amount)); true"
        case .top: script = "window.scrollTo(0, 0); true"
        case .bottom: script = "window.scrollTo(0, document.documentElement.scrollHeight); true"
        }
        _ = try? await webView.evaluateJavaScript(script)
        try? await Task.sleep(for: .milliseconds(350))
        if let preview = await preview(of: webView) { onPreview(preview) }
        let outline = await outline(of: webView)
        let inView = outline.lines.filter(\.inView)
        var text = page.lead + "Scrolled \(request.direction.rawValue). " + scrollPosition(outline) + "\n\n"
        text += inView.isEmpty
            ? "Nothing of the outline is in view here; the page may draw itself on a canvas or in a frame — browser_screenshot shows it."
            : "In view now:\n" + joinedLines(inView, limit: ChatBrowsing.outlineCharacterLimit)
        return ChatBrowserToolOutcome(text: text, isError: false, preview: await preview(of: webView))
    }

    private func screenshot(arguments: [String: Any], onPreview: @escaping @MainActor (Data) -> Void) async -> ChatBrowserToolOutcome {
        let page: DrivenPage
        switch drivenPage(arguments) {
        case .failed(let outcome): return outcome
        case .found(let found): page = found
        }
        let webView = page.webView
        host(webView)
        guard let png = await ChatBrowserSnapshot.png(of: webView, width: nil) else {
            return ChatBrowserToolOutcome(text: "Error: The page could not be pictured; it may still be loading.", isError: true)
        }
        let caption = (arguments["caption"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackAlt = page.title.isEmpty ? "Screenshot of \(webView.url?.host ?? "the page")" : page.title
        let alt = caption.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackAlt
        let id = GeneratedImageReference.newID()
        guard let reference = GeneratedImageReference(id: id) else {
            return ChatBrowserToolOutcome(text: "Error: The screenshot could not be stored.", isError: true)
        }
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try GeneratedImageStore.write(
                    GeneratedImage(data: png, mediaType: "image/png"),
                    id: id,
                    details: GeneratedImageStore.Details(origin: .screenshot, text: alt)
                )
            }.value
        } catch {
            return ChatBrowserToolOutcome(text: "Error: The screenshot could not be stored. \(error.localizedDescription)", isError: true)
        }
        let line = reference.markdown(alt: alt)
        let text = """
        \(page.lead)Screenshot of \(pageHeading(page, outline: nil)).
        \(line)

        The picture is attached to this result when the selected model reads images. Include the Markdown image line above verbatim, on its own line, where the picture belongs in your answer when the learner asked to see the page.
        """
        return ChatBrowserToolOutcome(
            text: text,
            isError: false,
            screenshot: AIChatImage(data: png, mediaType: "image/png"),
            preview: await preview(of: webView)
        )
    }

    // MARK: - Tab and hosting

    /// The page a step acts on: the chat's own tab, or the web page open in
    /// the learner's Reader.
    @MainActor
    struct DrivenPage {
        let webView: WKWebView
        /// The chat's tab; nil for the Reader's page.
        let tab: BrowserTab?

        var title: String { tab?.title ?? webView.title ?? "" }
        var loadErrorMessage: String? { tab?.loadErrorMessage }
        /// Said first in a Reader step's result, so neither the model nor the
        /// learner mistakes which page was acted on.
        var lead: String { tab == nil ? "In the learner's Reader: " : "" }
    }

    enum PageLookup {
        case found(DrivenPage)
        case failed(ChatBrowserToolOutcome)
    }

    private func drivenPage(_ arguments: [String: Any]) -> PageLookup {
        switch ChatBrowsing.Page.parse(arguments) {
        case .reader:
            guard let webView = ReaderWebPages.frontmost() else {
                return .failed(ChatBrowserToolOutcome(
                    text: "Error: The learner's Reader is not showing a web page — it is closed, or the source open there is a PDF, a book or a video rather than a page. Omit page to use the chat's own Browser tab.",
                    isError: true
                ))
            }
            return .found(DrivenPage(webView: webView, tab: nil))
        case .chat:
            guard let tab = liveTab, let webView = tab.webView else { return .failed(noTab()) }
            return .found(DrivenPage(webView: webView, tab: tab))
        }
    }

    private func noTab() -> ChatBrowserToolOutcome {
        var text = tab == nil
            ? "Error: No page is open in the chat's Browser tab. Call browser_open with a URL first."
            : "Error: The chat's Browser tab was closed. Call browser_open with a URL to open a new one."
        if let reader = ReaderWebPages.frontmost() {
            let title = reader.title?.isEmpty == false ? "“\(reader.title!)”" : (reader.url?.host ?? "a page")
            text += " The learner's Reader is showing \(title); pass page reader to act on that page instead."
        }
        return ChatBrowserToolOutcome(text: text, isError: true)
    }

    /// Keeps the tab rendering: in the hidden host while no pane shows it.
    private func host(_ webView: WKWebView) {
        if webView.window == nil {
            ChatBrowserHostWindow.shared.host(webView)
        }
    }

    // MARK: - Waiting

    private func waitForLoad(webView: WKWebView) async {
        // The load starts asynchronously; give it a moment to be in flight
        // before waiting for it to end.
        try? await Task.sleep(for: .milliseconds(150))
        let deadline = Date().addingTimeInterval(Self.loadTimeout)
        while webView.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .seconds(settleDelay))
    }

    /// After an input: wait for a navigation it may have started, then let
    /// the page's scripts finish what a click or key set in motion.
    private func settle(webView: WKWebView, navigatedFrom before: URL?) async {
        try? await Task.sleep(for: .milliseconds(150))
        if webView.isLoading || webView.url != before {
            await waitForLoad(webView: webView)
        } else {
            try? await Task.sleep(for: .seconds(settleDelay))
        }
    }

    // MARK: - Targets

    private enum Resolution {
        case success(CGPoint)
        case failure(String)
    }

    /// Where a target is on screen right now: a ref is scrolled into view and
    /// measured; a point is taken as given inside the viewport.
    private func resolve(_ target: ChatBrowsing.Target, in webView: WKWebView) async -> Resolution {
        switch target {
        case .point(let x, let y):
            let bounds = webView.bounds
            guard x >= 0, y >= 0, x <= bounds.width, y <= bounds.height else {
                return .failure("Error: (\(Int(x)), \(Int(y))) is outside the viewport, which is \(Int(bounds.width))×\(Int(bounds.height)) CSS pixels.")
            }
            return .success(CGPoint(x: x, y: y))
        case .ref(let ref):
            let script = ChatBrowserScripts.locate(ref: ref)
            guard let result = try? await webView.evaluateJavaScript(script) as? [String: Any] else {
                return .failure("Error: \(ref) is not a handle from the current page. Call browser_read_page and use a ref it returned.")
            }
            if let error = result["error"] as? String {
                return .failure("Error: \(error)")
            }
            guard let x = ChatBrowsing.number(result["x"]), let y = ChatBrowsing.number(result["y"]) else {
                return .failure("Error: \(ref) could not be located on the page.")
            }
            let bounds = webView.bounds
            guard x >= 0, y >= 0, x <= bounds.width, y <= bounds.height else {
                return .failure("Error: \(ref) is not visible in the viewport even after scrolling to it; it may be hidden or covered. Read the page again.")
            }
            return .success(CGPoint(x: x, y: y))
        }
    }

    // MARK: - Reading

    struct Outline {
        struct Line {
            let text: String
            let inView: Bool
        }

        var title = ""
        var url = ""
        var width = 0
        var height = 0
        var scrollY = 0
        var scrollHeight = 0
        var frameCount = 0
        var lines: [Line] = []
    }

    private func outline(of webView: WKWebView) async -> Outline {
        var outline = Outline()
        outline.title = webView.title ?? ""
        outline.url = webView.url?.absoluteString ?? ""
        guard let result = try? await webView.evaluateJavaScript(ChatBrowserScripts.outline) as? [String: Any] else {
            return outline
        }
        if let title = result["title"] as? String, !title.isEmpty { outline.title = title }
        if let url = result["url"] as? String, !url.isEmpty { outline.url = url }
        outline.width = Int(ChatBrowsing.number(result["width"]) ?? 0)
        outline.height = Int(ChatBrowsing.number(result["height"]) ?? 0)
        outline.scrollY = Int(ChatBrowsing.number(result["scrollY"]) ?? 0)
        outline.scrollHeight = Int(ChatBrowsing.number(result["scrollHeight"]) ?? 0)
        outline.frameCount = Int(ChatBrowsing.number(result["frames"]) ?? 0)
        if let lines = result["lines"] as? [[String: Any]] {
            outline.lines = lines.compactMap { line in
                guard let text = line["text"] as? String, !text.isEmpty else { return nil }
                return Outline.Line(text: text, inView: (line["inView"] as? Bool) ?? false)
            }
        }
        return outline
    }

    private func pageHeading(_ page: DrivenPage, outline: Outline?) -> String {
        let title = outline?.title.isEmpty == false ? outline!.title : page.title
        let url = outline?.url.isEmpty == false ? outline!.url : (page.webView.url?.absoluteString ?? "")
        return title.isEmpty ? url : "“\(title)” — \(url)"
    }

    private func scrollPosition(_ outline: Outline) -> String {
        guard outline.height > 0, outline.scrollHeight > outline.height else { return "The page fits the viewport." }
        let bottom = min(outline.scrollHeight, outline.scrollY + outline.height)
        let percent = Int((Double(bottom) / Double(outline.scrollHeight) * 100).rounded())
        return "Viewport \(outline.width)×\(outline.height); showing through \(percent)% of the page."
    }

    private func outlineText(_ outline: Outline, limit: Int, query: String?) -> String {
        var header: [String] = []
        if outline.width > 0 {
            header.append(scrollPosition(outline))
        }
        if outline.frameCount > 0 {
            header.append("\(outline.frameCount) frame\(outline.frameCount == 1 ? "" : "s") from other sites could not be read; browser_screenshot shows them and browser_click takes coordinates there.")
        }
        var lines = outline.lines
        if let query {
            lines = lines.filter { $0.text.localizedCaseInsensitiveContains(query) }
            if lines.isEmpty {
                return (header + ["No line of the outline mentions “\(query)”."]).joined(separator: "\n")
            }
            header.append("Lines mentioning “\(query)”:")
        }
        if lines.isEmpty {
            header.append("The page has no readable outline — it may draw itself on a canvas or in a frame, or still be loading. browser_screenshot shows what is there.")
            return header.joined(separator: "\n")
        }
        return (header + [joinedLines(lines, limit: limit)]).joined(separator: "\n")
    }

    private func joinedLines(_ lines: [Outline.Line], limit: Int) -> String {
        var text = ""
        var dropped = 0
        for line in lines {
            if text.count + line.text.count + 1 > limit {
                dropped += 1
                continue
            }
            text += (text.isEmpty ? "" : "\n") + line.text
        }
        if dropped > 0 {
            text += "\n… \(dropped) more line\(dropped == 1 ? "" : "s") not shown; browser_scroll or browser_read_page with a query narrows it."
        }
        return text
    }

    private func actionOutcome(verb: String, page: DrivenPage, navigatedFrom before: URL?) async -> ChatBrowserToolOutcome {
        let webView = page.webView
        if let failure = page.loadErrorMessage {
            return ChatBrowserToolOutcome(text: "Error: \(verb), but the page that followed could not be loaded. \(failure)", isError: true, preview: await preview(of: webView))
        }
        let outline = await outline(of: webView)
        var text = page.lead + "\(verb). "
        text += webView.url != before ? "The page navigated to \(pageHeading(page, outline: outline))." : "Still on \(pageHeading(page, outline: outline))."
        text += "\n\n" + outlineText(outline, limit: Self.actionOutlineLimit, query: nil)
        if outline.lines.count > 0 {
            text += "\n\n(browser_read_page returns the full outline; browser_screenshot shows the page as rendered.)"
        }
        return ChatBrowserToolOutcome(text: text, isError: false, preview: await preview(of: webView))
    }

    // MARK: - Pictures

    /// The row's thumbnail: the page at 480 points wide.
    private func preview(of webView: WKWebView) async -> Data? {
        await ChatBrowserSnapshot.png(of: webView, width: 480)
    }
}

// MARK: - The Reader's page

/// The web page open in the learner's Reader, found the way the learner sees
/// it: in the windows on screen, front to back. Nothing registers itself —
/// a reader's page moves between hosts and is parked when its pane goes
/// (`ReaderWebViewPark`), so a list kept beside it would drift; the view
/// tree never does. Within a window, the reader holding the keyboard focus
/// wins, then the first one.
@MainActor
enum ReaderWebPages {
    static func frontmost() -> WKWebView? {
        var seen = Set<ObjectIdentifier>()
        let windows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows
        for window in windows where window.isVisible && seen.insert(ObjectIdentifier(window)).inserted {
            guard let content = window.contentView else { continue }
            var hosts: [ReaderWebViewHost] = []
            collect(in: content, into: &hosts)
            let pages = hosts.compactMap { host -> WKWebView? in
                guard let webView = host.webView, !host.isHiddenOrHasHiddenAncestor,
                      webView.url != nil else { return nil }
                return webView
            }
            guard !pages.isEmpty else { continue }
            if let focused = window.firstResponder as? NSView,
               let page = pages.first(where: { focused.isDescendant(of: $0) }) {
                return page
            }
            return pages.first
        }
        return nil
    }

    private static func collect(in view: NSView, into hosts: inout [ReaderWebViewHost]) {
        if let host = view as? ReaderWebViewHost {
            hosts.append(host)
            return
        }
        for subview in view.subviews {
            collect(in: subview, into: &hosts)
        }
    }
}

// MARK: - Input

/// Real mouse and key events, delivered to the web view the way AppKit
/// would, so they reach canvases, frames and script handlers alike.
@MainActor
enum ChatBrowserInput {
    static func click(at point: CGPoint, in webView: WKWebView) {
        guard let window = webView.window else { return }
        // CSS pixels are view points here; the web view's coordinate space
        // is flipped, so a top-left origin needs no conversion of its own.
        let local = webView.isFlipped ? NSPoint(x: point.x, y: point.y) : NSPoint(x: point.x, y: webView.bounds.height - point.y)
        let inWindow = webView.convert(local, to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        if let move = NSEvent.mouseEvent(
            with: .mouseMoved, location: inWindow, modifierFlags: [], timestamp: time,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ) {
            webView.mouseMoved(with: move)
        }
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: time,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: inWindow, modifierFlags: [], timestamp: time + 0.05,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0
        ) else { return }
        webView.mouseDown(with: down)
        webView.mouseUp(with: up)
    }

    static func press(_ press: ChatBrowsing.KeyPress, in webView: WKWebView) {
        guard let window = webView.window else { return }
        var flags: NSEvent.ModifierFlags = []
        if press.modifiers.contains(.command) { flags.insert(.command) }
        if press.modifiers.contains(.shift) { flags.insert(.shift) }
        if press.modifiers.contains(.option) { flags.insert(.option) }
        if press.modifiers.contains(.control) { flags.insert(.control) }
        if press.keyCode >= 115, press.keyCode <= 126 { flags.insert(.function) }
        let time = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: time, windowNumber: window.windowNumber,
            context: nil, characters: press.characters, charactersIgnoringModifiers: press.characters,
            isARepeat: false, keyCode: press.keyCode
        ), let up = NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: flags, timestamp: time + 0.03, windowNumber: window.windowNumber,
            context: nil, characters: press.characters, charactersIgnoringModifiers: press.characters,
            isARepeat: false, keyCode: press.keyCode
        ) else { return }
        webView.keyDown(with: down)
        webView.keyUp(with: up)
    }
}

// MARK: - Snapshots

@MainActor
enum ChatBrowserSnapshot {
    /// The web view's page as PNG bytes, at its own size or scaled to `width`.
    static func png(of webView: WKWebView, width: CGFloat?) async -> Data? {
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }
        let configuration = WKSnapshotConfiguration()
        if let width { configuration.snapshotWidth = NSNumber(value: Double(width)) }
        configuration.afterScreenUpdates = true
        let image: NSImage
        do {
            image = try await webView.takeSnapshot(configuration: configuration)
        } catch {
            return nil
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Host window

/// The transparent, mouse-transparent window that keeps chat-driven tabs
/// rendering while no pane shows them. Kept at the main screen's corner,
/// below every ordinary window, on every Space, out of Exposé and the Window
/// menu; ordered in only while it holds a view.
@MainActor
final class ChatBrowserHostWindow {
    static let shared = ChatBrowserHostWindow()

    private var window: NSWindow?
    private var screenObserver: NSObjectProtocol?

    private init() {}

    func host(_ webView: WKWebView) {
        let window = window ?? makeWindow()
        guard let content = window.contentView else { return }
        webView.frame = CGRect(x: 0, y: 0, width: ChatBrowsing.viewportWidth, height: ChatBrowsing.viewportHeight)
        webView.autoresizingMask = []
        content.addSubview(webView)
        position(window)
        if !window.isVisible {
            window.orderBack(nil)
        }
    }

    private func makeWindow() -> NSWindow {
        let size = NSSize(width: ChatBrowsing.viewportWidth, height: ChatBrowsing.viewportHeight)
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
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                self.position(window)
            }
        }
        return window
    }

    /// The window sits at the main screen's bottom-left corner. It has to be
    /// on a screen: WebKit takes a window entirely off-screen for occluded
    /// and stops rendering the page.
    private func position(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.frame
        window.setFrameOrigin(NSPoint(x: frame.minX, y: frame.minY))
    }
}

// MARK: - Scripts

enum ChatBrowserScripts {
    /// The page as an outline: headings, text by block, and every control
    /// with a `ref_N` handle kept in `window.__foreverlmRefs` for
    /// `locate(ref:)`. Each line says whether it is in the viewport.
    static let outline = """
    (() => {
      const refs = new Map();
      window.__foreverlmRefs = refs;
      let n = 0, frames = 0;
      const lines = [];
      const vh = window.innerHeight, vw = window.innerWidth;
      const inView = r => r.bottom > 0 && r.top < vh && r.right > 0 && r.left < vw;
      const clean = s => (s || '').replace(/\\s+/g, ' ').trim();
      const label = el => clean(el.getAttribute('aria-label') || (el.innerText && el.innerText.length < 400 ? el.innerText : '') || el.value || el.placeholder || el.alt || el.title || el.getAttribute('name') || '').slice(0, 120);
      const interactive = 'a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[role=radio],[role=option],[role=switch],[role=textbox],[contenteditable=true],[onclick]';
      const role = el => {
        const tag = el.tagName.toLowerCase();
        const r = el.getAttribute('role');
        if (tag === 'a') return 'link';
        if (tag === 'input') { const t = (el.type || 'text').toLowerCase(); return t === 'submit' || t === 'button' ? 'button' : t + ' field'; }
        if (tag === 'textarea' || el.isContentEditable) return 'text area';
        if (tag === 'select') return 'select';
        if (tag === 'button' || r === 'button') return 'button';
        return r || tag;
      };
      const blockTags = new Set(['p','div','section','article','main','header','footer','nav','aside','li','ul','ol','table','tr','td','th','blockquote','pre','form','fieldset','figure','figcaption','dl','dt','dd','details','label','br','hr']);
      let buffer = [], bufferInView = false;
      const flush = () => {
        const text = clean(buffer.join(' '));
        if (text) lines.push({ text: text.slice(0, 600), inView: bufferInView });
        buffer = []; bufferInView = false;
      };
      const walk = node => {
        if (node.nodeType === 3) {
          const t = clean(node.textContent);
          if (t) {
            buffer.push(t);
            const parent = node.parentElement;
            if (parent && inView(parent.getBoundingClientRect())) bufferInView = true;
          }
          return;
        }
        if (node.nodeType !== 1) return;
        const el = node, tag = el.tagName.toLowerCase();
        if (['script','style','noscript','svg','template','head','meta','link'].includes(tag)) return;
        const style = getComputedStyle(el);
        if (style.display === 'none' || style.visibility === 'hidden') return;
        const rect = el.getBoundingClientRect();
        if (rect.width === 0 && rect.height === 0 && tag !== 'body' && el.childElementCount === 0) return;
        if (/^h[1-6]$/.test(tag)) { flush(); lines.push({ text: '#'.repeat(+tag[1]) + ' ' + label(el), inView: inView(rect) }); return; }
        if (el.matches(interactive)) {
          flush();
          const id = 'ref_' + (++n);
          refs.set(id, el);
          let line = '[' + id + '] ' + role(el) + ' "' + label(el) + '"';
          if (tag === 'a' && el.href && !el.href.startsWith('javascript:')) line += ' → ' + el.href.slice(0, 160);
          if (el.type === 'checkbox' || el.type === 'radio' || el.getAttribute('role') === 'checkbox') line += el.checked || el.getAttribute('aria-checked') === 'true' ? ' (checked)' : '';
          if (el.disabled) line += ' (disabled)';
          lines.push({ text: line, inView: inView(rect) });
          return;
        }
        if (tag === 'img') { const a = clean(el.alt); if (a) { flush(); lines.push({ text: '[image "' + a.slice(0, 100) + '"]', inView: inView(rect) }); } return; }
        if (tag === 'iframe' || tag === 'frame') {
          flush();
          let doc = null;
          try { doc = el.contentDocument; } catch (_) {}
          if (doc && doc.body) { lines.push({ text: '[frame ' + (el.src || '').slice(0, 120) + ']', inView: inView(rect) }); walk(doc.body); flush(); }
          else { frames++; lines.push({ text: '[frame from another site ' + (el.src || '').slice(0, 120) + ' — ' + Math.round(rect.width) + '×' + Math.round(rect.height) + ' at (' + Math.round(rect.left) + ', ' + Math.round(rect.top) + ')]', inView: inView(rect) }); }
          return;
        }
        if (tag === 'canvas' || tag === 'video') { flush(); lines.push({ text: '[' + tag + ' ' + Math.round(rect.width) + '×' + Math.round(rect.height) + ' at (' + Math.round(rect.left) + ', ' + Math.round(rect.top) + ') — drawn content; browser_screenshot shows it]', inView: inView(rect) }); return; }
        const isBlock = blockTags.has(tag) || /block|flex|grid|list-item|table/.test(style.display);
        if (isBlock) flush();
        for (const child of el.childNodes) walk(child);
        if (isBlock) flush();
      };
      walk(document.body);
      flush();
      return { title: document.title, url: location.href, width: vw, height: vh, scrollY: Math.round(window.scrollY), scrollHeight: document.documentElement.scrollHeight, frames, lines: lines.slice(0, 1500) };
    })()
    """

    /// The viewport centre of a handle's element after scrolling it into
    /// view; an `error` when the handle is stale or the element is gone.
    static func locate(ref: String) -> String {
        let escaped = ref.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return """
        (() => {
          const refs = window.__foreverlmRefs;
          if (!refs) return { error: 'The page has not been read yet; call browser_read_page first.' };
          const el = refs.get('\(escaped)');
          if (!el) return { error: '\(escaped) is not a handle on the current page; call browser_read_page for fresh handles.' };
          if (!el.isConnected) return { error: '\(escaped) is no longer on the page; call browser_read_page for fresh handles.' };
          el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
          const r = el.getBoundingClientRect();
          if (r.width === 0 && r.height === 0) return { error: '\(escaped) has no size on screen; it may be hidden.' };
          return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
        })()
        """
    }
}
