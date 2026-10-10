#if os(macOS)
import SwiftUI

/// How the Mac draws a memory review: as a deck of cards, one exchange a card,
/// or as the conversation it is underneath (product owner, 2026-09-24, after the
/// walkthrough became a deck: "maybe the memory mode can also be redesigned in
/// a kind of 'cards' like interface?"). Cards by default. Remembered on this
/// Mac, and set from chat or MCP as `memory.review_layout`.
enum MemoryReviewLayout: String, CaseIterable, Identifiable {
    /// One exchange at a time, on a card, with Back and Next through the day.
    case cards
    /// The whole transcript, as every other chat draws it.
    case conversation

    static let storageKey = "memoryReviewLayout"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cards: "Cards"
        case .conversation: "Conversation"
        }
    }

    /// The value `get_app_settings` / `set_app_setting` use.
    var mcpValue: String { rawValue }

    /// What the review will draw: the stored choice, cards when none.
    static var stored: MemoryReviewLayout {
        UserDefaults.standard.string(forKey: storageKey).flatMap(MemoryReviewLayout.init(rawValue:)) ?? .cards
    }
}

/// A memory review's transcript cut into cards, by the rule both clients
/// share (`MemoryReviewCardDealing`). The chat is untouched — every turn is
/// still in `chatMessages`, graded, persisted and read by the tutor — only
/// what is on screen changes, the way `WalkthroughTranscriptFold` shows a
/// card's own thread. A side question, More details and their replies stay on
/// the card they were asked from.
@MainActor
enum MemoryReviewCardFold {

    typealias Card = MemoryReviewCardDealing.Card

    /// The deck: one exchange a card, or, for a review planned by topic
    /// (`byTopic`), one topic a card (docs/memory-design.md, "Review by
    /// topic"). The old dealing stays for a review whose briefing carries no
    /// topics, so a day prepared before topics reads exactly as it did.
    static func cards(_ messages: [ReviewSessionManager.Message], byTopic: Bool = false) -> [Card] {
        let turns = messages.map(turn)
        return byTopic ? MemoryReviewCardDealing.topicCards(turns) : MemoryReviewCardDealing.cards(turns)
    }

    static func resolvedIndex(_ selected: Int?, count: Int) -> Int? {
        MemoryReviewCardDealing.resolvedIndex(selected, count: count)
    }

    /// The messages of the card on screen, whether it is the newest — the
    /// one the running turn writes into, where the steer chips, the working
    /// line and the ways back from a side question belong — and what the
    /// card is about: a source id, or a topic id in a review by topic.
    static func thread(
        _ messages: [ReviewSessionManager.Message],
        selected: Int?,
        byTopic: Bool = false
    ) -> (messages: [ReviewSessionManager.Message], isNewest: Bool, sourceID: String?) {
        let cards = cards(messages, byTopic: byTopic)
        guard let index = resolvedIndex(selected, count: cards.count) else { return (messages, true, nil) }
        return (Array(messages[cards[index].range]), index == cards.count - 1, cards[index].sourceID)
    }

    /// What a card is about: the topic or source it turned to, or, for the
    /// newest card when the tutor asked without a turn line, the source the
    /// review is on (the last contour graded), so the head, the ledger and
    /// the steers still know it.
    static func subjectID(of card: Card, isNewest: Bool, manager: ReviewSessionManager) -> String? {
        card.sourceID ?? (isNewest ? manager.memoryReviewCurrentSourceID : nil)
    }

    private static func turn(_ message: ReviewSessionManager.Message) -> MemoryReviewCardDealing.Turn {
        switch message.role {
        case .user:
            // A side question or More details is a detour; a blank line is
            // nothing. Anything else answers, steers or asks.
            guard !message.isSideQuestion,
                  ReviewSessionManager.displayableMessageContent(role: .user, content: message.content)?
                      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return .other }
            return .answer
        case .assistant:
            let turnsLine = message.content.contains("<\(MemoryReviewSourceTurn.tagName)")
            guard turnsLine
                || ReviewSessionManager.displayableMessageContent(role: .assistant, content: message.content) != nil
            else { return .other }
            let turnsTo = turnsLine
                ? ReviewSessionManager.displayableAssistantContentKeepingSourceTurns(message.content)
                    .flatMap { MemoryReviewSourceTurn.sourceIDs(in: $0).last }
                : nil
            return .reply(turnsTo: turnsTo)
        case .tool:
            // A settled reply keeps its turn line as a heading row of its own
            // (the manager splits the reply around it), so the row is where
            // the review moved once the streamed text is gone.
            if let target = message.toolActivity?.turnTargetID { return .turn(to: target) }
            return .other
        }
    }
}

// MARK: - What a card is about

/// What one card of the deck is about: a topic in a review planned by topic,
/// or a source (or chat) in one planned source by source. Both are dealt a
/// card each and drawn alike: the question large, the answer field under it,
/// the ledger of its ideas, and a segment in the session bar (product owner,
/// 2026-09-26: "please come up with a better design for the daily quiz",
/// after a source-by-source review drew its opening as a centred paragraph
/// under a strip of 23 chips).
struct MemoryReviewCardSubject: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    /// A topic's kind, which the card's head labels. Nil for a source.
    let kind: MemoryReviewTopicKind?
    /// The ideas the card's question cues, in the order the ledger lists them.
    let ideaIDs: [String]
    /// The sources the card draws on, drawn as faces under the question.
    let sourceIDs: [String]

    var isTopic: Bool { kind != nil }

    init(topic: MemoryReviewTopic) {
        id = topic.id
        title = topic.title
        kind = topic.kind
        ideaIDs = topic.ideaIDs
        sourceIDs = topic.sourceIDs
    }

    init(sourceID: String, title: String, ideaIDs: [String]) {
        id = sourceID
        self.title = title
        kind = nil
        self.ideaIDs = ideaIDs
        sourceIDs = [sourceID]
    }

    /// "topic" or "source", for the head's ordinal and the bar's summary.
    static func noun(_ subjects: [MemoryReviewCardSubject], plural: Bool) -> String {
        let topic = subjects.first?.isTopic ?? false
        switch (topic, plural) {
        case (true, false): return "topic"
        case (true, true): return "topics"
        case (false, false): return "source"
        case (false, true): return "sources"
        }
    }
}

// MARK: - A topic card's parts

/// What the foot of the newest topic card carries.
enum MemoryReviewTopicCardFoot: Equatable, Sendable {
    /// The tutor asked and is waiting: the card carries the answer field.
    case answer
    /// The learner's answer is out and the tutor is grading it.
    case reading
    /// The tutor replied to a graded answer: Go deeper and Next topic.
    case steer
    /// Nothing of its own: an older card, or a turn in flight after a
    /// steer, when the working line says what is happening.
    case none
}

/// The opening of a topic card: the turn line's topic, whatever the tutor
/// said before turning (the day's opening sentence, the close of the last
/// topic), and the question it asks, which is what the card sets large.
struct MemoryReviewTopicOpening: Equatable, Sendable {
    let topicID: String
    let preamble: String?
    /// Empty while the turn line has arrived and the question has not.
    let question: String
}

/// One idea of the topic as the ledger draws it.
struct MemoryReviewTopicLedgerRow: Equatable, Identifiable, Sendable {
    let ideaID: String
    let sourceID: String
    let status: MemoryIdeaCoverage.Status
    /// A missing idea is never read out: the row shows only that
    /// something from this source has not come back, until a probe on it
    /// fails too and the tutor re-teaches it (`MemoryReviewIdeaState.isRevealed`).
    let isVeiled: Bool
    /// The idea's statement, when the row may show it and the idea is
    /// loaded.
    let statement: String?

    var id: String { ideaID }
}

/// What a topic card shows besides its exchange, read off the card's own
/// thread (docs/memory-design.md, "Review by topic"): whether it is waiting
/// for the learner's answer, being graded, or graded and waiting on Go deeper
/// or Next topic; the opening question it is about; and the ledger of its
/// ideas. Pure, so the phone can deal the same card from the same rules.
@MainActor
enum MemoryReviewTopicCardFold {

    typealias Message = ReviewSessionManager.Message
    typealias Foot = MemoryReviewTopicCardFoot
    typealias Opening = MemoryReviewTopicOpening
    typealias LedgerRow = MemoryReviewTopicLedgerRow

    /// The learner's words when they take a topic now from the session bar,
    /// go deeper on one, or take a source out of the day. The words are
    /// theirs, the way the Next and Go deeper chips' are, and the fold reads
    /// them back to tell a steer from an answer; so they are minted here and
    /// nowhere else.
    static func takeNowMessage(title: String) -> String { "Let's do \(title) now." }
    static func deeperOnMessage(title: String) -> String { "Go deeper on \(title)." }
    static func skipMessage(title: String) -> String { "Skip \(title)." }

    /// Whether a learner message steers the review rather than answers it.
    static func isSteer(_ message: Message) -> Bool {
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == MemoryReviewTutoring.steerMessage(.next) || text == MemoryReviewTutoring.steerMessage(.deeper) {
            return true
        }
        return text.hasPrefix("Let's do ") || text.hasPrefix("Go deeper on ") || text.hasPrefix("Skip ")
    }

    /// A learner turn in the card's main line: an answer or a steer. A side
    /// question, More details and a blank line are not.
    private static func isMainLineLearnerTurn(_ message: Message) -> Bool {
        guard message.role == .user, !message.isSideQuestion else { return false }
        return ReviewSessionManager.displayableMessageContent(role: .user, content: message.content)?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// The tutor said something, or turned to a topic.
    private static func isReply(_ message: Message) -> Bool {
        switch message.role {
        case .assistant:
            return message.content.contains("<\(MemoryReviewSourceTurn.tagName)")
                || ReviewSessionManager.displayableMessageContent(role: .assistant, content: message.content) != nil
        case .tool:
            return message.toolActivity?.turnTargetID != nil
        case .user:
            return false
        }
    }

    /// What the newest card's foot carries, from the last two main-line turns
    /// on it: after the tutor's question (the opening, or a probe after Go
    /// deeper) the answer field; after an answer with nothing back yet, the
    /// field again, so a failed turn can be resent; after the tutor's reply
    /// to a graded answer, the two steers. `isGraded` is whether the card's
    /// topic has a grade in this review.
    static func foot(_ messages: [Message], isNewest: Bool, isGraded: Bool, isBusy: Bool) -> Foot {
        guard isNewest else { return .none }
        var lastIsLearner: Bool?
        var lastLearner: Message?
        for message in messages.reversed() {
            let learner = isMainLineLearnerTurn(message)
            guard learner || isReply(message) else { continue }
            if lastIsLearner == nil { lastIsLearner = learner }
            if learner {
                lastLearner = message
                break
            }
        }
        guard let lastIsLearner else { return .none }
        if isBusy {
            // The tutor is reading an answer, or writing the next question
            // after a steer; only the first is the card's own wait.
            return lastIsLearner && lastLearner.map({ !isSteer($0) }) == true ? .reading : .none
        }
        if lastIsLearner { return .answer }
        guard let lastLearner, !isSteer(lastLearner) else { return .answer }
        return isGraded ? .steer : .answer
    }

    /// The opening in a run of tutor turns: the card's first block. Nil when
    /// no turn line is in it, and the block is drawn as any reply is. A
    /// settled reply carries the turn as a heading row; a streaming one still
    /// carries it as text, and both read the same.
    static func opening(in messages: [Message]) -> Opening? {
        var preamble: [String] = []
        var topicID: String?
        var question: [String] = []
        for message in messages {
            switch message.role {
            case .tool:
                guard let target = message.toolActivity?.turnTargetID else { continue }
                // A second turn in one run (the tutor turned twice): what was
                // asked under the first is context, not the question.
                if topicID != nil { preamble.append(contentsOf: question) }
                topicID = target
                question = []
            case .assistant:
                let hasTurn = message.content.contains("<\(MemoryReviewSourceTurn.tagName)")
                if hasTurn, let kept = ReviewSessionManager.displayableAssistantContentKeepingSourceTurns(message.content) {
                    for part in MemoryReviewSourceTurn.split(kept) {
                        switch part {
                        case .turn(let sourceID):
                            if topicID != nil { preamble.append(contentsOf: question) }
                            topicID = sourceID
                            question = []
                        case .text(let prose):
                            if topicID == nil { preamble.append(prose) } else { question.append(prose) }
                        }
                    }
                } else if let prose = ReviewSessionManager.displayableMessageContent(role: .assistant, content: message.content)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !prose.isEmpty {
                    if topicID == nil { preamble.append(prose) } else { question.append(prose) }
                }
            case .user:
                continue
            }
        }
        guard let topicID else { return nil }
        let before = preamble.joined(separator: "\n\n")
        return Opening(topicID: topicID, preamble: before.isEmpty ? nil : before, question: question.joined(separator: "\n\n"))
    }

    /// The opening of a card the tutor asked without a turn line (a
    /// source-by-source review's first question, when the tutor skipped the
    /// line): its prose read as a question after whatever came before it.
    /// The question is the last paragraph that asks something, with anything
    /// after it; the paragraphs before it are the preamble. Nil for prose that
    /// asks nothing, and for block markdown (a list, a heading, a table, code),
    /// which the card's plain text would flatten; that block is drawn as any
    /// reply is.
    static func untitledOpening(in messages: [Message]) -> Opening? {
        let prose = messages.compactMap { message -> String? in
            guard message.role == .assistant,
                  !message.content.contains("<\(MemoryReviewSourceTurn.tagName)") else { return nil }
            return ReviewSessionManager.displayableMessageContent(role: .assistant, content: message.content)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
        guard !prose.isEmpty else { return nil }
        let blockMarkers = ["#", "- ", "* ", "|", "```", "> "]
        for line in prose.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if blockMarkers.contains(where: { trimmed.hasPrefix($0) }) { return nil }
            if let first = trimmed.first, first.isNumber, trimmed.dropFirst().drop(while: \.isNumber).hasPrefix(". ") {
                return nil
            }
        }
        let paragraphs = prose.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let asks = paragraphs.lastIndex(where: { $0.contains("?") }) else { return nil }
        let before = paragraphs[..<asks].joined(separator: "\n\n")
        return Opening(
            topicID: "",
            preamble: before.isEmpty ? nil : before,
            question: paragraphs[asks...].joined(separator: "\n\n")
        )
    }

    /// The ledger of a topic: a row per idea graded today, in the topic's
    /// order. An idea the grader has not seen yet has no row, so the ledger
    /// is empty until the opening answer is graded.
    static func ledgerRows(
        topic: MemoryReviewTopic,
        states: [String: MemoryReviewIdeaState],
        statement: (String) -> String?
    ) -> [LedgerRow] {
        ledgerRows(ideaIDs: topic.ideaIDs, states: states, statement: statement)
    }

    /// The ledger of any card's ideas, a topic's or a source's, in the order given.
    static func ledgerRows(
        ideaIDs: [String],
        states: [String: MemoryReviewIdeaState],
        statement: (String) -> String?
    ) -> [LedgerRow] {
        ideaIDs.compactMap { ideaID in
            guard let state = states[ideaID], let sourceID = SourceIdea.sourceID(fromIdeaID: ideaID) else { return nil }
            let veiled = state.status == .missing && !state.isRevealed
            return LedgerRow(
                ideaID: ideaID,
                sourceID: sourceID,
                status: state.status,
                isVeiled: veiled,
                statement: veiled ? nil : statement(ideaID)
            )
        }
    }
}

/// The card's own frame around the transcript: the review is a card on the
/// pane, not a column of bubbles running to the composer. The card fills the
/// pane like a slide (product owner, 2026-09-25: "maybe the quiz can just be full
/// screen cards?"), and its exchange starts at the top of it, set larger
/// than the chat, in a column narrow enough to read at that size, with the
/// answer field right under the question (2026-09-26: a question centred in
/// the card left its top half empty and the field a screen away). An
/// exchange taller than the card scrolls inside it.
struct MemoryReviewCardSurface: ViewModifier {
    let isOn: Bool
    let columnMaxWidth: CGFloat
    let gutter: CGFloat

    static let cornerRadius: CGFloat = 16
    /// How far the card's head, transcript and foot sit in from its edges.
    static let contentInset: CGFloat = 20
    /// The card's text against the chat's: a card holds one exchange, so it
    /// can be read from a step back.
    static let textScale: CGFloat = 1.3
    /// The widest the card's text runs, at chat zoom 1; wider than this a
    /// line at `textScale` is too long to follow back.
    static let textMaxWidth: CGFloat = 780

    /// The card's text column: the reading column less the card's own
    /// margins, capped at a comfortable line.
    static func textColumnWidth(columnMaxWidth: CGFloat, gutter: CGFloat, zoom: CGFloat) -> CGFloat {
        min(columnMaxWidth - 2 * gutter, textMaxWidth * zoom)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if isOn {
            let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            content
                .clipShape(shape)
                .background(
                    shape
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                        .shadow(color: .black.opacity(0.07), radius: 18, y: 8)
                )
                .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
                .padding(.horizontal, gutter)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .frame(maxWidth: columnMaxWidth)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("memory.card")
        } else {
            content
        }
    }
}

/// The line over the card: the topic or source it is about, small, and its
/// place in the day. A view of its own because it reads the messages, so a
/// streamed token re-evaluates it and not the panel.
struct MemoryReviewCardHeader: View {
    let manager: ReviewSessionManager
    let selectedIndex: Int?
    /// The card's text column, which the head sits over.
    let textColumnWidth: CGFloat
    /// Today's topics, or today's sources in a review planned source by source.
    let subjects: [MemoryReviewCardSubject]
    /// The name of a source or chat in today's review, by id.
    let sourceTitle: (String) -> String?

    var body: some View {
        let cards = MemoryReviewCardFold.cards(manager.chatMessages, byTopic: true)
        let index = MemoryReviewCardFold.resolvedIndex(selectedIndex, count: cards.count)
        let cardID = index.flatMap { position in
            MemoryReviewCardFold.subjectID(of: cards[position], isNewest: position == cards.count - 1, manager: manager)
        }
        // A topic card is headed by its topic's name and kind; a source card
        // by the source's name.
        let topicPosition = cardID.flatMap { id in subjects.firstIndex { $0.id == id } }
        let topic = topicPosition.map { subjects[$0] }
        let title = topic?.title ?? cardID.flatMap(sourceTitle) ?? "Today's review"
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .zoomedSystemFont(size: 10.5, weight: .semibold)
                .foregroundStyle(Color.accentColor)
                .textCase(.uppercase)
                .kerning(0.7)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(title)
                .accessibilityIdentifier("memory.card.source")
            if let kind = topic?.kind {
                Text(kind.label)
                    .zoomedSystemFont(size: 10, weight: .medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .fixedSize()
                    .accessibilityIdentifier("memory.card.kind")
            }
            Spacer(minLength: 0)
            if let topicPosition {
                let noun = MemoryReviewCardSubject.noun(subjects, plural: false).capitalized
                Text("\(noun) \(topicPosition + 1) of \(subjects.count)")
                    .zoomedSystemFont(size: 10.5, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .textSelection(.disabled)
                    .accessibilityLabel("\(noun) \(topicPosition + 1) of \(subjects.count)")
                    .accessibilityIdentifier("memory.card.ordinal")
            } else if let index {
                Text("\(index + 1) of \(cards.count)")
                    .zoomedSystemFont(size: 10.5, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .textSelection(.disabled)
                    .accessibilityLabel("Card \(index + 1) of \(cards.count)")
                    .accessibilityIdentifier("memory.card.ordinal")
            }
        }
        // Over the text column, so the head and the text under it share one
        // leading edge however wide the card is.
        .padding(.horizontal, MemoryReviewCardSurface.contentInset)
        .frame(maxWidth: textColumnWidth)
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 0)
    }
}

/// The foot of the card: the day as a row of segments, one a card, each a
/// jump; the way back to the card being answered when an older one is up;
/// and Back and Next. A new card — the learner sent something — always brings
/// the deck back to the newest.
struct MemoryReviewCardFooter: View {
    let manager: ReviewSessionManager
    @Binding var selectedIndex: Int?
    /// Whether the foot draws the day as segments. A review by topic has the
    /// session bar's stepper for that, so its foot keeps only Back and Next.
    var showsSegments = true

    var body: some View {
        let count = MemoryReviewCardFold.cards(manager.chatMessages, byTopic: true).count
        let index = MemoryReviewCardFold.resolvedIndex(selectedIndex, count: count)
        let onNewest = index.map { $0 == count - 1 } ?? true
        HStack(spacing: 8) {
            if showsSegments {
                segments(count: count, index: index)
            }
            Spacer(minLength: 8)
            if !onNewest {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selectedIndex = nil }
                } label: {
                    Label("Current card", systemImage: "arrow.uturn.forward")
                        .zoomedSystemFont(size: 11, weight: .medium)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.hoverWash)
                .help("Back to the card you are answering")
                .accessibilityIdentifier("memory.card.current")
            }
            Button {
                guard let index, index > 0 else { return }
                withAnimation(.easeOut(duration: 0.15)) { selectedIndex = index - 1 }
            } label: {
                Image(systemName: "chevron.left")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash)
            .disabled((index ?? 0) == 0)
            .help("Previous card")
            .accessibilityIdentifier("memory.card.back")
            Button {
                guard let index, index + 1 < count else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    selectedIndex = index + 1 == count - 1 ? nil : index + 1
                }
            } label: {
                Image(systemName: "chevron.right")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash)
            .disabled(onNewest)
            .help(onNewest ? "This is the card you are answering" : "Next card")
            .accessibilityIdentifier("memory.card.next")
        }
        .padding(.leading, MemoryReviewCardSurface.contentInset)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
        }
        .onChange(of: count) { _, _ in selectedIndex = nil }
        .onChange(of: manager.currentSessionID) { _, _ in selectedIndex = nil }
    }

    /// One segment a card: the one on screen in accent, the newest — the one
    /// being answered — half tinted while an older card is up, the rest faint.
    private func segments(count: Int, index: Int?) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { position in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        selectedIndex = position == count - 1 ? nil : position
                    }
                } label: {
                    Capsule()
                        .fill(segmentTint(position: position, index: index, count: count))
                        .frame(height: 4)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash(cornerRadius: 3, inset: 0, opacity: 0.08))
                .help("Card \(position + 1)")
                .accessibilityLabel("Card \(position + 1)")
            }
        }
        .frame(maxWidth: min(280, CGFloat(count) * 30))
        // A group of its own: on a plain container every card's button
        // carried the identifier.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.card.segments")
    }

    private func segmentTint(position: Int, index: Int?, count: Int) -> Color {
        if position == index { return .accentColor }
        if position == count - 1 { return Color.accentColor.opacity(0.4) }
        return Color.primary.opacity(0.12)
    }
}

// MARK: - A review by topic

/// The session bar of a review by topic, where the source strip stood: the
/// day as a stepper with a segment per topic. A finished topic is filled and
/// opens its card as a record; the current one is accented and a click does
/// nothing (its question is already on the card); a waiting one is faint and
/// a click takes it now. The title, the clock, the ⋯ and the × stay on the
/// pane's header above, which already carries them wherever it is mounted.
struct MemoryReviewSessionBar<Accessory: View>: View {
    /// A segment each: today's topics, or its sources in a review planned
    /// source by source, where the bar stands in for the old chip strip.
    let topics: [MemoryReviewCardSubject]
    let statusBySource: [String: MemoryReviewSourceStatus]
    /// The topic the tutor is on right now.
    let currentTopicID: String?
    /// True while a turn is in flight; a steer then would land mid-reply.
    let isBusy: Bool
    let columnMaxWidth: CGFloat
    let gutter: CGFloat
    /// A hairline under the bar, over a scrolling conversation. A card
    /// floats under the bar on its own and needs none.
    let separated: Bool
    let select: (MemoryReviewCardSubject) -> Void
    /// What sits at the bar's trailing edge: the model picker, out of the
    /// composer the card no longer shows.
    @ViewBuilder let accessory: () -> Accessory

    private var doneCount: Int { topics.filter { statusBySource[$0.id] != nil }.count }
    private var isComplete: Bool { doneCount == topics.count }

    private var summary: String {
        let noun = MemoryReviewCardSubject.noun(topics, plural: topics.count != 1)
        if doneCount == 0 { return "\(topics.count) \(noun) today" }
        if isComplete { return topics.count == 1 ? "Done today" : "All \(topics.count) done today" }
        return "\(doneCount) of \(topics.count) done today"
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                if isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.green)
                        .zoomedSystemFont(size: 10)
                }
                Text(summary)
                    .zoomedSystemFont(size: 10, weight: .semibold)
                    .foregroundStyle(isComplete ? Color.green : Color.secondary)
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .lineLimit(1)
                    .fixedSize()
            }
            stepper
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, gutter)
        .frame(maxWidth: columnMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, separated ? 8 : 2)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            if separated {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Today's review topics, \(summary)")
        .accessibilityIdentifier("memory.bar")
    }

    private var stepper: some View {
        HStack(spacing: 4) {
            ForEach(topics) { topic in
                let done = statusBySource[topic.id] != nil
                let current = topic.id == currentTopicID
                Button {
                    select(topic)
                } label: {
                    Capsule()
                        .fill(tint(done: done, current: current))
                        .frame(height: 5)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash(cornerRadius: 3, inset: 0, opacity: 0.08))
                // A finished topic is a record and opens whenever; taking a
                // waiting one mid-reply would land in the tutor's turn.
                .disabled(isBusy && !done)
                .help(help(topic, done: done, current: current))
                .accessibilityLabel(help(topic, done: done, current: current))
                .accessibilityAddTraits(current ? .isSelected : [])
                .accessibilityIdentifier("memory.bar.topic")
            }
        }
        // A source-by-source day can run to twenty-odd segments; they narrow
        // rather than push the model picker off the bar.
        .frame(maxWidth: min(360, CGFloat(topics.count) * 64))
        .frame(minWidth: 0)
        // A group of its own: on a plain container the identifier replaced
        // each topic's memory.bar.topic.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.bar.stepper")
    }

    private func help(_ topic: MemoryReviewCardSubject, done: Bool, current: Bool) -> String {
        let state: String
        if let status = statusBySource[topic.id] {
            state = status.recallSummary
        } else if current {
            state = "the question is on the card"
        } else {
            state = "click to take it now"
        }
        guard let kind = topic.kind else { return "\(topic.title): \(state)" }
        return "\(topic.title) (\(kind.label.lowercased())): \(state)"
    }

    private func tint(done: Bool, current: Bool) -> Color {
        if current { return .accentColor }
        if done { return Color.primary.opacity(0.4) }
        return Color.primary.opacity(0.12)
    }
}

/// The opening of a topic card: the question set large, in a serif rather
/// than the chat's face, so it is the one thing on the card that reads as
/// text to answer; whatever the tutor said before turning, small above it;
/// and the topic's sources as faces under it. Once the topic is graded the
/// question shrinks to the reply's size: the ledger is what the card is
/// about then.
struct MemoryReviewTopicQuestion<Faces: View>: View {
    let preamble: String?
    let question: String
    let isLarge: Bool
    @ViewBuilder let faces: () -> Faces

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let preamble {
                Self.markdown(preamble)
                    .zoomedSystemFont(size: 12.5)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("memory.card.preamble")
            }
            if !question.isEmpty {
                Self.markdown(question)
                    .zoomedSystemFont(size: isLarge ? 20 : 13, weight: .medium, design: .serif)
                    .lineSpacing(isLarge ? 4 : 2)
                    .foregroundStyle(isLarge ? Color.primary : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("memory.card.question")
            }
            faces()
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: isLarge)
    }

    /// The tutor writes inline markdown at most (emphasis, a link); a
    /// question is never a document, so `Text` draws it without a web view.
    static func markdown(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }
}

/// A source as a face: the cover or thumbnail for a source row, a titled
/// pill for a chat, which has no picture. The title is under the pointer, and
/// a click opens the source in the Reader.
struct MemoryReviewSourceFace: View {
    let title: String
    /// Nil for a chat, which is review material without being a source row.
    let article: StudioArticle?
    let bookCoverPath: String?
    var size: CGFloat = 30
    /// Open in the Reader; nil for a chat.
    let open: (() -> Void)?

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 7, style: .continuous) }

    @ViewBuilder
    private var face: some View {
        if let article {
            SourceThumbnail(source: article, size: size, bookCoverPath: bookCoverPath)
        } else {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .zoomedSystemFont(size: size * 0.4)
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 7)
            .frame(height: size)
            .frame(maxWidth: 180)
            .background(Color.accentColor.opacity(0.08), in: shape)
        }
    }

    var body: some View {
        if let open {
            Button(action: open) {
                face.contentShape(shape)
            }
            .buttonStyle(.hoverWash(in: shape, inset: 2, opacity: 0.12))
            .help("Open \(title)")
            .accessibilityLabel("Open \(title)")
        } else {
            // One element: a chat's face is its icon and title, and on the
            // plain row each read as the title.
            face
                .accessibilityElement(children: .combine)
                .help(title)
                .accessibilityLabel(title)
        }
    }
}

/// The ledger under a graded reply: a row per idea the topic's question
/// cued, in the topic's order. An idea that came back is a filled mark and
/// its statement; one that came back in outline a half mark; one that did
/// not come back is a veiled bar naming only the source it came from, since
/// a missing idea is never read out until a probe on it has failed too.
/// Each row wears its source's face; a right-click opens the source or takes
/// it out of the day, which is what the strip's × did.
struct MemoryReviewTopicLedger: View {
    let rows: [MemoryReviewTopicLedgerRow]
    let sourceTitle: (String) -> String
    let article: (String) -> StudioArticle?
    let bookCoverPath: (StudioArticle) -> String?
    /// True while a turn is in flight, when a removal would land mid-reply.
    let isBusy: Bool
    let open: (String) -> Void
    let notRead: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                ledgerRow(row)
            }
        }
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What came back")
        .accessibilityIdentifier("memory.card.ledger")
    }

    private func ledgerRow(_ row: MemoryReviewTopicLedgerRow) -> some View {
        let source = article(row.sourceID)
        let title = sourceTitle(row.sourceID)
        return HStack(alignment: .center, spacing: 10) {
            mark(row.status)
                .frame(width: 12, height: 12)
            if row.isVeiled {
                HStack(spacing: 6) {
                    Text("Not yet")
                        .zoomedSystemFont(size: 12, weight: .semibold)
                        .foregroundStyle(.secondary)
                    Text("from \(title)")
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                )
            } else {
                Text(row.statement ?? "")
                    .zoomedSystemFont(size: 12.5)
                    .foregroundStyle(row.status == .produced ? Color.primary : Color.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(row.statement ?? "")
            }
            MemoryReviewSourceFace(
                title: title,
                article: source,
                bookCoverPath: source.flatMap(bookCoverPath),
                size: 22,
                open: source == nil ? nil : { open(row.sourceID) }
            )
        }
        .contentShape(Rectangle())
        .contextMenu {
            if source != nil {
                Button("Open in Reader") { open(row.sourceID) }
            }
            Button("Not something I read") { notRead(row.sourceID) }
                .disabled(isBusy)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(row, title: title))
        .accessibilityAction(named: "Not something I read") { notRead(row.sourceID) }
        .accessibilityIdentifier("memory.card.ledger.row")
    }

    @ViewBuilder
    private func mark(_ status: MemoryIdeaCoverage.Status) -> some View {
        switch status {
        case .produced:
            Circle().fill(Color.accentColor)
        case .partial:
            Image(systemName: "circle.lefthalf.filled")
                .resizable()
                .foregroundStyle(Color.accentColor)
        case .missing:
            Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.2)
        }
    }

    private func accessibilityText(_ row: MemoryReviewTopicLedgerRow, title: String) -> String {
        switch row.status {
        case .produced: return "Came back: \(row.statement ?? ""). From \(title)."
        case .partial: return "Partly: \(row.statement ?? ""). From \(title)."
        case .missing: return row.isVeiled ? "Not yet, from \(title)." : "Not yet: \(row.statement ?? ""). From \(title)."
        }
    }
}

/// The two ways on from a graded topic, under its ledger: stay for a probe —
/// on what did not come back, or once everything did, an understanding probe
/// that goes past it (`MemoryUnderstandingProbe`) — or turn to the next
/// topic. The same steers the chips sent; the keys are the card's, since it
/// has no composer to take Return.
struct MemoryReviewTopicSteerButtons: View {
    let isBusy: Bool
    /// "Next topic", or "Next source" in a review planned source by source.
    var nextTitle = "Next topic"
    let deeper: () -> Void
    let next: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: deeper) {
                HStack(spacing: 6) {
                    Text("Go deeper")
                    Text("⌘D")
                        .foregroundStyle(.tertiary)
                        .monospaced()
                }
                .zoomedSystemFont(size: 12.5, weight: .medium)
                .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("d", modifiers: .command)
            .help("Stay here for a probe: on what did not come back, or, once it all did, one that goes past it")
            .accessibilityIdentifier("mac.chatMemoryDeeper")

            Button(action: next) {
                HStack(spacing: 6) {
                    Text(nextTitle)
                    Text("⌘↩")
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
                .zoomedSystemFont(size: 12.5, weight: .medium)
                .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Move on: \(nextTitle.lowercased())")
            .accessibilityIdentifier("mac.chatMemoryNext")
            Spacer(minLength: 0)
        }
        .controlSize(.regular)
        .disabled(isBusy)
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Memory review steer")
    }
}

/// The answer field inside the card, right under the question: the learner
/// answers where the question is, not in a composer at the foot of the
/// window, nor at the foot of the card. Return sends; **I don't
/// remember** is an honest miss that costs no typing and is graded like any
/// answer.
struct MemoryReviewTopicAnswerField: View {
    let isBusy: Bool
    let send: (String) -> Void
    let dontRemember: () -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("In your own words, from anything you read or heard", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .zoomedSystemFont(size: 13)
                .focused($isFocused)
                .onSubmit(submit)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(shape.fill(Color.primary.opacity(0.04)))
                .overlay(shape.strokeBorder(isFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1)))
                .accessibilityIdentifier("memory.card.answer")
            HStack(spacing: 8) {
                Button("I don't remember", action: dontRemember)
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.hoverWash)
                    .help("Send an honest miss; nothing is read out")
                    .accessibilityIdentifier("memory.card.dontRemember")
                Spacer(minLength: 0)
                Button("Send", action: submit)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(trimmed.isEmpty)
                    .help("Send your answer (Return)")
                    .accessibilityIdentifier("memory.card.send")
            }
        }
        .padding(.top, 4)
        .disabled(isBusy)
        .onAppear { isFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your answer")
    }

    private func submit() {
        let text = trimmed
        guard !text.isEmpty, !isBusy else { return }
        draft = ""
        send(text)
    }
}

/// The conversation's heading when the tutor turns to a topic: the same
/// full-width row a turn to a source draws, naming the topic and its kind. A
/// topic has no library record, so nothing opens on a click.
struct MemoryReviewTopicTurnRow: View {
    let title: String
    let kind: MemoryReviewTopicKind?

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 18, height: 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.map { "Now reviewing · \($0.label)" } ?? "Now reviewing")
                    .zoomedSystemFont(size: 10, weight: .semibold)
                    .foregroundStyle(Color.accentColor)
                    .textCase(.uppercase)
                    .kerning(0.6)
                Text(title)
                    .zoomedSystemFont(size: 13, weight: .medium)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now reviewing \(title)")
        .accessibilityIdentifier("mac.chatMemoryTopicTurn")
    }
}

/// What a topic card shows while the tutor grades an answer, in place of the
/// chat's working line and its Thinking disclosure: one line, breathing.
struct MemoryReviewReadingAnswerLine: View {
    @State private var isDim = false

    var body: some View {
        Text("Reading your answer")
            .zoomedSystemFont(size: 12.5, weight: .medium)
            .foregroundStyle(.secondary)
            .opacity(isDim ? 0.4 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    isDim = true
                }
            }
            .accessibilityLabel("Reading your answer")
            .accessibilityIdentifier("memory.card.reading")
    }
}
#endif
