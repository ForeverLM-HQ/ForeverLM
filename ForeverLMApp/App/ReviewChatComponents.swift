import SwiftUI

/// The composer's recording state: a level meter that spans the control row
/// rather than a badge tucked inside the record button.
///
/// Drawn as discrete rounded columns mirrored about a centre line — the shape
/// a voice recorder draws. Bars read as "level meter" instantly at composer
/// height, where the filled envelope this replaced smeared into a blob. New
/// samples enter at the right and scroll left, with a dotted rule marking the
/// stretch of the row the wave hasn't travelled into yet.
struct ReviewDictationWaveform: View {
    let levels: [Double]
    let seconds: Int
    /// Stop, transcribe and send — the default, and what Return does too.
    let onStop: () -> Void
    /// Stop and transcribe, but leave the words in the draft to be edited or
    /// sent by hand. The escape hatch from the default's auto-send.
    let onKeepInDraft: () -> Void

    /// Floor matching the service's own clamp, so a silent mic settles into an
    /// even row of dots rather than collapsing onto the baseline.
    private static let silentLevel = 0.08

    private let barWidth: CGFloat = 2.5
    private let barSpacing: CGFloat = 2
    private let meterHeight: CGFloat = 20
    /// Gap between the end of the dotted rule and the oldest bar.
    private let leaderGap: CGFloat = 7

    private var pitch: CGFloat { barWidth + barSpacing }

    var body: some View {
        HStack(spacing: 9) {
            Canvas { context, size in
                draw(&context, size: size)
            }
            .frame(height: meterHeight)
            .frame(maxWidth: .infinity)
            // The 30Hz sample stream supplies the motion; animating the bars on
            // top of it would smear one frame into the next.
            .animation(nil, value: levels)

            Text(elapsedText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())

            Button(action: onKeepInDraft) {
                Image(systemName: "xmark")
                    .zoomedSystemFont(size: 8, weight: .semibold)
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.hoverWash(in: Circle(), opacity: 0.12))
            .help("Stop recording and keep the transcript in the draft without sending")
            .accessibilityLabel("Stop recording without sending")
            .accessibilityIdentifier("mac.chatDictation.keepInDraft")

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .zoomedSystemFont(size: 8, weight: .semibold)
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.primary)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.hoverWash(in: Circle(), opacity: 0.12))
            .help("Stop recording and send (Return)")
            .accessibilityLabel("Stop recording and send")
            .accessibilityIdentifier("mac.chatDictation.send")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording, \(elapsedText)")
    }

    private var elapsedText: String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Three-tap moving average. The raw meter is noisy enough that neighbouring
    /// bars jitter against each other; this rounds it off without lagging the signal.
    private var smoothed: [Double] {
        guard levels.count > 2 else { return levels }
        return levels.indices.map { index in
            let lower = max(index - 1, 0)
            let upper = min(index + 1, levels.count - 1)
            return (levels[lower] + levels[index] + levels[upper]) / 3
        }
    }

    /// Bars are right-aligned and only as many are drawn as the row can hold,
    /// so the meter adapts to whatever width the composer has instead of being
    /// squeezed into a fixed frame.
    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let capacity = max(Int((size.width + barSpacing) / pitch), 0)
        guard capacity > 0 else { return }

        let samples = Array(smoothed.suffix(capacity))
        guard !samples.isEmpty else { return }

        let midY = size.height / 2
        let maxBarHeight = size.height
        let barsWidth = CGFloat(samples.count) * pitch - barSpacing
        let originX = size.width - barsWidth

        drawLeader(&context, upTo: originX - leaderGap, midY: midY)

        // The oldest bars fade out, so the meter reads as travelling leftwards
        // rather than merely wobbling in place.
        let fadeCount = max(Double(samples.count) * 0.25, 1)

        for (index, level) in samples.enumerated() {
            let clamped = min(max(level, Self.silentLevel), 1)
            let normalized = (clamped - Self.silentLevel) / (1 - Self.silentLevel)
            let height = max(barWidth, CGFloat(normalized) * maxBarHeight)
            let rect = CGRect(
                x: originX + CGFloat(index) * pitch,
                y: midY - height / 2,
                width: barWidth,
                height: height
            )
            let fade = min(Double(index) / fadeCount, 1)
            context.fill(
                Path(roundedRect: rect, cornerRadius: barWidth / 2),
                with: .color(Color.primary.opacity(0.25 + 0.6 * fade))
            )
        }
    }

    private func drawLeader(_ context: inout GraphicsContext, upTo endX: CGFloat, midY: CGFloat) {
        guard endX > 0 else { return }
        var rule = Path()
        rule.move(to: CGPoint(x: 0, y: midY))
        rule.addLine(to: CGPoint(x: endX, y: midY))
        context.stroke(
            rule,
            with: .color(Color.primary.opacity(0.16)),
            style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 4])
        )
    }
}

struct ReviewDictationTranscribingIndicator: View {
    var body: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.72)

            Text("Transcribing")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(height: 28)
        .background(Color.accentColor.opacity(0.10), in: Capsule())
        // One element: on the plain row the spinner and the word each read as
        // "Transcribing audio".
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Transcribing audio")
    }
}

struct ReviewChatBubble: View, Equatable {
    let message: ReviewSessionManager.Message
    /// What the replies above this one already said about its citations. See
    /// `ChatCitationLedger`.
    let citationContext: ChatCitationLedger.MessageContext
    let maxContentWidth: CGFloat
    let isSpeaking: Bool
    let isStreaming: Bool
    let linkedNotebookTitle: String?
    let updateLinkedNotebook: (() -> Void)?
    let createNotebook: (() -> Void)?
    let deleteMessage: () -> Void
    let canDelete: Bool
    let speakMessage: () -> Void
    let stopSpeaking: () -> Void
    /// Offered on a memory review's saved turns: lift this exchange out into a
    /// new chat beside the review. nil everywhere else, and on a turn that
    /// has not reached storage yet.
    var discussInNewChat: (() -> Void)? = nil
    /// Opens the source a learner message's quoted passage came from in the
    /// Reader, at those words. nil leaves the quote as plain text.
    var openPassage: ((ChatPassageOrigin.Passage) -> Void)? = nil
    /// The notebook this chat works in: a cited page's Add files it there as
    /// well as in Sources. nil outside a notebook.
    var webSourcesNotebookID: String? = nil
    /// Edit on the newest learner message: its words go back to the composer,
    /// and the send replaces it and the reply after it (Codex's edit and
    /// resend). Nil on every other message.
    var editMessage: (() -> Void)? = nil

    private var displayContent: String? {
        ReviewSessionManager.displayableMessageContent(role: message.role, content: message.content)
    }

    /// The Reader passage a learner message was asked about. It travels as
    /// model-only context rather than in the words, so without this the bubble
    /// showed "please explain this a bit more" and never what "this" was
    /// (product owner, 2026-09-23). The bubble is the one place it is drawn: a strip
    /// under the chat's title showed the same words a second time until
    /// 2026-09-26, and its click into the Reader now lives on this quote.
    private var readerPassage: ChatPassageOrigin.Passage? {
        guard message.role == .user else { return nil }
        return ChatPassageOrigin.parse(contextContent: message.contextualContent)
    }

    /// The guess a learner question went with (Think first), read off the
    /// model-only context it travels in.
    private var learnerGuess: String? {
        guard message.role == .user else { return nil }
        return ChatGuess.guess(contextContent: message.contextualContent)
    }

    /// An assistant reply's prose and the web pages its footer cites, kept
    /// apart so the pages render as native rows with an Add action instead of
    /// a markdown list the learner can only click through to the Reader.
    private func bodyAndWebCitations(_ content: String) -> (body: String, citations: [AIWebCitation]) {
        guard message.role == .assistant else { return (content, []) }
        return ReviewSessionManager.splitWebSourcesFooter(content)
    }

    static func == (lhs: ReviewChatBubble, rhs: ReviewChatBubble) -> Bool {
        lhs.message.id == rhs.message.id &&
        lhs.message.role == rhs.message.role &&
        lhs.message.content == rhs.message.content &&
        lhs.message.contextualContent == rhs.message.contextualContent &&
        lhs.message.modelID == rhs.message.modelID &&
        // A source cited earlier in the session stops being listed under this
        // reply, so the row has to redraw when the transcript above it changes.
        lhs.citationContext == rhs.citationContext &&
        lhs.maxContentWidth == rhs.maxContentWidth &&
        // Without this a tool row would keep rendering "running" after it finished,
        // since nothing else about the message changes when the tool completes.
        lhs.message.toolActivity == rhs.message.toolActivity &&
        lhs.isSpeaking == rhs.isSpeaking &&
        lhs.isStreaming == rhs.isStreaming &&
        lhs.canDelete == rhs.canDelete &&
        (lhs.discussInNewChat == nil) == (rhs.discussInNewChat == nil) &&
        (lhs.openPassage == nil) == (rhs.openPassage == nil) &&
        lhs.webSourcesNotebookID == rhs.webSourcesNotebookID &&
        (lhs.editMessage == nil) == (rhs.editMessage == nil) &&
        lhs.linkedNotebookTitle == rhs.linkedNotebookTitle
    }

    /// The pointer is over a learner message: its Copy shows under it.
    @State private var isHovering = false
    @State private var didCopy = false
    @State private var copyFeedbackTask: Task<Void, Never>?

    @ViewBuilder
    var body: some View {
        if let activity = message.toolActivity {
            HStack(alignment: .top) {
                ReviewChatToolRow(activity: activity)
                Spacer(minLength: 0)
            }
        } else if let displayContent, !displayContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if message.role == .user {
                // Codex's learner turn: a pill at most 70% of the column wide
                // against its trailing edge, with Copy under it on hover
                // (product owner, 2026-10-11: "make the chat experience more
                // look chatgpt codex").
                ChatUserMessageColumn(maxWidth: maxContentWidth) {
                    messageStack(displayContent)
                }
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
                .onDisappear { copyFeedbackTask?.cancel() }
            } else {
                HStack(alignment: .top) {
                    if message.role == .assistant, updateLinkedNotebook != nil || createNotebook != nil {
                        VStack(spacing: 6) {
                            artifactMenu
                        }
                    }
                    messageStack(displayContent)
                        .frame(maxWidth: maxContentWidth, alignment: .leading)
                    if message.role == .assistant {
                        Spacer(minLength: 48)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func messageStack(_ displayContent: String) -> some View {
        let split = bodyAndWebCitations(displayContent)
        // A learner message may carry pictures: they are drawn from the
        // raw content above the bubble, and the bubble shows only what
        // was typed — or nothing, when the message was the pictures.
        let attached = message.role == .user ? AttachedImageReference.split(message.content) : nil
        // What a learner message's Copy puts on the pasteboard: the words as sent.
        let copyText = attached?.text ?? split.body
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 3) {
            if let attached, !attached.images.isEmpty {
                ReviewChatAttachedImagesRow(images: attached.images, maxContentWidth: maxContentWidth)
                    .padding(.bottom, attached.text.isEmpty ? 0 : 3)
                    .contextMenu {
                        Button(role: .destructive) {
                            deleteMessage()
                        } label: {
                            Label("Delete Message", systemImage: "trash")
                        }
                        .disabled(!canDelete)
                    }
            }
            if attached == nil || attached?.text.isEmpty == false {
                ReviewChatMessageContent(
                    messageID: message.id,
                    content: attached?.text ?? split.body,
                    rendersMarkdown: message.role == .assistant,
                    citationContext: citationContext,
                    passage: readerPassage,
                    openPassage: openPassage
                )
                // Keep one identity across the stream→final transition so the same
                // markdown WebView is reused and fed deltas, rather than torn down
                // and rebuilt (which is what made streaming render as plain text).
                .id(message.id)
                .modifier(ReviewChatBubbleChrome(role: message.role))
                .contextMenu {
                    if let editMessage {
                        Button(action: editMessage) {
                            Label("Edit Message", systemImage: "pencil")
                        }
                    }
                    if let discussInNewChat {
                        Button(action: discussInNewChat) {
                            Label("Discuss in New Chat", systemImage: "bubble.left.and.text.bubble.right")
                        }
                    }
                    Button(role: .destructive) {
                        deleteMessage()
                    } label: {
                        Label("Delete Message", systemImage: "trash")
                    }
                    .disabled(!canDelete)
                }
            }
            if !split.citations.isEmpty {
                ReviewChatWebSourcesList(citations: split.citations, notebookID: webSourcesNotebookID)
                    .padding(.top, 4)
            }
            // Think first: the guess the learner wrote before asking,
            // under their question, in their words (`ChatGuess`).
            if let guess = learnerGuess {
                ReviewChatGuessLine(guess: guess)
            }
            if message.role == .user, !copyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Opacity rather than removal, as under a reply: the row keeps
                // its height so the transcript never shifts under the pointer,
                // and the button stays in the accessibility tree.
                HStack(spacing: 2) {
                    if let editMessage {
                        ReviewChatFooterButton(
                            systemImage: "pencil",
                            label: "Edit message",
                            tint: .secondary,
                            action: editMessage
                        )
                        .accessibilityIdentifier("mac.chatEditMessage")
                    }
                    ReviewChatFooterButton(
                        systemImage: didCopy ? "checkmark" : "doc.on.doc",
                        label: didCopy ? "Message copied" : "Copy message",
                        tint: didCopy ? .green : .secondary,
                        action: { copyMessage(copyText) }
                    )
                    .accessibilityIdentifier("mac.chatCopyMessage")
                }
                .opacity(isHovering || didCopy ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .padding(.top, 1)
            }
        }
    }

    @MainActor
    private func copyMessage(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }

    private var artifactMenu: some View {
        Menu {
            if let updateLinkedNotebook {
                Button(action: updateLinkedNotebook) {
                    Label(linkedNotebookTitle.map { "Add to \($0)" } ?? "Add to Notebook", systemImage: "folder.badge.plus")
                }
            }
            if let createNotebook {
                Button(action: createNotebook) {
                    Label("Create Notebook", systemImage: "doc.badge.plus")
                }
            }
        } label: {
            Image(systemName: "doc.badge.plus")
                .zoomedSystemFont(size: 11, weight: .semibold)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .hoverHighlight(in: Circle(), opacity: 0.12)
        .foregroundStyle(Color.secondary)
        .background(Color.secondary.opacity(0.10), in: Circle())
        .help(updateLinkedNotebook == nil ? "Create a notebook from this reply" : "Add this reply to the notebook")
    }
}

/// The pages a web-searched reply cited, as rows the learner can open beside
/// Chat or keep with one click. Opening never imports; Add runs the canonical
/// URL import with deduplication and archived-source revival — the same path
/// as the Reader's "Add to Library" button — so a page kept from here is the
/// same library record it would be from anywhere else. In a notebook's chat
/// Add files the page in that notebook too, and a row reads saved only once
/// the notebook holds it.
struct ReviewChatWebSourcesList: View {
    @Environment(StudioViewModel.self) private var vm
    let citations: [AIWebCitation]
    var notebookID: String? = nil
    /// Pages whose import is in flight, by normalized URL. Completion clears
    /// the entry; the saved state then comes from the library itself.
    @State private var addingKeys: Set<String> = []
    /// Pages this list saved or found already present, so a row reads "Added"
    /// even before the library publishes the new article.
    @State private var savedKeys: Set<String> = []
    /// The list is folded until the learner opens it: most replies are read
    /// without keeping a page, so five rows under every answer is noise.
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("Web sources")
                        .zoomedSystemFont(size: 12, weight: .medium)
                    Text("\(citations.count)")
                        .zoomedSystemFont(size: 12)
                        .monospacedDigit()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .zoomedSystemFont(size: 10, weight: .semibold)
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: -3))
            .padding(.leading, 2)
            .padding(.bottom, 2)
            .help(isExpanded ? "Hide the web sources" : "Show the web sources")
            .accessibilityLabel("Web sources, \(citations.count)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("chat.webSources.toggle")
            if isExpanded {
                ForEach(Array(citations.enumerated()), id: \.element.url) { index, citation in
                    row(index: index + 1, citation: citation)
                }
            }
        }
        // A group of its own: on a plain container the identifier replaced
        // each row's Add (chat.webSources.add) and landed on its Open button.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.webSources")
    }

    private func row(index: Int, citation: AIWebCitation) -> some View {
        let url = URL(string: citation.url)
        let key = SourceDiscovery.normalizedURL(citation.url)
        let notebook = vm.importableNotebook(notebookID)
        let state = ReaderAddPageToolbarState(
            isAdding: addingKeys.contains(key),
            isSaved: savedKeys.contains(key) || isInLibrary(citation.url, notebook: notebook)
        )
        let host = url?.host ?? citation.url
        let title = citation.title.isEmpty ? host : citation.title
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index).")
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(minWidth: 18, alignment: .trailing)
            Button {
                guard let url else { return }
                vm.openWebCitationInReader(url, title: citation.title)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if title != host {
                        Text(host)
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in Reader")
            Button {
                guard let url else { return }
                add(url, key: key, state: state, title: citation.title)
            } label: {
                Label(addTitle(state, notebook: notebook), systemImage: state.systemImage)
                    .zoomedSystemFont(size: 11, weight: .medium)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        (state == .saved ? Color.secondary : Color.accentColor).opacity(0.12),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(state == .saved ? Color.secondary : Color.accentColor)
            .disabled(!state.isEnabled || url == nil)
            .help(addHelp(state, notebook: notebook))
            .accessibilityIdentifier("chat.webSources.add")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .hoverHighlight(in: RoundedRectangle(cornerRadius: 6), opacity: 0.06)
    }

    private func isInLibrary(_ url: String, notebook: LearningGoalRecord?) -> Bool {
        // A memoized set, not a scan: this runs per citation inside `body`, and
        // the lazy transcript rebuilds the row on every scroll back into view.
        // Matched by address and by DOI, so a paper saved from its DOI link or
        // a recommendation link reads "Added" for the bare address a search cites.
        guard vm.libraryContainsSource(url: url) else { return false }
        guard let notebook else { return true }
        return vm.notebookHoldsSource(url: url, notebookID: notebook.id)
    }

    /// In a notebook's chat the Add names the notebook it files into.
    private func addTitle(_ state: ReaderAddPageToolbarState, notebook: LearningGoalRecord?) -> String {
        guard state == .available, let notebook else { return state.title }
        return "Add to \(notebook.title)"
    }

    private func addHelp(_ state: ReaderAddPageToolbarState, notebook: LearningGoalRecord?) -> String {
        guard state == .available, let notebook else { return state.help }
        return "Add to Library and to \u{201C}\(notebook.title)\u{201D}"
    }

    /// Mirrors the Reader's Add to Sources flow: acknowledge at once, check
    /// for a duplicate, import, then report exactly what the library ended up
    /// with. A failed import leaves the row available so the click can be
    /// retried, rather than pretending the page was kept.
    private func add(_ url: URL, key: String, state: ReaderAddPageToolbarState, title: String) {
        if state.opensSavedSource {
            // View in Sources: the saved copy, the way a source citation opens.
            guard let sourceID = vm.librarySourceID(forURL: url.absoluteString) else {
                vm.showToast("Already in Library")
                return
            }
            Task { await vm.openLinkedSourceInReader(sourceID) }
            return
        }
        vm.showToast(state.activationMessage)
        guard state == .available else { return }
        addingKeys.insert(key)
        Task {
            await Task.yield()
            defer { addingKeys.remove(key) }
            // The shared import, which a highlight's cited papers use too.
            if await vm.addCitedPageToSources(url, notebookID: notebookID, title: title) {
                savedKeys.insert(key)
            }
        }
    }
}
