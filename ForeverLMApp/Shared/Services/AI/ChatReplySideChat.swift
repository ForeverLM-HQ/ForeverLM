import Foundation
import CoreGraphics
import Observation

/// A side chat: a small chat that pops over words the learner selected in
/// one of the tutor's replies.
///
/// "Ask in side chat" first opened a whole new chat beside the transcript
/// with the passage as its context. The product owner (2026-09-19): "side chat should
/// just do a small popup chat; not start a whole new chat." So the question
/// is asked and answered in a popover hanging off the passage: the tutor
/// reads the passage, the reply it came from, the conversation before that
/// and the source text the chat has loaded (product owner, 2026-09-28: "give it the
/// paper's text"), answers briefly, and the chat underneath is left exactly as it was —
/// nothing is sent there, nothing is saved, no row joins the rail. When the
/// learner wants to go further than a popover allows, the exchange moves to a
/// new chat by the route a side question already takes (`ChatSideQuestionHandoff`).
///
/// The Reader's selection bar opens the same popover over words in a source
/// (product owner, 2026-09-29: "shoudl also have a side chat option here just like
/// for within a chat"). There the tutor reads the passage and the source's
/// own text, and there is no reply or conversation to read
/// (`ChatReplySideChatContext.Origin.reader`).
///
/// Foundation, CoreGraphics and Observation only: the model is what the
/// popover draws, and the context is what the model reads.
enum ChatReplySideChatError: LocalizedError, Equatable {
    case noModelConfigured
    case emptyAnswer

    var errorDescription: String? {
        switch self {
        case .noModelConfigured:
            return "No model is configured for Chat. Sign in and check Settings › AI Usage."
        case .emptyAnswer:
            return "The tutor returned nothing."
        }
    }
}

/// What the tutor is shown about where the words came from: the passage, the
/// reply it was selected in, the exchange before that reply, the source text
/// the chat has loaded, and the chat's open question when it is a review.
/// Built once when the popover opens. Words selected in the Reader have no
/// reply, exchange or question: the passage and the source's text are all.
struct ChatReplySideChatContext: Equatable, Sendable {
    /// Where the learner selected the words.
    enum Origin: Equatable, Sendable {
        /// In one of the tutor's replies in a chat.
        case reply
        /// In a source open in the Reader, named by its title.
        case reader(sourceTitle: String)
        /// No words selected: the chat as a whole, opened from `/side` or the
        /// newest reply's ⋯ (Codex's side chat beside a thread).
        case thread
    }

    let origin: Origin
    /// The words the learner selected, as the page read them.
    let passage: String
    /// The reply the words were selected in, as the learner saw it.
    let replyText: String
    /// The chat the reply is in, as its rail row reads.
    let chatTitle: String
    /// The exchange before that reply, oldest first, clipped to a budget.
    let recentTurns: [ChatSideQuestionHandoff.Turn]
    /// The tutor's question that the chat is waiting on, when there is one.
    let openQuestion: String?
    /// The verbatim source text loaded into the chat, as its tutor reads it
    /// with every turn: the text a question about the reply's claims is
    /// checked against. Held as the chat holds it, since the popover opens on
    /// the main actor; it is cut to the side chat's own model in
    /// `sourceHead(characterBudget:)`, off it. Empty when the chat has none.
    /// In the Reader, the source's own text, as a chat on it would read it.
    private(set) var sourceText: String

    /// The longest passage sent as it stands; a longer one is cut.
    static let maximumPassageCharacters = 2_000
    /// Characters of the reply the tutor sees. Enough for any reply the
    /// transcript draws whole.
    static let replyCharacterBudget = 8_000
    /// Characters of the earlier exchange the tutor sees, counted from its
    /// end: the newest turns matter most to a question about the newest reply.
    static let transcriptCharacterBudget = 8_000

    init(
        passage: String,
        replyText: String,
        chatTitle: String,
        recentTurns: [ChatSideQuestionHandoff.Turn],
        openQuestion: String?,
        sourceText: String = ""
    ) {
        self.origin = .reply
        self.passage = Self.clipped(passage, to: Self.maximumPassageCharacters)
        self.replyText = Self.clipped(replyText, to: Self.replyCharacterBudget)
        self.chatTitle = chatTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.recentTurns = Self.budgeted(recentTurns, to: Self.transcriptCharacterBudget)
        self.openQuestion = openQuestion?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.sourceText = sourceText
    }

    /// Words selected in a source in the Reader: the passage, the source's
    /// title, and its text when the library has it.
    init(readerPassage passage: String, sourceTitle: String, sourceText: String = "") {
        self.origin = .reader(sourceTitle: sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines))
        self.passage = Self.clipped(passage, to: Self.maximumPassageCharacters)
        self.replyText = ""
        self.chatTitle = ""
        self.recentTurns = []
        self.openQuestion = nil
        self.sourceText = sourceText
    }

    /// The whole chat, with no words selected: the conversation, newest turns
    /// first to keep, within the reply and transcript budgets together.
    init(
        threadTitle chatTitle: String,
        turns: [ChatSideQuestionHandoff.Turn],
        openQuestion: String?,
        sourceText: String = ""
    ) {
        self.origin = .thread
        self.passage = ""
        self.replyText = ""
        self.chatTitle = chatTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.recentTurns = Self.budgeted(turns, to: Self.transcriptCharacterBudget + Self.replyCharacterBudget)
        self.openQuestion = openQuestion?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.sourceText = sourceText
    }

    /// This context with the source text read after the popover opened.
    func withSourceText(_ text: String) -> ChatReplySideChatContext {
        var context = self
        context.sourceText = text
        return context
    }

    /// The one line the popover's heading shows for the passage: its
    /// whitespace collapsed, cut where a line's worth ends.
    var passageHeadline: String {
        let collapsed = passage
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > 160 else { return collapsed }
        return String(collapsed.prefix(157)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// What closes a source text cut to fit, so the tutor knows the rest
    /// exists and is out of its reach here.
    static let sourceCutNote = "[The rest of the source text did not fit this side chat's model and is not available here.]"

    /// The chat's source text as the tail of the stable half of the system
    /// prompt, cut to `characterBudget` characters (the note included) when the
    /// side chat's model publishes a window; nil means it publishes none, and
    /// the text goes as the chat holds it. Empty when the chat has no source
    /// text loaded.
    ///
    /// Stable rather than volatile: it is the same for every popover over this
    /// chat and every turn inside one, so it caches, while the passage and the
    /// conversation in `modelContext` change with each popover. Held to the
    /// sources' share of the window, so what a long paper crowds out is its
    /// own tail, never the passage the question is about.
    func sourceHead(characterBudget: Int?) -> String {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        var body = text
        if let characterBudget, text.count > characterBudget {
            let room = max(0, characterBudget - Self.sourceCutNote.count - 2)
            body = String(text.prefix(room)) + "\n\n" + Self.sourceCutNote
        }
        switch origin {
        case .reply, .thread:
            return "\n\n<chat_sources>\n"
                + "The source text loaded into the chat the words came from, as its tutor reads it:\n\n"
                + body
                + "\n</chat_sources>"
        case .reader(let sourceTitle):
            return "\n\n<source_text>\n"
                + "The text of the source the learner is reading"
                + (sourceTitle.isEmpty ? "" : ", \u{201C}\(sourceTitle)\u{201D}")
                + ":\n\n"
                + body
                + "\n</source_text>"
        }
    }

    /// The block the tutor reads ahead of the learner's first message here. It
    /// goes in the volatile half of the system prompt: it changes with every
    /// popover, so it must not break the cache of the stable half.
    var modelContext: String {
        if case .reader(let sourceTitle) = origin {
            return [
                "<side_chat_context>",
                "The learner selected these words while reading "
                    + (sourceTitle.isEmpty ? "a source" : "\u{201C}\(sourceTitle)\u{201D}")
                    + " in the Reader and opened a side chat about them. Their messages below are about these words:",
                "<selected_passage>",
                passage,
                "</selected_passage>",
                "</side_chat_context>",
            ].joined(separator: "\n")
        }
        var lines: [String] = []
        lines.append("<side_chat_context>")
        if origin == .thread {
            lines.append(
                "The learner opened a side chat beside the chat"
                    + (chatTitle.isEmpty ? "" : " \u{201C}\(chatTitle)\u{201D}")
                    + " to ask about the conversation as a whole, without adding to it."
                    + " The conversation, oldest first (its opening may be cut):"
            )
            lines.append("<conversation>")
            lines.append(Self.transcript(of: recentTurns))
            lines.append("</conversation>")
            if let openQuestion {
                lines.append("")
                lines.append(
                    "That chat is a review, and this question of yours is open. Do not give its answer away, "
                        + "in whole or in part; answer what can be answered and say plainly that the remainder "
                        + "is what the open question is asking."
                )
                lines.append("Open question: \(openQuestion)")
            }
            lines.append("</side_chat_context>")
            return lines.joined(separator: "\n")
        }
        lines.append(
            "The learner selected these words in one of your replies"
                + (chatTitle.isEmpty ? "" : " in the chat \u{201C}\(chatTitle)\u{201D}")
                + " and opened a side chat about them. Their messages below are about these words:"
        )
        lines.append("<selected_passage>")
        lines.append(passage)
        lines.append("</selected_passage>")
        lines.append("")
        lines.append("The reply the words were selected in:")
        lines.append("<reply>")
        lines.append(replyText)
        lines.append("</reply>")
        if !recentTurns.isEmpty {
            lines.append("")
            lines.append("The conversation before that reply, oldest first (its opening may be cut):")
            lines.append("<conversation>")
            lines.append(Self.transcript(of: recentTurns))
            lines.append("</conversation>")
        }
        if let openQuestion {
            lines.append("")
            lines.append(
                "That chat is a review, and this question of yours was open when the learner selected the words. "
                    + "Do not give its answer away, in whole or in part; if the side chat cannot be answered without "
                    + "doing that, answer what can be answered and say plainly that the remainder is what the open "
                    + "question is asking."
            )
            lines.append("Open question: \(openQuestion)")
        }
        lines.append("</side_chat_context>")
        return lines.joined(separator: "\n")
    }

    /// The exchange as the model reads it: labelled turns, in order.
    static func transcript(of turns: [ChatSideQuestionHandoff.Turn]) -> String {
        turns.compactMap { turn -> String? in
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "\(turn.speaker == .learner ? "Learner" : "Tutor"): \(text)"
        }
        .joined(separator: "\n\n")
    }

    /// The side chat's own turns, as the chat request carries them. A reply
    /// still empty — the one being written — is not a message yet.
    static func messages(for turns: [ChatSideQuestionHandoff.Turn]) -> [(role: String, content: String)] {
        turns.compactMap { turn in
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return (role: turn.speaker == .learner ? "user" : "assistant", content: text)
        }
    }

    static func clipped(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// The newest turns that fit the budget, whole turns only, oldest first.
    /// A single turn larger than the budget is cut from its start rather than
    /// dropped, so the tutor always sees what was said just before the reply.
    static func budgeted(_ turns: [ChatSideQuestionHandoff.Turn], to budget: Int) -> [ChatSideQuestionHandoff.Turn] {
        var kept: [ChatSideQuestionHandoff.Turn] = []
        var used = 0
        for turn in turns.reversed() {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if used + text.count > budget {
                if kept.isEmpty {
                    let room = max(0, budget)
                    kept.append(.init(speaker: turn.speaker, text: "…" + String(text.suffix(room))))
                }
                break
            }
            kept.append(.init(speaker: turn.speaker, text: text))
            used += text.count
        }
        return kept.reversed()
    }
}

/// Which side of the selected words the side chat opens on, and the tallest
/// it may grow there.
///
/// The popover grows with its exchange as the answer streams in, and a macOS
/// popover that outgrows the screen on its side jumps to the other side of the
/// words, mid-answer; where neither side holds it, it covers the words. So the
/// side is chosen once, as the popover opens, for the size it can grow to, and
/// the popover is held to the room on that side, so it never has to move.
struct ChatReplySideChatPlacement: Equatable, Sendable {
    enum Side: Equatable, Sendable {
        case below
        case above
    }

    /// How much of the screen's visible frame lies beyond the selected words
    /// on each side, in points.
    struct ScreenRoom: Equatable, Sendable {
        let above: CGFloat
        let below: CGFloat
    }

    let side: Side
    /// The tallest the popover's content may be on `side`, in points; nil
    /// when the words' place on screen is not known.
    let maximumHeight: CGFloat?

    /// What a popover's window adds to its content on the side it opens: the
    /// arrow and the window's inset, 26 points on macOS 27, and a margin so
    /// the popover never meets the screen's edge.
    static let windowAllowance: CGFloat = 34
    /// The least the popover is held to, even beside words with no room on
    /// either side: the heading, a line of the exchange and the field.
    static let minimumHeight: CGFloat = 160

    /// Nothing is known about the screen: below the words, where a popover
    /// opens by default, with no limit but its own.
    static let unmeasured = ChatReplySideChatPlacement(side: .below, maximumHeight: nil)

    /// Below the words when the popover can grow to `fullHeight` there,
    /// otherwise on the side with more room; held to the room on that side.
    static func choose(room: ScreenRoom?, fullHeight: CGFloat) -> ChatReplySideChatPlacement {
        guard let room else { return .unmeasured }
        let below = room.below - windowAllowance
        let above = room.above - windowAllowance
        let side: Side = below >= fullHeight || below >= above ? .below : .above
        return ChatReplySideChatPlacement(
            side: side,
            maximumHeight: max(minimumHeight, side == .below ? below : above)
        )
    }
}

/// The model side, behind a protocol so the popover's turns can be pinned in
/// tests with a canned stream.
protocol ChatReplySideChatBackend: Sendable {
    /// The tutor's answer to the newest learner turn, as it streams.
    func answer(
        context: ChatReplySideChatContext,
        turns: [ChatSideQuestionHandoff.Turn]
    ) async throws -> AsyncThrowingStream<String, Error>
}

/// The Chat task's model, with the side chat's own instructions: the learner's
/// Chat pick is the model they expect a chat to run on, and the prompt is not
/// theirs to override — a side chat that started quizzing would be a bug.
struct LiveChatReplySideChatBackend: ChatReplySideChatBackend {
    let aiService: AIService

    /// The longest answer a popover asks for, and what the window left for
    /// the source text is measured against.
    static let answerTokenLimit = 1_500

    func answer(
        context: ChatReplySideChatContext,
        turns: [ChatSideQuestionHandoff.Turn]
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let config = KeychainService.resolveConfig(for: .chat) else {
            throw ChatReplySideChatError.noModelConfigured
        }
        // The chat sized its source text for its own model, which may not be
        // this one; the share a chat gives its sources is measured again here,
        // for the model that reads it.
        let sourceBudget = AIService.sourceContextCharacterBudget(
            provider: config.provider,
            model: config.model,
            requestedMaxTokens: Self.answerTokenLimit
        )
        let instructions: String
        switch context.origin {
        case .reply: instructions = Prompts.replySideChat
        case .reader: instructions = Prompts.readerSideChat
        case .thread: instructions = Prompts.threadSideChat
        }
        return await aiService.streamChat(
            system: instructions + context.sourceHead(characterBudget: sourceBudget),
            volatileSystem: context.modelContext,
            messages: ChatReplySideChatContext.messages(for: turns),
            config: config,
            maxTokens: Self.answerTokenLimit
        )
    }
}

/// What one open side chat holds: where it hangs, what it is about, the
/// turns so far, and the answer being written. Owned by the pane whose
/// transcript the words were selected in, so the popover can be rebuilt as
/// its row is, and dropped when the popover closes. Words selected in the
/// Reader have no pane of that kind; the view model owns theirs
/// (`StudioViewModel.readerSideChat`).
@MainActor
@Observable
final class ChatReplySideChatModel {
    struct Turn: Identifiable, Equatable {
        let id: UUID
        let speaker: ChatSideQuestionHandoff.Turn.Speaker
        var text: String

        init(id: UUID = UUID(), speaker: ChatSideQuestionHandoff.Turn.Speaker, text: String) {
            self.id = id
            self.speaker = speaker
            self.text = text
        }
    }

    /// The words under "More details" on a selected passage inside the side
    /// chat. Fixed, so the press reads the same every time; the quoted
    /// passage above them says what they are about.
    static let moreDetailsQuestion = "Tell me more about this."

    /// The reply the words were selected in, so the popover attaches to its row.
    let messageID: UUID
    /// Where the words sit in that reply's view, when the page could measure.
    let anchor: CGRect?
    /// The side of the words the popover opens on, and how tall it may grow.
    /// The Reader's presenter sets it as the popover opens, since only the
    /// view knows the zoom the popover is drawn at.
    var placement: ChatReplySideChatPlacement
    private(set) var context: ChatReplySideChatContext
    private let backend: any ChatReplySideChatBackend
    /// The source text still being read as the popover opened, when the
    /// Reader opened it: the popover shows at once, and the first answer
    /// waits for the text rather than going without it.
    private var sourceTextLoad: Task<String, Never>?
    /// One id for the ledger: every answer in this popover is one activity.
    let usageID = UUID().uuidString

    private(set) var turns: [Turn] = []
    /// The words in the field, so a quote dropped in survives a row rebuild.
    var draft = ""
    private(set) var isAnswering = false
    private(set) var errorMessage: String?
    private var answerTask: Task<Void, Never>?

    init(
        messageID: UUID,
        anchor: CGRect?,
        placement: ChatReplySideChatPlacement = .unmeasured,
        context: ChatReplySideChatContext,
        backend: any ChatReplySideChatBackend,
        sourceTextLoad: Task<String, Never>? = nil
    ) {
        self.messageID = messageID
        self.anchor = anchor
        self.placement = placement
        self.context = context
        self.backend = backend
        self.sourceTextLoad = sourceTextLoad
    }

    /// Whether anything has been said here yet: what decides if moving to a
    /// new chat carries an exchange or just the passage.
    var hasExchange: Bool {
        turns.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The learner's question goes out and the tutor's reply streams in under
    /// it. A send while an answer is still being written is refused rather
    /// than queued: the field keeps the words, and the send button is a stop
    /// button until the answer lands.
    func ask(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return }
        errorMessage = nil
        draft = ""
        turns.append(Turn(speaker: .learner, text: question))
        let replyID = UUID()
        turns.append(Turn(id: replyID, speaker: .tutor, text: ""))
        isAnswering = true
        answerTask = Task { [weak self] in
            await self?.answer(into: replyID)
        }
    }

    /// The passage selected inside the popover's own reply, quoted into the
    /// field ahead of whatever is typed there.
    func quote(_ passage: String) {
        let trimmed = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let quoted = trimmed
            .components(separatedBy: .newlines)
            .map { line in line.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> \(line)" }
            .joined(separator: "\n")
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = body.isEmpty ? quoted + "\n\n" : quoted + "\n\n" + body
    }

    /// Stops the answer being written; what has arrived stays.
    func cancel() {
        answerTask?.cancel()
    }

    /// The exchange so far as a new chat's opening context, in the shape a
    /// side question already travels in. The first learner turn carries the
    /// passage as a quote, so the new chat knows which words this was about.
    /// Nil until something has been said.
    func handoff(chatTitle: String, openQuestion: String?, sourceIDs: [String], notebookID: String?) -> ChatSideQuestionHandoff? {
        let spoken = turns.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !spoken.isEmpty else { return nil }
        var handoffTurns = spoken.map { ChatSideQuestionHandoff.Turn(speaker: $0.speaker, text: $0.text) }
        if !context.passage.isEmpty, let first = handoffTurns.firstIndex(where: { $0.speaker == .learner }) {
            let quoted = context.passage
                .components(separatedBy: .newlines)
                .map { line in line.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> \(line)" }
                .joined(separator: "\n")
            handoffTurns[first] = .init(
                speaker: .learner,
                text: quoted + "\n\n" + handoffTurns[first].text
            )
        }
        let origin: ChatSideQuestionHandoff.Origin
        let title: String
        let named = chatTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        switch context.origin {
        case .reply, .thread:
            origin = .chat
            title = named.isEmpty ? "Chat" : chatTitle
        case .reader(let sourceTitle):
            // No chat yet: the source the words were read in names it.
            origin = .reader
            title = named.isEmpty ? sourceTitle : named
        }
        return ChatSideQuestionHandoff(
            chatTitle: title,
            openQuestion: openQuestion,
            turns: handoffTurns,
            sourceIDs: sourceIDs,
            notebookID: notebookID,
            origin: origin
        )
    }

    private func answer(into replyID: UUID) async {
        defer {
            isAnswering = false
            answerTask = nil
        }
        let asked = turns.compactMap { turn -> ChatSideQuestionHandoff.Turn? in
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return .init(speaker: turn.speaker, text: text)
        }
        do {
            if let sourceTextLoad {
                // Waiting on the read is not cancellable; a stop pressed
                // meanwhile takes effect once it lands, before any model call.
                let text = await sourceTextLoad.value
                context = context.withSourceText(text)
                self.sourceTextLoad = nil
                try Task.checkCancellation()
            }
            let context = context
            try await AIUsageAttribution.$sessionID.withValue(usageID) {
                try await AIUsageAttribution.$activityID.withValue(usageID) {
                    let stream = try await backend.answer(context: context, turns: asked)
                    for try await delta in stream {
                        try Task.checkCancellation()
                        append(delta, to: replyID)
                    }
                }
            }
            if text(of: replyID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                remove(replyID)
                // A stream cut short by a stop ends quietly, not as a failure:
                // the learner asked for the silence.
                if !Task.isCancelled {
                    errorMessage = ChatReplySideChatError.emptyAnswer.errorDescription
                }
            }
        } catch {
            // A stopped answer keeps what arrived; one stopped before any
            // words leaves no empty bubble behind, and no complaint either.
            if text(of: replyID).isEmpty { remove(replyID) }
            if !(error is CancellationError) && !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func append(_ delta: String, to replyID: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == replyID }) else { return }
        turns[index].text += delta
    }

    private func text(of replyID: UUID) -> String {
        turns.first(where: { $0.id == replyID })?.text ?? ""
    }

    private func remove(_ replyID: UUID) {
        turns.removeAll { $0.id == replyID }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
