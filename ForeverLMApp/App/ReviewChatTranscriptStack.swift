// The rows of one chat in a view of their own.
import SwiftUI
import Combine
import AppKit

/// The rows of one chat, in a view of their own so that a streamed token
/// re-evaluates this and nothing else.
///
/// `ReviewSessionManager` is `@Observable`, and Observation tracks a
/// dependency per property read: any body that touches `chatMessages` — even
/// only to ask how many there are — is re-evaluated by every content publish of
/// the streaming answer, a dozen times a second. The panel around this
/// transcript is thousands of lines of header, context chips and composer, and
/// sampling a scroll during a reply put that body, with the regrouping of every
/// message inside it, among the main thread's top costs. So the panel reads the
/// manager's coarse `chatMessageCount`, and the one body that reads the
/// messages is this one. The row builder and error view come from the panel as
/// closures, so the rows themselves are unchanged.
struct ReviewChatTranscriptStack<Row: View, ErrorView: View>: View {
    let manager: ReviewSessionManager
    let proxy: ScrollViewProxy
    let isTurnInFlight: Bool
    /// What a walk is doing while it has no step to show yet, if anything:
    /// shown as the working line, so pressing Walk Through or Next is not a
    /// silent wait.
    let walkthroughPreparation: String?
    let turnStartedAt: Date?
    let errorMessage: String?
    /// Empty space kept under the last row; see the panel's `transcriptBottomReserve`.
    let bottomReserve: CGFloat
    /// A memory review drawn as cards: the transcript holds the one card's
    /// exchange (`MemoryReviewCardFold`). False for every other chat.
    let showsMemoryCards: Bool
    /// The deck dealt a topic or a source a card: the rows on it carry what
    /// the card is about and its foot, and the wait for a grade reads
    /// "Reading your answer".
    let showsTopicCards: Bool
    /// The answer field stays under the steers once the card is graded: a
    /// source-by-source tutor can ask its next probe in the graded reply.
    let answersAfterGrade: Bool
    /// The card's answer field: an answer, or an honest miss.
    let sendMemoryAnswer: (String) -> Void
    let dontRememberMemoryAnswer: () -> Void
    /// The card chosen with Back and Next; nil for the newest.
    let memoryCardIndex: Int?
    /// The height the rows fill from the top: a card's viewport, so the card
    /// stands full height with its question at the top. Zero for every other
    /// chat.
    let minContentHeight: CGFloat
    let columnMaxWidth: CGFloat
    /// Width of one bubble; the queued rows draw at the same width as the sent ones.
    let messageMaxWidth: CGFloat
    /// A name in the sources-added row: that source opens in the reader.
    let openContextSource: (String) -> Void
    /// Undo on the sources-added row: those sources come back out.
    let undoContextAddition: ([String]) -> Void
    /// The ways on from a side question, drawn by the lane under the newest
    /// aside: back to the tutor's open question (answer it, or let it go), or
    /// on with the side question (a follow-up here, or a chat of its own).
    let answerOpenQuestion: () -> Void
    let skipOpenQuestion: () -> Void
    let followUpSideQuestion: () -> Void
    let openSideQuestionInNewChat: () -> Void
    /// More details pressed on a reply whose lane already exists: that lane
    /// opens and the transcript scrolls to it.
    let laneExpansionRequest: ReviewChatLaneExpansionRequest?
    /// The turn Find in chat is on, marked in the transcript.
    let findMatchID: UUID?
    /// Which source each `[n]` names, and whose card has been listed already.
    /// Written here rather than read here: the rows belong to the panel, but
    /// this is the view that already watches the messages, and rebuilding the
    /// ledger up there would make the whole panel re-evaluate per streamed
    /// token. See `ChatCitationLedger`.
    @Binding var citationContexts: [UUID: ChatCitationLedger.MessageContext]
    /// Builds one block; the context says whether it is the block the running
    /// turn is writing into, whether it is the newest block (where a memory
    /// review's steer chips sit once the reply has landed), whether it sits in
    /// a side question's lane, and which More details lane already hangs
    /// under it.
    let row: (ReviewChatTranscriptBlock, ReviewChatTranscriptRowContext) -> Row
    let errorText: (String) -> ErrorView

    var body: some View {
        // Grouped once per render: the last block is the one the running turn is
        // still writing into, and both the ForEach and the live flag need it.
        // A playing walk shows the conversation of the card on screen; the
        // card itself is drawn above the chat.
        // A memory review drawn as cards shows the one card's exchange; an
        // older card is a record, so nothing that belongs to the turn being
        // answered — the steer chips, the working line, the ways back from a
        // side question — is drawn on it.
        let walkMessages = WalkthroughTranscriptFold.cardThread(manager.chatMessages, playback: manager.walkthroughPlayback)
        let card = showsMemoryCards
            ? MemoryReviewCardFold.thread(walkMessages, selected: memoryCardIndex, byTopic: showsTopicCards)
            : (messages: walkMessages, isNewest: true, sourceID: nil)
        let messages = card.messages
        let showsNewest = card.isNewest
        let blocks = ReviewChatTranscriptBlock.grouping(messages)
        let sections = ReviewChatTranscriptSection.grouping(blocks)
        let liveBlockID = isTurnInFlight && showsNewest ? blocks.last?.id : nil
        // Newest by time: a lane about an older reply is drawn up under it.
        let newestSectionID = showsNewest ? ReviewChatTranscriptSection.newest(in: sections, blocks: blocks)?.id : nil
        // A topic card: what its foot carries, and its last block outside any
        // side question's lane, where the ledger hangs.
        let subjectID = card.sourceID ?? (showsTopicCards && card.isNewest ? manager.memoryReviewCurrentSourceID : nil)
        let topicFoot = showsTopicCards ? topicCardFoot(card, subjectID: subjectID) : .none
        let lastMainBlockID = showsTopicCards
            ? sections.last(where: { !$0.isSideQuestion })?.blocks.last?.id
            : nil
        let firstMainBlockID = showsTopicCards
            ? sections.first(where: { !$0.isSideQuestion })?.blocks.first?.id
            : nil
        // Each reply's More details lane, so its footer reopens the lane
        // instead of asking for a second one.
        let moreDetailsLanes: [UUID: UUID] = sections.reduce(into: [:]) { lanes, section in
            guard section.isSideQuestion, section.isMoreDetails, let aboutID = section.aboutBlockID else { return }
            if lanes[aboutID] == nil { lanes[aboutID] = section.id }
        }
        let context: (ReviewChatTranscriptBlock, ReviewChatTranscriptSection) -> ReviewChatTranscriptRowContext = { block, section in
            ReviewChatTranscriptRowContext(
                isLive: block.id == liveBlockID,
                isLatest: showsNewest && block.id == blocks.last?.id,
                isInsideAside: section.isSideQuestion,
                moreDetailsLaneID: moreDetailsLanes[block.id],
                isLastOnCard: lastMainBlockID != nil && block.id == lastMainBlockID,
                isFirstOnCard: firstMainBlockID != nil && block.id == firstMainBlockID,
                memoryCardTopicID: showsTopicCards ? subjectID : nil,
                memoryCardFoot: topicFoot
            )
        }
        // One card's exchange: few enough rows to build at once, so no row is
        // torn down and rebuilt under the scroll.
        VStack(alignment: .leading, spacing: 14) {
            // A finished review's graded summary: a quiet caption, the
            // grader's words, with no box around them.
            if showsNewest, let summary = manager.completedSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: messageMaxWidth, alignment: .leading)
            }

            // A side question and its replies share one lane, which folds once
            // the quiz has moved on. Every block keeps its own id: the scroll
            // anchors below are message ids, wherever the message sits.
            ForEach(sections) { section in
                if section.isSideQuestion {
                    ReviewChatAsideLane(
                        section: section,
                        isLatest: section.id == newestSectionID,
                        isLive: section.blocks.contains { $0.id == liveBlockID },
                        expandRequest: laneExpansionRequest?.laneID == section.id ? laneExpansionRequest?.token : nil,
                        answerOpenQuestion: answerOpenQuestion,
                        skipOpenQuestion: skipOpenQuestion,
                        followUpSideQuestion: followUpSideQuestion,
                        openSideQuestionInNewChat: openSideQuestionInNewChat
                    ) { block in
                        row(block, context(block, section))
                            .modifier(ChatFindMatchMark(isMatch: block.id == findMatchID))
                            .id(block.id)
                    }
                } else {
                    ForEach(section.blocks) { block in
                        row(block, context(block, section))
                            .modifier(ChatFindMatchMark(isMatch: block.id == findMatchID))
                            .id(block.id)
                    }
                }
            }

            // Sources the learner brought in since their last message. The row
            // stands here until that message is sent, then moves up above it,
            // written beside it (`ChatContextAdditions`).
            if showsNewest {
                if !manager.pendingContextAdditions.isEmpty {
                    ReviewChatContextAdditionsRow(
                        added: manager.pendingContextAdditions,
                        maxContentWidth: messageMaxWidth,
                        openSource: openContextSource,
                        undo: manager.pendingContextAdditions.contains { manager.linkedSourceIDs.contains($0.id) }
                            ? { undoContextAddition(manager.pendingContextAdditions.map(\.id)) } : nil
                    )
                }

                activityStatus(topicFoot: topicFoot)

                // The answer field, right under the question it answers.
                if showsTopicCards, topicFoot == .answer || (answersAfterGrade && topicFoot == .steer) {
                    MemoryReviewTopicAnswerField(
                        isBusy: isTurnInFlight,
                        send: sendMemoryAnswer,
                        dontRemember: dontRememberMemoryAnswer
                    )
                }

                if let errorMessage {
                    errorText(errorMessage)
                }
            }

            // Never let the transcript end flush against the composer.
            Color.clear.frame(height: bottomReserve)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, showsMemoryCards ? MemoryReviewCardSurface.contentInset : 14)
        .padding(.top, showsMemoryCards ? 10 : 12)
        // The stack's spacing already stands over the empty reserve row.
        .padding(.bottom, showsMemoryCards ? 6 : 12)
        .frame(minHeight: minContentHeight, alignment: .top)
        // The scroll view stays full-width (scrollbar at the panel edge,
        // drops land anywhere); only the content column is capped.
        .frame(maxWidth: columnMaxWidth)
        .frame(maxWidth: .infinity)
        // Which replies exist is what moves the ledger. A streaming reply's own
        // text cannot: nothing below it is written yet, and its context was
        // settled by the transcript it arrived into -- the whole cast so far,
        // since the ledger cannot know yet which of it the reply will cite.
        // The manager appends the reply and names it as streaming in one
        // step, so the id change always sees the streaming id already set.
        .onChange(of: manager.chatMessages.map(\.id), initial: true) { _, _ in
            citationContexts = ReviewChatCitationContexts.contexts(for: manager)
        }
        // Once it has finished, the reply cites only what it cites. Left open,
        // its context narrowed at the next message added, whenever that came,
        // and the reply drew its text again under the learner's selection.
        .onChange(of: manager.streamingMessageID) { _, _ in
            citationContexts = ReviewChatCitationContexts.contexts(for: manager)
        }
        .onChange(of: latestUserMessageID) { _, _ in
            // Scroll only when the user submits a message (or a session loads
            // its history). A fresh send leaves the user's message as the last
            // visible row: center it so the reply streams into the lower half
            // of the viewport. Loading history lands at the bottom instead.
            guard let message = latestVisibleChatMessage else { return }
            // A card is dealt with the answer at its top and the reply
            // growing under it, so a sent answer that has pushed the card
            // past its height is read from there.
            let anchor: UnitPoint = message.role == .user ? (showsMemoryCards ? .top : .center) : .bottom
            // Defer one tick so the reserved streaming space below the message
            // is laid out first; scrolling immediately clamps to the previous
            // content height and leaves the message pinned to the bottom.
            let id = message.id
            DispatchQueue.main.async {
                scrollToMessage(id, anchor: anchor)
            }
        }
        .onChange(of: laneExpansionRequest) { _, request in
            // More details pressed again: the lane opens (its own onChange),
            // and the transcript brings its heading into view. Deferred a tick
            // so the lane has laid its rows out before the scroll measures it.
            guard let request else { return }
            DispatchQueue.main.async {
                scrollToMessage(request.laneID, anchor: .top)
            }
        }
        .onChange(of: memoryCardIndex) { _, selected in
            // Back or Next through the deck: an older card opens at its top,
            // the newest at its end, where the question waits.
            guard showsMemoryCards else { return }
            let thread = MemoryReviewCardFold.thread(manager.chatMessages, selected: selected, byTopic: showsTopicCards)
            let cardBlocks = ReviewChatTranscriptBlock.grouping(thread.messages)
            guard let target = thread.isNewest ? cardBlocks.last : cardBlocks.first else { return }
            DispatchQueue.main.async {
                proxy.scrollTo(target.id, anchor: thread.isNewest ? .bottom : .top)
            }
        }
        .onChange(of: manager.walkthroughStepScrollRequest) { _, request in
            // A move in the walk: the chat under the card shows the end of
            // that card's conversation. Deferred a tick so the new card's
            // thread is laid out first.
            guard request != nil else { return }
            let thread = WalkthroughTranscriptFold.cardThread(manager.chatMessages, playback: manager.walkthroughPlayback)
            guard let last = ReviewChatTranscriptBlock.grouping(thread).last else { return }
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    /// What the running turn is doing, named for the learner.
    private var workingPhase: ReviewChatWorkingIndicator.Phase {
        .current(manager: manager, walkthroughPreparation: walkthroughPreparation)
    }

    /// What the newest topic card's foot carries: the answer field, the wait
    /// for a grade, or the two steers (`MemoryReviewTopicCardFold.foot`).
    private func topicCardFoot(
        _ card: (messages: [ReviewSessionManager.Message], isNewest: Bool, sourceID: String?),
        subjectID: String?
    ) -> MemoryReviewTopicCardFoot {
        let graded = subjectID.map { manager.memoryReviewStatusBySource[$0] != nil } ?? false
        return MemoryReviewTopicCardFold.foot(
            card.messages,
            isNewest: card.isNewest,
            isGraded: graded,
            isBusy: isTurnInFlight
        )
    }


    @ViewBuilder
    private func activityStatus(topicFoot: MemoryReviewTopicCardFoot) -> some View {
        if topicFoot == .reading, workingPhase != .writing {
            // A topic card grading an answer: one breathing line, and no
            // Thinking disclosure (docs/memory-design.md, "Review by topic").
            MemoryReviewReadingAnswerLine()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        } else if isTurnInFlight || walkthroughPreparation != nil {
            // The mark rather than a spinner: this is the wait for a reply, and a
            // system spinner here reads as the machine being busy where the mark
            // reads as the product thinking. Tool rows keep their spinners.
            ReviewChatWorkingIndicator(
                phase: workingPhase,
                detail: walkthroughPreparation ?? manager.sendPreparationDetail,
                startedAt: ReviewChatWorkingIndicator.Phase.clockStart(manager: manager, turnStartedAt: turnStartedAt, phase: workingPhase),
                // A topic card shows no thinking; the conversation keeps it.
                reasoning: showsTopicCards ? "" : manager.streamingReasoning
            )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)

            // The wait for a live plan is the one moment the offer to move it
            // to the morning is obviously relevant. The view decides whether
            // it still stands and keeps its confirmation up for the rest of
            // the turn once taken, so it lives for the whole turn.
            MemoryReviewPreparationOffer(
                isPlanning: workingPhase == .planning,
                startedAt: turnStartedAt ?? Date()
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            // A free model that has said nothing for a while: the offer to
            // ask a paid one instead, until Don't Ask Again.
            SlowFreeModelOffer(
                turnModel: manager.turnModel,
                isWaitingForText: workingPhase == .thinking,
                askAgain: { manager.restartTurnOnSelectedModel() }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The newest user-authored message. Used purely as an onChange trigger so the
    /// transcript scrolls once per submitted message instead of following every
    /// streamed token or appended tool row.
    private var latestUserMessageID: UUID? {
        manager.chatMessages.last(where: { $0.role == .user })?.id
    }

    private var latestVisibleChatMessage: ReviewSessionManager.Message? {
        manager.chatMessages.last(where: isVisibleChatMessage)
    }

    private func isVisibleChatMessage(_ message: ReviewSessionManager.Message) -> Bool {
        // Tool rows carry no text content but are rendered, so they must count as
        // visible or the transcript would scroll past the very activity it is showing.
        if message.toolActivity != nil { return true }
        return ReviewSessionManager.displayableMessageContent(role: message.role, content: message.content)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
    }

    private func scrollToMessage(_ id: UUID, anchor: UnitPoint) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(id, anchor: anchor)
        }
    }
}
