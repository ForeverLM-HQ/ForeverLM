// A chat message's content, with the selection, browser-reveal and notebook-citation environment values.

import SwiftUI

/// What the pane that owns a transcript does with words selected in one of
/// its replies: quotes them into its own composer, asks for more details on
/// them under their reply, or opens a small chat about them over the passage.
/// Set by the pane that owns the transcript, so a popped-out or comparison
/// chat quotes into itself and never into the primary pane's draft. The
/// message id says which reply the words were read in; the anchor is where
/// they sit in that reply's view and on screen, when the page could measure
/// them.
struct ChatSelectionAction {
    let run: (ChatReplySelectionAction, String, UUID, ChatSelectionAnchor?) -> Void

    func callAsFunction(
        _ action: ChatReplySelectionAction,
        _ passage: String,
        in messageID: UUID,
        at anchor: ChatSelectionAnchor? = nil
    ) {
        run(action, passage, messageID, anchor)
    }
}

/// Opens the chat's Browser tab in the Browser pane — what clicking the
/// preview under a browser step does. Set by the panel that owns the chat.
struct ChatBrowserRevealAction {
    let reveal: () -> Void
    func callAsFunction() { reveal() }
}

private struct ChatBrowserRevealKey: EnvironmentKey {
    static let defaultValue: ChatBrowserRevealAction? = nil
}

extension EnvironmentValues {
    var chatBrowserReveal: ChatBrowserRevealAction? {
        get { self[ChatBrowserRevealKey.self] }
        set { self[ChatBrowserRevealKey.self] = newValue }
    }
}

/// The small live picture of the chat's Browser tab under a browser step:
/// the page as it stood when the step settled, refreshed as the chat works.
/// Clicking it opens the tab in the Browser pane.
struct ReviewChatBrowserPreview: View {
    let image: Data
    var isRunning = false
    @Environment(\.chatBrowserReveal) private var reveal

    static let width: CGFloat = 260

    var body: some View {
        Button {
            reveal?()
        } label: {
            ZStack(alignment: .bottomTrailing) {
                if let nsImage = NSImage(data: image) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Color.secondary.opacity(0.1)
                }
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .padding(4)
                        .background(.thinMaterial, in: Circle())
                        .padding(6)
                }
            }
            .frame(width: Self.width)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: -2))
        .disabled(reveal == nil)
        .help("Open this tab in the Browser")
        .accessibilityLabel("Browser preview")
        .accessibilityIdentifier("chat.browserPreview")
    }
}

/// A notebook's chat's citations (docs/chat-design.md, "Citations outside
/// the notebook"): which library sources the chat's notebook holds, so a
/// citation of one it does not is marked, and the notebook write that adds
/// one. Set by the chat panel for a chat filed in a notebook; nil elsewhere.
struct ChatNotebookCitations {
    let notebookID: String
    /// The notebook and its membership revision: a change asks every row's
    /// cards again.
    let revision: String
    /// Whether the notebook holds the source a card names.
    let holds: @MainActor (String) -> Bool
    /// Adds the source a link token names to the notebook; nil when the
    /// notebook takes no sources (a read-only team's, an archived one).
    let add: (@MainActor (String) async -> Void)?
}

private struct ChatNotebookCitationsKey: EnvironmentKey {
    static let defaultValue: ChatNotebookCitations? = nil
}

extension EnvironmentValues {
    var chatNotebookCitations: ChatNotebookCitations? {
        get { self[ChatNotebookCitationsKey.self] }
        set { self[ChatNotebookCitationsKey.self] = newValue }
    }
}

private struct ChatSelectionActionKey: EnvironmentKey {
    static let defaultValue: ChatSelectionAction? = nil
}

extension EnvironmentValues {
    var chatSelectionAction: ChatSelectionAction? {
        get { self[ChatSelectionActionKey.self] }
        set { self[ChatSelectionActionKey.self] = newValue }
    }
}

struct ReviewChatMessageContent: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(\.chatSelectionAction) private var selectionAction
    @Environment(\.chatNotebookCitations) private var notebookCitations
    @Environment(\.chatReplySideChat) private var sideChat
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    @Environment(\.openWindow) private var openWindow
    let messageID: UUID
    let content: String
    var rendersMarkdown = true
    var citationContext = ChatCitationLedger.MessageContext()
    /// A learner message's Reader passage, drawn as a quote above its words
    /// when the words themselves carry none.
    var passage: ChatPassageOrigin.Passage?
    /// Opens `passage` in the Reader; the quote is a button when it is set.
    var openPassage: ((ChatPassageOrigin.Passage) -> Void)?
    @State private var renderedHeight: CGFloat

    @MainActor
    init(
        messageID: UUID,
        content: String,
        rendersMarkdown: Bool = true,
        citationContext: ChatCitationLedger.MessageContext = .init(),
        passage: ChatPassageOrigin.Passage? = nil,
        openPassage: ((ChatPassageOrigin.Passage) -> Void)? = nil
    ) {
        self.messageID = messageID
        self.content = content
        self.rendersMarkdown = rendersMarkdown
        self.citationContext = citationContext
        self.passage = passage
        self.openPassage = openPassage
        // Open at an estimate from the text rather than one line, so the
        // measurement a frame later moves the column by a few lines at most.
        _renderedHeight = State(
            initialValue: rendersMarkdown
                ? ChatMarkdownHeightEstimate.estimatedHeight(
                    markdown: content,
                    width: ChatMarkdownHeightEstimate.defaultEstimateWidth,
                    fontSize: ChatMarkdownView.baseFontSize
                )
                : 36
        )
    }

    var body: some View {
        Group {
            if rendersMarkdown {
                ChatMarkdownView(
                    identity: messageID,
                    markdown: content,
                    citationContext: citationContext,
                    height: $renderedHeight,
                    onOpenSource: { link in
                        Task {
                            await vm.openLinkedSourceInReader(
                                link.sourceID, at: link.seconds, passage: link.passage, page: link.page
                            )
                        }
                    },
                    onOpenWebURL: { url, title in
                        vm.openWebCitationInReader(url, title: title)
                    },
                    // "Open Link in New Window" on a citation or a Sources row:
                    // the source in a Studio window of its own, as the Docs
                    // page and the sidebar already offer.
                    onOpenSourceInNewWindow: { link in
                        Task {
                            guard let article = await vm.persistedArticle(forLinkToken: link.sourceID) else {
                                vm.showToast("Source not found in library")
                                return
                            }
                            StudioOtherWindowTargets.openInNewWindow(article.id, from: windowState, vm: vm) {
                                openWindow(id: "studio")
                            }
                        }
                    },
                    sourceWindowTargets: {
                        StudioOtherWindowTargets.targets(excluding: windowState, vm: vm).map { target in
                            LinkedDocWebView.SourceWindowTarget(label: target.label) { link in
                                Task {
                                    guard let article = await vm.persistedArticle(forLinkToken: link.sourceID) else {
                                        vm.showToast("Source not found in library")
                                        return
                                    }
                                    StudioOtherWindowTargets.open(article.id, in: target.state, from: windowState, vm: vm)
                                }
                            }
                        }
                    },
                    onSelectionAction: { action, passage, anchor in
                        selectionAction?(action, passage, in: messageID, at: anchor)
                    },
                    sourceCardForToken: { [notebookCitations] sourceToken in
                        guard let article = await vm.persistedArticle(forLinkToken: sourceToken) else { return nil }
                        let card = await ChatSourceCard.resolved(
                            article: article,
                            collectionTitle: vm.sourceGroupTitle(for: article)
                        )
                        // In a notebook's chat, a source it does not hold is marked.
                        guard let notebookCitations else { return card }
                        return card.inNotebook(notebookCitations.holds(article.id))
                    },
                    sourceImageForToken: { imageToken in
                        await ChatSourceImage.resolved(
                            token: imageToken,
                            articleForSourceID: { sourceID in await vm.persistedArticle(forLinkToken: sourceID) },
                            contentForSourceID: { sourceID in await vm.storage.loadSourceContent(sourceID) },
                            citedPapersForSource: { sourceID in await vm.loadCitedPapers(forSourceID: sourceID) }
                        )
                    },
                    addSlideCitedPaper: { paperID in
                        await vm.importCitedPaper(id: paperID)
                    },
                    citationScopeKey: notebookCitations?.revision ?? "",
                    addSourceToNotebook: notebookCitations?.add,
                    // Open beside on a figure: a picture window.
                    openPictureBeside: { picture in
                        ChatPictureWindow.present(picture)
                    },
                    // Right-click a picture a quiz or the chat drew: what drew
                    // it, and Redraw With another image model.
                    redrawPicture: { versionID, model, prompt in
                        await GeneratedImageRedrawCenter.shared.redraw(
                            id: versionID, with: model, prompt: prompt, usageTask: "chat_image", vm: vm
                        )
                    }
                )
                    .frame(height: renderedHeight)
                    // The side chat about words selected in this reply hangs
                    // off the words themselves, as the bar over them did; the
                    // whole reply stands in when the page could not measure.
                    // It opens on the side of the words with room for it to
                    // grow (`ChatReplySideChatPlacement`).
                    .popover(
                        isPresented: Binding(
                            get: { sideChat?.model.messageID == messageID },
                            set: { shown in if !shown { sideChat?.dismiss() } }
                        ),
                        attachmentAnchor: sideChat?.model.anchor.map { PopoverAttachmentAnchor.rect(.rect($0)) }
                            ?? PopoverAttachmentAnchor.rect(.bounds),
                        arrowEdge: sideChat?.model.placement.side == .above ? .top : .bottom
                    ) {
                        if let sideChat, sideChat.model.messageID == messageID {
                            // A side chat on other words of this reply is a
                            // new popover: its field takes focus again and it
                            // measures its own exchange, not the last one's.
                            ReviewChatSideChatPopover(presentation: sideChat)
                                .id(ObjectIdentifier(sideChat.model))
                        }
                    }
                    // Assistant markdown fills the column: the WebView needs a
                    // definite width to lay out and report its height.
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Explicit zoom-scaled size rather than `.font(.body)`: macOS
                // leaves the text styles at their fixed point sizes, so a
                // `.body` user bubble stayed put while assistant markdown grew
                // with the app zoom.
                //
                // No `maxWidth: .infinity` here: the user bubble hugs its text
                // and is placed against the trailing edge by its row's
                // `ChatUserMessageColumn`. Filling the column instead stretched a three-word
                // question into a pill spanning the whole transcript.
                if ChatLongUserMessage.isLong(content) {
                    // A long paste folds instead of being drawn as one selectable
                    // `Text`: with the window-wide `.textSelection(.enabled)`,
                    // an 11 KB transcript in this bubble pinned the main thread
                    // in SwiftUI's selection overlay until the app was
                    // force-quit. See `ChatLongUserMessage`.
                    ReviewChatLongUserMessageView(content: content)
                } else if let quoted = ChatQuoteDraft.split(userMessage: content) {
                    // A message that opened with a quoted passage draws the
                    // passage as a quote, the way the reply it came from drew
                    // its own blockquotes, and the question beneath as typed.
                    quotedUserMessage(quote: quoted.quote, body: quoted.body)
                } else if let passage {
                    // A question asked on a Reader selection: the highlighted
                    // words rode beside it as context, and are drawn the same
                    // way above what was typed. A click on them opens the
                    // source in the Reader at those words.
                    quotedUserMessage(
                        quote: passage.quote,
                        body: content,
                        open: openPassage.map { open in { open(passage) } }
                    )
                } else {
                    Text(content)
                        .zoomedSystemFont(size: ChatMarkdownView.baseFontSize)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A passage selected over an equation carries the TeX the reply was
    /// written in (`\(^{23}\mathrm{Na}\)`), which is what the model reads; the
    /// bubble shows it folded into the text the reply showed (`²³Na`), not
    /// the markup.
    private func quotedUserMessage(quote: String, body: String, open: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let open {
                Button(action: open) {
                    quoteBlock(quote)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, opacity: 0.10))
                .help("Show in the Reader")
                .accessibilityLabel("Show this passage in the Reader: \(quote.foldingTeXForPreview())")
            } else {
                quoteBlock(quote)
                    .textSelection(.enabled)
            }
            if !body.isEmpty {
                Text(body)
                    .zoomedSystemFont(size: ChatMarkdownView.baseFontSize)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func quoteBlock(_ quote: String) -> some View {
        Text(quote.foldingTeXForPreview())
            .zoomedSystemFont(size: ChatMarkdownView.baseFontSize)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 9)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(0.22))
                    .frame(width: 3)
            }
    }
}
