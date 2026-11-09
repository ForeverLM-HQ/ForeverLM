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
/// Every chat draws here (product owner, 2026-11-08: "Yes, finish the move"):
/// side questions' lanes, pictures, video moments, walks, Pages, browser steps
/// and saved cards included. Only a memory review dealt as cards keeps its own
/// native surface, one card's exchange at a time.
struct ChatTranscriptPage: NSViewRepresentable {
    // MARK: What the page draws

    /// One row of the transcript: the learner's turn, a reply, or a side
    /// question's lane heading and the card of ways on under it.
    struct Block: Encodable, Equatable {
        enum Kind: String, Encodable {
            case user
            case answer
            case laneHead
            case laneCard
        }

        let id: String
        let kind: Kind
        /// The lane this row sits in, by its heading's id: it folds with it.
        var lane: String?
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
        /// The pictures the message carries, as the Markdown image lines the
        /// app wrote (`AttachedImageReference`), which the renderer resolves.
        var images: String?
        /// The moments of a video the question was asked at.
        var moments: [Moment]?
        // A reply.
        var parts: [Part]?
        var footer: Footer?
        var isLatest: Bool?
        var isLive: Bool?
        var isFindMatch: Bool?
        // A lane's heading (`ReviewChatAsideLane`).
        var laneTitle: String?
        /// The side question's first line, shown while the lane is folded.
        var laneLine: String?
        var laneReplies: Int?
        /// "the quiz waits": the newest lane while a question stands open.
        var laneWaits: Bool?
        /// Open unless the learner folds it: the newest or the live lane.
        var laneOpen: Bool?
        var laneMoreDetails: Bool?
        // The card under the newest lane (`ReviewChatOpenQuestionCard`).
        var openQuestion: String?
        var followUp: Bool?
        var newChat: Bool?
    }

    struct Added: Encodable, Equatable {
        struct Source: Encodable, Equatable {
            let id: String
            let title: String
        }

        let summary: String
        let sources: [Source]
    }

    /// A video moment over the learner's question. The page asks for its
    /// frame (`momentFrames`); a click plays the video from there.
    struct Moment: Encodable, Equatable {
        let sourceID: String
        let seconds: Int
        let clock: String
        let title: String
        let hasFrame: Bool
    }

    /// A piece of a reply: its prose, its steps folded to one line, the Pages
    /// it names, a walk's resume row, a memory review's turn to a source or
    /// topic, or the cards a call saved.
    struct Part: Encodable, Equatable {
        enum Kind: String, Encodable {
            case prose
            case work
            case pages
            case resume
            case turn
            case savedCards
        }

        let kind: Kind
        let id: String
        // Prose.
        var markdown: String?
        var citations: ChatCitationLedger.MessageContext?
        var webSources: [WebSource]?
        // Steps; a resume row's, a turn's and saved cards' words too.
        var title: String?
        var subtitle: String?
        var failed: String?
        var running: Bool?
        var settled: Bool?
        /// Open by default: the turn is still working and no answer has begun.
        var opensWhileLive: Bool?
        var steps: [Step]?
        /// The newest browser step's picture as a data URL, and that step's
        /// index: under the line while the turn works with its steps folded,
        /// under the step once they are open.
        var preview: String?
        var previewStep: Int?
        /// What failed steps ask the learner to set up, a card each.
        var setup: [Setup]?
        /// Pages, under the steps or on their own.
        var pages: [PageCard]?
        /// The source a resume row or a turn heading opens.
        var sourceID: String?
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

    struct PageCard: Encodable, Equatable {
        let id: String
        let title: String
        /// `animation` for an animation `save_animation` saved, which the card
        /// plays in a frame at `url`; nil for a page.
        var kind: String?
        var url: String?
    }

    /// A plugin a failed step needed (`ChatPluginSetupCard`).
    struct Setup: Encodable, Equatable {
        let title: String
        let body: String
        let action: String
        let help: String
    }

    struct Footer: Encodable, Equatable {
        struct SideQuestion: Encodable, Equatable {
            let armed: Bool
            /// Inside a lane the icon asks a follow-up.
            var followUp = false
        }

        var copyLabel: String?
        var sideQuestion: SideQuestion?
        /// Skip, while a quiz question waits for its answer.
        var skip: Bool?
        var more: Bool
    }

    /// What follows the last turn.
    struct Tail: Encodable, Equatable {
        struct Working: Encodable, Equatable {
            let label: String
            /// Milliseconds since 1970, which the page counts from.
            let startedAt: Double
        }

        /// Sources brought in since the last message, waiting to go with the
        /// next one.
        var pending: Added?
        var suggested: [String]?
        /// A memory review's Go deeper and Next.
        var steer: Bool?
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
        /// A finished review's graded summary, over the first turn.
        var summary: String?
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
        /// A block's id, or a lane heading's (`lane:<id>`).
        let blockID: String?
        let position: Position
        var animated = false
        /// The block is a lane heading the learner asked to see again: it
        /// opens if it was folded.
        var opensLane = false
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
        /// A video moment over a question: play from there.
        case openMoment(sourceID: String, seconds: Int)
        case skipQuizQuestion
        /// A memory review's Go deeper (false) or Next (true).
        case steer(next: Bool)
        // The card under the newest lane.
        case laneAnswer
        case laneSkip
        case laneFollowUp
        case laneNewChat
        /// A walk's resume row.
        case resumeWalk(sourceID: String)
        case openPage(id: String)
        /// An animation card's Enlarge: the animation played in a sheet.
        case enlargeAnimation(id: String, title: String)
        /// A saved-cards card's Open: the deck, over where it was drawn.
        case openSavedCards(blockID: UUID, partID: UUID, rect: CGRect, view: NSView)
        /// A plugin card's button, by its place among its steps' needs.
        case pluginSetup(blockID: UUID, partID: UUID, index: Int)
        case revealBrowser
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

    // MARK: Building blocks

    /// What a reply's steps ask the learner to set up: a plugin that was not
    /// there to read with (`ReviewChatWorkFold.setupNeeds`).
    static func setupNeeds(_ work: ReviewChatWork) -> [ChatPluginRequest.SetupNeed] {
        ChatPluginRequest.setupNeeds(in: work.steps.filter { $0.kind != .thinking }.map { activity in
            (toolName: activity.toolName, error: activity.state == .failed ? activity.resultPreview : nil)
        })
    }

    /// Pages as their cards, each by its title as it stands now; an
    /// animation's carries the library address its frame plays.
    static func pageCards(_ pages: [ChatWrittenPage], title: (ChatWrittenPage) -> String) -> [PageCard] {
        pages.map { page in
            PageCard(
                id: page.id,
                title: title(page),
                kind: page.kind == .animation ? page.kind.rawValue : nil,
                url: page.animationURL?.absoluteString
            )
        }
    }

    /// A reply's steps as the page's fold draws them, with the newest
    /// browser picture, the plugins a failed step needed, and the Pages the
    /// steps wrote.
    @MainActor
    static func workPart(
        _ work: ReviewChatWork,
        isLive: Bool,
        pageTitle: (ChatWrittenPage) -> String = { $0.title.isEmpty ? "Untitled" : $0.title }
    ) -> Part {
        let working = isLive && !work.answerHasBegun
        let failedCount = work.steps.filter { $0.state == .failed }.count
        let previewIndex = work.steps.lastIndex { $0.isBrowserStep && $0.previewImage != nil }
        let setup = setupNeeds(work)
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
            steps: steps,
            preview: previewIndex.flatMap { work.steps[$0].previewImage }.map(dataURL),
            previewStep: previewIndex,
            setup: setup.isEmpty ? nil : setup.map { need in
                Setup(title: need.title, body: need.body, action: need.actionTitle, help: need.actionHelp)
            },
            pages: work.pages.isEmpty ? nil : pageCards(work.pages, title: pageTitle)
        )
    }

    /// A picture as the page shows it: JPEG and PNG say which they are by
    /// their first bytes.
    nonisolated static func dataURL(_ data: Data) -> String {
        let type = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
        return "data:\(type);base64,\(data.base64EncodedString())"
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

    /// The learner's turn: their words, and the pictures, video moments,
    /// passage and sources that came with them.
    @MainActor
    static func userBlock(
        _ block: ReviewChatTranscriptBlock,
        message: ReviewSessionManager.Message,
        canEdit: Bool,
        isFindMatch: Bool,
        lane: String? = nil
    ) -> Block {
        // Pictures are drawn from the raw content over the bubble, which
        // shows only what was typed, or nothing when the message was the
        // pictures (`ReviewChatBubble`).
        let attached = AttachedImageReference.split(message.content)
        let text = ReviewSessionManager.displayableMessageContent(
            role: .user,
            content: attached.images.isEmpty ? message.content : attached.text
        ) ?? ""
        let stored = ChatContextAdditions.parse(contextContent: message.contextualContent)
        let moments = ReviewChatVideoMomentRow.moments(in: stored.onScreen)
        return Block(
            id: block.id.uuidString,
            kind: .user,
            lane: lane,
            messageID: message.id.uuidString,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text,
            passage: ChatPassageOrigin.parse(contextContent: message.contextualContent)?.quote,
            guess: ChatGuess.guess(contextContent: message.contextualContent),
            canEdit: canEdit ? true : nil,
            collapses: ChatLongUserMessage.isLong(text) ? true : nil,
            added: added(stored.added),
            images: attached.images.isEmpty ? nil : attached.images
                .map { $0.reference.markdown(alt: $0.alt) }
                .joined(separator: "\n\n"),
            moments: moments.isEmpty ? nil : moments.map { moment in
                Moment(
                    sourceID: moment.sourceID,
                    seconds: moment.moment.at,
                    clock: moment.moment.clock,
                    title: moment.title.isEmpty ? "Video" : moment.title,
                    hasFrame: moment.moment.frame == true
                )
            },
            isFindMatch: isFindMatch ? true : nil
        )
    }

    /// "Added 3 articles to context" and the sources by name.
    static func added(_ sources: [ChatContextAdditions.Source]) -> Added? {
        guard !sources.isEmpty else { return nil }
        return Added(
            summary: ChatContextAdditions.summary(added: sources),
            sources: sources.map { Added.Source(id: $0.id, title: $0.title.isEmpty ? "Untitled source" : $0.title) }
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
        "openSourceImageBeside", "openSource", "webLinks", "selectionAction", "momentFrames",
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
        // An animation a reply saved plays in its card's frame from its
        // library address, under the card player's policy: scripts run in a
        // sandbox of their own, nothing loads from the network
        // (`LocalSiteServing.cardContentSecurityPolicy`).
        LocalSiteSchemeHandler.installCardPlayer(on: configuration)
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
        private var sentSummary: String?
        private var hasSentSummary = false
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
            if !hasSentSummary || state.summary != sentSummary {
                if let summary = state.summary, let data = try? encoder.encode(summary),
                   let json = String(data: data, encoding: .utf8) {
                    pieces.append("\"summary\":\(json)")
                } else {
                    pieces.append("\"summary\":null")
                }
                sentSummary = state.summary
                hasSentSummary = true
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
                scroll(to: request.blockID, position: request.position, animated: request.animated, opensLane: request.opensLane, in: webView)
            }
        }

        private func scroll(
            to blockID: String?,
            position: ScrollRequest.Position,
            animated: Bool,
            opensLane: Bool = false,
            in webView: WKWebView
        ) {
            let id = blockID.map { "\"\($0)\"" } ?? "null"
            webView.evaluateJavaScript(
                "window.transcriptScrollTo(\(id), \"\(position.rawValue)\", \(animated), \(opensLane));"
            )
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // Only the transcript page itself, never a reply's visualization
            // frame (`ScriptMessageSender`).
            guard message.isFrom(.appFile), let parent else { return }
            switch message.name {
            case "ready":
                isReady = true
                sentBlocks = [:]
                sentOrder = []
                sentTail = nil
                hasSentTail = false
                sentSummary = nil
                hasSentSummary = false
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
            case "momentFrames":
                resolveMomentFrames(message.body)
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
            case "openMoment":
                if let sourceID = body["sourceID"] as? String, !sourceID.isEmpty,
                   let seconds = (body["seconds"] as? NSNumber)?.intValue {
                    parent.onAction(.openMoment(sourceID: sourceID, seconds: seconds))
                }
            case "skipQuizQuestion":
                parent.onAction(.skipQuizQuestion)
            case "steer":
                parent.onAction(.steer(next: (body["next"] as? Bool) == true))
            case "laneAnswer":
                parent.onAction(.laneAnswer)
            case "laneSkip":
                parent.onAction(.laneSkip)
            case "laneFollowUp":
                parent.onAction(.laneFollowUp)
            case "laneNewChat":
                parent.onAction(.laneNewChat)
            case "resumeWalk":
                if let sourceID = body["sourceID"] as? String, !sourceID.isEmpty {
                    parent.onAction(.resumeWalk(sourceID: sourceID))
                }
            case "openPage":
                if let id = body["pageID"] as? String, !id.isEmpty {
                    parent.onAction(.openPage(id: id))
                }
            case "enlargeAnimation":
                if let id = body["pageID"] as? String, !id.isEmpty {
                    parent.onAction(.enlargeAnimation(id: id, title: body["title"] as? String ?? ""))
                }
            case "openSavedCards":
                guard let blockID, let view,
                      let partID = (body["partID"] as? String).flatMap(UUID.init(uuidString:)),
                      let rect = ChatMarkdownView.Coordinator.selectionRect(in: body) else { return }
                parent.onAction(.openSavedCards(blockID: blockID, partID: partID, rect: rect, view: view))
            case "pluginSetup":
                guard let blockID,
                      let partID = (body["partID"] as? String).flatMap(UUID.init(uuidString:)),
                      let index = (body["index"] as? NSNumber)?.intValue else { return }
                parent.onAction(.pluginSetup(blockID: blockID, partID: partID, index: index))
            case "revealBrowser":
                parent.onAction(.revealBrowser)
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

        /// The frames a video moment was asked at, read off the main actor,
        /// as data URLs by "sourceID@seconds"; a frame this Mac never held is
        /// left out, and its button keeps the play glyph.
        private func resolveMomentFrames(_ body: Any) {
            guard let values = body as? [[String: Any]] else { return }
            let wanted: [(sourceID: String, seconds: Int)] = values.compactMap { value in
                guard let sourceID = value["sourceID"] as? String, !sourceID.isEmpty,
                      let seconds = (value["seconds"] as? NSNumber)?.intValue else { return nil }
                return (sourceID, seconds)
            }
            guard !wanted.isEmpty else { return }
            Task { @MainActor [weak self] in
                let frames = await Task.detached(priority: .utility) { () -> [String: String] in
                    var frames: [String: String] = [:]
                    for (sourceID, seconds) in wanted {
                        guard let path = SlideFrameExtraction.existingMomentFramePath(sourceID: sourceID, seconds: seconds),
                              let data = FileManager.default.contents(atPath: path) else { continue }
                        frames["\(sourceID)@\(seconds)"] = ChatTranscriptPage.dataURL(data)
                    }
                    return frames
                }.value
                let encoder = JSONEncoder()
                encoder.outputFormatting = .withoutEscapingSlashes
                guard !frames.isEmpty, let webView = self?.webView,
                      let data = try? encoder.encode(frames),
                      let json = String(data: data, encoding: .utf8) else { return }
                _ = try? await webView.evaluateJavaScript("window.setMomentFrames(\(json));")
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
            // A reply's visualization frame loads its own document and nothing
            // more (`ChatMarkdownView`): sending itself, or the page, to an
            // address would carry whatever its program put there off the Mac,
            // and a link its script clicks is the same thing.
            if navigationAction.targetFrame?.isMainFrame == false {
                // An animation card's frame loads its animation from the
                // library and moves within it; nothing else.
                let url = navigationAction.request.url
                let isAnimation = url.flatMap(LinkedPage.localSiteID(from:)) != nil
                decisionHandler(url?.scheme?.lowercased() == "about" || isAnimation ? .allow : .cancel)
                return
            }
            if navigationAction.request.url == ChatTranscriptPage.templateURL {
                decisionHandler(.allow)
                return
            }
            if navigationAction.sourceFrame.isMainFrame,
               let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
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
            guard navigationAction.sourceFrame.isMainFrame else { return nil }
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
