// The web page host that draws the chat transcript.
import SwiftUI
import Combine
import AppKit

/// The one-page transcript's view of the chat: the messages as page blocks,
/// the tail, where to scroll, and the offers that stay native under it.
struct ReviewChatTranscriptPageHost: View {
    let manager: ReviewSessionManager
    let isTurnInFlight: Bool
    let walkthroughPreparation: String?
    let turnStartedAt: Date?
    let errorMessage: String?
    let bottomReserve: CGFloat
    let layout: ChatTranscriptPage.Layout
    let findMatchID: UUID?
    let findScrollRevision: Int
    let armedSideQuestionBlockID: UUID?
    let editableMessageID: UUID?
    /// More details pressed on a reply whose lane already exists.
    let laneExpansionRequest: ReviewChatLaneExpansionRequest?
    @Binding var citationContexts: [UUID: ChatCitationLedger.MessageContext]
    let suggestedQuestions: (ReviewChatTranscriptBlock, ReviewChatTranscriptRowContext) -> [String]?
    let lookups: ChatTranscriptLookups
    let resolvers: ChatTranscriptPage.Resolvers
    let onAction: (ChatTranscriptPage.Action) -> Void

    @Environment(\.chatReplySideChat) private var sideChat
    @Environment(StudioViewModel.self) private var vm
    @State private var scrollRequest: ChatTranscriptPage.ScrollRequest?
    /// How each saved-cards row's cards stand now ("1 card kept"), read again
    /// whenever a card is kept or skipped anywhere (`memoryCardRevision`). A
    /// row not read yet keeps the words its reply was stored with.
    @State private var savedCardTitles: [String: String] = [:]

    /// The saved-cards rows in the chat, in order.
    private var savedCardsInChat: [ChatSavedCards] {
        ReviewChatTranscriptBlock.grouping(messages).flatMap { block in
            ReviewChatAnswerLayout.items(block.answerMessages).compactMap { item -> ChatSavedCards? in
                if case .entry(let entry) = item { return entry.savedCards }
                return nil
            }
        }
    }

    private func refreshSavedCardTitles() async {
        for saved in savedCardsInChat {
            guard let read = await vm.chatSavedCards(saved), !read.isEmpty else { continue }
            savedCardTitles["\(saved.destination)"] = ReviewChatSavedCardsView.title(read, saved: saved)
        }
    }

    private var workingPhase: ReviewChatWorkingIndicator.Phase {
        .current(manager: manager, walkthroughPreparation: walkthroughPreparation)
    }

    /// While a walk plays its step turns are the card above the chat, and the
    /// transcript holds the card's own conversation (`WalkthroughTranscriptFold`).
    private var messages: [ReviewSessionManager.Message] {
        WalkthroughTranscriptFold.cardThread(manager.chatMessages, playback: manager.walkthroughPlayback)
    }

    private static func laneID(_ section: ReviewChatTranscriptSection) -> String {
        "lane:\(section.id.uuidString)"
    }

    private var state: ChatTranscriptPage.State {
        let blocks = ReviewChatTranscriptBlock.grouping(messages)
        let sections = ReviewChatTranscriptSection.grouping(blocks)
        let liveBlockID = isTurnInFlight ? blocks.last?.id : nil
        let latestBlockID = blocks.last?.id
        let newestSectionID = ReviewChatTranscriptSection.newest(in: sections, blocks: blocks)?.id
        var pageBlocks: [ChatTranscriptPage.Block] = []
        func context(_ block: ReviewChatTranscriptBlock, insideAside: Bool) -> ReviewChatTranscriptRowContext {
            ReviewChatTranscriptRowContext(
                isLive: block.id == liveBlockID,
                isLatest: block.id == latestBlockID,
                isInsideAside: insideAside,
                moreDetailsLaneID: nil
            )
        }
        for section in sections {
            guard section.isSideQuestion else {
                for block in section.blocks {
                    pageBlocks.append(pageBlock(block, context: context(block, insideAside: false), lane: nil))
                }
                continue
            }
            let lane = Self.laneID(section)
            let isNewest = section.id == newestSectionID
            let isLaneLive = section.blocks.contains { $0.id == liveBlockID }
            let firstLine = section.sideQuestionMessage.map {
                ReviewSessionManager.displayableMessageContent(role: .user, content: $0.content) ?? $0.content
            }?.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let replies = section.blocks.dropFirst().count
            pageBlocks.append(ChatTranscriptPage.Block(
                id: lane,
                kind: .laneHead,
                laneTitle: section.isMoreDetails ? ChatSideQuestion.moreDetailsQuestion : "Side question",
                laneLine: section.isMoreDetails ? nil : ChatSideQuestion.plainLine(firstLine ?? ""),
                laneReplies: replies > 1 ? replies : nil,
                laneWaits: (isNewest || isLaneLive) && section.openQuestion != nil ? true : nil,
                laneOpen: isNewest || isLaneLive,
                laneMoreDetails: section.isMoreDetails ? true : nil
            ))
            for block in section.blocks {
                // A More details press is the app's, not the learner's words:
                // the heading is their line.
                if let user = block.userMessage, user.isMoreDetailsRequest { continue }
                pageBlocks.append(pageBlock(block, context: context(block, insideAside: true), lane: lane))
            }
            // The ways on, under the newest lane once its reply has landed,
            // outside the fold so the way back is never hidden.
            if isNewest, !isLaneLive, section.openQuestion != nil || !section.isMoreDetails {
                pageBlocks.append(ChatTranscriptPage.Block(
                    id: "lane-card:\(section.id.uuidString)",
                    kind: .laneCard,
                    openQuestion: section.openQuestion,
                    followUp: section.isMoreDetails ? nil : true,
                    newChat: section.isMoreDetails ? nil : true
                ))
            }
        }

        var tail = ChatTranscriptPage.Tail()
        tail.pending = ChatTranscriptPage.added(manager.pendingContextAdditions, inChat: Set(manager.linkedSourceIDs))
        if let last = blocks.last, last.userMessage == nil {
            let insideAside = sections.contains { $0.isSideQuestion && $0.blocks.contains { $0.id == last.id } }
            let lastContext = context(last, insideAside: insideAside)
            if !lastContext.isLive, manager.offersMemoryReviewSteer, !manager.isGenerating, !manager.isSearching {
                tail.steer = true
            } else {
                tail.suggested = suggestedQuestions(last, lastContext)
            }
        }
        if isTurnInFlight || walkthroughPreparation != nil {
            tail.working = .init(
                label: ReviewChatWorkingIndicator.label(
                    for: workingPhase,
                    detail: walkthroughPreparation ?? manager.sendPreparationDetail
                ),
                startedAt: ReviewChatWorkingIndicator.Phase.clockStart(
                    manager: manager, turnStartedAt: turnStartedAt, phase: workingPhase
                ).timeIntervalSince1970 * 1000
            )
        }
        tail.error = errorMessage
        return ChatTranscriptPage.State(
            blocks: pageBlocks,
            summary: manager.completedSummary,
            tail: tail == ChatTranscriptPage.Tail() ? nil : tail,
            reserve: bottomReserve,
            layout: layout
        )
    }

    /// One block of the transcript as the page draws it.
    private func pageBlock(
        _ block: ReviewChatTranscriptBlock,
        context: ReviewChatTranscriptRowContext,
        lane: String?
    ) -> ChatTranscriptPage.Block {
        if let user = block.userMessage {
            return ChatTranscriptPage.userBlock(
                block,
                message: user,
                canEdit: user.id == editableMessageID,
                isFindMatch: block.id == findMatchID,
                lane: lane,
                inChat: Set(manager.linkedSourceIDs)
            )
        }
        if let marker = block.answerMessages.first?.walkthroughStep {
            // Only a walk that is not playing leaves a step turn in the
            // transcript (`WalkthroughTranscriptFold.resting`): its cards
            // come back from here.
            return ChatTranscriptPage.Block(
                id: block.id.uuidString,
                kind: .answer,
                lane: lane,
                parts: [ChatTranscriptPage.Part(
                    kind: .resume,
                    id: block.id.uuidString,
                    title: "Walkthrough of \(lookups.walkTitle(marker.sourceID))",
                    subtitle: "Resume picks the cards up where you left them",
                    sourceID: marker.sourceID
                )]
            )
        }
        let parts: [ChatTranscriptPage.Part] = ReviewChatAnswerLayout.items(block.answerMessages).compactMap { item in
            switch item {
            case .work(let work):
                return ChatTranscriptPage.workPart(work, isLive: context.isLive, pageTitle: lookups.pageTitle)
            case .pages(let id, let pages):
                return ChatTranscriptPage.Part(
                    kind: .pages,
                    id: id.uuidString,
                    pages: ChatTranscriptPage.pageCards(pages, title: lookups.pageTitle)
                )
            case .entry(let entry):
                return entryPart(entry)
            }
        }
        return ChatTranscriptPage.Block(
            id: block.id.uuidString,
            kind: .answer,
            lane: lane,
            parts: parts,
            footer: context.isLive ? nil : ChatTranscriptPage.Footer(
                sideQuestion: .init(armed: armedSideQuestionBlockID == block.id, followUp: context.isInsideAside),
                skip: lookups.offersQuizSkip(context) ? true : nil,
                more: true
            ),
            isLatest: context.isLatest ? true : nil,
            isLive: context.isLive ? true : nil,
            isFindMatch: block.id == findMatchID ? true : nil
        )
    }

    /// A row that stands on its own in a reply: its prose, a review's turn to
    /// a source or topic, or the cards a call saved.
    private func entryPart(_ entry: ReviewChatTranscriptEntry) -> ChatTranscriptPage.Part? {
        if let message = entry.message {
            return ChatTranscriptPage.prosePart(message, citations: citationContexts[message.id] ?? .init())
        }
        if let turn = entry.sourceTurn {
            return ChatTranscriptPage.Part(
                kind: .turn,
                id: entry.id.uuidString,
                title: turn.title,
                subtitle: ["Now reviewing", lookups.reviewPosition(turn.id)].compactMap { $0 }.joined(separator: " · "),
                sourceID: turn.id
            )
        }
        if entry.activities.count == 1, let activity = entry.activities.first,
           activity.kind == .sourceTurn, let topicID = activity.turnTargetID {
            let kind = manager.memoryReviewTopics.first { $0.id == topicID }?.kind
            return ChatTranscriptPage.Part(
                kind: .turn,
                id: entry.id.uuidString,
                title: activity.title,
                subtitle: kind.map { "Now reviewing · \($0.label)" } ?? "Now reviewing"
            )
        }
        if let saved = entry.savedCards {
            return ChatTranscriptPage.Part(
                kind: .savedCards,
                id: entry.id.uuidString,
                title: savedCardTitles["\(saved.destination)"] ?? saved.label,
                subtitle: lookups.savedCardsSubtitle(saved)
            )
        }
        return nil
    }

    /// The newest learner message: a send, or a chat loading its history.
    private var latestUserMessageID: UUID? {
        messages.last(where: { $0.role == .user })?.id
    }

    private func requestScroll(to id: String?, _ position: ChatTranscriptPage.ScrollRequest.Position, animated: Bool = false, opensLane: Bool = false) {
        scrollRequest = .init(
            token: (scrollRequest?.token ?? 0) + 1,
            blockID: id,
            position: position,
            animated: animated,
            opensLane: opensLane
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatTranscriptPage(
                state: state,
                scrollRequest: scrollRequest,
                resolvers: resolvers,
                onAction: onAction
            )
            // The side chat about words selected in a reply hangs off the
            // words, as it does over a native reply.
            .popover(
                isPresented: Binding(
                    get: { sideChat != nil },
                    set: { shown in if !shown { sideChat?.dismiss() } }
                ),
                attachmentAnchor: sideChat?.model.anchor.map { PopoverAttachmentAnchor.rect(.rect($0)) }
                    ?? PopoverAttachmentAnchor.rect(.bounds),
                arrowEdge: sideChat?.model.placement.side == .above ? .top : .bottom
            ) {
                if let sideChat {
                    ReviewChatSideChatPopover(presentation: sideChat)
                        .id(ObjectIdentifier(sideChat.model))
                }
            }

            if isTurnInFlight {
                // The offers that come with a long wait stay native, under the
                // page.
                VStack(alignment: .leading, spacing: 6) {
                    MemoryReviewPreparationOffer(
                        isPlanning: workingPhase == .planning,
                        startedAt: turnStartedAt ?? Date()
                    )
                    SlowFreeModelOffer(
                        turnModel: manager.turnModel,
                        isWaitingForText: workingPhase == .thinking,
                        askAgain: { manager.restartTurnOnSelectedModel() }
                    )
                }
                .frame(maxWidth: layout.columnMaxWidth, alignment: .leading)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
            }
        }
        .task(id: "\(vm.memoryCardRevision)#\(savedCardsInChat.count)") { await refreshSavedCardTitles() }
        .onChange(of: manager.chatMessages.map(\.id), initial: true) { _, _ in
            citationContexts = ReviewChatCitationContexts.contexts(for: manager)
        }
        // A reply that has finished streaming cites only what it cites. Left
        // open, its context narrowed at the next message added, whenever that
        // came, and the reply drew its text again under the learner's
        // selection (`ReviewChatTranscriptStack` says why it opens).
        .onChange(of: manager.streamingMessageID) { _, _ in
            citationContexts = ReviewChatCitationContexts.contexts(for: manager)
        }
        .onChange(of: latestUserMessageID) { _, _ in
            // A send puts the learner's message at the middle, with the reply
            // to stream under it; a chat loading its history lands at its end.
            // A More details press draws no bubble: its lane's heading is the
            // line it sent.
            let blocks = ReviewChatTranscriptBlock.grouping(messages)
            guard let last = blocks.last else { return }
            if let user = last.userMessage, user.isMoreDetailsRequest,
               let lane = ReviewChatTranscriptSection.grouping(blocks).first(where: {
                   $0.isSideQuestion && $0.blocks.contains { $0.id == last.id }
               }) {
                requestScroll(to: Self.laneID(lane), .top)
                return
            }
            requestScroll(to: last.id.uuidString, last.userMessage != nil ? .center : .bottom)
        }
        .onChange(of: findScrollRevision) { _, _ in
            guard let findMatchID else { return }
            requestScroll(to: findMatchID.uuidString, .center, animated: true)
        }
        .onChange(of: laneExpansionRequest) { _, request in
            // More details pressed again: the lane opens and comes into view.
            guard let request else { return }
            requestScroll(to: "lane:\(request.laneID.uuidString)", .top, animated: true, opensLane: true)
        }
        .onChange(of: manager.walkthroughStepScrollRequest) { _, request in
            // A move in the walk: the chat under the card shows the end of
            // that card's conversation.
            guard request != nil, let last = ReviewChatTranscriptBlock.grouping(messages).last else { return }
            requestScroll(to: last.id.uuidString, .bottom, animated: true)
        }
    }
}
