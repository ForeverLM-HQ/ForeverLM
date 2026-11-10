// The controls and small rows around a chat message: reply menu, editing, save to note, suggested questions, queued messages, context additions and video moments.

import SwiftUI

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

struct ReviewChatFooterButton: View {
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

struct ReviewChatBubbleChrome: ViewModifier {
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
