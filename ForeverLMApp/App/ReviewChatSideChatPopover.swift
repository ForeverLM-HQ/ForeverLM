import SwiftUI

/// The side chat a pane has open over one of its replies, handed to the reply
/// row that hangs the popover: the model to draw, and what closing it or
/// moving it to a new chat does — both the pane's business, since the pane
/// owns the model and the neighbouring chat.
struct ChatReplySideChatPresentation {
    let model: ChatReplySideChatModel
    let dismiss: () -> Void
    let continueInChat: () -> Void
}

private struct ChatReplySideChatKey: EnvironmentKey {
    static let defaultValue: ChatReplySideChatPresentation? = nil
}

extension EnvironmentValues {
    var chatReplySideChat: ChatReplySideChatPresentation? {
        get { self[ChatReplySideChatKey.self] }
        set { self[ChatReplySideChatKey.self] = newValue }
    }
}

/// The popover over words selected in a reply: the passage as its heading, the
/// exchange about it, and a field. A question and its answer, a follow-up or
/// two, with one way out to a full chat when the learner wants more than a
/// popover holds (`ChatReplySideChat`). The Reader's selection bar opens the
/// same popover over words in a source (`View.readerSideChat(for:)`).
///
/// Sized for reading the answer (product owner, 2026-09-27: "this side chat popup
/// is too small"): a line as long as a comfortable line of the chat's own
/// text, and as tall as the exchange, up to a question and an answer of two
/// short paragraphs before it scrolls, all at the chat's zoom. It grows as the
/// answer streams in, and never past the room the screen leaves on the side
/// of the words it opened on (`ChatReplySideChatPlacement`), so it never has
/// to jump across them.
///
/// It stays open until its X is clicked (product owner, 2026-09-28: "i only want
/// that to disappear when i click the X on it; not if i click anywhere
/// outside of that side chat"). A click in the chat beside it, in another
/// window or another app, and Escape, all leave it where it is.
struct ReviewChatSideChatPopover: View {
    let presentation: ChatReplySideChatPresentation
    @Environment(\.uiZoomScale) private var zoom
    @FocusState private var isFieldFocused: Bool
    /// The exchange's own height, as its stack lays out; nil before anything
    /// has been asked. A macOS popover takes its size from its content once,
    /// as it opens, and a scroll view held only by a maximum never asks for
    /// more, so the answer stayed at the popover's opening height however
    /// long it grew. The scroll view is given this height instead, up
    /// to the room left, and the popover follows it.
    @State private var exchangeHeight: CGFloat?
    /// The heading and its rule, as laid out: what the exchange shares the
    /// popover's height with above it.
    @State private var headingHeight: CGFloat = 0
    /// The field, its rule and any error line over it: the rest of what the
    /// exchange shares the height with.
    @State private var footerHeight: CGFloat = 0

    /// The width at zoom one: about 65 characters of the answer's 13-point
    /// text to a line, which is a comfortable measure to read at. The old
    /// fixed 400 points held some 45 characters at the default zoom.
    static let baseWidth: CGFloat = 440
    /// The height at zoom one the popover may grow to where the screen has
    /// room: its heading and field, a question, and an answer of the two short
    /// paragraphs the side chat's instructions ask for (`Prompts.replySideChat`),
    /// whole. A longer exchange scrolls inside it.
    static let baseFullHeight: CGFloat = 560
    /// The least of the popover's height the exchange keeps, at zoom one,
    /// however little room the screen leaves: two lines of the answer.
    static let baseMinimumExchangeHeight: CGFloat = 44

    /// The popover's width at the chat's zoom.
    static func width(zoom: CGFloat) -> CGFloat {
        (baseWidth * zoom).rounded()
    }

    /// The tallest the popover grows at the chat's zoom, before the screen has
    /// its say. The pane picks the popover's side of the words for this height
    /// (`ChatReplySideChatPlacement.choose`), and the popover holds itself to
    /// the smaller of it and the room on that side.
    static func fullHeight(zoom: CGFloat) -> CGFloat {
        (baseFullHeight * zoom).rounded()
    }

    private var model: ChatReplySideChatModel { presentation.model }

    /// The tallest the popover may be: its own full height, or the room the
    /// screen leaves on the side of the words it opened on, if less.
    private var heightLimit: CGFloat {
        let full = Self.fullHeight(zoom: zoom)
        guard let room = model.placement.maximumHeight else { return full }
        return min(full, room)
    }

    /// The exchange's scroll view: as tall as the exchange while it fits, and
    /// what is left of the limit once it does not, with the answer scrolling
    /// inside. Nil until the exchange has measured, so the first layout is
    /// the stack's own.
    private var transcriptHeight: CGFloat? {
        guard let exchangeHeight else { return nil }
        let left = heightLimit - headingHeight - footerHeight
        return min(exchangeHeight, max(left, (Self.baseMinimumExchangeHeight * zoom).rounded()))
    }

    var body: some View {
        @Bindable var model = presentation.model
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                heading
                Divider()
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                headingHeight = height
            }
            transcript
            VStack(alignment: .leading, spacing: 0) {
                if let error = model.errorMessage {
                    Text(error)
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                        .accessibilityIdentifier("mac.chatSideChatError")
                }
                // Before the first question the heading's rule sits over the
                // field already.
                if !model.turns.isEmpty {
                    Divider()
                }
                field(draft: $model.draft)
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                footerHeight = height
            }
        }
        .frame(width: Self.width(zoom: zoom))
        // Words selected in the side chat's own replies stay in the side chat:
        // quoted into its field, or expanded here. Nothing opens a popover
        // over a popover.
        .environment(\.chatSelectionAction, ChatSelectionAction { action, passage, _, _ in
            switch action {
            case .quote, .sideChat:
                presentation.model.quote(passage)
                isFieldFocused = true
            case .moreDetails:
                presentation.model.ask(
                    ChatQuoteDraft.compose(quote: passage, body: ChatReplySideChatModel.moreDetailsQuestion)
                )
            }
        })
        // A group of its own: on a plain container the identifier replaced
        // Continue's, Close's, the passage's and the field's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac.chatSideChatPopover")
        // A macOS popover is transient: the first click anywhere outside it
        // closed it, and the exchange with it. Only the X closes it now.
        .interactiveDismissDisabled()
        .onAppear { isFieldFocused = true }
    }

    /// The words this is about, the way out to a full chat, and the X.
    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: model.context.origin == .thread ? "bubble.left.and.bubble.right" : "text.quote")
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.secondary)
            Text(model.context.origin == .thread ? "Side chat about this conversation" : model.context.passageHeadline)
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("mac.chatSideChatPassage")
            Spacer(minLength: 8)
            Button {
                presentation.continueInChat()
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4))
            .help(continueHelp)
            .accessibilityLabel("Continue in a new chat")
            .accessibilityIdentifier("mac.chatSideChatContinue")
            Button {
                presentation.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4))
            .help("Close the side chat")
            .accessibilityLabel("Close")
            .accessibilityIdentifier("mac.chatSideChatClose")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// What the arrow does: the new chat takes the sources of the chat the
    /// words were in, or the source they were read in.
    private var continueHelp: String {
        let sources: String
        switch model.context.origin {
        case .reply, .thread: sources = "this chat's sources"
        case .reader: sources = "this source"
        }
        if model.context.origin == .thread, !model.hasExchange {
            return "Branch this chat into a new one"
        }
        return model.hasExchange
            ? "Continue this side chat in a new chat, with \(sources)"
            : "Ask about this passage in a new chat, with \(sources)"
    }

    /// Nothing until the first question: the heading and the field say what
    /// the popover is for.
    @ViewBuilder
    private var transcript: some View {
        if !model.turns.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.turns) { turn in
                            turnView(turn)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("end")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                        exchangeHeight = height
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: transcriptHeight)
                // New lines exist once the answer's page has laid them out and
                // the exchange has grown, not when the text arrives; keep the
                // newest in view once the exchange scrolls.
                .onChange(of: exchangeHeight) { _, _ in
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
            .accessibilityIdentifier("mac.chatSideChatTranscript")
        }
    }

    @ViewBuilder
    private func turnView(_ turn: ChatReplySideChatModel.Turn) -> some View {
        switch turn.speaker {
        case .learner:
            HStack {
                Spacer(minLength: 32)
                // A question that opened with a quoted passage ("More details"
                // on words in the answer) draws the passage as a quote, TeX
                // folded into readable text, and the words beneath as typed —
                // the way the main transcript draws the same message.
                learnerText(turn.text)
                    .zoomedSystemFont(size: ChatMarkdownView.baseFontSize)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    )
            }
            .accessibilityIdentifier("mac.chatSideChatQuestion")
        case .tutor:
            if turn.text.isEmpty {
                // The answer has not started arriving; the row says so
                // rather than standing empty.
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Thinking…")
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .accessibilityIdentifier("mac.chatSideChatThinking")
            } else {
                // Drawn at the popover's width, not the transcript's, so its
                // height stays out of the transcript's height memory.
                ReviewChatMessageContent(messageID: turn.id, content: turn.text, remembersHeight: false)
                    .accessibilityIdentifier("mac.chatSideChatAnswer")
            }
        }
    }

    @ViewBuilder
    private func learnerText(_ text: String) -> some View {
        if let quoted = ChatQuoteDraft.split(userMessage: text) {
            VStack(alignment: .leading, spacing: 6) {
                Text(quoted.quote.foldingTeXForPreview())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 9)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.primary.opacity(0.22))
                            .frame(width: 3)
                    }
                if !quoted.body.isEmpty {
                    Text(quoted.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Text(text)
        }
    }

    private func field(draft: Binding<String>) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this passage…", text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .zoomedSystemFont(size: ChatMarkdownView.baseFontSize)
                .lineLimit(1...6)
                .focused($isFieldFocused)
                .onSubmit { send() }
                .accessibilityIdentifier("mac.chatSideChatField")
            if model.isAnswering {
                Button {
                    model.cancel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .zoomedSystemFont(size: 18)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverWash(in: Circle(), opacity: 0.12))
                .help("Stop the answer")
                .accessibilityLabel("Stop")
                .accessibilityIdentifier("mac.chatSideChatStop")
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .zoomedSystemFont(size: 18)
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.hoverWash(in: Circle(), opacity: 0.12))
                .disabled(!canSend)
                .help("Ask")
                .accessibilityLabel("Ask")
                .accessibilityIdentifier("mac.chatSideChatSend")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isAnswering
    }

    private func send() {
        guard canSend else { return }
        model.ask(model.draft)
        isFieldFocused = true
    }
}
