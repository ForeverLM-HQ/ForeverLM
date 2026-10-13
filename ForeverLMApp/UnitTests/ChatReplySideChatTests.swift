import Foundation
import Testing
@testable import ForeverLM

/// "Ask in side chat" opens a small chat over the words, not a whole new chat
/// (`ChatReplySideChat`). The context is what the tutor reads about where the
/// words came from; the model is what the popover draws: the turns, the answer
/// streaming in, the field, and the way out to a full chat.
@Suite("Chat reply side chat")
struct ChatReplySideChatTests {
    private static let passage = "The matrix is electrically negative relative to the intermembrane space."
    private static let reply = "Mitochondrial membrane potential is one component of the proton-motive force.\n\n"
        + Self.passage

    private static func context(
        turns: [ChatSideQuestionHandoff.Turn] = [
            .init(speaker: .learner, text: "how is MMP different from the proton motive force"),
        ],
        openQuestion: String? = nil,
        chatTitle: String = "Sestamibi kinetics"
    ) -> ChatReplySideChatContext {
        ChatReplySideChatContext(
            passage: passage,
            replyText: reply,
            chatTitle: chatTitle,
            recentTurns: turns,
            openQuestion: openQuestion
        )
    }

    // MARK: - What the tutor reads

    @Test("The tutor reads the passage, the reply it came from, and the exchange before it, in that order")
    func contextNamesPassageReplyAndConversation() throws {
        let context = Self.context()
        let block = context.modelContext
        #expect(block.hasPrefix("<side_chat_context>"))
        #expect(block.hasSuffix("</side_chat_context>"))
        #expect(block.contains("in the chat \u{201C}Sestamibi kinetics\u{201D}"))
        let passageRange = try #require(block.range(of: "<selected_passage>\n\(Self.passage)\n</selected_passage>"))
        let replyRange = try #require(block.range(of: "<reply>\n\(Self.reply)\n</reply>"))
        let conversationRange = try #require(block.range(
            of: "<conversation>\nLearner: how is MMP different from the proton motive force\n</conversation>"
        ))
        #expect(passageRange.upperBound <= replyRange.lowerBound)
        #expect(replyRange.upperBound <= conversationRange.lowerBound)
        // Nothing was open, so nothing is protected.
        #expect(!block.contains("Open question:"))
        #expect(context.openQuestion == nil)
    }

    @Test("A side chat about the whole chat reads the conversation, with no passage or reply of its own")
    func threadSideChatReadsTheConversation() throws {
        let context = ChatReplySideChatContext(
            threadTitle: "Sestamibi kinetics",
            turns: [
                .init(speaker: .learner, text: "how is MMP different from the proton motive force"),
                .init(speaker: .tutor, text: Self.reply),
            ],
            openQuestion: "What sets the matrix potential?"
        )
        #expect(context.origin == .thread)
        let block = context.modelContext
        #expect(block.hasPrefix("<side_chat_context>"))
        #expect(block.hasSuffix("</side_chat_context>"))
        #expect(block.contains("beside the chat \u{201C}Sestamibi kinetics\u{201D}"))
        #expect(block.contains("Learner: how is MMP different from the proton motive force"))
        #expect(!block.contains("<selected_passage>"))
        #expect(!block.contains("<reply>"))
        #expect(block.contains("Open question: What sets the matrix potential?"))
    }

    @Test("A chat with no title and no earlier turns is described without them")
    func contextWithoutTitleOrConversation() {
        let context = Self.context(turns: [], chatTitle: "  ")
        let block = context.modelContext
        #expect(!block.contains("in the chat"))
        #expect(!block.contains("<conversation>"))
        #expect(context.chatTitle == "")
    }

    @Test("A review's open question travels with the words and is protected")
    func openQuestionIsProtected() {
        let context = Self.context(openQuestion: "  Why does sestamibi accumulate in the matrix?  ")
        #expect(context.openQuestion == "Why does sestamibi accumulate in the matrix?")
        let block = context.modelContext
        #expect(block.contains("Open question: Why does sestamibi accumulate in the matrix?"))
        #expect(block.contains("Do not give its answer away"))
    }

    @Test("The passage and the reply are clipped, and the exchange keeps its newest whole turns")
    func contextClipsToItsBudgets() {
        let long = String(repeating: "x", count: ChatReplySideChatContext.maximumPassageCharacters + 50)
        let context = ChatReplySideChatContext(
            passage: long,
            replyText: String(repeating: "y", count: ChatReplySideChatContext.replyCharacterBudget + 5),
            chatTitle: "Chat",
            recentTurns: [
                .init(speaker: .learner, text: String(repeating: "a", count: 5_000)),
                .init(speaker: .tutor, text: String(repeating: "b", count: 5_000)),
                .init(speaker: .learner, text: "   "),
                .init(speaker: .tutor, text: String(repeating: "c", count: 2_000)),
            ],
            openQuestion: nil
        )
        #expect(context.passage.count == ChatReplySideChatContext.maximumPassageCharacters + 1)
        #expect(context.passage.hasSuffix("…"))
        #expect(context.replyText.count == ChatReplySideChatContext.replyCharacterBudget + 1)
        // 2,000 + 5,000 fit an 8,000 budget; the oldest 5,000 does not, and
        // a blank turn is not a turn.
        #expect(context.recentTurns.map(\.speaker) == [.tutor, .tutor])
        #expect(context.recentTurns.map { $0.text.count } == [5_000, 2_000])

        // One turn larger than the whole budget is cut from its start, not dropped.
        let single = ChatReplySideChatContext.budgeted(
            [.init(speaker: .learner, text: String(repeating: "z", count: 20_000))],
            to: 100
        )
        #expect(single.count == 1)
        #expect(single[0].text.count == 101)
        #expect(single[0].text.hasPrefix("…"))
    }

    @Test("The chat's source text rides at the tail of the stable half, whole when it fits, and not in the volatile block")
    func sourceHeadCarriesTheChatsSourceText() {
        let paper = "## Source 1: Cristae flicker independently (paper, id: p1)\n\nIn Figure 2, the cristae depolarized at 9 s."
        let context = ChatReplySideChatContext(
            passage: Self.passage,
            replyText: Self.reply,
            chatTitle: "Cristae",
            recentTurns: [],
            openQuestion: nil,
            sourceText: "  \n" + paper + "\n "
        )
        let whole = context.sourceHead(characterBudget: nil)
        #expect(whole == "\n\n<chat_sources>\nThe source text loaded into the chat the words came from, as its tutor reads it:\n\n"
            + paper + "\n</chat_sources>")
        // Within the model's share it goes exactly as it does with no window.
        #expect(context.sourceHead(characterBudget: paper.count) == whole)
        // The passage block changes with every popover; the paper does not, so
        // it stays out of it and the cached head survives.
        #expect(!context.modelContext.contains("Cristae flicker independently"))
        #expect(!context.modelContext.contains("<chat_sources>"))
    }

    @Test("A source text longer than the model's share keeps its start, within the budget, and says the rest is out of reach")
    func sourceHeadCutsToTheBudget() throws {
        let context = ChatReplySideChatContext(
            passage: Self.passage,
            replyText: Self.reply,
            chatTitle: "Cristae",
            recentTurns: [],
            openQuestion: nil,
            sourceText: String(repeating: "p", count: 5_000)
        )
        let head = context.sourceHead(characterBudget: 1_000)
        let body = try #require(
            head.components(separatedBy: "as its tutor reads it:\n\n").last?
                .components(separatedBy: "\n</chat_sources>").first
        )
        #expect(body.count == 1_000)
        #expect(body.hasPrefix(String(repeating: "p", count: 900)))
        #expect(body.hasSuffix("\n\n" + ChatReplySideChatContext.sourceCutNote))
    }

    @Test("A chat with no source text loaded adds nothing to the side chat's prompt")
    func sourceHeadIsEmptyWithoutSourceText() {
        #expect(Self.context().sourceText == "")
        #expect(Self.context().sourceHead(characterBudget: nil) == "")
        let blank = ChatReplySideChatContext(
            passage: Self.passage, replyText: Self.reply, chatTitle: "c", recentTurns: [], openQuestion: nil,
            sourceText: " \n\t "
        )
        #expect(blank.sourceHead(characterBudget: 1_000) == "")
    }

    @Test("The heading is the passage on one line, cut where a line's worth ends")
    func passageHeadline() {
        let short = Self.context()
        #expect(short.passageHeadline == Self.passage)
        let wrapped = ChatReplySideChatContext(
            passage: "First   line\n\nsecond\tline", replyText: "r", chatTitle: "c", recentTurns: [], openQuestion: nil
        )
        #expect(wrapped.passageHeadline == "First line second line")
        let long = ChatReplySideChatContext(
            passage: String(repeating: "word ", count: 60), replyText: "r", chatTitle: "c", recentTurns: [], openQuestion: nil
        )
        #expect(long.passageHeadline.count == 158)
        #expect(long.passageHeadline.hasSuffix("…"))
    }

    @Test("The side chat's turns go to the model as user and assistant messages; a reply still empty is not one")
    func messagesForTurns() {
        let messages = ChatReplySideChatContext.messages(for: [
            .init(speaker: .learner, text: " What is Δψm? "),
            .init(speaker: .tutor, text: "The electrical part."),
            .init(speaker: .learner, text: "And the chemical part?"),
            .init(speaker: .tutor, text: ""),
        ])
        #expect(messages.map(\.role) == ["user", "assistant", "user"])
        #expect(messages.map(\.content) == ["What is Δψm?", "The electrical part.", "And the chemical part?"])
    }

    // MARK: - Where the popover opens

    private static let allowance = ChatReplySideChatPlacement.windowAllowance

    private static func placement(above: CGFloat, below: CGFloat, fullHeight: CGFloat) -> ChatReplySideChatPlacement {
        ChatReplySideChatPlacement.choose(room: .init(above: above, below: below), fullHeight: fullHeight)
    }

    @Test("With the words' place on the screen unknown, the popover opens below them with no limit but its own")
    func placementUnmeasured() {
        let placement = ChatReplySideChatPlacement.choose(room: nil, fullHeight: 560)
        #expect(placement == .unmeasured)
        #expect(placement.side == .below)
        #expect(placement.maximumHeight == nil)
    }

    @Test("With room for its full height below the words, the popover opens below, held to that room")
    func placementBelowWhenItFits() {
        let placement = Self.placement(above: 60, below: 900, fullHeight: 560)
        #expect(placement.side == .below)
        #expect(placement.maximumHeight == 900 - Self.allowance)
    }

    @Test("Below is kept whenever the full height fits there, even with more room above")
    func placementPrefersBelow() {
        let placement = Self.placement(above: 900, below: 700, fullHeight: 560)
        #expect(placement.side == .below)
        #expect(placement.maximumHeight == 700 - Self.allowance)
    }

    @Test("Words low on the screen: the popover opens above from the start, rather than jumping there mid-answer")
    func placementAboveWhenOnlyAboveHoldsIt() {
        // The harness case of 2026-09-27: 312 points below the words held the
        // empty popover, and its window outgrew them mid-answer at 313, when
        // macOS moved it above the words.
        let placement = Self.placement(above: 727, below: 312, fullHeight: 728)
        #expect(placement.side == .above)
        #expect(placement.maximumHeight == 727 - Self.allowance)
    }

    @Test("Where neither side holds the full height, the popover takes the side with more room and stays there; a tie goes below")
    func placementLargerSide() {
        let above = Self.placement(above: 527, below: 512, fullHeight: 728)
        #expect(above.side == .above)
        #expect(above.maximumHeight == 527 - Self.allowance)

        let below = Self.placement(above: 500, below: 520, fullHeight: 728)
        #expect(below.side == .below)
        #expect(below.maximumHeight == 520 - Self.allowance)

        let tie = Self.placement(above: 400, below: 400, fullHeight: 728)
        #expect(tie.side == .below)
        #expect(tie.maximumHeight == 400 - Self.allowance)
    }

    @Test("The popover's window takes the allowance beyond its content, so the full height fits below only with it")
    func placementCountsTheWindowAllowance() {
        let full: CGFloat = 560
        let exactly = Self.placement(above: 900, below: full + Self.allowance, fullHeight: full)
        #expect(exactly.side == .below)
        #expect(exactly.maximumHeight == full)

        let short = Self.placement(above: 900, below: full + Self.allowance - 1, fullHeight: full)
        #expect(short.side == .above)
        #expect(short.maximumHeight == 900 - Self.allowance)
    }

    @Test("Beside words with no room on either side, the popover still keeps its least height")
    func placementKeepsItsMinimum() {
        let tight = Self.placement(above: 60, below: 90, fullHeight: 560)
        #expect(tight.side == .below)
        #expect(tight.maximumHeight == ChatReplySideChatPlacement.minimumHeight)

        // Words partly off the screen leave no room on that side at all.
        let offTop = Self.placement(above: -40, below: 1_000, fullHeight: 560)
        #expect(offTop.side == .below)
        #expect(offTop.maximumHeight == 1_000 - Self.allowance)
        let offBottom = Self.placement(above: 1_000, below: -40, fullHeight: 560)
        #expect(offBottom.side == .above)
        #expect(offBottom.maximumHeight == 1_000 - Self.allowance)
    }

    @Test("The popover is sized at the chat's zoom, and at the default zoom it is wider than the old 400 points")
    @MainActor
    func popoverSizeFollowsTheZoom() {
        let defaultZoom = UIZoom.scale(for: UIZoom.defaultStep)
        #expect(ReviewChatSideChatPopover.width(zoom: 1) == ReviewChatSideChatPopover.baseWidth)
        #expect(ReviewChatSideChatPopover.fullHeight(zoom: 1) == ReviewChatSideChatPopover.baseFullHeight)
        #expect(ReviewChatSideChatPopover.fullHeight(zoom: 2) == 2 * ReviewChatSideChatPopover.baseFullHeight)
        #expect(ReviewChatSideChatPopover.width(zoom: defaultZoom) == (ReviewChatSideChatPopover.baseWidth * defaultZoom).rounded())
        #expect(ReviewChatSideChatPopover.width(zoom: defaultZoom) > 400)

        // Words a third of the way up a laptop's screen at the default zoom:
        // the full height does not fit below them, so the popover goes above.
        let placement = ChatReplySideChatPlacement.choose(
            room: .init(above: 727, below: 312),
            fullHeight: ReviewChatSideChatPopover.fullHeight(zoom: defaultZoom)
        )
        #expect(placement.side == .above)
    }

    // MARK: - The popover's model

    @Test("A model opened without the words' place on the screen opens below them, unlimited")
    @MainActor
    func modelDefaultsToUnmeasuredPlacement() {
        let model = Self.model(ScriptedBackend(.refusal))
        #expect(model.placement == .unmeasured)
        let placed = ChatReplySideChatModel(
            messageID: UUID(),
            anchor: nil,
            placement: Self.placement(above: 727, below: 312, fullHeight: 728),
            context: Self.context(),
            backend: ScriptedBackend(.refusal)
        )
        #expect(placed.placement.side == .above)
        #expect(placed.anchor == nil)
    }

    /// Streams a scripted answer, or refuses, and remembers what it was asked.
    private final class ScriptedBackend: ChatReplySideChatBackend, @unchecked Sendable {
        enum Script {
            case deltas([String], delayMilliseconds: Int = 0)
            case refusal
        }

        let script: Script
        private(set) var asked: [[ChatSideQuestionHandoff.Turn]] = []
        private(set) var contexts: [ChatReplySideChatContext] = []

        init(_ script: Script) {
            self.script = script
        }

        func answer(
            context: ChatReplySideChatContext,
            turns: [ChatSideQuestionHandoff.Turn]
        ) async throws -> AsyncThrowingStream<String, Error> {
            asked.append(turns)
            contexts.append(context)
            switch script {
            case .refusal:
                throw ChatReplySideChatError.noModelConfigured
            case .deltas(let deltas, let delay):
                return AsyncThrowingStream { continuation in
                    let task = Task {
                        for delta in deltas {
                            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                            if Task.isCancelled { break }
                            continuation.yield(delta)
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        }
    }

    @MainActor
    private static func model(_ backend: ScriptedBackend, openQuestion: String? = nil) -> ChatReplySideChatModel {
        ChatReplySideChatModel(
            messageID: UUID(),
            anchor: CGRect(x: 10, y: 20, width: 200, height: 17),
            context: context(openQuestion: openQuestion),
            backend: backend
        )
    }

    @MainActor
    private static func settled(_ model: ChatReplySideChatModel) async throws {
        for _ in 0..<300 where model.isAnswering {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isAnswering)
    }

    @Test("A question goes out as a learner turn and the answer streams into the tutor turn under it")
    @MainActor
    func askStreamsAnAnswer() async throws {
        let backend = ScriptedBackend(.deltas(["The matrix ", "is negative ", "because protons are pumped out."]))
        let model = Self.model(backend)
        #expect(!model.hasExchange)
        model.draft = "  why negative?  "
        model.ask(model.draft)
        #expect(model.draft == "")
        #expect(model.isAnswering)
        #expect(model.turns.map(\.speaker) == [.learner, .tutor])
        #expect(model.turns[0].text == "why negative?")
        try await Self.settled(model)
        #expect(model.turns.map(\.text) == ["why negative?", "The matrix is negative because protons are pumped out."])
        #expect(model.errorMessage == nil)
        #expect(model.hasExchange)
        // The model was asked with the exchange so far: the question alone.
        #expect(backend.asked == [[.init(speaker: .learner, text: "why negative?")]])

        // A follow-up carries the whole exchange.
        model.ask("and the chemical part?")
        try await Self.settled(model)
        #expect(model.turns.count == 4)
        #expect(backend.asked.last?.map(\.text) == [
            "why negative?",
            "The matrix is negative because protons are pumped out.",
            "and the chemical part?",
        ])
    }

    @Test("A refused answer leaves the question standing, no empty bubble, and the reason under it")
    @MainActor
    func refusalLeavesNoEmptyBubble() async throws {
        let model = Self.model(ScriptedBackend(.refusal))
        model.ask("why negative?")
        try await Self.settled(model)
        #expect(model.turns.map(\.speaker) == [.learner])
        #expect(model.errorMessage == ChatReplySideChatError.noModelConfigured.errorDescription)
        // Asking again clears the reason.
        model.ask("once more")
        #expect(model.errorMessage == nil)
        try await Self.settled(model)
    }

    @Test("An answer that streamed nothing is reported rather than drawn empty")
    @MainActor
    func emptyAnswerIsReported() async throws {
        let model = Self.model(ScriptedBackend(.deltas(["  ", "\n"])))
        model.ask("why negative?")
        try await Self.settled(model)
        #expect(model.turns.map(\.speaker) == [.learner])
        #expect(model.errorMessage == ChatReplySideChatError.emptyAnswer.errorDescription)
    }

    @Test("A blank send, or one while an answer is being written, is refused")
    @MainActor
    func blankAndBusySendsAreRefused() async throws {
        let model = Self.model(ScriptedBackend(.deltas(["slow ", "answer"], delayMilliseconds: 60)))
        model.ask("   ")
        #expect(model.turns.isEmpty)
        #expect(!model.isAnswering)

        model.ask("first")
        model.draft = "second"
        model.ask("second")
        #expect(model.turns.count == 2, "the second question waits in the field")
        #expect(model.draft == "second")
        try await Self.settled(model)
        #expect(model.turns.map(\.text) == ["first", "slow answer"])
    }

    @Test("Stopping keeps what arrived; stopping before any words leaves no bubble")
    @MainActor
    func cancelKeepsPartialAnswer() async throws {
        let model = Self.model(ScriptedBackend(.deltas(["part ", "two ", "three"], delayMilliseconds: 40)))
        model.ask("go on")
        for _ in 0..<200 where model.turns.last?.text.isEmpty ?? true {
            try await Task.sleep(for: .milliseconds(5))
        }
        model.cancel()
        try await Self.settled(model)
        #expect(model.turns.count == 2)
        #expect(model.turns[1].text.hasPrefix("part"))
        #expect(model.errorMessage == nil)

        let early = Self.model(ScriptedBackend(.deltas(["never"], delayMilliseconds: 500)))
        early.ask("go on")
        early.cancel()
        try await Self.settled(early)
        #expect(early.turns.map(\.speaker) == [.learner])
        #expect(early.errorMessage == nil)
    }

    @Test("Words selected in the side chat's own reply are quoted into its field, ahead of what is typed")
    @MainActor
    func quoteGoesIntoTheField() {
        let model = Self.model(ScriptedBackend(.refusal))
        model.quote("  ")
        #expect(model.draft == "")
        model.quote("Protons are pumped out.")
        #expect(model.draft == "> Protons are pumped out.\n\n")
        model.draft += "by which complexes?"
        model.quote("Complex I\n\nComplex IV")
        #expect(model.draft == "> Complex I\n>\n> Complex IV\n\n> Protons are pumped out.\n\nby which complexes?")
    }

    @Test("Moving to a new chat carries the exchange as a side question, with the passage quoted into the first line")
    @MainActor
    func handoffCarriesTheExchange() async throws {
        let model = Self.model(ScriptedBackend(.deltas(["Because protons are pumped out."])), openQuestion: "What sets Δψm?")
        #expect(model.handoff(chatTitle: "Sestamibi kinetics", openQuestion: nil, sourceIDs: ["s1"], notebookID: nil) == nil)

        model.ask("why negative?")
        try await Self.settled(model)
        let handoff = try #require(model.handoff(
            chatTitle: "Sestamibi kinetics",
            openQuestion: model.context.openQuestion,
            sourceIDs: ["s1", "s2"],
            notebookID: "p1"
        ))
        #expect(handoff.chatTitle == "Sestamibi kinetics")
        #expect(handoff.openQuestion == "What sets Δψm?")
        #expect(handoff.sourceIDs == ["s1", "s2"])
        #expect(handoff.notebookID == "p1")
        #expect(handoff.turns.map(\.speaker) == [.learner, .tutor])
        #expect(handoff.turns[0].text == "> \(Self.passage)\n\nwhy negative?")
        #expect(handoff.turns[1].text == "Because protons are pumped out.")
        // The chip's line is the question, not the quote.
        #expect(handoff.headline == "why negative?")

        // A chat with no title is called Chat, as a side question's is.
        let untitled = try #require(model.handoff(chatTitle: " ", openQuestion: nil, sourceIDs: [], notebookID: nil))
        #expect(untitled.chatTitle == "Chat")
        #expect(untitled.origin == .chat)
    }

    // MARK: - In the Reader

    private static let sourceTitle = "Mitochondrial membrane potential in health and disease"

    @Test("Words selected in the Reader are read in their source: no reply, no conversation, no open question")
    func readerContextNamesTheSource() throws {
        let context = ChatReplySideChatContext(
            readerPassage: "  \(Self.passage)\n",
            sourceTitle: "  \(Self.sourceTitle) ",
            sourceText: "Mitochondria hold a membrane potential of about 150 mV."
        )
        #expect(context.origin == .reader(sourceTitle: Self.sourceTitle))
        #expect(context.passage == Self.passage)
        let block = context.modelContext
        #expect(block.hasPrefix("<side_chat_context>"))
        #expect(block.hasSuffix("</side_chat_context>"))
        #expect(block.contains("while reading \u{201C}\(Self.sourceTitle)\u{201D} in the Reader"))
        #expect(block.contains("<selected_passage>\n\(Self.passage)\n</selected_passage>"))
        #expect(!block.contains("<reply>"))
        #expect(!block.contains("<conversation>"))
        #expect(!block.contains("Open question:"))

        // The source's text is the stable half's tail, named as the source.
        let head = context.sourceHead(characterBudget: nil)
        #expect(head.hasPrefix("\n\n<source_text>\n"))
        #expect(head.contains("the source the learner is reading, \u{201C}\(Self.sourceTitle)\u{201D}:"))
        #expect(head.contains("about 150 mV"))
        #expect(head.hasSuffix("</source_text>"))
        #expect(!head.contains("<chat_sources>"))
        #expect(!block.contains("150 mV"))

        let untitled = ChatReplySideChatContext(readerPassage: Self.passage, sourceTitle: " ")
        #expect(untitled.modelContext.contains("while reading a source in the Reader"))
        #expect(untitled.sourceHead(characterBudget: nil) == "")
    }

    @Test("A side chat the Reader opens shows before the source's text is read, and its first answer waits for the text")
    @MainActor
    func readerSideChatWaitsForTheSourceText() async throws {
        let backend = ScriptedBackend(.deltas(["About 150 mV."]))
        let load = Task<String, Never> {
            try? await Task.sleep(for: .milliseconds(80))
            return "Mitochondria hold a membrane potential of about 150 mV."
        }
        let model = ChatReplySideChatModel(
            messageID: UUID(),
            anchor: nil,
            context: ChatReplySideChatContext(readerPassage: Self.passage, sourceTitle: Self.sourceTitle),
            backend: backend,
            sourceTextLoad: load
        )
        #expect(model.context.sourceText == "")
        model.ask("how negative?")
        #expect(model.isAnswering)
        try await Self.settled(model)
        #expect(model.turns.map(\.text) == ["how negative?", "About 150 mV."])
        #expect(backend.contexts.first?.sourceText == "Mitochondria hold a membrane potential of about 150 mV.")
        #expect(model.context.sourceText == "Mitochondria hold a membrane potential of about 150 mV.")

        // The follow-up reads the same text, without reading it again.
        model.ask("and in disease?")
        try await Self.settled(model)
        #expect(backend.contexts.count == 2)
        #expect(backend.contexts.last?.sourceText == backend.contexts.first?.sourceText)
    }

    @Test("Stopped while the source's text is still being read, a Reader side chat asks no model and leaves no bubble")
    @MainActor
    func readerSideChatStoppedBeforeTheText() async throws {
        let backend = ScriptedBackend(.deltas(["never"]))
        let load = Task<String, Never> {
            try? await Task.sleep(for: .milliseconds(120))
            return "text"
        }
        let model = ChatReplySideChatModel(
            messageID: UUID(),
            anchor: nil,
            context: ChatReplySideChatContext(readerPassage: Self.passage, sourceTitle: Self.sourceTitle),
            backend: backend,
            sourceTextLoad: load
        )
        model.ask("how negative?")
        model.cancel()
        try await Self.settled(model)
        #expect(backend.asked.isEmpty)
        #expect(model.turns.map(\.speaker) == [.learner])
        #expect(model.errorMessage == nil)
    }

    @Test("A Reader side chat moves to a new chat framed as the Reader's and named by its source")
    @MainActor
    func readerHandoffIsFramedAsTheReaders() async throws {
        let model = ChatReplySideChatModel(
            messageID: UUID(),
            anchor: nil,
            context: ChatReplySideChatContext(readerPassage: Self.passage, sourceTitle: Self.sourceTitle),
            backend: ScriptedBackend(.deltas(["Because protons are pumped out."]))
        )
        model.ask("why negative?")
        try await Self.settled(model)
        let handoff = try #require(model.handoff(chatTitle: " ", openQuestion: nil, sourceIDs: ["s1"], notebookID: nil))
        #expect(handoff.origin == .reader)
        #expect(handoff.chatTitle == Self.sourceTitle)
        #expect(handoff.turns[0].text == "> \(Self.passage)\n\nwhy negative?")
        #expect(handoff.headline == "why negative?")
        let content = handoff.contextualContent
        #expect(content.hasPrefix("From a side chat over a passage of \"\(Self.sourceTitle)\" in the Reader:"))
        #expect(content.contains(ChatSideQuestionHandoff.readerFraming))
        #expect(!content.contains("quiz"))

        let request = ReaderSelectionExplanationRequest(sideQuestionHandoff: handoff)
        #expect(request.sourceIDs == ["s1"])
        #expect(request.contextTitle == "Side chat on: \(Self.sourceTitle)")
        #expect(request.contextualContent() == content)
    }
}
