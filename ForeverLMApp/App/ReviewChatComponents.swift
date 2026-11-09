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

/// A presentation-only transcript entry: a message, or a run of consecutive
/// tool messages, the unit a block takes its identity from. A reply is drawn
/// from its messages by `ReviewChatAnswerLayout`, which folds every step into
/// one "Worked for" line. The first activity's id remains the group's stable
/// scroll/list identity as more operations arrive during generation.
struct ReviewChatTranscriptEntry: Identifiable {
    let id: UUID
    let message: ReviewSessionManager.Message?
    let activities: [ReviewSessionManager.Message.ToolActivity]

    /// The heading a memory review shows when the tutor turns to a source,
    /// with the source it names. Nil for every other entry.
    var sourceTurn: ReviewSessionManager.Message.ToolActivity.SourcePresentation? {
        guard activities.count == 1, let activity = activities.first,
              activity.kind == .sourceTurn else { return nil }
        return activity.sourcePresentation
    }

    /// The model's thinking before a step, which stands as its own entry and
    /// is drawn inside the reply's "Worked for" fold. Nil for every other entry.
    var thinking: ReviewSessionManager.Message.ToolActivity? {
        guard activities.count == 1, let activity = activities.first,
              activity.kind == .thinking else { return nil }
        return activity
    }

    /// The cards a `save_card_drafts` call saved, drawn as the cards
    /// (`ReviewChatSavedCardsView`). Nil for every other entry.
    var savedCards: ChatSavedCards? {
        guard activities.count == 1, let activity = activities.first else { return nil }
        return activity.savedCards
    }

    @MainActor
    static func grouping(
        _ messages: [ReviewSessionManager.Message]
    ) -> [ReviewChatTranscriptEntry] {
        var entries: [ReviewChatTranscriptEntry] = []
        var activityID: UUID?
        var activities: [ReviewSessionManager.Message.ToolActivity] = []

        func flushActivities() {
            guard let activityID, !activities.isEmpty else { return }
            entries.append(
                ReviewChatTranscriptEntry(
                    id: activityID,
                    message: nil,
                    activities: activities
                )
            )
            activities.removeAll(keepingCapacity: true)
        }

        for message in messages {
            if let activity = message.toolActivity {
                // A source-turn heading stands on its own: folding it into a
                // disclosure of tool steps would hide the one row that says
                // the review moved on. So does a thinking row, which is the
                // model's own working rather than a tool step, and would turn
                // a fold of "Sources in context" into a vague "Activity".
                // So do the cards a call saved, which are what the turn made,
                // not a step on the way to it.
                if activity.kind == .sourceTurn || activity.kind == .thinking || activity.savedCards != nil {
                    flushActivities()
                    entries.append(
                        ReviewChatTranscriptEntry(
                            id: message.id,
                            message: nil,
                            activities: [activity]
                        )
                    )
                    continue
                }
                if activities.isEmpty {
                    activityID = message.id
                }
                activities.append(activity)
                continue
            }

            // Provider placeholders and protocol-only messages render no content.
            // Ignore them here too so they do not fragment one activity run into
            // several disclosures while a response is still being assembled.
            guard ReviewSessionManager.displayableMessageContent(
                role: message.role,
                content: message.content
            )?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                continue
            }

            flushActivities()
            entries.append(
                ReviewChatTranscriptEntry(
                    id: message.id,
                    message: message,
                    activities: []
                )
            )
        }

        flushActivities()
        return entries
    }
}

/// One row in the outer transcript. Learner messages remain independent bubbles;
/// everything the assistant emits before the next learner message becomes one
/// answer block, including its collapsed activity rows. This gives that entire
/// answer one hover target and one faithful clipboard representation.
struct ReviewChatTranscriptBlock: Identifiable {
    let id: UUID
    let userMessage: ReviewSessionManager.Message?
    let answerEntries: [ReviewChatTranscriptEntry]
    let answerMessages: [ReviewSessionManager.Message]

    @MainActor
    static func grouping(
        _ messages: [ReviewSessionManager.Message]
    ) -> [ReviewChatTranscriptBlock] {
        var blocks: [ReviewChatTranscriptBlock] = []
        var answerMessages: [ReviewSessionManager.Message] = []

        func flushAnswer() {
            let entries = ReviewChatTranscriptEntry.grouping(answerMessages)
            guard let first = entries.first else {
                answerMessages.removeAll(keepingCapacity: true)
                return
            }
            blocks.append(
                ReviewChatTranscriptBlock(
                    id: first.id,
                    userMessage: nil,
                    answerEntries: entries,
                    answerMessages: answerMessages
                )
            )
            answerMessages.removeAll(keepingCapacity: true)
        }

        for message in messages {
            // A walkthrough step's turn is a block of its own: with no walk
            // playing it is drawn as the row that resumes the walk, never
            // under a reply's actions.
            if message.walkthroughStep != nil {
                flushAnswer()
                answerMessages.append(message)
                flushAnswer()
                continue
            }
            if message.role == .user {
                flushAnswer()
                guard ReviewSessionManager.displayableMessageContent(
                    role: message.role,
                    content: message.content
                )?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    continue
                }
                blocks.append(
                    ReviewChatTranscriptBlock(
                        id: message.id,
                        userMessage: message,
                        answerEntries: [],
                        answerMessages: []
                    )
                )
            } else {
                answerMessages.append(message)
            }
        }

        flushAnswer()
        return blocks
    }
}

/// A stretch of the transcript: one ordinary block, or a side question with
/// the replies it drew. The quiz is the flush column; a side question is a
/// lane beside it that folds to one line once the quiz has moved on, so a
/// transcript full of detours still reads as the review it was.
///
/// A lane hangs under the reply it is about. Usually that is the reply just
/// above it, but an aside about an older reply (its footer icon, or More
/// details on it) is drawn under that reply, wherever it was sent in time —
/// so the sections are not always in the order the messages were.
struct ReviewChatTranscriptSection: Identifiable {
    let id: UUID
    let blocks: [ReviewChatTranscriptBlock]
    /// True when this section is a side question and its replies.
    let isSideQuestion: Bool
    /// The tutor's question that was open when the side question was asked,
    /// read from the reply just before it. Nil for an ordinary section, and
    /// for an aside asked under a reply that ended in a statement.
    let openQuestion: String?
    /// True when the lane was opened by More details on a reply: the app's
    /// own side question, drawn as a heading rather than as the learner's
    /// words, with the tutor's expansion under it.
    var isMoreDetails = false
    /// The reply block this lane hangs under: the one its mark names, or
    /// failing that the newest reply before it. Nil for an ordinary section
    /// and for an aside with no reply above it at all.
    var aboutBlockID: UUID? = nil

    /// The side question itself, when this section is one.
    var sideQuestionMessage: ReviewSessionManager.Message? {
        guard isSideQuestion else { return nil }
        return blocks.first?.userMessage
    }

    /// The section holding the block that was sent or written last — the one
    /// that is "newest" for the lane that stays open and the card of ways on.
    /// Not `last`, since a lane about an older reply sits up in the transcript.
    static func newest(
        in sections: [ReviewChatTranscriptSection],
        blocks: [ReviewChatTranscriptBlock]
    ) -> ReviewChatTranscriptSection? {
        guard let lastID = blocks.last?.id else { return nil }
        return sections.first { section in section.blocks.contains { $0.id == lastID } }
    }

    /// The first line, in plain text, of the reply a block holds, as the mark
    /// beside an aside about it stores it. Nil for a learner block or a block
    /// of tool rows alone.
    @MainActor
    static func replyLine(of block: ReviewChatTranscriptBlock) -> String? {
        guard block.userMessage == nil, let reply = lastVisibleReply(in: block) else { return nil }
        return ChatSideQuestion.replyLine(
            in: ReviewSessionManager.displayableMessageContent(role: .assistant, content: reply.content) ?? ""
        )
    }

    @MainActor
    private static func lastVisibleReply(in block: ReviewChatTranscriptBlock) -> ReviewSessionManager.Message? {
        block.answerMessages.last(where: { message in
            message.role == .assistant
                && ReviewSessionManager.displayableMessageContent(role: .assistant, content: message.content)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        })
    }

    /// The lane as a conversation: the aside, the replies it drew, and any
    /// follow-ups, as the text the learner saw. What a new chat opens on when
    /// the side question is taken out of the quiz.
    @MainActor
    var sideQuestionTurns: [ChatSideQuestionHandoff.Turn] {
        guard isSideQuestion else { return [] }
        var turns: [ChatSideQuestionHandoff.Turn] = []
        for block in blocks {
            if let user = block.userMessage {
                let text = ReviewSessionManager.displayableMessageContent(role: .user, content: user.content) ?? user.content
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    turns.append(.init(speaker: .learner, text: text))
                }
                continue
            }
            let reply = block.answerMessages
                .filter { $0.role == .assistant }
                .compactMap { ReviewSessionManager.displayableMessageContent(role: .assistant, content: $0.content) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            if !reply.isEmpty {
                turns.append(.init(speaker: .tutor, text: reply))
            }
        }
        return turns
    }

    @MainActor
    static func grouping(_ blocks: [ReviewChatTranscriptBlock]) -> [ReviewChatTranscriptSection] {
        var sections: [ReviewChatTranscriptSection] = []
        var asideBlocks: [ReviewChatTranscriptBlock] = []
        var asideOpenQuestion: String?
        var asideIsMoreDetails = false
        /// The reply line the open lane's mark named, if it named one.
        var asideAboutLine: String?
        var asideAboutBlockID: UUID?
        // The question the newest tutor reply leaves waiting, if any.
        var openQuestion: String?
        // Every ordinary reply so far, by the line an aside's mark would name
        // it with, so an aside about an older reply finds its way back to it.
        var replyLines: [(blockID: UUID, line: String?)] = []

        func flushAside() {
            guard let first = asideBlocks.first else { return }
            sections.append(ReviewChatTranscriptSection(
                id: first.id,
                blocks: asideBlocks,
                isSideQuestion: true,
                openQuestion: asideOpenQuestion,
                isMoreDetails: asideIsMoreDetails,
                aboutBlockID: asideAboutBlockID
            ))
            asideBlocks.removeAll(keepingCapacity: true)
            asideOpenQuestion = nil
            asideIsMoreDetails = false
            asideAboutLine = nil
            asideAboutBlockID = nil
        }

        for block in blocks {
            if let user = block.userMessage {
                if user.isSideQuestion {
                    let mark = ChatSideQuestion.parse(contextContent: user.contextualContent)
                    // A side question asked while a lane is still open is a
                    // follow-up: it joins the lane, so one detour, however many
                    // turns it took, folds to one heading. Only an ordinary
                    // message closes a lane — or an aside about a different
                    // reply, or a More details press, which is a lane of its own.
                    let joinsOpenLane = !asideBlocks.isEmpty
                        && !mark.isMoreDetails
                        && (mark.aboutReply == nil || mark.aboutReply == asideAboutLine)
                    if !joinsOpenLane {
                        flushAside()
                        // The stored question wins when there is one: it is what was
                        // open at the time, even if the reply above has since changed.
                        asideOpenQuestion = mark.openQuestion ?? openQuestion
                        asideIsMoreDetails = mark.isMoreDetails
                        asideAboutLine = mark.aboutReply
                        // The reply the mark names, when it is still in the
                        // transcript; else the newest reply before the aside.
                        asideAboutBlockID = mark.aboutReply.flatMap { line in
                            replyLines.last(where: { $0.line == line })?.blockID
                        } ?? replyLines.last?.blockID
                    }
                    asideBlocks.append(block)
                } else {
                    flushAside()
                    sections.append(ReviewChatTranscriptSection(
                        id: block.id, blocks: [block], isSideQuestion: false, openQuestion: nil
                    ))
                }
                continue
            }

            if let lastReply = lastVisibleReply(in: block) {
                // A reply to a side question leaves the quiz's question open;
                // only an ordinary reply can change what is waiting.
                if asideBlocks.isEmpty {
                    openQuestion = ChatSideQuestion.openQuestion(
                        in: ReviewSessionManager.displayableMessageContent(role: .assistant, content: lastReply.content) ?? ""
                    )
                }
            }

            if asideBlocks.isEmpty {
                replyLines.append((block.id, replyLine(of: block)))
                sections.append(ReviewChatTranscriptSection(
                    id: block.id, blocks: [block], isSideQuestion: false, openQuestion: nil
                ))
            } else {
                asideBlocks.append(block)
            }
        }

        flushAside()
        return hangingLanesUnderTheirReplies(sections)
    }

    /// Each lane moved up under the reply it is about. A lane about the reply
    /// just above it does not move, so a transcript of ordinary asides keeps
    /// the order its messages had; lanes about one reply keep the order they
    /// were sent in.
    private static func hangingLanesUnderTheirReplies(
        _ sections: [ReviewChatTranscriptSection]
    ) -> [ReviewChatTranscriptSection] {
        var ordered: [ReviewChatTranscriptSection] = []
        ordered.reserveCapacity(sections.count)
        for section in sections {
            guard section.isSideQuestion, let aboutID = section.aboutBlockID,
                  let replyIndex = ordered.firstIndex(where: { !$0.isSideQuestion && $0.blocks.contains { $0.id == aboutID } })
            else {
                ordered.append(section)
                continue
            }
            var insertAt = replyIndex + 1
            while insertAt < ordered.count, ordered[insertAt].isSideQuestion, ordered[insertAt].aboutBlockID == aboutID {
                insertAt += 1
            }
            ordered.insert(section, at: insertAt)
        }
        return ordered
    }
}

/// A side question and its replies, drawn as a lane beside the quiz.
///
/// Open, it is the learner's bubble under a small "Side question" heading and
/// the tutor's replies behind a hairline rule, with follow-ups in the same
/// lane. Under the newest lane sits one card with both ways on: stay with the
/// side question (**Follow up** here, or **New chat** to take it out of the
/// quiz) or go back to the tutor's open question (**Answer it** / **Skip**).
/// The heading folds the lane at any time; the card stays out of the fold, so
/// the way back is never hidden. Once the quiz has moved on the lane folds on
/// its own to the heading alone, and a click reopens it.
///
/// A More details lane is the same shape with the learner's bubble left out:
/// the heading *is* their line, since they pressed an icon rather than typing,
/// and the tutor's expansion sits under it. Pressing More details again on
/// that reply reopens the lane through `expandRequest`.
struct ReviewChatAsideLane<Row: View>: View {
    let section: ReviewChatTranscriptSection
    /// True while this is the newest stretch of the transcript: the lane stays
    /// open, and the card underneath offers the ways on.
    let isLatest: Bool
    /// True while the tutor is still replying inside this lane.
    let isLive: Bool
    /// A fresh value each time something outside asks the lane to open —
    /// More details pressed on a reply whose lane already exists.
    var expandRequest: UUID? = nil
    /// The learner goes back to the open question: the composer takes focus,
    /// in answer mode.
    let answerOpenQuestion: () -> Void
    /// The learner lets the open question go and asks the tutor to move on.
    let skipOpenQuestion: () -> Void
    /// The learner asks more about the side question, here: the composer takes
    /// focus with the side-question token in place, and the reply joins the lane.
    let followUpSideQuestion: () -> Void
    /// The learner takes the side question to a chat of its own, aside and
    /// replies included; the quiz stays where it is.
    let openSideQuestionInNewChat: () -> Void
    @ViewBuilder let row: (ReviewChatTranscriptBlock) -> Row

    /// Set once the learner works the lane themselves; their choice then
    /// outranks the default for the rest of the session.
    @State private var manualExpansion: Bool?
    @State private var isHeadingHovering = false

    private var isExpanded: Bool { manualExpansion ?? (isLatest || isLive) }

    private var questionLine: String {
        let text = section.sideQuestionMessage.map {
            ReviewSessionManager.displayableMessageContent(role: .user, content: $0.content) ?? $0.content
        } ?? ""
        return ChatSideQuestion.plainLine(
            text.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        )
    }

    private var replyCount: Int {
        section.blocks.dropFirst().count
    }

    private var title: String {
        section.isMoreDetails ? ChatSideQuestion.moreDetailsQuestion : "Side question"
    }

    /// The card is drawn under the newest lane once its reply has landed. A
    /// More details lane offers only the way back to an open question: a
    /// follow-up there is a side question about the same reply, which the
    /// reply's own footer icon already offers.
    private var showsCard: Bool {
        guard isLatest, !isLive else { return false }
        return section.openQuestion != nil || !section.isMoreDetails
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if section.isMoreDetails {
                // The press has no bubble, so the heading takes its message id:
                // it is what the transcript scrolls to when the press is sent.
                heading.id(section.id)
            } else {
                heading
            }
            if isExpanded {
                ForEach(section.blocks) { block in
                    if let user = block.userMessage {
                        if !user.isMoreDetailsRequest {
                            row(block)
                        }
                    } else {
                        row(block)
                            .padding(.leading, 14)
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 1, style: .continuous)
                                    .fill(Color.primary.opacity(0.10))
                                    .frame(width: 2)
                            }
                    }
                }
            }
            if showsCard {
                ReviewChatOpenQuestionCard(
                    question: section.openQuestion,
                    answer: answerOpenQuestion,
                    skip: skipOpenQuestion,
                    followUp: section.isMoreDetails ? nil : followUpSideQuestion,
                    openInNewChat: section.isMoreDetails ? nil : openSideQuestionInNewChat
                )
                .padding(.leading, 14)
            }
        }
        .onChange(of: expandRequest) { _, request in
            guard request != nil else { return }
            manualExpansion = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private var heading: some View {
        Button {
            manualExpansion = !isExpanded
        } label: {
            HStack(spacing: 6) {
                Image(systemName: section.isMoreDetails ? "text.magnifyingglass" : "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if !isExpanded {
                    if !section.isMoreDetails {
                        Text(questionLine)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if replyCount > 1 {
                        Text("\(replyCount) replies")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else if isLatest || isLive, section.openQuestion != nil {
                    Text("the quiz waits")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: -3))
        .help(
            section.isMoreDetails
                ? (isExpanded ? "Fold the details away" : "Show the details")
                : (isExpanded ? "Fold the side question away" : "Show the side question and its replies")
        )
        .accessibilityIdentifier(section.isMoreDetails ? "mac.chatMoreDetailsHeading" : "mac.chatSideQuestionHeading")
    }
}

/// The card under the newest side question: the ways on from here.
///
/// Two rows. The first stays with the side question — **Follow up** asks more
/// in the lane, **New chat** lifts the aside and its replies into a chat of
/// its own where nothing is held back. The second is the tutor's open
/// question drawn back, so the learner can pick the review up where it
/// stopped: the tutor is told not to repeat the question itself, and this
/// card is where it lives. Built without the first row's actions it is the
/// second row alone; built without a question — an aside in a chat where
/// nothing is open — it is the first row alone.
struct ReviewChatOpenQuestionCard: View {
    let question: String?
    let answer: () -> Void
    let skip: () -> Void
    var followUp: (() -> Void)? = nil
    var openInNewChat: (() -> Void)? = nil

    private var hasSideQuestionRow: Bool { followUp != nil || openInNewChat != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasSideQuestionRow {
                sideQuestionRow
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                if question != nil {
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(height: 1)
                }
            }
            if let question {
                openQuestionRow(question)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            }
        }
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(question.map { "Back to the question: \($0)" } ?? "Still on the side question?")
    }

    private var sideQuestionRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("Still on the side question?")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("Ask more here, or take it to a chat of its own.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let followUp {
                Button("Follow up", action: followUp)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(
                        question == nil
                            ? "Ask more about the side question here"
                            : "Ask more about the side question here; the quiz keeps waiting"
                    )
                    .accessibilityIdentifier("mac.chatSideQuestionFollowUp")
            }
            if let openInNewChat {
                Button("New chat", action: openInNewChat)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                    .help("Take the side question and its replies to a new chat, where nothing is held back")
                    .accessibilityIdentifier("mac.chatSideQuestionNewChat")
            }
        }
    }

    private func openQuestionRow(_ question: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("Back to the question")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(question)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Answer it", action: answer)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Go back to answering the tutor's question")
                .accessibilityIdentifier("mac.chatOpenQuestionAnswer")
            Button("Skip", action: skip)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .help("Let this question go and ask the tutor to move on")
                .accessibilityIdentifier("mac.chatOpenQuestionSkip")
        }
    }
}

/// Footer controls for a complete assistant turn, ChatGPT's way: Copy, Side
/// question, Skip while a quiz question waits, and a ⋯ holding the rest —
/// the reply's time, Save to Note, Add to Canvas, Branch in New Chat, Discuss
/// in New Chat and More Details (product owner, 2026-10-06: "make the app more slick; kind of
/// like the chatgpt app … fewer buttons and bells and whistles"). The content
/// keeps its existing lazy, selectable renderers; copy includes all visible
/// answer text plus compact tool labels even when their disclosures have
/// never been opened.
struct ReviewChatAnswerBlock<Content: View>: View {
    let messages: [ReviewSessionManager.Message]
    /// False while this turn is still running. Copy and branching both act
    /// on a finished answer, and a footer under a block that has so far
    /// produced one tool row reads as a reply that arrived empty.
    let showsActions: Bool
    /// True for the newest answer in the transcript, whose footer stays
    /// visible. Earlier answers keep the row's space but only draw it while
    /// the pointer is over the block, so a long transcript reads as prose
    /// rather than a column of icon rows.
    let isLatest: Bool
    /// Keep this answer as a Doc, the ⋯'s Save to Note; after the save it
    /// opens that Doc. Nil while the reply is still being written or has no
    /// prose, and the item is not offered.
    let saveToNote: ReviewChatSaveToNoteControl?
    /// Put this answer on the open canvas as an Idea, the ⋯'s Add to Canvas:
    /// its first sentence as the title, the answer as the note, the sources it
    /// cites as the evidence. Nil while the reply is still being written, has
    /// no prose, or the Canvas is not offered, and the item is not offered.
    let addToCanvas: (() -> Void)?
    let canFork: Bool
    /// The whole conversation so far as a plain chat: Branch in New Chat.
    let fork: () -> Void
    /// Lift this exchange out of a memory review into a new chat beside it.
    /// nil in every chat that is not a review, and the item is not offered.
    let discussInNewChat: (() -> Void)?
    /// Ask a side question about this reply. Nil while the reply is still
    /// being written, and the button is not drawn.
    let sideQuestion: ReviewChatSideQuestionControl?
    /// Ask the tutor to expand this reply — mechanism, examples, caveats,
    /// where to read on — as a lane under it. Nil while the reply is still
    /// being written or has no prose to expand, and the item is not offered.
    let moreDetails: (() -> Void)?
    /// Skip the quiz question this reply asks, one icon beside the others
    /// (product owner, 2026-09-27: "skip question shouldn't be such a big button;
    /// should just be one of the small icons"). Nil except under the newest
    /// reply while a quiz question waits for its answer.
    let skipQuizQuestion: (() -> Void)?
    /// A memory review's topic card keeps only Side question and More
    /// details under a reply (docs/memory-design.md, "Review by topic"): the
    /// card is a study surface, and copy, branching and the time are chat
    /// furniture on it. The conversation view keeps them all.
    let asideActionsOnly: Bool
    /// Try again on the newest reply, and Try Again With a model. Nil on
    /// every other reply, and while the turn cannot be asked again.
    let tryAgain: ReviewChatTryAgainControl?
    /// A side chat about the whole chat, from the newest reply's ⋯. Nil on
    /// every other reply.
    let openSideChat: (() -> Void)?
    let content: Content

    @State private var didCopy = false
    @State private var isHovering = false
    @State private var feedbackTask: Task<Void, Never>?
    /// The chat picker's models, for Try Again With; loaded off-main once
    /// the reply offers Try again.
    @State private var tryAgainModels: [AIModelCatalogEntry] = []

    init(
        messages: [ReviewSessionManager.Message],
        showsActions: Bool = true,
        isLatest: Bool = true,
        saveToNote: ReviewChatSaveToNoteControl? = nil,
        addToCanvas: (() -> Void)? = nil,
        canFork: Bool,
        fork: @escaping () -> Void,
        discussInNewChat: (() -> Void)? = nil,
        sideQuestion: ReviewChatSideQuestionControl? = nil,
        moreDetails: (() -> Void)? = nil,
        skipQuizQuestion: (() -> Void)? = nil,
        asideActionsOnly: Bool = false,
        tryAgain: ReviewChatTryAgainControl? = nil,
        openSideChat: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.messages = messages
        self.showsActions = showsActions
        self.isLatest = isLatest
        self.saveToNote = saveToNote
        self.addToCanvas = addToCanvas
        self.canFork = canFork
        self.fork = fork
        self.discussInNewChat = discussInNewChat
        self.sideQuestion = sideQuestion
        self.moreDetails = moreDetails
        self.skipQuizQuestion = skipQuizQuestion
        self.asideActionsOnly = asideActionsOnly
        self.tryAgain = tryAgain
        self.openSideChat = openSideChat
        self.content = content()
    }

    private var timestamp: Date? {
        messages.last(where: { $0.role == .assistant })?.createdAt
    }

    /// "Today, 23:05": when the reply was written, on Copy's tooltip and as
    /// the ⋯'s first line. Nil on a topic card, which shows no time.
    private var timeLine: String? {
        guard !asideActionsOnly, let timestamp else { return nil }
        return ReviewChatReplyMenu.timeLine(timestamp)
    }

    private var menuItems: [ReviewChatReplyMenu.Item] {
        ReviewChatReplyMenu.items(
            timeLine: timeLine,
            savedDocID: saveToNote.map(\.savedDocID),
            offersAddToCanvas: addToCanvas != nil,
            offersDiscussInNewChat: discussInNewChat != nil,
            offersMoreDetails: moreDetails != nil,
            asideActionsOnly: asideActionsOnly,
            offersTryAgain: tryAgain != nil,
            offersSideChat: openSideChat != nil
        )
    }

    var body: some View {
        // Preserve the transcript's visible-screenful-only rule. One answer can
        // contain many Markdown fragments around tool calls, and constructing
        // every WKWebView eagerly would reintroduce main-thread stalls.
        LazyVStack(alignment: .leading, spacing: 14) {
            content

            if showsActions, !messages.isEmpty {
                // Opacity rather than removal: the row keeps its height so the
                // transcript never shifts under the pointer, and the buttons
                // stay in the accessibility tree for clients that never hover.
                actionRow
                    .opacity(isLatest || isHovering ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: isHovering)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .textSelection(.enabled)
        .accessibilityAction(named: "Copy answer", copyAnswer)
        .onDisappear {
            feedbackTask?.cancel()
        }
        .task(id: tryAgain != nil) {
            guard tryAgain != nil, tryAgainModels.isEmpty else { return }
            let entries = await Task.detached(priority: .utility) {
                InlineModelPicker.loadMenuEntries(task: .chat)
            }.value
            guard !Task.isCancelled else { return }
            tryAgainModels = entries
        }
    }

    private var actionRow: some View {
        HStack(spacing: 5) {
            if !asideActionsOnly {
                ReviewChatFooterButton(
                    systemImage: didCopy ? "checkmark" : "doc.on.doc",
                    label: didCopy ? "Answer copied" : "Copy answer",
                    help: timeLine.map { "Copy answer — \($0)" },
                    tint: didCopy ? .green : .secondary,
                    action: copyAnswer
                )
                .accessibilityIdentifier("mac.chatCopyAnswer")
            }

            if let sideQuestion {
                // The light door beside branching's heavy one: the
                // conversation stays where it is, and the composer carries the
                // token from here with this reply as what the aside is about.
                ReviewChatFooterButton(
                    systemImage: "arrow.turn.down.right",
                    label: sideQuestion.isArmed
                        ? "Take the side question off"
                        : sideQuestion.isFollowUp
                            ? "Follow up on the side question (⌥Return sends one)"
                            : "Ask a side question about this reply (⌥Return sends one)",
                    tint: sideQuestion.isArmed ? .accentColor : .secondary,
                    action: sideQuestion.toggle
                )
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(sideQuestion.isArmed ? 0.10 : 0))
                )
                .accessibilityIdentifier("mac.chatSideQuestion")
                .accessibilityAddTraits(sideQuestion.isArmed ? .isSelected : [])
            }

            if let skipQuizQuestion {
                // Asking to skip in words works too; this is the one-click
                // form, with no more weight than the icons beside it.
                ReviewChatFooterButton(
                    systemImage: "forward",
                    label: "Skip this question (no grade, and it counts as not right)",
                    tint: .secondary,
                    action: skipQuizQuestion
                )
                .accessibilityIdentifier("mac.chatQuizSkip")
            }

            // The ⋯ only when it holds something to do, not the time alone.
            let items = menuItems
            if items.contains(where: { !$0.isTime }) {
                moreMenu(items)
            }
        }
        .frame(height: 24)
        .padding(.top, 1)
    }

    /// The ⋯: the reply's time, then what else can be done with it.
    private func moreMenu(_ items: [ReviewChatReplyMenu.Item]) -> some View {
        Menu {
            ForEach(items, id: \.self) { item in
                menuEntry(item)
            }
        } label: {
            Image(systemName: "ellipsis")
                .zoomedSystemFont(size: 11, weight: .medium)
                .frame(width: 25, height: 24)
                .contentShape(Rectangle())
        }
        // A borderless Menu redraws its label as a native popup title and
        // drops the font; the button style keeps the label as drawn, washed
        // under the pointer like the icons beside it.
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.hoverWash(in: RoundedRectangle(cornerRadius: 6), opacity: 0.10))
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More actions")
        .accessibilityIdentifier("mac.chatAnswerMore")
    }

    @ViewBuilder
    private func menuEntry(_ item: ReviewChatReplyMenu.Item) -> some View {
        switch item {
        case .time(let line):
            // Read, not pressed: the reply's time heads the menu.
            Button(line) {}
                .disabled(true)
            Divider()
        case .saveToNote:
            Button(item.title) { saveToNote?.save() }
                .accessibilityIdentifier("mac.chatSaveToNote")
        case .openNote(let docID):
            Button(item.title) { saveToNote?.open(docID) }
                .accessibilityIdentifier("mac.chatSaveToNote")
            OtherWindowMenuItem(.doc(docID))
        case .addToCanvas:
            Button(item.title) { addToCanvas?() }
                .accessibilityIdentifier("mac.chatAnswerToCanvas")
        case .branch:
            Button(item.title, action: fork)
                .disabled(!canFork)
                .accessibilityIdentifier("mac.chatForkAnswer")
        case .discussInNewChat:
            Button(item.title) { discussInNewChat?() }
                .disabled(!canFork)
                .accessibilityIdentifier("mac.chatDiscussAnswer")
        case .moreDetails:
            Button(item.title) { moreDetails?() }
                .accessibilityIdentifier("mac.chatMoreDetails")
        case .sideChat:
            Button(item.title) { openSideChat?() }
                .accessibilityIdentifier("mac.chatOpenSideChat")
        case .tryAgain:
            Button(item.title) { tryAgain?.retry() }
                .accessibilityIdentifier("mac.chatTryAgain")
        case .tryAgainWith:
            Menu(item.title) {
                ForEach(tryAgainModels) { entry in
                    Button(AIModelCatalog.pickerName(provider: entry.provider, modelID: entry.modelID)) {
                        tryAgain?.retryWith(entry)
                    }
                }
                if !tryAgainModels.isEmpty { Divider() }
                Button("Choose Models…") { ModelPickerSheetRequest.open(.chat) }
            }
            .accessibilityIdentifier("mac.chatTryAgainWith")
        }
    }

    @MainActor
    private func copyAnswer() {
        let copyText = ReviewSessionManager.copiedAnswerText(from: messages)
        guard !copyText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)

        didCopy = true
        feedbackTask?.cancel()
        feedbackTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}

/// What a reply's ⋯ holds, as data, so the footer and its tests read one list
/// (docs/chat-design.md, "The reply's footer").
enum ReviewChatReplyMenu {
    enum Item: Hashable {
        /// The reply's time, a line to read rather than an action.
        case time(String)
        case saveToNote
        /// The Doc this answer was saved to, once it has been.
        case openNote(docID: String)
        /// The answer as an Idea on the open canvas.
        case addToCanvas
        case branch
        case discussInNewChat
        case moreDetails
        /// The newest reply asked again (Codex's Try again).
        case tryAgain
        /// The newest reply asked again on another model, a submenu.
        case tryAgainWith
        /// A side chat about the whole chat (Codex's Open side chat).
        case sideChat

        var title: String {
            switch self {
            case .time(let line): return line
            case .saveToNote: return "Save to Note"
            case .openNote: return "Open Note"
            case .addToCanvas: return "Add to Canvas"
            case .branch: return "Branch in New Chat"
            case .discussInNewChat: return "Discuss in New Chat"
            case .moreDetails: return "More Details"
            case .tryAgain: return "Try Again"
            case .tryAgainWith: return "Try Again With"
            case .sideChat: return "Open Side Chat"
            }
        }

        var isTime: Bool {
            if case .time = self { return true }
            return false
        }
    }

    /// The ⋯'s lines in order. `savedDocID` is nil when Save to Note is not
    /// offered, `.some(nil)` before the save and `.some(id)` after it. A
    /// topic card keeps only More Details.
    static func items(
        timeLine: String?,
        savedDocID: String??,
        offersAddToCanvas: Bool = false,
        offersDiscussInNewChat: Bool,
        offersMoreDetails: Bool,
        asideActionsOnly: Bool,
        offersTryAgain: Bool = false,
        offersSideChat: Bool = false
    ) -> [Item] {
        var items: [Item] = []
        if !asideActionsOnly {
            if let timeLine { items.append(.time(timeLine)) }
            if offersTryAgain { items += [.tryAgain, .tryAgainWith] }
            if let savedDocID {
                items.append(savedDocID.map { .openNote(docID: $0) } ?? .saveToNote)
            }
            if offersAddToCanvas { items.append(.addToCanvas) }
            items.append(.branch)
            if offersSideChat { items.append(.sideChat) }
            if offersDiscussInNewChat { items.append(.discussInNewChat) }
        }
        if offersMoreDetails { items.append(.moreDetails) }
        return items
    }

    /// "Today, 23:05", "Yesterday, 10:12", "Oct 3, 14:40", "Dec 30, 2025, 18:00":
    /// the day as a person says it, then the time in the Mac's own format.
    static func timeLine(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        var timeStyle = Date.FormatStyle(date: .omitted, time: .shortened)
        timeStyle.locale = locale
        timeStyle.calendar = calendar
        timeStyle.timeZone = calendar.timeZone
        let time = date.formatted(timeStyle)
        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }
        var dayStyle = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? Date.FormatStyle().month(.abbreviated).day()
            : Date.FormatStyle(date: .abbreviated, time: .omitted)
        dayStyle.locale = locale
        dayStyle.calendar = calendar
        dayStyle.timeZone = calendar.timeZone
        return "\(date.formatted(dayStyle)), \(time)"
    }
}

/// The ⋯'s Save to Note: the Doc this answer was saved to in this chat, once
/// it has been, and the two things the item does.
/// Edit and resend on the newest learner message (Codex's edit). The words go
/// back to the composer; the send takes back the message and its reply
/// (`ReviewSessionManager.takeBackNewestTurn`) and goes in their place.
enum ChatEditMessage {
    struct Editing: Equatable {
        /// The row of the message being edited.
        let exchangeID: String
        /// What the composer held before Edit, for Cancel.
        let stashedDraft: String
        let stashedQuote: String
    }

    /// Whether the composer can carry the whole message: words and a quote
    /// typed into them, yes; pictures, a Reader passage riding beside it, a
    /// side question's mark or a guess, no, since the field cannot hold
    /// them and an edit would silently drop them.
    static func isEditable(_ message: ReviewSessionManager.Message) -> Bool {
        guard message.role == .user, message.toolActivity == nil, message.exchangeID != nil else { return false }
        guard AttachedImageReference.split(message.content).images.isEmpty else { return false }
        return ChatPassageOrigin.parse(contextContent: message.contextualContent) == nil
            && !message.isSideQuestion
            && !message.isMoreDetailsRequest
            && ChatGuess.guess(contextContent: message.contextualContent) == nil
    }
}

/// Above the field while Edit has a message in the composer: what the send
/// will do, and Cancel.
struct ReviewChatEditingLine: View {
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil")
                .zoomedSystemFont(size: 10, weight: .semibold)
                .foregroundStyle(.secondary)
            Text("Editing message. Sending replaces it and the reply after it.")
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button("Cancel", action: cancel)
                .buttonStyle(.hoverWash(cornerRadius: 5, inset: -3))
                .zoomedSystemFont(size: 11, weight: .medium)
                .accessibilityIdentifier("mac.chatEditCancel")
        }
        .padding(.horizontal, ReviewChatComposerTextView.overlayTextLeadingInset)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac.chatEditing")
    }
}

/// The newest reply's Try again: asked again on the chat's model, or on
/// another one picked from Try Again With.
struct ReviewChatTryAgainControl {
    let retry: () -> Void
    let retryWith: (AIModelCatalogEntry) -> Void
}

struct ReviewChatSaveToNoteControl {
    let savedDocID: String?
    /// Makes the Doc. Nothing opens.
    let save: () -> Void
    /// Opens the saved Doc in this window.
    let open: (String) -> Void
}

/// What Save to note writes: a Doc holding the answer as the learner read
/// it, citations, moments, pages, pictures and the web sources list
/// included, named after the question it answers (docs/chat-design.md,
/// "Save to note").
enum ReviewChatSaveToNote {
    /// A title longer than this is cut at a word, with "…".
    static let maximumTitleLength = 80

    /// The answer's prose: every reply row of the block, without its tool or
    /// thinking rows, as the transcript shows it. Its `foreverlm://source`
    /// links make the Doc list as citing each source.
    @MainActor
    static func markdown(of messages: [ReviewSessionManager.Message]) -> String {
        messages
            .filter { $0.role == .assistant && $0.toolActivity == nil }
            .compactMap { ReviewSessionManager.displayableMessageContent(role: .assistant, content: $0.content) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// The first line of the learner's question, when it has three words or
    /// more; otherwise the chat's title. With neither, the answer's first
    /// line, so the Doc is still named by what it holds.
    static func title(learnerMessage: String?, chatTitle: String, answer: String) -> String {
        let question = firstLine(of: learnerMessage ?? "")
        if question.split(separator: " ").count >= 3 {
            return cut(question)
        }
        let chat = collapsed(chatTitle)
        if !chat.isEmpty { return cut(chat) }
        if !question.isEmpty { return cut(question) }
        return cut(firstLine(of: answer.replacingOccurrences(of: "#", with: "")))
    }

    private static func firstLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .lazy
            .map { collapsed(String($0)) }
            .first { !$0.isEmpty } ?? ""
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func cut(_ line: String) -> String {
        guard line.count > maximumTitleLength else { return line }
        let head = line.prefix(maximumTitleLength)
        let atWord = line[head.endIndex] == " "
            ? head
            : head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return atWord.trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Up to three questions the learner could ask next, as cards under the
/// newest answer's footer (docs/chat-design.md, "Suggested questions under
/// the answer"). The reply wrote them (`ChatFollowUps`); a click asks one in
/// the chat. Side by side while the column has room, stacked when it does
/// not. The shell's notebook guide shows its suggested questions with the
/// same view.
struct ChatSuggestedQuestionCards: View {
    let questions: [String]
    /// The chat's body size, zoom applied; a question is set a little under it.
    let fontSize: CGFloat
    let maxWidth: CGFloat
    let send: (String) -> Void

    /// Below this the cards stack: three abreast would leave each a sliver.
    static let sideBySideMinimumWidth: CGFloat = 470

    init(questions: [String], fontSize: CGFloat, maxWidth: CGFloat, send: @escaping (String) -> Void) {
        self.questions = questions
        self.fontSize = fontSize
        self.maxWidth = maxWidth
        self.send = send
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // The ideal width is what decides: a row of wrapping questions
            // would otherwise measure as one unbroken line and never fit.
            HStack(alignment: .top, spacing: 10) { cards }
                .fixedSize(horizontal: false, vertical: true)
                .frame(
                    minWidth: Self.sideBySideMinimumWidth,
                    idealWidth: Self.sideBySideMinimumWidth,
                    maxWidth: .infinity,
                    alignment: .leading
                )
            VStack(alignment: .leading, spacing: 10) { cards }
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .modifier(SuggestedQuestionsGroupLabel(namesGroup: questions.count > 1))
    }

    /// The group has no visible heading, so an assistive client hears what
    /// the cards are before it reaches them. `.contain` first makes the group
    /// its own element, so the cards keep their labels; a lone card makes no
    /// group and would take the name instead of its question, so it gets none.
    private struct SuggestedQuestionsGroupLabel: ViewModifier {
        let namesGroup: Bool

        func body(content: Content) -> some View {
            if namesGroup {
                content
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Suggested questions")
            } else {
                content.accessibilityElement(children: .contain)
            }
        }
    }

    private var cards: some View {
        ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
            ChatSuggestedQuestionCard(question: question, index: index, fontSize: fontSize) {
                send(question)
            }
        }
    }
}

private struct ChatSuggestedQuestionCard: View {
    let question: String
    /// Its place among the cards, which names it for automation
    /// (`mac.chatFollowUp.0` …).
    let index: Int
    let fontSize: CGFloat
    let ask: () -> Void

    private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        Button(action: ask) {
            VStack(alignment: .leading, spacing: 10) {
                Text(question)
                    .font(.system(size: fontSize * 0.94))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    // The whole question, however many lines it takes: a
                    // cut-off question has no other place to be read in full
                    // (product owner, 2026-11-07: "don't cut these off").
                    // The row's cards grow together to the tallest.
                    .fixedSize(horizontal: false, vertical: true)
                    // The card is the control; its words are its label.
                    .textSelection(.disabled)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up")
                    .font(.system(size: fontSize * 0.8, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Self.shape.fill(Color.primary.opacity(0.045)))
        }
        .buttonStyle(.hoverWash(in: Self.shape, inset: 0))
        // No tooltip: it would only repeat the card's words, and VoiceOver
        // would read the question twice.
        .accessibilityLabel("Ask: \(question)")
        .accessibilityIdentifier("mac.chatFollowUp.\(index)")
    }
}

/// The footer's side-question control: whether the composer is currently set
/// to send one about this reply, and the switch either way. `isFollowUp` is
/// true on a reply inside a side question's lane, where the same icon reads
/// as a follow-up.
struct ReviewChatSideQuestionControl {
    let isArmed: Bool
    var isFollowUp = false
    let toggle: () -> Void
}

/// The reply an armed side question is about: the block that holds it and
/// the line the mark beside the aside will name it by. Block ids are message
/// ids, so the reference survives the transcript being regrouped.
struct ReviewChatReplyReference: Equatable {
    let blockID: UUID
    let line: String?
}

/// What the transcript stack knows about a block when it asks the panel to
/// draw it, beyond the block itself.
struct ReviewChatTranscriptRowContext {
    /// The running turn is writing into this block.
    let isLive: Bool
    /// The newest block in the transcript, by time.
    let isLatest: Bool
    /// The block sits inside a side question's lane.
    let isInsideAside: Bool
    /// The More details lane already hanging under this reply, if one does:
    /// its section id, which is also the id the lane's heading scrolls by.
    let moreDetailsLaneID: UUID?
    /// The last block on the memory review card being drawn, newest or not:
    /// where a topic card's ledger hangs. False in every other chat.
    var isLastOnCard = false
    /// The first block on the memory review card being drawn: where a
    /// question asked without a turn line is still read as the card's
    /// question. False in every other chat.
    var isFirstOnCard = false
    /// What the memory review card being drawn is about: a topic id in a
    /// review by topic. Nil in every other chat.
    var memoryCardTopicID: String? = nil
    /// What the newest topic card's foot carries, so the last block knows
    /// whether Go deeper and Next topic belong under it. `.none` elsewhere.
    var memoryCardFoot: MemoryReviewTopicCardFoot = .none
}

/// Something outside a lane asking it to open: which lane, and a fresh token
/// per ask so two asks in a row both land.
struct ReviewChatLaneExpansionRequest: Equatable {
    let laneID: UUID
    let token: UUID
}

private struct ReviewChatFooterButton: View {
    let systemImage: String
    let label: String
    /// The tooltip when it says more than the label: Copy's names the
    /// reply's time.
    var help: String? = nil
    let tint: Color
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .zoomedSystemFont(size: 11, weight: .medium)
                .frame(width: 25, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(in: RoundedRectangle(cornerRadius: 6), opacity: 0.10))
        .foregroundStyle(isEnabled ? tint : Color.secondary.opacity(0.35))
        .disabled(!isEnabled)
        .help(help ?? label)
        .accessibilityLabel(label)
    }
}

/// Messages sent while a reply was still being written, waiting above the
/// composer as Codex's queue does, oldest first; each goes, in order, the
/// moment the turn before it ends. Per message: Send now (the ↑) cuts the
/// running reply short, keeping what it said, and asks this next; it does not
/// steer the running turn, so it is not called Steer. Edit (the pencil) takes
/// the words back into the composer; Delete (the trash) drops them.
struct ReviewChatQueuedMessages: View {
    let items: [ReviewSessionManager.QueuedFollowUp]
    let edit: (ReviewSessionManager.QueuedFollowUp) -> Void
    let delete: (ReviewSessionManager.QueuedFollowUp) -> Void
    let sendNow: (ReviewSessionManager.QueuedFollowUp) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                row(item)
            }
        }
        .padding(.horizontal, StudioDesign.Spacing.small)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            StudioDesign.Chat.trayFill,
            in: RoundedRectangle(cornerRadius: StudioDesign.Chat.trayCornerRadius, style: .continuous)
        )
        .padding(.horizontal, StudioDesign.Chat.trayInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(items.count == 1 ? "1 queued message" : "\(items.count) queued messages")
        .accessibilityIdentifier("mac.chatQueued")
    }

    private func row(_ item: ReviewSessionManager.QueuedFollowUp) -> some View {
        let attached = AttachedImageReference.split(item.text)
        let line = ReviewChatQueuedMessages.oneLine(attached.text)
        return HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .zoomedSystemFont(size: 10, weight: .medium)
                .foregroundStyle(.tertiary)
            if !attached.images.isEmpty {
                Image(systemName: "photo")
                    .zoomedSystemFont(size: 10)
                    .foregroundStyle(.secondary)
            }
            Text(line.isEmpty ? "Picture" : line)
                .zoomedSystemFont(size: 12)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(attached.text)
            button("arrow.up", label: "Send now", help: "Send now: stop the reply being written and ask this next",
                   identifier: "mac.chatQueued.sendNow") { sendNow(item) }
            button("pencil", label: "Edit", help: "Edit: put this message back in the composer",
                   identifier: "mac.chatQueued.edit") { edit(item) }
            button("trash", label: "Delete", help: "Delete this queued message",
                   identifier: "mac.chatQueued.delete") { delete(item) }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued message: \(line)")
    }

    private func button(
        _ systemImage: String,
        label: String,
        help: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .zoomedSystemFont(size: 10, weight: .semibold)
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
                .contentShape(Circle())
        }
        .buttonStyle(.hoverWash(in: Circle(), opacity: 0.12))
        .help(help)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    /// The message on one line, its line breaks as spaces.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// "Added 3 articles to context": the sources the learner brought into the
/// chat before the message under it (`ChatContextAdditions`). Drawn on the
/// learner's side, since it was their gesture, and folded to one line the way
/// a side question's lane is; the line opens to the sources by name, and a
/// name opens its source. Before the next message is sent the same row stands
/// at the foot of the transcript, so a drop never looks like it did nothing.
struct ReviewChatContextAdditionsRow: View {
    let added: [ChatContextAdditions.Source]
    let maxContentWidth: CGFloat
    let openSource: (String) -> Void

    @State private var isExpanded = false

    private var summary: String {
        ChatContextAdditions.summary(added: added)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 64)
            VStack(alignment: .trailing, spacing: 1) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.circle")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(summary)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
                .help(isExpanded ? "Hide which sources were added" : "Show which sources were added")
                .accessibilityIdentifier("mac.chatContextAdditions.toggle")

                if isExpanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(added, id: \.id) { source in
                            Button {
                                openSource(source.id)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: StudioSourceType(rawValue: source.type)?.symbolName ?? "doc")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 12)
                                    Text(source.title.isEmpty ? "Untitled source" : source.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
                            .opensInOtherWindow(sourceID: source.id)
                            .help("Open \(source.title) in the reader")
                            .accessibilityLabel("Open \(source.title)")
                        }
                    }
                    .padding(.trailing, 18)
                }
            }
            .frame(maxWidth: maxContentWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(summary)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("mac.chatContextAdditions")
    }
}

/// The moment of a video a question was asked at, above the question: the
/// frame the tutor was shown, the time, and the video's name. Drawn on the
/// learner's side, like the sources they added, and read from the message's
/// stored mark (`ChatContextAdditions.VideoMoment`), so a reopened chat shows
/// it too. A click plays the video from that moment.
struct ReviewChatVideoMomentRow: View {
    struct Moment: Identifiable, Equatable {
        let sourceID: String
        let title: String
        let moment: ChatContextAdditions.VideoMoment

        var id: String { "\(sourceID)@\(moment.at)" }
    }

    let moments: [Moment]
    let maxContentWidth: CGFloat
    let open: (_ sourceID: String, _ seconds: Int) -> Void

    /// The moments a message was asked at: the videos whose moment the send
    /// filled in. A video that was only on screen beside another chat's
    /// question has a time and nothing more, and draws nothing.
    static func moments(in onScreen: [ChatContextAdditions.OnScreen]) -> [Moment] {
        onScreen.compactMap { shown in
            guard let moment = shown.moment, moment.said != nil || moment.frame != nil else { return nil }
            return Moment(sourceID: shown.id, title: shown.title, moment: moment)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 64)
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(moments) { moment in
                    ReviewChatVideoMomentButton(moment: moment, open: open)
                }
            }
            .frame(maxWidth: maxContentWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac.chatVideoMoment")
    }
}

private struct ReviewChatVideoMomentButton: View {
    let moment: ReviewChatVideoMomentRow.Moment
    let open: (_ sourceID: String, _ seconds: Int) -> Void

    @State private var thumbnail: NSImage?

    private static let thumbnailSize = CGSize(width: 64, height: 36)

    var body: some View {
        Button {
            open(moment.sourceID, moment.moment.at)
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "play.rectangle")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(moment.moment.clock)
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(moment.title.isEmpty ? "Video" : moment.title)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 220, alignment: .leading)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
        .help("Play from \(moment.moment.clock)")
        .accessibilityLabel("Asked at \(moment.moment.clock) of \(moment.title)")
        .accessibilityHint("Plays the video from that moment")
        .task(id: moment.id) {
            thumbnail = await Self.loadThumbnail(for: moment)
        }
    }

    /// The captured frame, read off the main actor. Nil when the send took no
    /// picture, or this Mac never held it.
    private static func loadThumbnail(for moment: ReviewChatVideoMomentRow.Moment) async -> NSImage? {
        guard moment.moment.frame == true else { return nil }
        let sourceID = moment.sourceID
        let seconds = moment.moment.at
        let data = await Task.detached(priority: .utility) { () -> Data? in
            guard let path = SlideFrameExtraction.existingMomentFramePath(sourceID: sourceID, seconds: seconds) else {
                return nil
            }
            return FileManager.default.contents(atPath: path)
        }.value
        return data.flatMap(NSImage.init(data:))
    }
}

private struct ReviewChatBubbleChrome: ViewModifier {
    let role: ReviewSessionManager.Message.Role

    func body(content: Content) -> some View {
        switch role {
        case .user:
            // Codex's user turn: a light grey pill that reads as "your
            // message" without shouting in saturated accent color, its fill
            // resolved per appearance (`StudioDesign.Chat.userBubbleFill`).
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    StudioDesign.Chat.userBubbleFill,
                    in: RoundedRectangle(cornerRadius: StudioDesign.Chat.userBubbleCornerRadius, style: .continuous)
                )
        case .assistant:
            // Assistant replies render as flush, borderless text on the panel
            // background — the way Claude desktop and Codex present model output —
            // so long answers read like a document rather than a stack of cards.
            content
                .padding(.vertical, 1)
        case .tool:
            // Tool rows carry their own chrome (see ReviewChatToolRow) and sit flush
            // with assistant text so they read as part of the assistant's turn.
            content
                .padding(.vertical, 1)
        }
    }
}

/// Consecutive operations shown as one subdued disclosure. A single operation keeps
/// its specific label; larger runs summarize the work and reveal the old per-action
/// rows only when the learner asks for them.
/// The line that stands in for the reply until the reply exists.
///
/// A mark on its own answers "is anything happening?" with "something is", and
/// nothing else — which is the wrong answer when the first token can be twenty
/// seconds away behind source lookups. So it says what the turn is doing right
/// now and how long it has been doing it, the way a terminal agent's status
/// line does. The clock is the point: a number that keeps moving is the only
/// honest evidence that a silent wait is a wait rather than a stall.
struct ReviewChatWorkingIndicator: View {
    enum Phase: Equatable {
        /// Before the request goes out: hydrating attached sources, reopening
        /// the session, assembling Notebook context.
        case preparing
        case searching
        /// Today's memory review is being planned live: ideas extracted for
        /// the cohort, then the planner called. Named for what it is, because
        /// "Searching your library" over a half-minute planning wait described
        /// work that was not happening.
        case planning
        /// The request is out and the model has produced no visible text yet.
        case thinking
        /// Tokens are landing in the bubble above.
        case writing

        var label: String {
            switch self {
            case .preparing: return "Getting your sources ready"
            case .searching: return "Searching your library"
            case .planning: return "Planning today's review"
            case .thinking: return "Thinking"
            case .writing: return "Writing"
            }
        }
    }

    let phase: Phase
    /// What the preparing phase is waiting on when that is worth naming —
    /// "Downloading <video title>". Shown in place of the generic label, and
    /// only while preparing; the other phases already say what they mean.
    var detail: String? = nil
    /// When the whole turn began, not when this phase did — the learner is
    /// waiting on the answer, so the clock runs from the send.
    let startedAt: Date
    /// The reasoning the model has shown so far in this step. A clock proves
    /// the wait is a wait; this says what the wait is spent on. Shown only
    /// while thinking — once the answer is landing, the thinking has folded
    /// into the reply's "Worked for" line above it (`ReviewChatWorkFold`).
    var reasoning: String = ""
    /// All of the thinking so far streams under the label, the way Claude
    /// shows thinking as it happens, until the learner closes it.
    @State private var isShowingReasoning = true
    @Environment(\.uiZoomScale) private var uiZoomScale

    /// The generic phase label, or the named wait while preparing.
    var label: String {
        Self.label(for: phase, detail: detail)
    }

    static func label(for phase: Phase, detail: String?) -> String {
        if phase == .preparing,
           let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines),
           !detail.isEmpty {
            return detail
        }
        return phase.label
    }

    private var showsReasoning: Bool {
        phase == .thinking && reasoning.contains { !$0.isWhitespace }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showsReasoning {
                Button {
                    isShowingReasoning.toggle()
                } label: {
                    statusLine(chevron: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -3))
                .help(isShowingReasoning ? "Hide thinking" : "Show thinking")
                .accessibilityValue(isShowingReasoning ? "Expanded" : "Collapsed")

                if isShowingReasoning {
                    ReviewChatReasoningText(
                        reasoning: reasoning,
                        textInset: ForeverLMLoadingIndicator.inlineWidth / 2 + 9
                    )
                    // The rule hangs under the middle of the mark and the text
                    // lines up with the label beside it.
                    .padding(.leading, ForeverLMLoadingIndicator.inlineWidth / 2 - 1)
                    // Read as its newest step while it streams, not as the
                    // whole growing text again on every update.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Thinking: \(Self.reasoningGlimpse(reasoning) ?? "")")
                }
            } else {
                statusLine(chevron: false)
            }
        }
    }

    private func statusLine(chevron: Bool) -> some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            HStack(spacing: 8) {
                ForeverLMLoadingIndicator(
                    width: ForeverLMLoadingIndicator.inlineWidth,
                    style: .flowingGoo
                )

                // The size of the "Worked for" line it becomes, and of the
                // thinking under it: all three scale with the chat's zoom, so
                // they keep their proportions to the reply at every size.
                Text(label)
                    .font(.system(size: ChatMarkdownView.baseFontSize * uiZoomScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(Self.elapsedText(from: startedAt, to: context.date))
                    .font(.system(size: ReviewChatReasoningText.fontSize * uiZoomScale).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())

                if chevron {
                    Image(systemName: isShowingReasoning ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10 * uiZoomScale, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(label), \(Self.elapsedText(from: startedAt, to: context.date))"
            )
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    /// One line for what the model is doing now, which VoiceOver reads for
    /// the thinking as it streams. Reasoning summaries open each step with a
    /// bold heading ("**Checking the exchanger's identity**") and the newest
    /// heading is that line; raw thinking has none, so it gets the tail of
    /// its newest paragraph. Nil while nothing has been shown.
    static func reasoningGlimpse(_ reasoning: String) -> String? {
        let trimmed = ReviewChatReasoningText.withoutSourceIDs(reasoning)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let heading = latestReasoningHeading(in: trimmed) { return heading }
        guard let paragraph = trimmed
            .components(separatedBy: .newlines)
            .map({ plainReasoning($0).trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty }) else { return nil }
        let limit = 180
        guard paragraph.count > limit else { return paragraph }
        let tail = paragraph.suffix(limit)
        // Start on a word, not mid-way through one.
        let start = tail.firstIndex(of: " ").map { tail.index(after: $0) } ?? tail.startIndex
        return "…" + tail[start...]
    }

    private static let headingPattern = try? NSRegularExpression(
        pattern: #"^\s*\*\*([^*\n]+)\*\*\s*$"#,
        options: [.anchorsMatchLines]
    )

    private static func latestReasoningHeading(in text: String) -> String? {
        guard let headingPattern else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = headingPattern.matches(in: text, range: range).last,
              let headingRange = Range(match.range(at: 1), in: text) else { return nil }
        let heading = text[headingRange].trimmingCharacters(in: .whitespaces)
        return heading.isEmpty ? nil : heading
    }

    /// The reasoning without the markdown emphasis it is written in.
    static func plainReasoning(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Seconds while the wait is short enough to count in seconds, then m:ss —
    /// "184s" stops being a duration anyone reads at a glance.
    static func elapsedText(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        guard seconds >= 60 else { return "\(seconds)s" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The model's reasoning, set the way Claude's desktop app sets its thinking:
/// small quiet text hung from a thin rule, so it reads as the working behind
/// the answer rather than as the answer. All of it shows, uncapped: no nested
/// scroll box and no clipped window. Emphasis renders, so a summary's bold
/// step headings read as headings and raw thinking shows no stray asterisks.
struct ReviewChatReasoningText: View {
    /// One step under the reply's 13, before zoom. A fixed `.caption` (10pt)
    /// did not scale with the chat's zoom while the reply and the tool rows
    /// did, so a zoomed chat set the thinking at half their size.
    static let fontSize: CGFloat = 12

    let reasoning: String
    /// From the rule to the text, so the text can line up with the label above.
    var textInset: CGFloat = 12

    var body: some View {
        // One text per paragraph: while the thinking streams only the newest
        // paragraph changes, so the ones above keep their parse and layout.
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.paragraphs(reasoning).enumerated()), id: \.offset) { _, paragraph in
                ReviewChatReasoningParagraph(text: paragraph)
                    .equatable()
            }
        }
        .zoomedSystemFont(size: Self.fontSize)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, textInset)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 2)
        }
    }

    /// The reasoning's paragraphs, split on blank lines. A single line break
    /// stays inside its paragraph, where the markdown keeps it.
    static func paragraphs(_ reasoning: String) -> [String] {
        withoutSourceIDs(reasoning).components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// An id in parentheses, "(src_5c74…)" or "(id: src_5c74…, src_ff45…)",
    /// taken with the space before it. A parenthesis still streaming in has
    /// no close yet, so the end of the text closes it too.
    private static let parenthesizedSourceIDPattern = try? NSRegularExpression(
        pattern: #"[ \t]*\(\s*(?:(?:source[ _]?)?ids?\s*[:=]?\s*)?`?src_[0-9a-fA-F]*`?(?:\s*,\s*`?src_[0-9a-fA-F]*`?)*\s*(?:\)|\z)"#,
        options: [.caseInsensitive]
    )
    /// A bare id goes with the comma or space before it, so "video, src_…,
    /// on" leaves "video, on" rather than a doubled comma.
    private static let bareSourceIDPattern = try? NSRegularExpression(
        pattern: #"(?:,[ \t]*|[ \t]+)?`?\bsrc_[0-9a-fA-F]*`?"#
    )
    private static let spaceBeforePunctuationPattern = try? NSRegularExpression(
        pattern: #"[ \t]+([,.;:!?)])"#
    )
    private static let doubledSpacePattern = try? NSRegularExpression(
        pattern: #"(?<=\S)[ \t]{2,}(?=\S)"#
    )

    /// The reasoning with the library's source ids taken out. The model
    /// names its sources by id while it works ("The Feldman Protocol episode
    /// (src_ff45f9d4…)"); the title already says which source it means, and
    /// the id is sixty-odd hex digits nobody reads. Display only: the stored
    /// reasoning keeps them.
    static func withoutSourceIDs(_ reasoning: String) -> String {
        guard reasoning.contains("src_") else { return reasoning }
        var text = reasoning
        for pattern in [parenthesizedSourceIDPattern, bareSourceIDPattern] {
            guard let pattern else { continue }
            text = pattern.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
            )
        }
        if let spaceBeforePunctuationPattern {
            text = spaceBeforePunctuationPattern.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1"
            )
        }
        if let doubledSpacePattern {
            text = doubledSpacePattern.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " "
            )
        }
        return text
    }

    static func attributed(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(markdown)
    }
}

private struct ReviewChatReasoningParagraph: View, Equatable {
    let text: String

    var body: some View {
        Text(ReviewChatReasoningText.attributed(text))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One reply as it is drawn: its prose and the rows that stand on their own
/// (a review's turn to a source, the cards a call saved), with every step it
/// took on the way — its thinking and its tool calls — gathered into one
/// "Worked for" fold where the first of them ran, and the pages it wrote as
/// cards under that fold (docs/chat-design.md, "One line for the work").
/// ChatGPT draws a reply the same way; until 2026-10-06 one reply could stack
/// "Thought for 8s", "Sources in context", "Thought for 3s" and "Activity · 4
/// steps" above its answer.
enum ReviewChatAnswerLayout {
    enum Item: Identifiable {
        /// A prose message, a review's turn heading, or the cards a call saved.
        case entry(ReviewChatTranscriptEntry)
        /// The reply's steps, folded to one line.
        case work(ReviewChatWork)
        /// Pages a reopened chat's reply names at its head, drawn as cards.
        /// A live turn's pages ride its `work` instead.
        case pages(id: UUID, [ChatWrittenPage])

        var id: UUID {
            switch self {
            case .entry(let entry): return entry.id
            case .work(let work): return work.id
            case .pages(let id, _): return id
            }
        }
    }

    /// The items one reply's messages draw as. `showsThinking` is false on a
    /// memory review's topic card, which draws no thinking: its steps are
    /// the tool calls alone.
    @MainActor
    static func items(
        _ messages: [ReviewSessionManager.Message],
        showsThinking: Bool = true
    ) -> [Item] {
        // Nil marks where the fold goes: where its first step ran.
        var slots: [Item?] = []
        var workSlot: Int?
        var firstStepID: UUID?
        var steps: [ReviewSessionManager.Message.ToolActivity] = []
        var pages: [ChatWrittenPage] = []
        var lastStepPosition: Int?

        for (position, message) in messages.enumerated() {
            if let activity = message.toolActivity {
                if activity.toolName == ChatWrittenPage.cardRowName, let page = activity.writtenPage {
                    // A reopened reply's page: a card with no step behind it.
                    if case .pages(let id, let held)?? = slots.last {
                        slots[slots.count - 1] = .pages(id: id, held + [page])
                    } else {
                        slots.append(.pages(id: message.id, [page]))
                    }
                    continue
                }
                if activity.kind == .sourceTurn || activity.savedCards != nil {
                    slots.append(.entry(ReviewChatTranscriptEntry(id: message.id, message: nil, activities: [activity])))
                    continue
                }
                guard showsThinking || activity.kind != .thinking else { continue }
                if workSlot == nil {
                    workSlot = slots.count
                    firstStepID = message.id
                    slots.append(nil)
                }
                steps.append(activity)
                lastStepPosition = position
                // A failed attempt's page is not the retried reply's, which
                // stores none of them (`Message.isFromFailedAttempt`).
                if let page = activity.writtenPage, !message.isFromFailedAttempt {
                    pages = ChatWrittenPage.adding(page, to: pages)
                }
                continue
            }
            // Provider placeholders and protocol-only messages render nothing.
            guard isProse(message) else { continue }
            slots.append(.entry(ReviewChatTranscriptEntry(id: message.id, message: message, activities: [])))
        }

        if let workSlot, let firstStepID, let lastStepPosition {
            let answerHasBegun = messages[(lastStepPosition + 1)...].contains {
                !$0.isFromFailedAttempt && isProse($0)
            }
            slots[workSlot] = .work(ReviewChatWork(
                id: firstStepID,
                steps: steps,
                pages: pages,
                duration: workDuration(messages),
                answerHasBegun: answerHasBegun
            ))
        }
        return slots.compactMap { $0 }
    }

    /// How long the reply worked before its answer began: from the first
    /// step's start to the answer's first words, read off the rows' own
    /// clocks. A thinking row was written when the answer's first words
    /// landed and knows how long its step had run; a tool row, and the
    /// message each step streams into, were made when they began. When the
    /// answer's step thought first, the end is exact; otherwise it is when
    /// that step began, a little short of the first words. Nil with no step,
    /// and when the reply stopped at a tool with no answer after it, whose
    /// end no row records. Rows a reopened chat rebuilds carry no steps, so
    /// a reopened reply has no fold to time. A retried reply is timed from
    /// its own attempt: the rows the failed one left are not its work.
    @MainActor
    static func workDuration(_ messages: [ReviewSessionManager.Message]) -> TimeInterval? {
        let messages = messages.filter { !$0.isFromFailedAttempt }
        guard let lastStep = messages.lastIndex(where: isStep) else { return nil }
        let answer = messages[(lastStep + 1)...].firstIndex(where: isProse)
        let span = messages[...(answer ?? lastStep)]
        let starts = span.map { message -> Date in
            guard let activity = message.toolActivity, activity.kind == .thinking else { return message.createdAt }
            return message.createdAt.addingTimeInterval(-(activity.thinkingDuration ?? 0))
        }
        guard let start = starts.min() else { return nil }
        let thoughtUntil = span
            .filter { $0.toolActivity?.kind == .thinking }
            .map(\.createdAt)
            .max()
        let end: Date
        if let answer {
            end = max(messages[answer].createdAt, thoughtUntil ?? .distantPast)
        } else if messages[lastStep].toolActivity?.kind == .thinking {
            end = messages[lastStep].createdAt
        } else {
            return nil
        }
        return max(0, end.timeIntervalSince(start))
    }

    /// A row of the work: thinking, a tool call, a harness step. Not a
    /// review's turn heading, saved cards or a reopened reply's page card,
    /// which stand on their own.
    private static func isStep(_ message: ReviewSessionManager.Message) -> Bool {
        guard let activity = message.toolActivity else { return false }
        return activity.kind != .sourceTurn
            && activity.savedCards == nil
            && activity.toolName != ChatWrittenPage.cardRowName
    }

    @MainActor
    private static func isProse(_ message: ReviewSessionManager.Message) -> Bool {
        guard message.toolActivity == nil, message.role != .tool else { return false }
        return ReviewSessionManager.displayableMessageContent(role: message.role, content: message.content)?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

/// The steps one reply took, for its fold.
struct ReviewChatWork: Equatable {
    /// The first step's message id, which the fold scrolls by.
    let id: UUID
    /// Thinking and tool rows, in the order they ran.
    let steps: [ReviewSessionManager.Message.ToolActivity]
    /// The pages the steps wrote, a card each under the fold.
    let pages: [ChatWrittenPage]
    /// How long the reply worked (`ReviewChatAnswerLayout.workDuration`).
    let duration: TimeInterval?
    /// The answer's words have begun landing under the fold.
    let answerHasBegun: Bool
}

/// A reply's work as one quiet line, ChatGPT's "Worked for 2m 17s ›" — or
/// "Thought for 8s ›" when the reply only thought — that opens onto every
/// step in order: the reasoning as it was written and each tool call, with
/// grey glyphs. While the turn works it reads "Working" and stays open, so
/// the steps show as they happen and each step's thinking streams under the
/// status line below (product owner, 2026-09-23: "you can show all the thinking …
/// but then it gets collapsed when it's done and shows the final answer");
/// it folds once the answer's first words land, and stays folded. What asks
/// the learner to act — a plugin to connect — and the pages the steps wrote
/// stay under the line, outside the fold. The line is set at the reply's own
/// size with a thin rule under it once the work is done, as Codex draws it
/// (2026-10-11).
struct ReviewChatWorkFold: View {
    let work: ReviewChatWork
    /// True while the turn these steps belong to is still running.
    var isLive = false
    /// Set once the learner works the disclosure themselves; their choice then
    /// outranks the live default for the rest of the session.
    @State private var manualExpansion: Bool?
    /// The answer began while the turn ran: the fold closed and stays closed,
    /// even when a later step runs after words the model wrote first.
    @State private var answerLanded = false

    private var isExpanded: Bool { manualExpansion ?? (isLive && !answerLanded) }

    private var isRunning: Bool {
        work.steps.contains { $0.state == .running }
    }

    private var failedCount: Int {
        work.steps.filter { $0.state == .failed }.count
    }

    /// "Working" while a step may still follow; once the answer is landing
    /// the work is done, and the line says how long it took.
    private var title: String {
        isLive && !work.answerHasBegun ? "Working" : Self.title(steps: work.steps, duration: work.duration)
    }

    /// The work is done and the line says how long it took: the rule under it
    /// is drawn. While it reads "Working" the steps are still coming.
    private var isSettled: Bool {
        !(isLive && !work.answerHasBegun)
    }

    private var failedDetail: String? {
        guard failedCount > 0 else { return nil }
        return failedCount == 1 ? "1 failed" : "\(failedCount) failed"
    }

    /// The most recent browser step with a picture: the one picture the fold
    /// shows, under the line while folded and on its own row when open.
    private var latestBrowserPreviewIndex: Int? {
        work.steps.lastIndex { $0.isBrowserStep && $0.previewImage != nil }
    }

    /// What the failed steps ask the learner to set up: a plugin that was not
    /// there to read with. One card per plugin, under the line and outside
    /// the fold, so the way to connect stays in view when the steps close.
    private var setupNeeds: [ChatPluginRequest.SetupNeed] {
        ChatPluginRequest.setupNeeds(in: work.steps.filter { $0.kind != .thinking }.map { activity in
            (toolName: activity.toolName, error: activity.state == .failed ? activity.resultPreview : nil)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                manualExpansion = !isExpanded
            } label: {
                HStack(spacing: 6) {
                    if isLive, isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                    }

                    // The reply's own size, as Codex sets it, a step softer.
                    Text(title)
                        .zoomedSystemFont(size: ChatMarkdownView.baseFontSize)
                        .foregroundStyle(.secondary)

                    if let failedDetail {
                        Text(failedDetail)
                            .zoomedSystemFont(size: ChatMarkdownView.baseFontSize)
                            .foregroundStyle(.orange)
                    }

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .zoomedSystemFont(size: 10, weight: .semibold)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: -3))
            .help(isExpanded ? "Hide the steps" : "Show the steps")
            .accessibilityLabel([title, failedDetail].compactMap { $0 }.joined(separator: ", "))
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("mac.chatWorkFold")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Self.segments(of: work.steps)) { segment in
                        if segment.isThinking, let step = segment.steps.first?.step {
                            ReviewChatReasoningText(reasoning: step.reasoning, textInset: 10)
                        } else {
                            // Claude Science's way: a run of tool calls is one
                            // soft card, a line each.
                            ReviewChatToolCard {
                                ForEach(segment.steps, id: \.index) { entry in
                                    ReviewChatToolRow(
                                        activity: entry.step,
                                        showsBrowserPreview: entry.index == latestBrowserPreviewIndex,
                                        inCard: true
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 2)
            } else if isLive, let index = latestBrowserPreviewIndex,
                      let preview = work.steps[index].previewImage {
                // Folded while the turn still runs: the learner watches the
                // chat work in the Browser without opening the steps.
                ReviewChatBrowserPreview(image: preview, isRunning: isRunning)
            }

            if isSettled {
                // Codex's thin rule between the work and the answer under it.
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }

            ForEach(setupNeeds, id: \.self) { need in
                ChatPluginSetupCard(need: need)
            }

            if !work.pages.isEmpty {
                ReviewChatPageCards(pages: work.pages)
            }
        }
        .onChange(of: work.answerHasBegun, initial: true) { _, begun in
            if begun { answerLanded = true }
        }
    }

    /// One stretch of the steps as the open fold draws it: a single thinking
    /// step, or the run of tool calls between two of them.
    struct Segment: Identifiable {
        let id: Int
        let isThinking: Bool
        let steps: [(index: Int, step: ReviewSessionManager.Message.ToolActivity)]
    }

    static func segments(of steps: [ReviewSessionManager.Message.ToolActivity]) -> [Segment] {
        var segments: [Segment] = []
        for (index, step) in steps.enumerated() {
            let isThinking = step.kind == .thinking
            if !isThinking, let last = segments.last, !last.isThinking {
                segments[segments.count - 1] = Segment(
                    id: last.id, isThinking: false, steps: last.steps + [(index, step)]
                )
            } else {
                segments.append(Segment(id: index, isThinking: isThinking, steps: [(index, step)]))
            }
        }
        return segments
    }

    /// The settled line: "Worked for 2m 17s" when the reply used a tool,
    /// "Thought for 8s" when it only thought. With no time to give it says
    /// what it knows: "Worked · 4 steps", or "Thought".
    static func title(
        steps: [ReviewSessionManager.Message.ToolActivity],
        duration: TimeInterval?
    ) -> String {
        let actions = steps.filter { $0.kind != .thinking }.count
        guard actions > 0 else {
            // Only thinking: the time each step thought, added up.
            let durations = steps.map(\.thinkingDuration)
            guard !durations.isEmpty, durations.allSatisfy({ $0 != nil }) else { return "Thought" }
            return "Thought for \(durationText(durations.compactMap { $0 }.reduce(0, +)))"
        }
        guard let duration else {
            return actions == 1 ? "Worked · 1 step" : "Worked · \(actions) steps"
        }
        return "Worked for \(durationText(duration))"
    }

    /// "a moment", "8s", "1m", "1m 36s", "1h 4m". Rounded to the second: the
    /// line says roughly how long the work took, not a stopwatch reading.
    static func durationText(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        guard seconds >= 1 else { return "a moment" }
        guard seconds >= 60 else { return "\(seconds)s" }
        let minutes = seconds / 60
        guard minutes >= 60 else {
            let rest = seconds % 60
            return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s"
        }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}

/// The pages a reply wrote, a card each, ChatGPT's way: the page's glyph, its
/// title, "Page", and Open, which opens it in this window (right-click for the
/// other one). The title is the page's own as it stands now when the library
/// holds it, so a page renamed since reads by its new name.
struct ReviewChatPageCards: View {
    let pages: [ChatWrittenPage]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(pages, id: \.id) { page in
                if let url = page.animationURL {
                    ReviewChatAnimationCard(page: page, url: url)
                } else {
                    ReviewChatPageCard(page: page)
                }
            }
        }
    }
}

/// An animation the reply saved, playing in the chat from its library
/// address under the card player's policy, with its title, Enlarge and Open
/// (into the Animations pane) under it (product owner, 2026-11-08: "make sure
/// they can be rendered from a chat also").
private struct ReviewChatAnimationCard: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?

    let page: ChatWrittenPage
    let url: URL
    @State private var isEnlarged = false

    private static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    private var title: String {
        let current = vm.artifacts.first(where: { $0.id == page.id })?.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let current, !current.isEmpty { return current }
        return page.title.isEmpty ? "Animation" : page.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WalkthroughHostedAnimationWebView(url: url, restrictsNetwork: true)
                .frame(height: 400)
                .clipShape(Self.shape)
                .overlay(Self.shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            HStack(spacing: 8) {
                Image(systemName: ArtifactKind.animation.symbolName)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                Button { isEnlarged = true } label: {
                    Label("Enlarge", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                }
                .buttonStyle(.hoverWash)
                .help("Play the animation larger")
                Button("Open") { vm.revealArtifact(page.id, in: windowState) }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.hoverWash)
                    .help("Open \(title) in Animations")
            }
            .textSelection(.disabled)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Animation \(title)")
        .accessibilityIdentifier("mac.chatAnimationCard")
        .sheet(isPresented: $isEnlarged) {
            WalkthroughAnimationSheet(title: title, content: .hosted(url: url), restrictsNetwork: true)
        }
    }
}

private struct ReviewChatPageCard: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    @Environment(\.colorScheme) private var colorScheme

    let page: ChatWrittenPage

    private static let maxWidth: CGFloat = 420
    private static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    private var title: String {
        let current = vm.artifacts.first(where: { $0.id == page.id })?.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let current, !current.isEmpty { return current }
        return page.title.isEmpty ? "Untitled" : page.title
    }

    var body: some View {
        Button {
            vm.revealArtifact(page.id, in: windowState)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "doc.text")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("Page")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text("Open")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            .padding(10)
            .frame(maxWidth: Self.maxWidth, alignment: .leading)
            .background(Self.shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.03)))
            .overlay(Self.shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .contentShape(Self.shape)
        }
        .buttonStyle(.hoverWash(in: Self.shape, inset: 0))
        // The card is the control; its words are its label.
        .textSelection(.disabled)
        .contextMenu {
            OtherWindowMenuItem(.doc(page.id))
        }
        .help("Open \(title)")
        .accessibilityLabel("Open page \(title)")
        .accessibilityIdentifier("mac.chatPageCard")
    }
}

/// The soft rounded card a run of tool calls sits in inside an open fold, as
/// Claude Science draws them: a light fill, no border, a line per call.
struct ReviewChatToolCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04))
        )
    }
}

/// A single tool operation, one step inside an open "Worked for" fold
/// (`ReviewChatWorkFold`): a grey glyph, what it did and on what, and, when it
/// returned something worth reading, a disclosure onto it. In a card
/// (`ReviewChatToolCard`) the glyph is a check, and what the call returned is
/// said in a few words at the right edge ("1 line of output").
struct ReviewChatToolRow: View {
    let activity: ReviewSessionManager.Message.ToolActivity
    /// Whether this row draws the picture of the Browser tab behind it. Only
    /// the latest browser step in a group does, so a run of ten page turns
    /// shows one live picture rather than a column of them.
    var showsBrowserPreview = true
    /// Drawn as a line of a `ReviewChatToolCard` rather than on its own.
    var inCard = false
    @State private var isExpanded = false

    /// What the call returned, in a few words. Counted from the preview the
    /// row keeps, so a result cut at the preview's length says "+".
    private var resultSummary: String? { Self.resultSummary(for: activity) }

    /// `resultSummary` for any step; the one-page transcript's step list reads
    /// the same words (`ChatTranscriptPage.workPart`).
    static func resultSummary(for activity: ReviewSessionManager.Message.ToolActivity) -> String? {
        switch activity.state {
        case .running: return nil
        case .failed: return "failed"
        case .succeeded: break
        }
        if presentsRetrievedPassages(activity) {
            let count = activity.retrievedPassages.count
            return count == 1 ? "1 passage" : "\(count) passages"
        }
        if presentsListedSources(activity) {
            let count = activity.listedSources.count
            return count == 1 ? "1 source" : "\(count) sources"
        }
        if presentsSourceCard(activity) { return "loaded" }
        guard let preview = activity.resultPreview else { return "done" }
        let lines = preview.split(whereSeparator: \.isNewline).count
        let cut = preview.count >= 1_200 ? "+" : ""
        return lines == 1 && cut.isEmpty ? "1 line of output" : "\(lines)\(cut) lines of output"
    }

    private var presentsSourceCard: Bool { Self.presentsSourceCard(activity) }

    private static func presentsSourceCard(_ activity: ReviewSessionManager.Message.ToolActivity) -> Bool {
        activity.toolName == "get_source_content"
            && activity.state == .succeeded
            && activity.sourcePresentation != nil
    }

    /// A retrieval that parsed into per-source passages shows those as cards;
    /// one that did not keeps the raw preview so nothing is hidden.
    private var presentsRetrievedPassages: Bool { Self.presentsRetrievedPassages(activity) }

    private static func presentsRetrievedPassages(_ activity: ReviewSessionManager.Message.ToolActivity) -> Bool {
        activity.toolName == "retrieve_sources"
            && activity.state == .succeeded
            && !activity.retrievedPassages.isEmpty
    }

    /// A day listing whose sources have loaded shows a banner per source; the
    /// transcripts it handed the model stay out of the transcript.
    private var presentsListedSources: Bool { Self.presentsListedSources(activity) }

    private static func presentsListedSources(_ activity: ReviewSessionManager.Message.ToolActivity) -> Bool {
        activity.toolName == "get_today_sources"
            && activity.state == .succeeded
            && !activity.listedSources.isEmpty
    }

    private var canExpand: Bool {
        presentsSourceCard || presentsRetrievedPassages || presentsListedSources || activity.resultPreview != nil
    }

    private var icon: String {
        switch activity.state {
        // .running renders as a spinner below; the symbol here is a fallback.
        case .running: return "circle.dotted"
        // Per-operation glyph rather than a uniform checkmark, so the transcript
        // scans as a sequence of distinct actions (search, read, compact, retry).
        case .succeeded: return activity.symbolName
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    /// Grey for every step, ChatGPT's way: the glyph says what kind of step
    /// it was, and colour is kept for a step that failed.
    private var tint: Color {
        activity.state == .failed ? .orange : .secondary
    }

    private var helpText: String {
        guard canExpand else { return activity.toolName }
        if presentsSourceCard {
            return isExpanded ? "Hide source" : "Show source"
        }
        if presentsListedSources {
            return isExpanded ? "Hide the sources" : "Show the sources"
        }
        if presentsRetrievedPassages {
            let plural = activity.retrievedPassages.count > 1
            return isExpanded
                ? (plural ? "Hide passages" : "Hide passage")
                : (plural ? "Show the passages read" : "Show the passage read")
        }
        return activity.state == .failed
            ? "\(activity.toolName) — click to show the error"
            : "\(activity.toolName) — click to show what it returned"
    }

    private var title: String { Self.title(for: activity) }

    /// `title` for any step (`ChatTranscriptPage.workPart`).
    static func title(for activity: ReviewSessionManager.Message.ToolActivity) -> String {
        guard ["get_source_content", "retrieve_sources"].contains(activity.toolName) else {
            return activity.title
        }
        switch activity.state {
        case .running: return "Loading source into context"
        case .succeeded: return activity.retrievedPassages.count > 1 ? "Sources in context" : "Source in context"
        case .failed: return "Source could not be loaded"
        }
    }

    /// A line of a card: a check (a spinner while it runs, a warning when it
    /// failed), the step and what it was on, and the result at the right edge.
    private var cardLabel: some View {
        HStack(spacing: 10) {
            ZStack {
                switch activity.state {
                case .running:
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                case .succeeded:
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.green.opacity(0.75))
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 14, height: 14)

            Text(title)
                .zoomedSystemFont(size: ReviewChatReasoningText.fontSize)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let detail = activity.detail, !detail.isEmpty {
                Text(detail)
                    .zoomedSystemFont(size: ReviewChatReasoningText.fontSize)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(activity.sourcePresentation == nil ? .middle : .tail)
            }

            Spacer(minLength: 12)

            if let resultSummary {
                Text(resultSummary)
                    .zoomedSystemFont(size: ReviewChatReasoningText.fontSize)
                    .foregroundStyle(activity.state == .failed ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }

            if canExpand {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .zoomedSystemFont(size: 10, weight: .semibold)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard canExpand else { return }
                isExpanded.toggle()
            } label: {
                if inCard {
                    cardLabel
                } else {
                    HStack(spacing: 6) {
                        if activity.state == .running {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: icon)
                                .font(.system(size: 11))
                                .foregroundStyle(tint)
                        }

                        Text(title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                        if let detail = activity.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(activity.sourcePresentation == nil ? .middle : .tail)
                        }

                        if canExpand {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    // No chip: a step is a line of the fold, lit only under the
                    // pointer.
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.hoverWash(cornerRadius: inCard ? 9 : 6, inset: inCard ? 0 : -3))
            .help(helpText)

            if showsBrowserPreview, activity.isBrowserStep, let preview = activity.previewImage {
                ReviewChatBrowserPreview(image: preview, isRunning: activity.state == .running)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if presentsSourceCard, let presentation = activity.sourcePresentation {
                        HStack(spacing: 9) {
                            SourceThumbnail(source: presentation.source, size: 34)

                            Text(presentation.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)

                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(
                            Color.primary.opacity(0.03),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                    } else if presentsRetrievedPassages {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(activity.retrievedPassages) { passage in
                                ReviewChatRetrievedPassageCard(passage: passage)
                            }
                        }
                    } else if presentsListedSources {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(activity.listedSources, id: \.id) { presentation in
                                ReviewChatSourceBanner(source: presentation.source)
                            }
                        }
                    } else if let preview = activity.resultPreview {
                        Text(preview)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                            .background(
                                Color.primary.opacity(0.03),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                    }
                }
                .padding(.horizontal, inCard ? 8 : 0)
            }
        }
    }
}

/// One source under an expanded day listing ("What you watched today"): its
/// picture — a video's still at 16:9, anything else its library thumbnail —
/// with the title and channel or author beside it. Clicking opens it in the
/// Reader, so the list doubles as a way back to what was watched.
struct ReviewChatSourceBanner: View {
    let source: StudioArticle
    @Environment(StudioViewModel.self) private var vm

    private static let pictureSize = CGSize(width: 112, height: 63)

    private var byline: String? {
        let candidates: [String?] = [source.displayAuthor, vm.sourceGroupTitle(for: source), source.displayDomain]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private var typeLabel: String {
        switch source.sourceType {
        case .article, .unclassified, .manual: return "Article"
        case .paper: return "Paper"
        case .podcast: return "Podcast"
        case .book: return "Book"
        case .course: return "Course lecture"
        case .meeting: return "Meeting"
        case .video: return "Video"
        case .xPost: return "Post"
        }
    }

    @ViewBuilder
    private var picture: some View {
        if source.sourceType == .video || source.sourceType == .course,
           let url = SourceArtwork.remoteURL(for: source) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    SourceThumbnail(source: source, size: Self.pictureSize.height)
                default:
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: Self.pictureSize.width, height: Self.pictureSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            SourceThumbnail(source: source, size: Self.pictureSize.height)
                .frame(width: Self.pictureSize.width, height: Self.pictureSize.height)
                .background(
                    Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
    }

    var body: some View {
        Button {
            Task { await vm.openLinkedSourceInReader(source.id) }
        } label: {
            HStack(spacing: 11) {
                picture

                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let byline {
                        Text(byline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(typeLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 9, inset: 0))
        .help("Open \(source.title)")
    }
}

/// One retrieved source under an expanded retrieval row: the library card the
/// read-source row already uses, with the passage the tutor read beneath it as
/// ordinary prose. The passage is clipped so a long excerpt never turns the
/// transcript into a second reader; the source itself is one click away.
struct ReviewChatRetrievedPassageCard: View {
    let passage: ReviewSessionManager.Message.ToolActivity.RetrievedPassage
    @State private var showsWholePassage = false

    private static let clipLength = 700

    private var isClipped: Bool {
        passage.passage.count > Self.clipLength && !showsWholePassage
    }

    private var visiblePassage: String {
        guard isClipped else { return passage.passage }
        let head = passage.passage.prefix(Self.clipLength)
        // Cut at a word, not mid-word.
        let cut = head.lastIndex(where: { $0.isWhitespace }).map { head[..<$0] } ?? head
        return String(cut).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private var sourceTypeLabel: String? {
        guard let type = StudioSourceType(rawValue: passage.sourceType) else { return nil }
        switch type {
        case .article, .unclassified, .manual: return "Article"
        case .paper: return "Paper"
        case .podcast: return "Podcast"
        case .book: return "Book"
        case .course: return "Course"
        case .meeting: return "Meeting"
        case .video: return "Video"
        case .xPost: return "Post"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                if let presentation = passage.presentation {
                    SourceThumbnail(source: presentation.source, size: 34)
                } else {
                    Image(systemName: "doc.text")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .frame(width: 34, height: 34)
                        .background(
                            Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(passage.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if let sourceTypeLabel {
                            Text(sourceTypeLabel)
                        }
                        if passage.addedByForeverLM {
                            Text("Added by ForeverLM")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
            }

            if !passage.passage.isEmpty {
                Text(visiblePassage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if passage.passage.count > Self.clipLength {
                    Button(showsWholePassage ? "Show less" : "Show more") {
                        showsWholePassage.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
    }
}

/// Codex-style operation glyphs: each family of operations gets a small
/// distinctive icon so the transcript reads as a sequence of actions —
/// searched, read, compacted, retried — rather than a column of identical
/// checkmarks. Presentation-only, so it lives with the view, not the model.
private extension ReviewSessionManager.Message.ToolActivity {
    var symbolName: String {
        switch kind {
        case .compaction: return "arrow.down.right.and.arrow.up.left"
        case .retry: return "arrow.clockwise"
        case .continuation: return "arrow.turn.down.right"
        case .fallback: return "arrow.triangle.branch"
        case .sourceTurn: return "arrow.right.circle"
        case .thinking: return "clock"
        case .tool: break
        }

        if let sourcePresentation,
           let sourceType = StudioSourceType(rawValue: sourcePresentation.sourceType) {
            switch sourceType {
            case .article, .unclassified: return "doc.richtext"
            case .paper: return "doc.text.magnifyingglass"
            case .podcast: return "headphones"
            case .book: return "book.closed"
            case .course: return "graduationcap"
            case .meeting: return "person.2.wave.2"
            case .video: return "play.rectangle"
            case .xPost: return "bubble.left"
            case .manual: return "link"
            }
        }
        switch toolName {
        case "get_source_content", "retrieve_sources": return "doc.text"
        case "generate_image", "list_generated_images": return "photo"
        case "show_source_image", "inspect_paper_figure": return "photo.on.rectangle"
        case "focus_source_anchor": return "scope"
        case "list_skills", "get_skill", "save_skill", "delete_skill": return "wand.and.stars"
        case "list_working_notes", "save_working_note", "update_working_note", "forget_working_note": return "note.text"
        case "extract_video_slides": return "rectangle.on.rectangle.angled"
        case "run_code": return "terminal"
        case "list_sources", "filter_sources": return "list.bullet"
        case "list_shows": return "mic"
        case "get_app_context": return "info.circle"
        case "list_open_panes": return "rectangle.split.2x1"
        case "get_today_sources", "get_schedule", "assign_sources_to_day", "set_source_completion": return "calendar"
        default: break
        }
        // Family fallbacks, most specific first: "search_review_sessions" is a
        // search before it is a review; "update_notebook_notes" is notes before
        // it is a notebook tool.
        if toolName.contains("search") { return "magnifyingglass" }
        if toolName.contains("notes") || toolName.contains("synthesis") { return "square.and.pencil" }
        if toolName.contains("question") { return "questionmark.circle" }
        if toolName.contains("goal") { return "target" }
        if toolName.contains("schedule") { return "calendar" }
        if toolName.contains("review") || toolName.contains("quiz") { return "graduationcap" }
        if toolName.contains("notebook") || toolName.contains("companion") { return NotebookGlyph.systemImage }
        if toolName.contains("source") { return "doc.text" }
        return "hammer"
    }
}

/// Claude-style context gauge: a small ring in the composer showing how full
/// the model's context window is, with a popover breaking the estimate down by
/// component and per attached source, plus the latest request's prompt-cache
/// read/write counts from the local usage ledger.
struct ChatContextGauge: View {
    let breakdown: ReviewSessionManager.ChatContextBreakdown
    let sessionCost: ReviewSessionManager.ChatSessionCost?
    /// The chat ⋯'s Context and Cost…: true opens the breakdown, and the
    /// gauge sets it back to false once the breakdown closes.
    @Binding var isBreakdownRequested: Bool
    @State private var isPopoverPresented = false

    init(
        breakdown: ReviewSessionManager.ChatContextBreakdown,
        sessionCost: ReviewSessionManager.ChatSessionCost?,
        isBreakdownRequested: Binding<Bool> = .constant(false)
    ) {
        self.breakdown = breakdown
        self.sessionCost = sessionCost
        self._isBreakdownRequested = isBreakdownRequested
    }

    var body: some View {
        Button {
            isPopoverPresented = true
        } label: {
            ZStack {
                // Dashed track when no host has published a window: the ring
                // then has nothing to fill against.
                Circle()
                    .stroke(
                        Color.primary.opacity(0.15),
                        style: StrokeStyle(lineWidth: 2.5, dash: breakdown.contextWindowTokens == nil ? [2, 2] : [])
                    )
                Circle()
                    .trim(from: 0, to: max(0.03, breakdown.usedFraction))
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
            .padding(4)
            .contentShape(Circle())
        }
        .buttonStyle(.hoverWash(in: Circle(), opacity: 0.12))
        .help("Context window: \(breakdown.headlineText) — click for the breakdown")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            ChatContextGaugePopover(breakdown: breakdown, sessionCost: sessionCost)
        }
        // Asked for from the ⋯: open as the ring appears, and give the ask
        // back when the breakdown closes, so the ring goes with it unless the
        // context is filling up.
        .task(id: isBreakdownRequested) {
            if isBreakdownRequested { isPopoverPresented = true }
        }
        .onChange(of: isPopoverPresented) { _, presented in
            if !presented, isBreakdownRequested { isBreakdownRequested = false }
        }
        // A ring that goes with its breakdown still open — another chat
        // opened, the mic took the row — gives the ask back too, or the next
        // ring would open its breakdown unasked.
        .onDisappear {
            if isBreakdownRequested { isBreakdownRequested = false }
        }
    }

    private var ringColor: Color {
        switch breakdown.usedFraction {
        case ..<0.7: return .accentColor
        case ..<0.9: return .orange
        default: return .red
        }
    }
}

private struct ChatContextGaugePopover: View {
    let breakdown: ReviewSessionManager.ChatContextBreakdown
    let sessionCost: ReviewSessionManager.ChatSessionCost?

    private struct ComponentRow: Identifiable {
        let id: String
        let label: String
        let tokens: Int
        let color: Color
    }

    private var componentRows: [ComponentRow] {
        var rows: [ComponentRow] = [
            ComponentRow(id: "instructions", label: "Instructions", tokens: breakdown.instructionTokens, color: Color.accentColor)
        ]
        if breakdown.sourceTokens > 0 {
            rows.append(ComponentRow(id: "sources", label: "Attached sources", tokens: breakdown.sourceTokens, color: Color.accentColor.opacity(0.75)))
        }
        if breakdown.toolTokens > 0 {
            rows.append(ComponentRow(id: "tools", label: "App tools", tokens: breakdown.toolTokens, color: Color.accentColor.opacity(0.55)))
        }
        rows.append(ComponentRow(id: "conversation", label: "Conversation & tool results", tokens: breakdown.conversationTokens, color: Color.accentColor.opacity(0.4)))
        if breakdown.volatileTokens > 0 {
            rows.append(ComponentRow(id: "volatile", label: "History digest & turn notes", tokens: breakdown.volatileTokens, color: Color.accentColor.opacity(0.25)))
        }
        if let freeTokens = breakdown.freeTokens {
            rows.append(ComponentRow(id: "free", label: "Free space", tokens: freeTokens, color: Color.primary.opacity(0.10)))
        }
        return rows
    }

    /// Sources shown individually before collapsing into "+N more".
    private let maxSourceRows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Context window")
                    .font(.headline)
                Spacer()
                Text(breakdown.headlineText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plainTextSummary, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.hoverWash)
                .foregroundStyle(.secondary)
                .help("Copy this breakdown")
            }

            Text("\(breakdown.providerName) · \(breakdown.modelID)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            usageBar

            VStack(alignment: .leading, spacing: 5) {
                ForEach(componentRows) { row in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(row.color)
                            .frame(width: 8, height: 8)
                        Text(row.label)
                            .font(.caption)
                        Spacer()
                        Text(chatTokenText(row.tokens))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(percentText(row.tokens))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            if !breakdown.perSource.isEmpty {
                Divider()
                sourceRows
            }

            Divider()
            cacheSection

            if sessionCost != nil {
                Divider()
                costSection
            }

            if breakdown.contextWindowTokens == nil {
                Text(unknownWindowNote)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
        .textSelection(.enabled)
    }

    /// Everything the popover shows, flattened for the clipboard so a breakdown
    /// can be pasted into a bug report without retyping the numbers.
    private var plainTextSummary: String {
        var lines: [String] = [
            "Context window: \(breakdown.headlineText)",
            "\(breakdown.providerName) · \(breakdown.modelID)",
            ""
        ]
        for row in componentRows {
            lines.append("\(row.label): \(chatTokenText(row.tokens)) (\(percentText(row.tokens)))")
        }

        if !breakdown.perSource.isEmpty {
            lines.append("")
            lines.append("Per source")
            for share in breakdown.perSource {
                lines.append("\(share.title): \(chatTokenText(breakdown.tokens(share.characters)))")
            }
            let attributed = breakdown.perSource.reduce(0) { $0 + $1.characters }
            let remainder = breakdown.tokens(breakdown.sourceCharacters - attributed)
            if remainder > 0 {
                lines.append("Source inventory & retrieved excerpts: \(chatTokenText(remainder))")
            }
        }

        lines.append("")
        lines.append("Prompt cache — last request")
        if let cache = lastRequestCache {
            lines.append("Read from cache: \(chatTokenText(cache.reads))")
            lines.append("Written to cache: \(chatTokenText(cache.writes))")
            lines.append("Fresh input: \(chatTokenText(cache.fresh))")
        } else {
            lines.append("No completed request on \(breakdown.providerName) yet in this app run.")
        }

        if let cost = sessionCost {
            lines.append("")
            lines.append("Cost — this chat")
            lines.append("\(cost.eventCount) request\(cost.eventCount == 1 ? "" : "s"): \(chatCostText(cost.totalUSD))")
            if cost.unpricedEventCount > 0 {
                lines.append("\(cost.unpricedEventCount) of these carried no price — the total is a floor.")
            }
        }

        lines.append("")
        if breakdown.contextWindowTokens == nil { lines.append(unknownWindowNote) }
        lines.append(footnote)
        return lines.joined(separator: "\n")
    }

    private var usageBar: some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(componentRows) { row in
                    row.color
                        .frame(width: max(0, proxy.size.width * fraction(row.tokens)))
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var sourceRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Per source")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(breakdown.perSource.prefix(maxSourceRows)) { share in
                HStack(spacing: 6) {
                    Text(share.title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Text(chatTokenText(breakdown.tokens(share.characters)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if breakdown.perSource.count > maxSourceRows {
                Text("+ \(breakdown.perSource.count - maxSourceRows) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            // Attributed against characters, not the rounded per-row tokens, so
            // the remainder can't pick up rounding drift across many sources.
            let attributed = breakdown.perSource.reduce(0) { $0 + $1.characters }
            let remainder = breakdown.tokens(breakdown.sourceCharacters - attributed)
            if remainder > 0 {
                HStack(spacing: 6) {
                    Text("Source inventory & retrieved excerpts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(chatTokenText(remainder))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    /// Cache read/write/fresh split for the last streamed chat request on this
    /// provider, as the provider itself reported it. Nil until one completes.
    private var lastRequestCache: (reads: Int, writes: Int, fresh: Int)? {
        guard let event = ChatUsageLiveMonitor.shared.latestStreamChatEvent,
              event.provider == breakdown.providerName else { return nil }
        let reads = event.cachedInputTokens ?? 0
        let writes = event.cacheCreationInputTokens ?? 0
        let input = event.inputTokens ?? 0
        // Anthropic's input_tokens already excludes cache reads and writes;
        // OpenAI-style providers fold cached reads into prompt_tokens.
        let fresh = breakdown.providerName == AIProvider.anthropic.shortName
            ? input
            : max(0, input - reads)
        return (reads, writes, fresh)
    }

    /// True when the last request re-read most of the stable prefix
    /// (instructions + sources + tools) from cache rather than paying full price.
    private var stablePrefixWasCached: Bool {
        guard let cache = lastRequestCache else { return false }
        let stablePrefixTokens = breakdown.instructionTokens + breakdown.sourceTokens + breakdown.toolTokens
        guard stablePrefixTokens > 0 else { return false }
        return Double(cache.reads) >= 0.7 * Double(stablePrefixTokens)
    }

    @ViewBuilder
    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Prompt cache — last request")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if let cache = lastRequestCache {
                cacheRow("Read from cache", cache.reads)
                cacheRow("Written to cache", cache.writes)
                cacheRow("Fresh input", cache.fresh)

                if stablePrefixWasCached {
                    Label("Instructions, sources, and tools were served from cache", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            } else {
                Text("No completed request on \(breakdown.providerName) yet in this app run.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func cacheRow(_ label: String, _ tokens: Int) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
            Spacer()
            Text(chatTokenText(tokens))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var costSection: some View {
        if let cost = sessionCost {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cost — this chat")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Text(cost.eventCount == 1 ? "1 request" : "\(cost.eventCount) requests")
                        .font(.caption)
                    Spacer()
                    Text(chatCostText(cost.totalUSD))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if cost.unpricedEventCount > 0 {
                    Text("\(cost.unpricedEventCount) of these carried no price — the total is a floor.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Says exactly how much of the panel is measured. The total is the
    /// provider's own number once a request has completed; the split across
    /// components stays a proportional attribution either way, because
    /// providers bill a request as a whole, never per component.
    private var footnote: String {
        guard breakdown.isCalibrated else {
            return "Estimated at ~\(AIService.approxCharsPerToken) characters per token until the first request completes."
        }
        let ratio = String(format: "%.1f", breakdown.charactersPerToken)
        let source = breakdown.measuredPromptTokens == nil ? "the last request" : "this request"
        return "Total measured from \(source) (\(ratio) characters per token); the split across components is proportional."
    }

    /// No host published a window for this model, so the popover shows the
    /// request's composition without percentages and says why.
    private var unknownWindowNote: String {
        "No context window is published for \(breakdown.modelID) on \(breakdown.providerName), so no percentage is shown and nothing is trimmed to fit."
    }

    /// Share of the window — or, when none is published, share of the request
    /// itself, so the bar still shows how the request is composed.
    private func fraction(_ tokens: Int) -> Double {
        let denominator = breakdown.contextWindowTokens ?? breakdown.usedTokens
        guard denominator > 0 else { return 0 }
        return Double(tokens) / Double(denominator)
    }

    private func percentText(_ tokens: Int) -> String {
        guard let window = breakdown.contextWindowTokens, window > 0 else { return "—" }
        let percent = 100 * Double(tokens) / Double(window)
        if percent > 0 && percent < 0.1 { return "<0.1%" }
        return String(format: "%.1f%%", percent)
    }
}

extension ReviewSessionManager.ChatContextBreakdown {
    var usedPercentText: String {
        String(format: "%.0f%%", 100 * usedFraction)
    }

    /// "115k / 256k (45%)", or "115k · window not published" when no host has
    /// published one — never a percentage of a guessed denominator.
    var headlineText: String {
        let used = approximationPrefix + chatTokenText(usedTokens)
        guard let window = contextWindowTokens else { return "\(used) · window not published" }
        return "\(used) / \(chatTokenText(window)) (\(usedPercentText))"
    }

    /// "~" only while the numbers are still the raw character guess.
    var approximationPrefix: String { isCalibrated ? "" : "~" }
}

func chatTokenText(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 10_000 { return String(format: "%.0fk", Double(value) / 1_000) }
    if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
    return "\(value)"
}

/// USD amount for the chat cost rows. Same convention as the AI Usage pane:
/// sub-cent amounts keep four decimals so a cheap cached turn doesn't round
/// to a flat $0.00 the moment it costs anything.
func chatCostText(_ usd: Double) -> String {
    if usd > 0 && usd < 0.01 { return String(format: "$%.4f", usd) }
    return String(format: "$%.2f", usd)
}

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
                    // force-quit (2026-09-17). See `ChatLongUserMessage`.
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

// MARK: - The cards a chat saved

/// The cards a chat saved (`save_card_drafts`), drawn in the reply as the cards
/// themselves (docs/memory-design.md, "The cards in the chat"). Until
/// 2026-10-06 the reply only said in prose what it had saved, under a bare
/// `save_card_drafts` step, and the product owner had to ask where they were: "it should
/// immediately point to those actual cards".
///
/// A small deck: the card on top drawn as To Check draws it — the front in
/// the card review's serif, a rule, the back — with where it
/// stands now, the cards under it stacked behind, ‹ › to page through them.
/// The header counts them as they stand ("6 cards to check", "4 to check · 2
/// kept"). Its one primary action, **Check Cards**, opens To Check beside the
/// chat at the card on top (`openChatSavedCard`); **Keep All** keeps every card
/// still to check, as the reply's own words promise one press does. A click on
/// a card to check opens To Check at it; its right-click keeps it or shows the
/// passage it stands on. What the cards stand at is read again whenever a card
/// is kept or skipped anywhere (`memoryCardRevision`).
struct ReviewChatSavedCardsView: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    @Environment(\.colorScheme) private var colorScheme

    let saved: ChatSavedCards

    /// The cards as storage read them, in the call's order; nil until read.
    @State private var cards: [ChatSavedCard]?
    @State private var readFailed = false
    @State private var page: Int
    @State private var isKeeping = false
    @State private var isHovered = false

    private static let maxWidth: CGFloat = 560

    /// Opened again, the deck shows the cards it last read, on the card it
    /// was left at (`ChatSavedCardsMemory`), while a fresh read lands.
    init(saved: ChatSavedCards) {
        self.saved = saved
        _cards = State(initialValue: ChatSavedCardsMemory.cards["\(saved.destination)"])
        _page = State(initialValue: ChatSavedCardsMemory.pages["\(saved.destination)"] ?? 0)
    }

    private var reloadKey: String { "\(saved.destination)#\(vm.memoryCardRevision)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let cards, !cards.isEmpty {
                let shown = min(page, cards.count - 1)
                deck(cards, page: shown)
                if cards.contains(where: { $0.toCheck != nil }) {
                    footer(cards, page: shown)
                }
            } else if cards != nil || readFailed {
                Text(readFailed ? "These cards could not be read." : "These cards are not on this Mac right now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 96)
            }
        }
        .padding(14)
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .textSelection(.disabled)
        .task(id: reloadKey) { await load() }
        .onChange(of: page) { _, page in
            ChatSavedCardsMemory.pages["\(saved.destination)"] = page
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.savedCards")
    }

    // MARK: The header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(cards, saved: saved))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(saved.notSavedCount > 0
                              ? "A card whose quote the source does not print word for word is not saved."
                              : "")
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if let cards, cards.count > 1 {
                pager(count: cards.count, page: min(page, cards.count - 1))
            }
        }
    }

    /// "6 cards to check" while every card waits, "6 cards kept" once all are
    /// kept, else the cards and how they stand: "6 cards · 4 to check · 2
    /// kept". Before the first read, the words the reply was stored with.
    static func title(_ cards: [ChatSavedCard]?, saved: ChatSavedCards) -> String {
        guard let cards, !cards.isEmpty else { return saved.label }
        func plural(_ count: Int) -> String { count == 1 ? "1 card" : "\(count) cards" }
        var toCheck = 0, kept = 0, skipped = 0, notOffered = 0
        for card in cards {
            switch card.standing {
            case .toCheck: toCheck += 1
            case .kept: kept += 1
            case .skipped: skipped += 1
            case .notOffered: notOffered += 1
            }
        }
        let parts = [
            (toCheck, "to check"), (kept, "kept"), (skipped, "skipped"), (notOffered, "no longer offered"),
        ].filter { $0.0 > 0 }
        if parts.count == 1, let only = parts.first { return "\(plural(only.0)) \(only.1)" }
        return ([plural(cards.count)] + parts.map { "\($0.0) \($0.1)" }).joined(separator: " · ")
    }

    /// The source the cards stand on, and how many the call sent that were not
    /// saved.
    private var subtitle: String? {
        Self.subtitle(saved, articlesById: vm.articlesById, canonicalID: vm.canonicalSourceID)
    }

    static func subtitle(
        _ saved: ChatSavedCards,
        articlesById: [String: StudioArticle],
        canonicalID: (String) -> String
    ) -> String? {
        var parts: [String] = []
        if saved.sourceIDs.count == 1 {
            let title = articlesById[canonicalID(saved.sourceIDs[0])]?.title
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !title.isEmpty { parts.append(title) }
        } else if saved.sourceIDs.count > 1 {
            parts.append("From \(saved.sourceIDs.count) sources")
        }
        if saved.notSavedCount > 0 {
            parts.append("\(saved.notSavedCount) not saved")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func pager(count: Int, page: Int) -> some View {
        HStack(spacing: 2) {
            pageButton("chevron.left", help: "Previous card", step: -1)
                .disabled(page == 0)
            Text("\(page + 1) of \(count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 42)
            pageButton("chevron.right", help: "Next card", step: 1)
                .disabled(page >= count - 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Card \(page + 1) of \(count)")
    }

    private func pageButton(_ systemImage: String, help: String, step: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { page = max(0, page + step) }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, tint: .secondary))
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: The deck

    private func deck(_ cards: [ChatSavedCard], page: Int) -> some View {
        let card = cards[page]
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        // The cards still under this one, up to two, peek out below it.
        let under = min(2, cards.count - 1 - page)
        let opensToCheck = card.toCheck != nil
        return face(card)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardFill(shape))
            .overlay(shape.strokeBorder(Color.primary.opacity(isHovered && opensToCheck ? 0.2 : 0.1), lineWidth: 0.5))
            .background(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    ForEach(Array((0..<under).reversed()), id: \.self) { depth in
                        cardFill(shape)
                            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                            .padding(.horizontal, CGFloat(depth + 1) * 9)
                            .offset(y: CGFloat(depth + 1) * 5)
                    }
                }
            }
            .padding(.bottom, CGFloat(under) * 5)
            .contentShape(shape)
            .onHover { isHovered = $0 }
            .onTapGesture {
                if opensToCheck { open(card) }
            }
            .help(opensToCheck ? "Open in To Check" : "")
            .contextMenu { cardMenu(card) }
            .id(card.id)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(opensToCheck ? .isButton : [])
            .accessibilityIdentifier("chat.savedCards.card.\(card.id)")
    }

    private func cardFill(_ shape: RoundedRectangle) -> some View {
        shape
            .fill(Color(nsColor: .controlBackgroundColor))
            // In dark mode the control colour is the pane's own; a touch of
            // white lifts the card off it, as To Check does.
            .overlay(shape.fill(Color.white.opacity(colorScheme == .dark ? 0.045 : 0)))
            .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }

    private func face(_ card: ChatSavedCard) -> some View {
        let isSetAside: Bool = {
            switch card.standing {
            case .skipped, .notOffered: return true
            case .toCheck, .kept: return false
            }
        }()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                standing(card.standing)
            }
            .frame(minHeight: 16)
            .padding(.bottom, 8)
            Text(card.face.front.foldingMathSpans())
                .font(.system(size: 15, design: .serif))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if !card.face.frontImages.isEmpty {
                MemoryCardImageGrid(images: card.face.frontImages, animationStartsAtOnce: false)
                    .padding(.top, 10)
            }
            MemoryCardFold()
                .padding(.vertical, 10)
            Text(card.face.back.foldingMathSpans())
                .font(.system(size: 13))
                .foregroundStyle(Color.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            if !card.face.backImages.isEmpty {
                MemoryCardImageGrid(images: card.face.backImages, animationStartsAtOnce: false)
                    .padding(.top, 10)
            }
        }
        .opacity(isSetAside ? 0.5 : 1)
    }

    @ViewBuilder
    private func standing(_ standing: ChatSavedCard.Standing) -> some View {
        switch standing {
        case .toCheck:
            EmptyView()
        case .kept:
            Label("Kept", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .skipped:
            Label("Skipped", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .notOffered:
            Text("No longer offered")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Drafted more than 14 days ago, or the same card as one already gone through")
        }
    }

    @ViewBuilder
    private func cardMenu(_ card: ChatSavedCard) -> some View {
        if let entry = card.toCheck {
            Button("Open in To Check") { open(card) }
            Button("Keep") { keep([entry]) }
        }
        if let quote = card.quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty {
            Button("Show Passage") {
                Task { await vm.openLinkedSourceInReader(card.sourceID, passage: quote) }
            }
        }
    }

    // MARK: The actions

    private func footer(_ cards: [ChatSavedCard], page: Int) -> some View {
        let waiting = cards.compactMap(\.toCheck)
        // Check Cards opens at the card on top when it waits, else the first
        // that does.
        let target = cards[page].toCheck != nil ? cards[page] : cards.first { $0.toCheck != nil }
        return HStack(spacing: 12) {
            Spacer(minLength: 8)
            Button("Keep All") { keep(waiting) }
                .font(.callout)
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -5, tint: .accentColor))
                .disabled(isKeeping)
                .help(waiting.count == 1 ? "Keep the card still to check" : "Keep the \(waiting.count) cards still to check")
                .accessibilityIdentifier("chat.savedCards.keepAll")
            // The Space's dark pill, as every primary action outside a
            // sheet (docs/ui-design.md).
            SpaceDarkPillButton(title: "Check Cards", systemImage: nil, image: nil) {
                if let target { open(target) }
            }
            .help("Open To Check beside the chat, at this card")
            .accessibilityIdentifier("chat.savedCards.check")
        }
    }

    private func open(_ card: ChatSavedCard) {
        vm.openChatSavedCard(
            sourceID: card.sourceID,
            cardID: card.toCheck?.cardID,
            in: windowState ?? vm.activeWindowState
        )
    }

    /// Keeps the cards as drafted, as To Check's Keep All does; the read that
    /// the kept cards set off redraws them kept.
    private func keep(_ entries: [MemoryCardToCheck]) {
        guard !entries.isEmpty, !isKeeping else { return }
        isKeeping = true
        Task {
            await vm.triageCardsToCheck(MemoryCardTriage.keepAll(entries))
            isKeeping = false
        }
    }

    private func load() async {
        guard let read = await vm.chatSavedCards(saved) else {
            readFailed = cards == nil
            return
        }
        readFailed = false
        cards = read
        ChatSavedCardsMemory.cards["\(saved.destination)"] = read
        if page >= read.count { page = max(0, read.count - 1) }
    }
}

/// What `ReviewChatSavedCardsView` last showed, per set of saved cards, for
/// the next time the deck opens. None of it is stored or synced, and a read
/// replaces it as soon as it lands.
@MainActor
enum ChatSavedCardsMemory {
    static var cards: [String: [ChatSavedCard]] = [:]
    static var pages: [String: Int] = [:]
}

// MARK: - Find in chat

/// Find in the open chat (⌘F, then Return or ⌘G for the next match and ⇧Return
/// or ⌘⇧G for the previous), as Codex finds in a thread. A match is a turn of
/// the transcript (`ReviewChatTranscriptBlock`) whose words hold the query;
/// the transcript scrolls it to the middle and marks it. The first search
/// lands on the newest match, where the learner already is.
@MainActor
@Observable
final class ChatFind {
    var isVisible = false
    var query = ""
    private(set) var matchIDs: [UUID] = []
    private(set) var currentIndex: Int?
    private(set) var searchedQuery = ""
    private(set) var focusRevision = 0
    /// Bumped by every step; the transcript scrolls to `currentMatchID` on it.
    private(set) var scrollRevision = 0

    var currentMatchID: UUID? {
        guard let currentIndex, matchIDs.indices.contains(currentIndex) else { return nil }
        return matchIDs[currentIndex]
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "2 of 7", "No matches", or nothing before the first search of this query.
    var status: String {
        guard !searchedQuery.isEmpty, searchedQuery == trimmedQuery else { return "" }
        guard let currentIndex, !matchIDs.isEmpty else { return "No matches" }
        return "\(currentIndex + 1) of \(matchIDs.count)"
    }

    func show() {
        isVisible = true
        focusRevision += 1
    }

    func close() {
        isVisible = false
        query = ""
        matchIDs = []
        currentIndex = nil
        searchedQuery = ""
    }

    /// The next match after the current one (or the one before it), read
    /// afresh from `blocks` so turns that arrived since are found too. A new
    /// query starts from the newest match.
    func step(in blocks: [ReviewChatTranscriptBlock], backwards: Bool = false) {
        let query = trimmedQuery
        defer { scrollRevision += 1 }
        guard !query.isEmpty else {
            matchIDs = []
            currentIndex = nil
            searchedQuery = ""
            return
        }
        let fresh = Self.matchingBlockIDs(query, in: blocks)
        let previous = query == searchedQuery ? currentMatchID : nil
        searchedQuery = query
        matchIDs = fresh
        guard !fresh.isEmpty else {
            currentIndex = nil
            return
        }
        if let previous, let at = fresh.firstIndex(of: previous) {
            currentIndex = backwards ? (at - 1 + fresh.count) % fresh.count : (at + 1) % fresh.count
        } else {
            currentIndex = fresh.count - 1
        }
    }

    /// The turns whose words, the learner's or the reply's, hold `query`,
    /// ignoring case and accents, oldest first. Tool rows are not searched.
    static func matchingBlockIDs(_ query: String, in blocks: [ReviewChatTranscriptBlock]) -> [UUID] {
        blocks.filter { block in
            ([block.userMessage].compactMap { $0 } + block.answerMessages).contains { message in
                guard message.toolActivity == nil, message.role != .tool,
                      let text = ReviewSessionManager.displayableMessageContent(role: message.role, content: message.content)
                else { return false }
                return AttachedImageReference.split(text).text.localizedStandardContains(query)
            }
        }
        .map(\.id)
    }
}

/// The find bar over the top of the transcript, quiet like the Reader's: the
/// field, where it is ("2 of 7"), previous and next, and ×. Escape closes it.
struct ChatFindBar: View {
    @Bindable var find: ChatFind
    /// The transcript's turns, read when a search runs.
    let blocks: () -> [ReviewChatTranscriptBlock]
    @FocusState private var isFocused: Bool

    private var hasQuery: Bool {
        !find.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.secondary)
            TextField("Find in chat", text: $find.query)
                .textFieldStyle(.plain)
                .zoomedSystemFont(size: 12)
                .focused($isFocused)
                .onSubmit { step(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .accessibilityIdentifier("mac.chatFind.field")
            if !find.status.isEmpty {
                Text(find.status)
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            button("chevron.up", help: "Previous match (⌘⇧G)") { step(backwards: true) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!hasQuery)
            button("chevron.down", help: "Next match (⌘G)") { step(backwards: false) }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!hasQuery)
            button("xmark", help: "Close find") { find.close() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .frame(maxWidth: 420)
        .onAppear { isFocused = true }
        .onChange(of: find.focusRevision) { _, _ in isFocused = true }
        .onExitCommand { find.close() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac.chatFind")
    }

    private func step(backwards: Bool) {
        find.step(in: blocks(), backwards: backwards)
    }

    private func button(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .zoomedSystemFont(size: 10, weight: .semibold)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 5))
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Jump to latest

/// The arrow over the foot of the transcript once it is scrolled up from the
/// newest turn, as Codex's: a click goes back down.
enum ChatJumpToLatest {
    /// How far above the end, beyond the empty band kept under the last row,
    /// the view must be before the arrow shows.
    static let threshold: CGFloat = 120

    static func isScrolledUp(offsetY: CGFloat, visibleHeight: CGFloat, contentHeight: CGFloat, bottomReserve: CGFloat) -> Bool {
        contentHeight - (offsetY + visibleHeight) > bottomReserve + threshold
    }
}

/// Reports whether the scroll view it modifies is scrolled up from its end
/// (`ChatJumpToLatest`). macOS 15 reads scroll geometry; on 14 it reports
/// nothing and the arrow never shows.
struct ChatScrolledUpReader: ViewModifier {
    let bottomReserve: CGFloat
    @Binding var isScrolledUp: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                ChatJumpToLatest.isScrolledUp(
                    offsetY: geometry.contentOffset.y,
                    visibleHeight: geometry.containerSize.height,
                    contentHeight: geometry.contentSize.height,
                    bottomReserve: bottomReserve
                )
            } action: { _, scrolledUp in
                if isScrolledUp != scrolledUp { isScrolledUp = scrolledUp }
            }
        } else {
            content
        }
    }
}

struct ChatJumpToLatestButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .zoomedSystemFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.10)))
                .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Jump to latest")
        .accessibilityLabel("Jump to latest")
        .accessibilityIdentifier("mac.chatJumpToLatest")
    }
}

/// The turn Find in chat is on: a faint wash behind it.
struct ChatFindMatchMark: ViewModifier {
    let isMatch: Bool

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(isMatch ? 0.09 : 0))
                .padding(-6)
                .allowsHitTesting(false)
        )
    }
}
