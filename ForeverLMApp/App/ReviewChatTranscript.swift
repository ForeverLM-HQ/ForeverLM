// The chat transcript model and the rows that lay it out: entries, blocks, sections, the aside lane, open questions and answer blocks.

import SwiftUI

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
