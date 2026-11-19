import SwiftUI

/// The composer's recording state: a level meter that spans the control row
/// rather than a badge tucked inside the record button.
///
/// Drawn as discrete rounded columns mirrored about a centre line — the shape
/// a voice recorder draws. Bars read as "level meter" instantly at composer
/// height, where a filled envelope would smear into a blob. New
/// samples enter at the right and scroll left, with a dotted rule marking the
/// stretch of the row the wave hasn't travelled into yet.
struct ReviewDictationWaveform: View {
    /// Observed here and nowhere above, so the 30Hz samples redraw this row
    /// and not the pane that holds it.
    @ObservedObject var meter: DictationMeter
    private var levels: [Double] { meter.levels }
    private var seconds: Int { meter.seconds }
    /// Stop, transcribe and send — the default, and what Return does too.
    let onStop: () -> Void
    /// Stop and transcribe, but leave the words in the draft to be edited or
    /// sent by hand. The escape hatch from the default's auto-send.
    let onKeepInDraft: () -> Void

    /// Floor matching the service's own clamp, so a silent mic settles into an
    /// even row of dots rather than collapsing onto the baseline.
    private static let silentLevel = DictationMeter.silentLevel

    /// Whole points, so every bar edge lands on a device pixel. A 2.5pt bar
    /// on a 4.5pt pitch put half the edges between pixels and the row read
    /// as fuzzy.
    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 2
    private let meterHeight: CGFloat = 20
    /// Gap between the end of the dotted rule and the oldest bar.
    private let leaderGap: CGFloat = 7

    @Environment(\.displayScale) private var displayScale

    private var pitch: CGFloat { barWidth + barSpacing }

    /// Rounds a coordinate to the nearest device pixel.
    private func snapped(_ value: CGFloat) -> CGFloat {
        let scale = max(displayScale, 1)
        return (value * scale).rounded() / scale
    }

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

        let midY = snapped(size.height / 2)
        let maxBarHeight = size.height
        let barsWidth = CGFloat(samples.count) * pitch - barSpacing
        // The Canvas can be a fractional width; snapping the origin keeps
        // every bar after it on the pixel grid too.
        let originX = snapped(size.width - barsWidth)

        drawLeader(&context, upTo: originX - leaderGap, midY: midY)

        // The oldest bars fade out, so the meter reads as travelling leftwards
        // rather than merely wobbling in place.
        let fadeCount = max(Double(samples.count) * 0.25, 1)

        for (index, level) in samples.enumerated() {
            let clamped = min(max(level, Self.silentLevel), 1)
            let normalized = (clamped - Self.silentLevel) / (1 - Self.silentLevel)
            // Even pixel count, so the bar centres on midY without a half pixel.
            let pixel = 1 / max(displayScale, 1)
            let rawHeight = max(barWidth, CGFloat(normalized) * maxBarHeight)
            let height = max(barWidth, (rawHeight / (2 * pixel)).rounded() * 2 * pixel)
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
    /// under the chat's title would show the same words a second time. Its
    /// click into the Reader lives on this quote.
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

