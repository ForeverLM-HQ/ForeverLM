import AppKit
import SwiftUI
import WebKit

/// The whole chat transcript as one web page.
///
/// The transcript used to be a lazy SwiftUI list with every reply its own
/// `WKWebView`. The list placed a reply before its page could say how tall it
/// was, so it guessed, the page answered a few frames later, and the
/// difference moved the text under the learner's scroll; height memory, scroll
/// anchoring and measuring ahead each hid one case of it. Here one page holds
/// the whole conversation: the browser lays it out, scrolls it, and keeps the
/// learner's place when something above changes, as Codex's and Claude's
/// desktop apps draw theirs. Nothing reports a height, so nothing is guessed.
///
/// Swift stays the owner of the conversation and of every action. The panel
/// turns its messages into `ChatTranscriptPage.Block`s; this view sends the
/// page what changed (`window.transcriptApply`) and hands back what the
/// learner did as an `Action` naming its block. Replies render with the same
/// renderer and stylesheet as the per-reply pages (`Web/ChatRenderer`,
/// `mac-transcript.js`).
///
/// Step one of the move (product owner, 2026-11-07: "Start step 1"): the page
/// draws the learner's turns, replies with their steps and footer, suggested
/// questions and the working line. A chat holding anything else — a side
/// question's lane, saved cards, a page card, a walk, a memory review's cards —
/// stays on the native transcript (`draws(_:)`). The page is on unless
/// `isEnabled` says it was turned off.
struct ChatTranscriptPage: NSViewRepresentable {
    // MARK: What the page draws

    /// One turn: the learner's message, or a reply with its steps.
    struct Block: Encodable, Equatable {
        enum Kind: String, Encodable {
            case user
            case answer
        }

        let id: String
        let kind: Kind
        // The learner's turn.
        var messageID: String?
        var text: String?
        /// The Reader passage the message was asked about.
        var passage: String?
        /// Think first: the guess written before asking.
        var guess: String?
        var canEdit: Bool?
        /// A long paste, folded to its first lines (`ChatLongUserMessage`).
        var collapses: Bool?
        /// Sources added to the chat just before this message.
        var added: Added?
        // A reply.
        var parts: [Part]?
        var footer: Footer?
        var isLatest: Bool?
        var isLive: Bool?
        var isFindMatch: Bool?
    }

    struct Added: Encodable, Equatable {
        struct Source: Encodable, Equatable {
            let id: String
            let title: String
        }

        let summary: String
        let sources: [Source]
    }

    /// A piece of a reply: its prose, or its steps folded to one line.
    struct Part: Encodable, Equatable {
        enum Kind: String, Encodable {
            case prose
            case work
        }

        let kind: Kind
        let id: String
        // Prose.
        var markdown: String?
        var citations: ChatCitationLedger.MessageContext?
        var webSources: [WebSource]?
        // Steps.
        var title: String?
        var failed: String?
        var running: Bool?
        var settled: Bool?
        /// Open by default: the turn is still working and no answer has begun.
        var opensWhileLive: Bool?
        var steps: [Step]?
    }

    struct WebSource: Encodable, Equatable {
        let title: String
        let url: String
        let host: String?
    }

    struct Step: Encodable, Equatable {
        /// "thinking" or "tool".
        let kind: String
        var paragraphs: [String]?
        var title: String?
        /// "running", "succeeded" or "failed".
        var state: String?
        var summary: String?
    }

    struct Footer: Encodable, Equatable {
        struct SideQuestion: Encodable, Equatable {
            let armed: Bool
        }

        var copyLabel: String?
        var sideQuestion: SideQuestion?
        var more: Bool
    }

    /// What follows the last turn.
    struct Tail: Encodable, Equatable {
        struct Working: Encodable, Equatable {
            let label: String
            /// Milliseconds since 1970, which the page counts from.
            let startedAt: Double
        }

        var suggested: [String]?
        var working: Working?
        var error: String?
    }

    struct Layout: Encodable, Equatable {
        let fontSize: CGFloat
        let columnMaxWidth: CGFloat
        let messageMaxWidth: CGFloat
    }

    struct State: Equatable {
        var blocks: [Block]
        var tail: Tail?
        /// Empty space kept under the last turn (`transcriptBottomReserve`).
        var reserve: CGFloat
        var layout: Layout
    }

    /// Bring a turn into view: its end at the foot of the screen, its middle
    /// at the middle, or its start at the top. A new `token` is a new request.
    struct ScrollRequest: Equatable {
        enum Position: String {
            case top
            case center
            case bottom
        }

        let token: Int
        let blockID: UUID?
        let position: Position
        var animated = false
    }

    /// What the learner did on the page.
    enum Action {
        case copyAnswer(blockID: UUID)
        case copyMessage(blockID: UUID)
        case editMessage(blockID: UUID)
        case sideQuestion(blockID: UUID)
        /// The ⋯ under a reply, with where it was drawn in `view`.
        case moreMenu(blockID: UUID, rect: CGRect, view: NSView)
        case openPassage(blockID: UUID)
        case openContextSource(sourceID: String)
        case suggestedQuestion(String)
    }

    /// What a reply's links and pictures need from the app: the same lookups
    /// and routes a per-reply page is given (`ReviewChatMessageContent`).
    struct Resolvers {
        let sourceCard: @MainActor (String) async -> ChatSourceCard?
        let sourceImage: @MainActor (String) async -> ChatSourceImage?
        let openSource: (ChatSourceLink) -> Void
        let openWebURL: (URL, String?) -> Void
        let selection: (ChatReplySelectionAction, String, UUID, ChatSelectionAnchor?) -> Void
    }

    let state: State
    let scrollRequest: ScrollRequest?
    let resolvers: Resolvers
    let onAction: (Action) -> Void

    // MARK: When the page is used

    /// On by default (product owner, 2026-11-08: "I think it's still glitchy
    /// actually, so please fix that": the native list still guessed heights).
    /// While the page is new it can be turned off with
    /// `defaults write com.foreverlm chatTranscriptOnePage -bool NO`
    /// (`com.foreverlm.dev` for the Dev app).
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "chatTranscriptOnePage") as? Bool ?? true
    }

    /// Whether the page draws every row of these sections. Anything it does
    /// not draw yet keeps the chat on the native transcript, so nothing the
    /// learner has is lost while the move is under way.
    @MainActor
    static func draws(_ sections: [ReviewChatTranscriptSection]) -> Bool {
        for section in sections {
            guard !section.isSideQuestion else { return false }
            for block in section.blocks where !draws(block) {
                return false
            }
        }
        return true
    }

    @MainActor
    static func draws(_ block: ReviewChatTranscriptBlock) -> Bool {
        if let user = block.userMessage {
            let stored = ChatContextAdditions.parse(contextContent: user.contextualContent)
            guard ReviewChatVideoMomentRow.moments(in: stored.onScreen).isEmpty,
                  AttachedImageReference.split(user.content).images.isEmpty else { return false }
            return true
        }
        guard !block.answerMessages.contains(where: { $0.walkthroughStep != nil }) else { return false }
        for item in ReviewChatAnswerLayout.items(block.answerMessages) {
            switch item {
            case .pages:
                return false
            case .entry(let entry):
                guard let message = entry.message, message.role == .assistant else { return false }
            case .work(let work):
                guard work.pages.isEmpty,
                      !work.steps.contains(where: { $0.isBrowserStep }),
                      ChatPluginRequest.setupNeeds(in: work.steps.filter { $0.kind != .thinking }.map { activity in
                          (toolName: activity.toolName, error: activity.state == .failed ? activity.resultPreview : nil)
                      }).isEmpty
                else { return false }
            }
        }
        return true
    }

    // MARK: Building blocks

    /// A reply's steps as the page's fold draws them.
    @MainActor
    static func workPart(_ work: ReviewChatWork, isLive: Bool) -> Part {
        let working = isLive && !work.answerHasBegun
        let failedCount = work.steps.filter { $0.state == .failed }.count
        let steps: [Step] = work.steps.map { activity in
            if activity.kind == .thinking {
                return Step(kind: "thinking", paragraphs: ReviewChatReasoningText.paragraphs(activity.reasoning))
            }
            return Step(
                kind: "tool",
                title: ReviewChatToolRow.title(for: activity),
                state: stateName(activity.state),
                summary: ReviewChatToolRow.resultSummary(for: activity)
            )
        }
        return Part(
            kind: .work,
            id: work.id.uuidString,
            title: working ? "Working" : ReviewChatWorkFold.title(steps: work.steps, duration: work.duration),
            failed: failedCount == 0 ? nil : (failedCount == 1 ? "1 failed" : "\(failedCount) failed"),
            running: isLive && work.steps.contains { $0.state == .running },
            settled: !working,
            opensWhileLive: working,
            steps: steps
        )
    }

    private static func stateName(_ state: ReviewSessionManager.Message.ToolActivity.State) -> String {
        switch state {
        case .running: return "running"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        }
    }

    /// A prose message of a reply: its markdown without the web pages it
    /// cited, which the page lists under it, as the bubble does.
    @MainActor
    static func prosePart(
        _ message: ReviewSessionManager.Message,
        citations: ChatCitationLedger.MessageContext
    ) -> Part? {
        guard let display = ReviewSessionManager.displayableMessageContent(role: message.role, content: message.content)
        else { return nil }
        let split = ReviewSessionManager.splitWebSourcesFooter(display)
        return Part(
            kind: .prose,
            id: message.id.uuidString,
            markdown: split.body,
            citations: citations.isEmpty ? nil : citations,
            webSources: split.citations.isEmpty ? nil : split.citations.map { citation in
                WebSource(title: citation.title, url: citation.url, host: URL(string: citation.url)?.host())
            }
        )
    }

    /// The learner's turn.
    @MainActor
    static func userBlock(
        _ block: ReviewChatTranscriptBlock,
        message: ReviewSessionManager.Message,
        canEdit: Bool,
        isFindMatch: Bool
    ) -> Block {
        let text = ReviewSessionManager.displayableMessageContent(role: .user, content: message.content) ?? ""
        let stored = ChatContextAdditions.parse(contextContent: message.contextualContent)
        return Block(
            id: block.id.uuidString,
            kind: .user,
            messageID: message.id.uuidString,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text,
            passage: ChatPassageOrigin.parse(contextContent: message.contextualContent)?.quote,
            guess: ChatGuess.guess(contextContent: message.contextualContent),
            canEdit: canEdit ? true : nil,
            collapses: ChatLongUserMessage.isLong(text) ? true : nil,
            added: stored.added.isEmpty ? nil : Added(
                summary: ChatContextAdditions.summary(added: stored.added),
                sources: stored.added.map { Added.Source(id: $0.id, title: $0.title.isEmpty ? "Untitled source" : $0.title) }
            ),
            isFindMatch: isFindMatch ? true : nil
        )
    }

    // MARK: NSViewRepresentable

    static let templateURL: URL = {
        if let url = Bundle.main.url(
            forResource: "chat-transcript",
            withExtension: "html",
            subdirectory: "ChatRendererResources"
        ) {
            return url
        }
        return Bundle.main.url(forResource: "chat-transcript", withExtension: "html")
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ChatRendererResources/chat-transcript.html")
    }()

    static let messageNames = [
        "ready", "action", "sourceCards", "sourceImages", "copySourceImage", "zoomSourceImage",
        "openSourceImageBeside", "openSource", "webLinks", "selectionAction",
    ]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        let handler = WeakScriptMessageHandler(context.coordinator)
        for name in Self.messageNames {
            contentController.add(handler, name: name)
        }
        contentController.addUserScript(ChatMarkdownView.configurationScript)
        configuration.userContentController = contentController
        SharedWebKit.applySharedProcessPool(to: configuration)
        SharedWebKit.disableSystemWritingTools(on: configuration)
        let webView = PageWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // Files and sources dropped on the transcript go to the chat
        // (`InternalReviewPanel.handleDrop`), never into the page.
        webView.unregisterDraggedTypes()
        context.coordinator.webView = webView
        context.coordinator.parent = self
        webView.loadFileURL(Self.templateURL, allowingReadAccessTo: Self.templateURL.deletingLastPathComponent())
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.flush()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        for name in messageNames {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var parent: ChatTranscriptPage?
        weak var webView: WKWebView?
        private var isReady = false
        /// What the page holds, so only what changed is sent.
        private var sentBlocks: [String: Block] = [:]
        private var sentOrder: [String] = []
        private var sentTail: Tail?
        private var hasSentTail = false
        private var sentReserve: CGFloat?
        private var sentLayout: Layout?
        private var handledScrollToken: Int?
        /// A chat opened from history lands at its end, once.
        private var hasLanded = false

        func flush() {
            guard isReady, let parent, let webView else { return }
            let state = parent.state
            let encoder = JSONEncoder()
            var pieces: [String] = []
            var upserts: [String] = []
            for block in state.blocks where sentBlocks[block.id] != block {
                guard let data = try? encoder.encode(block), let json = String(data: data, encoding: .utf8) else { continue }
                upserts.append(json)
                sentBlocks[block.id] = block
            }
            if !upserts.isEmpty {
                pieces.append("\"upserts\":[\(upserts.joined(separator: ","))]")
            }
            let order = state.blocks.map(\.id)
            if order != sentOrder {
                let kept = Set(order)
                sentBlocks = sentBlocks.filter { kept.contains($0.key) }
                if let data = try? encoder.encode(order), let json = String(data: data, encoding: .utf8) {
                    pieces.append("\"order\":\(json)")
                }
                sentOrder = order
            }
            if !hasSentTail || state.tail != sentTail {
                if let tail = state.tail, let data = try? encoder.encode(tail), let json = String(data: data, encoding: .utf8) {
                    pieces.append("\"tail\":\(json)")
                } else {
                    pieces.append("\"tail\":null")
                }
                sentTail = state.tail
                hasSentTail = true
            }
            if state.reserve != sentReserve {
                pieces.append("\"reserve\":\(Double(state.reserve))")
                sentReserve = state.reserve
            }
            if state.layout != sentLayout,
               let data = try? encoder.encode(state.layout), let json = String(data: data, encoding: .utf8) {
                pieces.append("\"layout\":\(json)")
                sentLayout = state.layout
            }
            if !pieces.isEmpty {
                webView.evaluateJavaScript("window.transcriptApply({\(pieces.joined(separator: ","))});")
            }
            if !hasLanded, let last = state.blocks.last {
                hasLanded = true
                scroll(to: last.id, position: .bottom, animated: false, in: webView)
            }
            if let request = parent.scrollRequest, request.token != handledScrollToken {
                handledScrollToken = request.token
                scroll(to: request.blockID?.uuidString, position: request.position, animated: request.animated, in: webView)
            }
        }

        private func scroll(to blockID: String?, position: ScrollRequest.Position, animated: Bool, in webView: WKWebView) {
            let id = blockID.map { "\"\($0)\"" } ?? "null"
            webView.evaluateJavaScript("window.transcriptScrollTo(\(id), \"\(position.rawValue)\", \(animated));")
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let parent else { return }
            switch message.name {
            case "ready":
                isReady = true
                sentBlocks = [:]
                sentOrder = []
                sentTail = nil
                hasSentTail = false
                sentReserve = nil
                sentLayout = nil
                flush()
            case "action":
                handleAction(message.body, parent: parent, view: message.webView)
            case "sourceCards":
                resolveSourceCards(message.body, resolver: parent.resolvers.sourceCard)
            case "sourceImages":
                resolveSourceImages(message.body, resolver: parent.resolvers.sourceImage)
            case "copySourceImage":
                guard let token = (message.body as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !token.isEmpty else { return }
                let resolver = parent.resolvers.sourceImage
                Task { @MainActor in
                    await resolver(token)?.copyToPasteboard()
                }
            case "zoomSourceImage", "openSourceImageBeside":
                guard let body = message.body as? [String: Any],
                      let token = (body["token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !token.isEmpty else { return }
                let alt = (body["alt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = alt?.isEmpty == false ? alt : nil
                let resolver = parent.resolvers.sourceImage
                let window = message.webView?.window
                let zooms = message.name == "zoomSourceImage"
                Task { @MainActor in
                    guard let image = await resolver(token) else { return }
                    if zooms {
                        ChatImageLightbox.present(image, title: title, over: window)
                    } else {
                        ChatPictureWindow.present(DockedChatPicture(data: image.data, mediaType: image.mediaType, title: title))
                    }
                }
            case "openSource":
                guard let body = message.body as? [String: Any],
                      let token = (body["token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !token.isEmpty else { return }
                let seconds = (body["seconds"] as? NSNumber)?.doubleValue
                let passage = (body["passage"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let page = (body["page"] as? NSNumber)?.intValue
                parent.resolvers.openSource(ChatSourceLink(
                    sourceID: token,
                    seconds: seconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                    passage: passage?.isEmpty == false ? passage : nil,
                    page: page.flatMap { $0 >= 1 ? $0 : nil }
                ))
            case "webLinks":
                guard let body = message.body as? [String: Any],
                      let rawURL = body["url"] as? String,
                      let url = URL(string: rawURL),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else { return }
                let title = (body["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                parent.resolvers.openWebURL(url, title?.isEmpty == false ? title : nil)
            case "selectionAction":
                guard let body = message.body as? [String: Any],
                      let action = (body["action"] as? String).flatMap(ChatReplySelectionAction.init(rawValue:)),
                      let text = (body["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty,
                      let messageID = (body["messageID"] as? String).flatMap(UUID.init(uuidString:)) else { return }
                let anchor = ChatMarkdownView.Coordinator.selectionRect(in: body).map { rect in
                    ChatSelectionAnchor(rect: rect, screenRoom: ChatSelectionAnchor.screenRoom(around: rect, in: message.webView))
                }
                parent.resolvers.selection(action, text, messageID, anchor)
            default:
                break
            }
        }

        private func handleAction(_ body: Any, parent: ChatTranscriptPage, view: WKWebView?) {
            guard let body = body as? [String: Any], let type = body["type"] as? String else { return }
            let blockID = (body["blockID"] as? String).flatMap(UUID.init(uuidString:))
            switch type {
            case "copyAnswer":
                if let blockID { parent.onAction(.copyAnswer(blockID: blockID)) }
            case "copyMessage":
                if let blockID { parent.onAction(.copyMessage(blockID: blockID)) }
            case "editMessage":
                if let blockID { parent.onAction(.editMessage(blockID: blockID)) }
            case "sideQuestion":
                if let blockID { parent.onAction(.sideQuestion(blockID: blockID)) }
            case "openPassage":
                if let blockID { parent.onAction(.openPassage(blockID: blockID)) }
            case "moreMenu":
                guard let blockID, let view,
                      let rect = ChatMarkdownView.Coordinator.selectionRect(in: body) else { return }
                parent.onAction(.moreMenu(blockID: blockID, rect: rect, view: view))
            case "openContextSource":
                if let sourceID = body["sourceID"] as? String, !sourceID.isEmpty {
                    parent.onAction(.openContextSource(sourceID: sourceID))
                }
            case "suggestedQuestion":
                if let question = body["question"] as? String, !question.isEmpty {
                    parent.onAction(.suggestedQuestion(question))
                }
            default:
                break
            }
        }

        private func resolveSourceCards(_ body: Any, resolver: @escaping @MainActor (String) async -> ChatSourceCard?) {
            guard let values = body as? [Any] else { return }
            let tokens = values.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            Task { @MainActor [weak self] in
                guard let json = await ChatMarkdownView.sourceCardLookupJSON(tokens: tokens, sourceCardForToken: resolver),
                      let webView = self?.webView else { return }
                _ = try? await webView.evaluateJavaScript("window.setSourceCards(\(json));")
            }
        }

        private func resolveSourceImages(_ body: Any, resolver: @escaping @MainActor (String) async -> ChatSourceImage?) {
            guard let values = body as? [Any] else { return }
            let tokens = values.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            Task { @MainActor [weak self] in
                guard let json = await ChatMarkdownView.sourceImageLookupJSON(tokens: tokens, sourceImageForToken: resolver),
                      let webView = self?.webView else { return }
                _ = try? await webView.evaluateJavaScript("window.setSourceImages(\(json));")
            }
        }

        // MARK: Navigation

        /// The page is the template and nothing else: a link the renderer did
        /// not take, or anything dropped on it, never replaces it.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.request.url == ChatTranscriptPage.templateURL || navigationAction.targetFrame?.isMainFrame == false {
                decisionHandler(.allow)
                return
            }
            if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                parent?.resolvers.openWebURL(url, nil)
            }
            decisionHandler(.cancel)
        }

        /// A link that asks for a new window opens where a reply's links do.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                parent?.resolvers.openWebURL(url, nil)
            }
            return nil
        }

        /// The web process went away (memory pressure, a crash): load the page
        /// again and send it everything.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            isReady = false
            hasLanded = false
            webView.loadFileURL(ChatTranscriptPage.templateURL, allowingReadAccessTo: ChatTranscriptPage.templateURL.deletingLastPathComponent())
        }
    }

    /// The content controller holds its handlers strongly; this keeps it from
    /// holding the coordinator, and through it the panel, after the view goes.
    private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
        weak var target: (any WKScriptMessageHandler)?

        init(_ target: any WKScriptMessageHandler) {
            self.target = target
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(userContentController, didReceive: message)
        }
    }

    /// The page's web view: no Apple Intelligence badge on a selection, as in
    /// every chat web view, and the reply's three selection actions at the top
    /// of the right-click menu over selected words.
    private final class PageWebView: WKWebView {
        @objc(allowsWritingToolsAffordance)
        var allowsWritingToolsAffordance: Bool { SharedWebKit.allowsWritingToolsAffordance(in: self) }

        @objc(unionRectInVisibleSelectedRange)
        var unionRectInVisibleSelectedRange: NSRect { SharedWebKit.unionRectInVisibleSelectedRange(in: self) }

        override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
            super.willOpenMenu(menu, with: event)
            guard menu.items.contains(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }) else { return }
            let hadItems = !menu.items.isEmpty
            for (index, action) in ChatReplySelectionAction.allCases.enumerated() {
                let item = NSMenuItem(title: action.menuTitle, action: #selector(runSelectionAction(_:)), keyEquivalent: "")
                item.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.menuTitle)
                item.representedObject = action.rawValue
                item.target = self
                menu.insertItem(item, at: index)
            }
            if hadItems {
                menu.insertItem(.separator(), at: ChatReplySelectionAction.allCases.count)
            }
        }

        @objc private func runSelectionAction(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String else { return }
            evaluateJavaScript("window.requestSelectionAction && window.requestSelectionAction('\(raw)'); undefined;")
        }
    }
}
