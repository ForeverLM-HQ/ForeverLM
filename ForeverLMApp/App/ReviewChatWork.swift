// What the model is doing in a chat turn: the working indicator, reasoning text, answer layout, the work fold, page cards and tool rows.

import SwiftUI

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
/// ChatGPT draws a reply the same way; one reply never stacks
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
/// size with a thin rule under it once the work is done, as Codex draws it.
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
        // The figure under the step is what it returned.
        if activity.lookedAtFigure != nil { return nil }
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

    /// A step that loaded a source into the chat. Its row says so in words and
    /// that is all: no thumbnail banner, no passage cards, no raw text under it
    /// (product owner, 2026-11-18: "never show it at all"). The banner showed
    /// while the reply streamed and vanished once the fold closed, which read
    /// as a glitch.
    private var loadsSourceIntoContext: Bool {
        ["get_source_content", "retrieve_sources", "get_today_sources"].contains(activity.toolName)
            && activity.state == .succeeded
    }

    private var canExpand: Bool {
        guard !loadsSourceIntoContext else { return false }
        return presentsSourceCard || presentsRetrievedPassages || presentsListedSources || activity.resultPreview != nil
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
        // A figure the step looked at names itself: "Looked at Figure 1d".
        if let figure = activity.lookedAtFigure, activity.state != .failed, !figure.label.isEmpty {
            return activity.state == .running ? "Looking at \(figure.label)" : "Looked at \(figure.label)"
        }
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

            if isExpanded, canExpand {
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
