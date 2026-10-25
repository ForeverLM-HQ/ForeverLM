import SwiftUI
import UIKit

// The source chat surface. Reader chat is modal and owns its NavigationStack; a
// walkthrough card's chat is the same, in a sheet over the deck. A notebook's
// Chat tab draws its own composer around the same bubbles
// (`MobileNotebookChatTab`). Its top bar is Done and the title alone
// (2026-10-06, ChatGPT's): copying the conversation and reading every reply
// aloud are in each finished reply's ⋯ (`MobileChatReplyFooter`).
struct MobileChatView: View {
    enum Presentation: Equatable {
        case modal
        /// A walkthrough card's chat, in a sheet over the deck: modal, but
        /// closing it only closes the sheet — the chat goes on under the
        /// next card, and the deck ends it when the deck closes.
        case walkthroughCard
    }

    // The presenter owns the view model so the conversation survives a redraw of
    // whatever is behind the sheet.
    @ObservedObject var viewModel: MobileChatViewModel
    /// Raises the Sign in with Apple sheet, which lives in MobileSignInGate. The
    /// button is hidden when no handler is wired up.
    var onNeedsSignIn: (() -> Void)?
    var presentation: Presentation = .modal

    @StateObject private var dictation = MobileComposerDictation()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isComposerFocused: Bool
    /// A source a reply cited, opened over the chat in the chat's own stack.
    @State private var citation: MobileChatCitation?

    var body: some View {
        NavigationStack {
            chatBody
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }
                .navigationDestination(item: $citation) { citation in
                    citedReader(citation.sourceID)
                }
        }
        // The chat is a sheet over the Reader or a walk: a source a reply
        // cites opens over the chat, and Back returns to it, rather than
        // being pushed out of sight under the sheet (following a link never
        // closes what it was read in).
        .environment(\.openURL, OpenURLAction { url in
            guard case .source(let sourceID)? = MobileDeepLink.parse(url) else { return .systemAction }
            citation = MobileChatCitation(sourceID: sourceID)
            return .handled
        })
        .task {
            await viewModel.refreshSignInState()
            viewModel.sendInitialPromptIfNeeded()
        }
        .task { await dictation.refreshAvailability() }
        .onDisappear {
            Task { await dictation.cancel() }
            if presentation == .modal {
                viewModel.finish()
            }
        }
    }

    @ViewBuilder
    private func citedReader(_ sourceID: String) -> some View {
        if let source = MobileAudioReviewViewModel.shared.sourcesByID[sourceID] {
            MobileSourceReaderView(source: source, notebook: viewModel.notebook)
        } else {
            ContentUnavailableView(
                "Not on This iPhone Yet",
                systemImage: "icloud.and.arrow.down",
                description: Text("This source has not synced from your Mac yet.")
            )
            .navigationTitle("Source")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var navigationTitle: String {
        if presentation == .walkthroughCard, let title = viewModel.currentStep?.title, !title.isEmpty {
            return title
        }
        return viewModel.title
    }

    private var chatBody: some View {
        VStack(spacing: 0) {
            transcript
            composer
        }
    }

    private var copiedConversationText: String {
        ConversationTranscriptFormatter.plainText(
            from: viewModel.displayedMessages.map { message in
                ConversationTranscriptFormatter.Turn(
                    speaker: message.role == .user ? .user : .assistant,
                    content: message.content
                )
            }
        )
    }

    /// What each finished reply's footer does.
    private var replyActions: MobileChatReplyActions {
        MobileChatReplyActions(
            chat: viewModel,
            conversationText: { copiedConversationText }
        )
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    // An empty chat is its composer alone: the placeholder
                    // already says what it is about.
                    ForEach(viewModel.displayedMessages) { message in
                        MobileChatBubble(
                            message: message,
                            relativePDFPath: MobileSourceFilePath.relativePDFPath(
                                localFilePath: viewModel.source.localFilePath,
                                url: viewModel.source.url
                            ),
                            replyActions: replyActions
                        )
                        .equatable()
                        .id(message.id)
                    }
                    // Sent while the reply above was still streaming; they wait
                    // here, dimmed, and move up as real turns when it ends.
                    ForEach(viewModel.queuedMessages) { queued in
                        MobileQueuedChatBubble(message: queued) {
                            viewModel.returnQueuedMessageToDraft(queued.id)
                        }
                        .id(queued.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MobileDesign.Spacing.large)
                .padding(.vertical, MobileDesign.Spacing.large)
                .mobileReadableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                TapGesture().onEnded {
                    isComposerFocused = false
                }
            )
            .onChange(of: viewModel.messages.count) { _, _ in
                scrollToLastMessage(proxy, animated: true)
            }
            .onChange(of: viewModel.queuedMessages.count) { _, _ in
                scrollToLastMessage(proxy, animated: true)
            }
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                // Unanimated during the stream: an animation per 75 ms publish
                // fights the growing text instead of following it.
                scrollToLastMessage(proxy, animated: false)
            }
            // A finished reply grows its footer: keep it in view.
            .onChange(of: viewModel.messages.last?.isStreaming) { _, _ in
                scrollToLastMessage(proxy, animated: true)
            }
        }
    }

    private func scrollToLastMessage(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = viewModel.messages.last?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
        } else {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: MobileDesign.Spacing.small) {
            if let banner = bannerMessage {
                errorBanner(banner.message, onDismiss: banner.dismiss)
            }

            switch viewModel.signInState {
            case .unknown:
                // Resolving it is a keychain read, so it lands a frame or two after
                // the sheet. Showing nothing beats flashing a sign-in prompt at
                // someone who is already signed in.
                EmptyView()
            case .signedIn:
                if let selection = viewModel.pendingSelection {
                    selectionChip(selection)
                }
                if isListening {
                    listeningIndicator
                }
                inputRow
            case .signedOut:
                signInPrompt
            }
        }
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .padding(.vertical, MobileDesign.Spacing.small)
        .mobileReadableWidth()
        .background(.ultraThinMaterial)
    }

    private var inputRow: some View {
        MobileComposerSurface {
            HStack(alignment: .bottom, spacing: MobileDesign.Spacing.small) {
                TextField(placeholder, text: composerText, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .focused($isComposerFocused)
                    .disabled(isListening)
                    .submitLabel(.send)
                    .onSubmit {
                        guard viewModel.canSend else { return }
                        sendComposerText()
                    }
                    .padding(.vertical, 7)
                    .accessibilityIdentifier("chat.composer")

                if dictation.isAvailable {
                    Button {
                        dictation.toggle { text in
                            // A finished utterance is the message: send it,
                            // along with anything already typed, instead of
                            // parking it in the field for a second tap.
                            viewModel.appendDictatedText(text)
                            viewModel.send()
                        }
                    } label: {
                        Image(systemName: isListening ? "stop.fill" : "mic")
                            .font(.body.weight(.medium))
                            .foregroundStyle(isListening ? Color.red : Color.secondary)
                            .frame(
                                width: MobileDesign.Metrics.minimumTouchTarget,
                                height: MobileDesign.Metrics.minimumTouchTarget
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isListening ? "Stop dictation" : "Dictate a question")
                }

                Button {
                    sendComposerText()
                } label: {
                    MobileComposerDiscLabel(systemImage: "arrow.up")
                }
                .buttonStyle(.plain)
                // A streaming reply does not hold the button: the send queues.
                .disabled(!canSendComposerText)
                .accessibilityLabel(isListening ? "Transcribe and send" : "Send")
                .accessibilityIdentifier("chat.send")
            }
        }
    }

    private func selectionChip(_ selection: MobileReaderSelection) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "text.quote")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(Self.selectionPreview(selection.text))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Button {
                viewModel.pendingSelection = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove selected passage")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Selected passage: \(Self.selectionPreview(selection.text))")
    }

    private var listeningIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.red)
            Text("Listening…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var signInPrompt: some View {
        if let onNeedsSignIn {
            // A host that wants to own the sign-in flow gets a plain hand-off.
            VStack(spacing: 8) {
                Text("Sign in with Apple to ask questions about this source.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Sign In") { onNeedsSignIn() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        } else {
            MobileSignInPrompt {
                Task {
                    await viewModel.refreshSignInState()
                    viewModel.sendInitialPromptIfNeeded()
                }
            }
        }
    }

    private func errorBanner(_ message: String, onDismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            // Clamped at the boundary as well as at the source: a failure that
            // hands back a payload instead of a sentence must never be able to
            // paste it into the chat.
            Text(AIProviderErrorText.clamped(message))
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(MobileDesign.Spacing.medium)
        .background(
            Color.orange.opacity(0.12),
            in: RoundedRectangle(cornerRadius: MobileDesign.Radius.compact, style: .continuous)
        )
    }

    // MARK: - Derived view state

    private var isListening: Bool {
        dictation.state == .listening
    }

    private var placeholder: String {
        if viewModel.pendingSelection != nil { return "Ask about this passage" }
        return presentation == .walkthroughCard ? "Ask about this card" : "Ask about this source"
    }

    private var canSendComposerText: Bool {
        if isListening {
            return !dictation.partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return viewModel.canSend
    }

    private func sendComposerText() {
        isComposerFocused = false
        guard isListening else {
            viewModel.send()
            return
        }

        Task {
            // The final transcript is delivered to the toggle's handler, which
            // sends it. Sending again here only matters when that handler had
            // nothing to deliver and a typed draft or passage is still waiting.
            await dictation.finish()
            if viewModel.canSend { viewModel.send() }
        }
    }

    /// Shows live partial results in the field while dictating, without letting
    /// them overwrite what the user already typed.
    private var composerText: Binding<String> {
        Binding(
            get: { isListening ? dictation.partialText : viewModel.draft },
            set: { newValue in
                guard !isListening else { return }
                viewModel.draft = newValue
            }
        )
    }

    private var bannerMessage: (message: String, dismiss: () -> Void)? {
        if let message = viewModel.errorMessage {
            return (message, { viewModel.clearError() })
        }
        switch dictation.state {
        case .denied(let message), .failed(let message):
            return (message, { Task { await dictation.cancel() } })
        case .idle, .requestingPermission, .listening:
            return nil
        }
    }

    /// The chip's line for the passage; TeX is folded into readable text for
    /// the preview only, the selection itself keeps its markup.
    private static func selectionPreview(_ text: String) -> String {
        let trimmed = text.foldingTeXForPreview().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Selected passage" }
        guard trimmed.count > 120 else { return trimmed }
        return String(trimmed.prefix(117)) + "…"
    }
}

/// A source a chat's reply cited, as the chat's own stack pushes it.
struct MobileChatCitation: Hashable {
    let sourceID: String
}

/// The voice conversation that just ended, shown when the learner exits
/// voice. The conversation saved its turns through the chat or review it
/// drove; this value is presentation-only and deliberately does not create a
/// second persistence path.
struct MobileVoiceChatTranscript {
    let messages: [MobileChatMessage]

    init(turns: [MobileVoiceConversationController.VoiceTurn]) {
        messages = turns.compactMap { turn in
            let content = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }

            let role: MobileChatMessage.Role
            switch turn.kind {
            case .user:
                role = .user
            case .assistant:
                role = .assistant
            }

            return MobileChatMessage(
                id: UUID(),
                role: role,
                content: content,
                isStreaming: false
            )
        }
    }

    init(messages: [MobileChatMessage]) {
        self.messages = messages
    }

    var copiedConversationText: String {
        ConversationTranscriptFormatter.plainText(
            from: messages.map { message in
                ConversationTranscriptFormatter.Turn(
                    speaker: message.role == .user ? .user : .assistant,
                    content: message.content
                )
            }
        )
    }
}

/// A finished conversation in the same bubble vocabulary as typed chat, and
/// read-only: the voice session that just ended, or a saved chat a notebook's
/// Chat tab opens (continuing an old chat is not offered on the phone yet).
struct MobileVoiceTranscriptView: View {
    let transcript: MobileVoiceChatTranscript

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if transcript.messages.isEmpty {
                        Label("No messages", systemImage: "text.bubble")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, MobileDesign.Spacing.small)
                    }

                    ForEach(transcript.messages) { message in
                        MobileChatBubble(message: message)
                            .equatable()
                            .id(message.id)
                            .accessibilityIdentifier("voice.transcript.message")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MobileDesign.Spacing.large)
                .padding(.vertical, MobileDesign.Spacing.large)
                .mobileReadableWidth()
            }
            .onAppear {
                guard let id = transcript.messages.last?.id else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                MobileConversationCopyButton(text: transcript.copiedConversationText)
            }
        }
        .accessibilityIdentifier("voice.transcript")
    }
}

struct MobileConversationCopyButton: View {
    let text: String
    @State private var didCopy = false
    @State private var feedbackTask: Task<Void, Never>?

    var body: some View {
        Button {
            guard !text.isEmpty else { return }
            UIPasteboard.general.string = text
            didCopy = true
            feedbackTask?.cancel()
            feedbackTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                didCopy = false
            }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
        }
        .disabled(text.isEmpty)
        .foregroundStyle(didCopy ? Color.green : Color.primary)
        .accessibilityLabel(didCopy ? "Conversation copied" : "Copy conversation")
        .accessibilityIdentifier("chat.copyConversation")
        .onDisappear {
            feedbackTask?.cancel()
        }
    }
}

/// A message waiting for the streaming reply above it to finish. Dimmed so it
/// reads as not yet sent; the × hands it back to the composer.
struct MobileQueuedChatBubble: View {
    let message: MobileQueuedChatMessage
    let returnToDraft: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: MobileDesign.Spacing.small) {
            Spacer(minLength: 48)
            Button(action: returnToDraft) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(
                        width: MobileDesign.Metrics.minimumTouchTarget,
                        height: MobileDesign.Metrics.minimumTouchTarget
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Take queued message back")
            VStack(alignment: .trailing, spacing: 3) {
                Text("Queued")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(message.text.isEmpty ? "Explain this passage" : message.text)
                    .padding(.horizontal, MobileDesign.Spacing.medium)
                    .padding(.vertical, MobileDesign.Spacing.small)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
            }
            .opacity(0.6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued message: \(message.text)")
    }
}

/// The composer's one round button, ChatGPT's: a filled disc in the text's
/// colour holding ↑ (send), inside a 44-point target,
/// dimmed while it cannot act. The disc grows with Dynamic Type.
struct MobileComposerDiscLabel: View {
    let systemImage: String

    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 32

    var body: some View {
        Image(systemName: systemImage)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Color(uiColor: .systemBackground))
            .frame(width: diameter, height: diameter)
            .background(Color.primary.opacity(isEnabled ? 0.9 : 0.25), in: Circle())
            .frame(
                minWidth: MobileDesign.Metrics.minimumTouchTarget,
                minHeight: MobileDesign.Metrics.minimumTouchTarget
            )
            .contentShape(Rectangle())
    }
}

/// What a finished reply's footer does, for the chat it is in. Equal while
/// what it shows is: whether every reply is read aloud.
struct MobileChatReplyActions: Equatable {
    /// Every reply is read aloud as it lands (`speakReplies`).
    let readsRepliesAloud: Bool
    let setReadsRepliesAloud: @MainActor (Bool) -> Void
    let readAloud: @MainActor (MobileChatMessage) -> Void
    let stopReadingAloud: @MainActor () -> Void
    /// The whole visible conversation, as Copy Conversation copies it.
    let conversationText: @MainActor () -> String

    static func == (lhs: MobileChatReplyActions, rhs: MobileChatReplyActions) -> Bool {
        lhs.readsRepliesAloud == rhs.readsRepliesAloud
    }
}

extension MobileChatReplyActions {
    /// A chat's own: its view model reads aloud and keeps the switch.
    @MainActor
    init(chat: MobileChatViewModel, conversationText: @escaping @MainActor () -> String) {
        self.init(
            readsRepliesAloud: chat.speakReplies,
            setReadsRepliesAloud: { chat.speakReplies = $0 },
            readAloud: { chat.readAloud($0) },
            stopReadingAloud: { chat.stopReadingAloud() },
            conversationText: conversationText
        )
    }
}

/// Under a finished reply, ChatGPT's quiet row (2026-10-06, as the Mac's
/// footer): Copy, then a ⋯ with Read Aloud and Share for the reply, and
/// Copy Conversation and Read Replies Aloud for the whole chat, which were
/// buttons in the top bar until then. Grey glyphs in 44-point targets, the
/// first one's glyph on the reply's leading edge.
struct MobileChatReplyFooter: View {
    let message: MobileChatMessage
    let actions: MobileChatReplyActions

    @ObservedObject private var speech = MobileReviewSpeechService.shared
    @State private var didCopy = false
    @State private var feedbackTask: Task<Void, Never>?

    private var replyText: String {
        message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: copy) {
                glyph(didCopy ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(didCopy ? "Reply copied" : "Copy reply")
            .accessibilityIdentifier("chat.reply.copy")

            Menu {
                if speech.isSpeaking {
                    Button("Stop Reading Aloud", systemImage: "stop.fill") {
                        actions.stopReadingAloud()
                    }
                } else {
                    Button("Read Aloud", systemImage: "speaker.wave.2") {
                        actions.readAloud(message)
                    }
                }
                ShareLink(item: replyText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button("Copy Conversation", systemImage: "doc.on.doc") {
                    let text = actions.conversationText()
                    guard !text.isEmpty else { return }
                    UIPasteboard.general.string = text
                }
                Toggle(isOn: Binding(
                    get: { actions.readsRepliesAloud },
                    set: { actions.setReadsRepliesAloud($0) }
                )) {
                    Text("Read Replies Aloud")
                }
            } label: {
                glyph("ellipsis")
            }
            .accessibilityLabel("More for this reply")
            .accessibilityIdentifier("chat.reply.more")
        }
        .foregroundStyle(.secondary)
        // The first glyph lines up with the reply's text; its target still
        // reaches out the full 44 points.
        .padding(.leading, -MobileDesign.Spacing.medium)
        .padding(.top, -MobileDesign.Spacing.small)
        .onDisappear { feedbackTask?.cancel() }
    }

    private func glyph(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.footnote.weight(.medium))
            .frame(
                minWidth: MobileDesign.Metrics.minimumTouchTarget,
                minHeight: MobileDesign.Metrics.minimumTouchTarget
            )
            .contentShape(Rectangle())
    }

    private func copy() {
        guard !replyText.isEmpty else { return }
        UIPasteboard.general.string = replyText
        didCopy = true
        feedbackTask?.cancel()
        feedbackTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}

struct MobileChatBubble: View, Equatable {
    let message: MobileChatMessage
    var relativePDFPath: String? = nil
    /// Copy and a ⋯ under the reply once it is finished; nil draws none (a
    /// read-only transcript).
    var replyActions: MobileChatReplyActions? = nil

    var body: some View {
        switch message.role {
        case .user:
            HStack(spacing: 0) {
                Spacer(minLength: 48)
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, MobileDesign.Spacing.medium)
                    .padding(.vertical, MobileDesign.Spacing.small)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
            }
        case .assistant:
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
                HStack(spacing: 0) {
                    Group {
                        if message.content.isEmpty {
                            // The mark rather than a spinner: this is the wait
                            // for a reply, and it sits where the reply will.
                            ForeverLMLoadingIndicator(
                                width: ForeverLMLoadingIndicator.inlineWidth,
                                style: .flowingGoo
                            )
                        } else if let rendered = message.rendered {
                            Text(rendered)
                                .textSelection(.enabled)
                        } else {
                            // Still streaming: plain text, because parsing markdown
                            // here would put AttributedString(markdown:) on the render
                            // path for every publish of a growing reply. The view model
                            // parses once and fills `rendered` when the stream ends.
                            Text(message.content)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 32)
                }
                ForEach(message.figures) { figure in
                    MobilePaperFigureCard(figure: figure, relativePDFPath: relativePDFPath)
                        .frame(maxWidth: 620)
                }
                if let replyActions, !message.isStreaming, !message.content.isEmpty {
                    MobileChatReplyFooter(message: message, actions: replyActions)
                }
            }
        }
    }
}
