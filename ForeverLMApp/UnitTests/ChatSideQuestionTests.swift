import Foundation
import Testing
@testable import ForeverLM

/// A side question: asked while the tutor's question is open, answered
/// without being graded, followed up in its own lane or taken to a new chat,
/// folded away once the quiz moves on.
@Suite("Chat side questions")
struct ChatSideQuestionTests {

    // MARK: - The open question

    @Test("A reply that ends in a question leaves it open, in plain text")
    func openQuestionIsTheLastParagraph() {
        let reply = """
        Correct. The sample may have **abundant mitochondrial material**, but low respiratory function.

        One caveat: mtDNA copy number and citrate synthase are imperfect content markers.

        Why can an increase in **mitochondrial ROS** not automatically be interpreted as mitochondrial dysfunction?
        """
        #expect(ChatSideQuestion.openQuestion(in: reply)
            == "Why can an increase in mitochondrial ROS not automatically be interpreted as mitochondrial dysfunction?")
    }

    @Test("A reply that ends in a statement leaves nothing open")
    func statementLeavesNothingOpen() {
        #expect(ChatSideQuestion.openQuestion(in: "Is it ATP?\n\nNo: it is the membrane potential that drops first.") == nil)
        #expect(ChatSideQuestion.openQuestion(in: "   \n") == nil)
    }

    @Test("A quoted or bulleted question still counts, without its dressing")
    func plainLineStripsDressing() {
        #expect(ChatSideQuestion.openQuestion(in: "- *What does GDF15 track?*") == "What does GDF15 track?")
        #expect(ChatSideQuestion.openQuestion(in: "> “Which came first?”") == "Which came first?")
        #expect(ChatSideQuestion.plainLine("## `OCR` per **unit**") == "OCR per unit")
    }

    // MARK: - The mark beside the message

    @Test("The mark round-trips with the open question and any passage the message carried")
    func contextRoundTrips() {
        let stored = ChatSideQuestion.contextContent(
            openQuestion: "Why can an increase in **ROS** not be read as dysfunction?",
            referenceContext: "> Two heart failure patients may both present with preserved ejection fraction.\n\nSource: Mitochondrial Phenotyping"
        )
        let parsed = ChatSideQuestion.parse(contextContent: stored)
        #expect(parsed.isSideQuestion)
        #expect(parsed.openQuestion == "Why can an increase in ROS not be read as dysfunction?")
        #expect(parsed.referenceContext == "> Two heart failure patients may both present with preserved ejection fraction.\n\nSource: Mitochondrial Phenotyping")
    }

    @Test("A mark alone is a side question with nothing else to say")
    func bareMark() {
        let parsed = ChatSideQuestion.parse(contextContent: ChatSideQuestion.contextContent(openQuestion: nil))
        #expect(parsed == .init(isSideQuestion: true, openQuestion: nil, referenceContext: nil))
        #expect(ChatSideQuestion.isSideQuestion(contextContent: "<flm_side_question/>"))
    }

    @Test("A passage without the mark is an ordinary message with reference material")
    func passageWithoutMark() {
        let parsed = ChatSideQuestion.parse(contextContent: "> a quoted passage\n\nSource: A paper")
        #expect(parsed == .init(isSideQuestion: false, openQuestion: nil, referenceContext: "> a quoted passage\n\nSource: A paper"))
        #expect(ChatSideQuestion.parse(contextContent: nil) == .init(isSideQuestion: false, openQuestion: nil, referenceContext: nil))
        #expect(ChatSideQuestion.parse(contextContent: "  ") == .init(isSideQuestion: false, openQuestion: nil, referenceContext: nil))
    }

    @Test("A message reads its own mark")
    @MainActor
    func messageReadsMark() {
        let aside = ReviewSessionManager.Message(
            role: .user,
            content: "what do they see in patients?",
            contextualContent: ChatSideQuestion.contextContent(openQuestion: "Why not dysfunction?")
        )
        let answer = ReviewSessionManager.Message(role: .user, content: "because ROS also signals")
        let tutor = ReviewSessionManager.Message(
            role: .assistant,
            content: "Why?",
            contextualContent: ChatSideQuestion.marker
        )
        #expect(aside.isSideQuestion)
        #expect(!answer.isSideQuestion)
        #expect(!tutor.isSideQuestion)
    }

    // MARK: - What the tutor is told

    @Test("The tutor is told not to grade a side question, outside the reference wrapper")
    @MainActor
    func tutorIsToldAboutTheAside() {
        let contents = ReviewSessionManager.providerContentsForTesting(learnerTurns: [
            (
                visible: "what do they see, then, in patients with primary mitochondrial diseases?",
                context: ChatSideQuestion.contextContent(
                    openQuestion: "Why can an increase in ROS not be read as dysfunction?",
                    referenceContext: "> a quoted passage\n\nSource: Picard 2022"
                )
            ),
        ]).joined(separator: "\n")

        #expect(contents.contains("what do they see, then, in patients"))
        #expect(contents.contains("<side_question>"))
        #expect(contents.contains("do not grade it"))
        #expect(contents.contains("Open question: Why can an increase in ROS not be read as dysfunction?"))
        // The passage keeps its wrapper; the mark and the question stay out of it.
        #expect(contents.contains("<reader_selection_context>"))
        #expect(contents.contains("Source: Picard 2022"))
        #expect(!contents.contains("<flm_side_question/>"))
        let wrapperRange = contents.range(of: "<reader_selection_context>")!
        let wrapperEnd = contents.range(of: "</reader_selection_context>")!
        let insideWrapper = contents[wrapperRange.upperBound..<wrapperEnd.lowerBound]
        #expect(!insideWrapper.contains("Open question:"))
        #expect(!insideWrapper.contains("<side_question>"))
    }

    @Test("The tutor is told not to give the open question's answer away")
    func framingGuardsTheOpenQuestion() {
        let framing = ChatSideQuestion.framing(openQuestion: "Why is that result not sufficient by itself?")
        #expect(framing.contains("Do not give its answer away"))
        #expect(framing.contains("what the open question is asking"))
        #expect(framing.contains("Open question: Why is that result not sufficient by itself?"))
    }

    @Test("The answer after a side question is read against the tutor's question")
    @MainActor
    func answerAfterAsideIsFramed() {
        let contents = ReviewSessionManager.providerContentsForTesting(learnerTurns: [
            (visible: "what do they see in patients?", context: ChatSideQuestion.contextContent(openQuestion: "Why not dysfunction?")),
            (visible: "because ROS is also a signal", context: nil),
            (visible: "and what about GDF15?", context: nil),
        ]).joined(separator: "\n")

        let closing = contents.ranges(of: "<side_question_closed>")
        #expect(closing.count == 1)
        let framing = contents.range(of: "<side_question>")!
        let answer = contents.range(of: "because ROS is also a signal")!
        let third = contents.range(of: "and what about GDF15?")!
        #expect(framing.lowerBound < answer.lowerBound)
        #expect(answer.lowerBound < closing[0].lowerBound)
        #expect(closing[0].lowerBound < third.lowerBound)
    }

    @Test("An ordinary passage message is framed as before")
    @MainActor
    func ordinaryPassageUnchanged() {
        let contents = ReviewSessionManager.providerContentsForTesting(learnerTurns: [
            (visible: "What is preserved ejection fraction?", context: "> a quoted passage\n\nSource: Mitochondrial Phenotyping"),
        ]).joined(separator: "\n")
        #expect(contents.contains("<reader_selection_context>"))
        #expect(!contents.contains("<side_question>"))
        #expect(!contents.contains("<side_question_closed>"))
    }

    // MARK: - The lane in the transcript

    @MainActor
    private func transcript() -> [ReviewSessionManager.Message] {
        [
            .init(role: .assistant, content: "Let's begin. What was the paper about?"),
            .init(role: .user, content: "mitochondrial phenotyping across levels"),
            .init(role: .assistant, content: "Good.\n\nWhy can an increase in **ROS** not be read as dysfunction?"),
            .init(role: .user, content: "what do they see in patients?",
                  contextualContent: ChatSideQuestion.contextContent(openQuestion: "Why can an increase in ROS not be read as dysfunction?")),
            .init(role: .assistant, content: "Picard's patients show inefficient energy transformation."),
            .init(role: .user, content: "because ROS also signals"),
            .init(role: .assistant, content: "Right. Next: what does GDF15 track?"),
        ]
    }

    @Test("A side question and its reply form one lane; the quiz stays flush")
    @MainActor
    func asideFormsOneLane() {
        let blocks = ReviewChatTranscriptBlock.grouping(transcript())
        let sections = ReviewChatTranscriptSection.grouping(blocks)

        #expect(sections.map(\.isSideQuestion) == [false, false, false, true, false, false])
        let lane = sections[3]
        #expect(lane.blocks.count == 2)
        #expect(lane.sideQuestionMessage?.content == "what do they see in patients?")
        #expect(lane.openQuestion == "Why can an increase in ROS not be read as dysfunction?")
        #expect(sections.filter { !$0.isSideQuestion }.allSatisfy { $0.blocks.count == 1 && $0.openQuestion == nil })
    }

    @Test("The open question is read off the reply above when the mark carries none")
    @MainActor
    func openQuestionFallsBackToTheReplyAbove() {
        var messages = transcript()
        messages[3] = .init(role: .user, content: "what do they see in patients?", contextualContent: ChatSideQuestion.marker)
        let sections = ReviewChatTranscriptSection.grouping(ReviewChatTranscriptBlock.grouping(messages))
        #expect(sections[3].openQuestion == "Why can an increase in ROS not be read as dysfunction?")
    }

    @Test("A side question with no reply yet is a lane of one")
    @MainActor
    func unansweredAsideIsALaneOfOne() {
        let messages = Array(transcript().prefix(4))
        let sections = ReviewChatTranscriptSection.grouping(ReviewChatTranscriptBlock.grouping(messages))
        #expect(sections.last?.isSideQuestion == true)
        #expect(sections.last?.blocks.count == 1)
    }

    @Test("A follow-up side question joins the lane, so one detour folds to one heading")
    @MainActor
    func followUpJoinsTheLane() {
        var messages = Array(transcript().prefix(5))
        messages.append(.init(role: .user, content: "and GDF15?", contextualContent: ChatSideQuestion.marker))
        messages.append(.init(role: .assistant, content: "GDF15 tracks severity."))
        let sections = ReviewChatTranscriptSection.grouping(ReviewChatTranscriptBlock.grouping(messages))
        #expect(sections.map(\.isSideQuestion) == [false, false, false, true])
        let lane = sections[3]
        #expect(lane.blocks.count == 4)
        #expect(lane.sideQuestionMessage?.content == "what do they see in patients?")
        // The lane keeps the question that was open when the detour began: the
        // reply to the first aside did not change what was open.
        #expect(lane.openQuestion == "Why can an increase in ROS not be read as dysfunction?")
    }

    @Test("An ordinary answer closes the lane; the next side question starts another")
    @MainActor
    func ordinaryAnswerClosesTheLane() {
        var messages = transcript()
        messages.append(.init(role: .user, content: "what is GDF15, actually?", contextualContent: ChatSideQuestion.marker))
        messages.append(.init(role: .assistant, content: "A stress-responsive cytokine."))
        let sections = ReviewChatTranscriptSection.grouping(ReviewChatTranscriptBlock.grouping(messages))
        #expect(sections.map(\.isSideQuestion) == [false, false, false, true, false, false, true])
        #expect(sections[6].openQuestion == "Right. Next: what does GDF15 track?")
    }

    // MARK: - Out to a new chat

    @Test("The lane reads back as turns: the aside, its replies, and the follow-ups")
    @MainActor
    func laneReadsBackAsTurns() {
        var messages = Array(transcript().prefix(5))
        messages.append(.init(role: .user, content: "and GDF15?", contextualContent: ChatSideQuestion.marker))
        messages.append(.init(role: .assistant, content: "GDF15 tracks severity."))
        let lane = ReviewChatTranscriptSection.grouping(ReviewChatTranscriptBlock.grouping(messages))[3]
        #expect(lane.sideQuestionTurns == [
            .init(speaker: .learner, text: "what do they see in patients?"),
            .init(speaker: .tutor, text: "Picard's patients show inefficient energy transformation."),
            .init(speaker: .learner, text: "and GDF15?"),
            .init(speaker: .tutor, text: "GDF15 tracks severity."),
        ])
        // An ordinary section has no side question to hand over.
        let sections = ReviewChatTranscriptSection.grouping(ReviewChatTranscriptBlock.grouping(transcript()))
        #expect(sections[2].sideQuestionTurns.isEmpty)
    }

    private var handoff: ChatSideQuestionHandoff {
        ChatSideQuestionHandoff(
            chatTitle: "Mito Phenotyping",
            openQuestion: "How does ³¹P-MRS provide information about muscle mitochondrial function without taking a biopsy?",
            turns: [
                .init(speaker: .learner, text: "i don't know, and i don't really know how **31P-MRS** works"),
                .init(speaker: .tutor, text: "³¹P-MRS means phosphorus-31 magnetic resonance spectroscopy.\n\nIt uses the same physics as MRI."),
            ],
            sourceIDs: ["src-picard"],
            notebookID: "proj-mito"
        )
    }

    @Test("The handoff's chip line is the side question's first line, in plain text")
    func handoffHeadline() {
        #expect(handoff.headline == "i don't know, and i don't really know how 31P-MRS works")
        let untitled = ChatSideQuestionHandoff(
            chatTitle: "Picard review", openQuestion: nil, turns: [], sourceIDs: [], notebookID: nil
        )
        #expect(untitled.headline == "A side question from Picard review")
    }

    @Test("The model gets the exchange, the open question for orientation, and leave to hold nothing back")
    func handoffContext() {
        let context = handoff.contextualContent
        #expect(context.hasPrefix("From a side question in the chat \"Mito Phenotyping\":"))
        #expect(context.contains("Learner: i don't know, and i don't really know how **31P-MRS** works"))
        #expect(context.contains("Tutor: ³¹P-MRS means phosphorus-31 magnetic resonance spectroscopy."))
        #expect(context.contains("for orientation only: How does ³¹P-MRS provide information"))
        #expect(context.contains("nothing is held back here"))
        #expect(context.contains("Do not grade them"))
        // The learner's own words are labelled turns, never a reply's tag.
        #expect(!context.contains("<side_question>"))
    }

    @Test("As a selection request: the chip shows the question, the model gets the exchange, the chat gets the sources and the Notebook")
    func handoffAsSelectionRequest() {
        let request = ReaderSelectionExplanationRequest(sideQuestionHandoff: handoff)
        #expect(request.selectedText == handoff.headline)
        #expect(request.sourceIDs == ["src-picard"])
        #expect(request.contextTitle == "Side question from: Mito Phenotyping")
        #expect(request.sideQuestionHandoff == handoff)
        #expect(request.sideQuestionHandoff?.notebookID == "proj-mito")
        #expect(request.reviewHandoff == nil)
        // Not a passage: the exchange block replaces the "Selected passage"
        // shape, and there is no doc to anchor a link to.
        #expect(request.contextualContent(fallbackTitle: "Picard 2022") == handoff.contextualContent)
        #expect(request.docAnchor == nil)
    }

    // MARK: - More details, and asides about any reply

    @Test("A More details press stores a second mark, the reply it is about, and the open question")
    func moreDetailsMarkRoundTrips() {
        let stored = ChatSideQuestion.contextContent(
            openQuestion: "Why can an increase in **ROS** not be read as dysfunction?",
            aboutReply: "Correct. The sample may have **abundant mitochondrial material**, but low respiratory function.",
            moreDetails: true,
            referenceContext: "> a quoted passage\n\nSource: Picard 2022"
        )
        #expect(stored.hasPrefix("<flm_side_question/>\n<flm_more_details/>\n"))
        let parsed = ChatSideQuestion.parse(contextContent: stored)
        #expect(parsed.isSideQuestion)
        #expect(parsed.isMoreDetails)
        #expect(parsed.aboutReply == "Correct. The sample may have abundant mitochondrial material, but low respiratory function.")
        #expect(parsed.openQuestion == "Why can an increase in ROS not be read as dysfunction?")
        #expect(parsed.referenceContext == "> a quoted passage\n\nSource: Picard 2022")
        #expect(ChatSideQuestion.isMoreDetails(contextContent: stored))
        #expect(ChatSideQuestion.isSideQuestion(contextContent: stored))
    }

    @Test("A side question about an older reply names it; a side question from before the widening reads back as it was")
    func aboutReplyRoundTrips() {
        let stored = ChatSideQuestion.contextContent(openQuestion: nil, aboutReply: "Picard's patients show *inefficient* energy transformation.")
        let parsed = ChatSideQuestion.parse(contextContent: stored)
        #expect(parsed == .init(
            isSideQuestion: true, openQuestion: nil, referenceContext: nil,
            isMoreDetails: false, aboutReply: "Picard's patients show inefficient energy transformation."
        ))

        let bare = ChatSideQuestion.parse(contextContent: "<flm_side_question/>\nOpen question: Why not dysfunction?\n\n> a passage")
        #expect(bare == .init(isSideQuestion: true, openQuestion: "Why not dysfunction?", referenceContext: "> a passage"))
        #expect(!bare.isMoreDetails)
        #expect(bare.aboutReply == nil)
    }

    @Test("A reply is named by its first paragraph, in plain text, cut to a line")
    func replyLineIsTheFirstParagraph() {
        #expect(ChatSideQuestion.replyLine(in: "\n\n## **Good.**\n\nWhy can an increase in ROS not be read as dysfunction?") == "Good.")
        #expect(ChatSideQuestion.replyLine(in: "   \n") == nil)
        let long = String(repeating: "mitochondria ", count: 20)
        let line = ChatSideQuestion.replyLine(in: long)!
        #expect(line.hasSuffix("…"))
        #expect(line.count <= 161)
    }

    @Test("A message reads the More details mark")
    @MainActor
    func messageReadsMoreDetailsMark() {
        let press = ReviewSessionManager.Message(
            role: .user,
            content: ChatSideQuestion.moreDetailsQuestion,
            contextualContent: ChatSideQuestion.contextContent(openQuestion: nil, aboutReply: "Good.", moreDetails: true)
        )
        let aside = ReviewSessionManager.Message(
            role: .user, content: "what do they see?", contextualContent: ChatSideQuestion.marker
        )
        #expect(press.isSideQuestion)
        #expect(press.isMoreDetailsRequest)
        #expect(aside.isSideQuestion)
        #expect(!aside.isMoreDetailsRequest)
    }

    @Test("More details asks the tutor to expand the named reply and still guards the open question")
    func moreDetailsFramingGuardsTheOpenQuestion() {
        let framing = ChatSideQuestion.framing(
            openQuestion: "Why is that result not sufficient by itself?",
            aboutReply: "Correct. The sample may have abundant mitochondrial material.",
            moreDetails: true
        )
        #expect(framing.hasPrefix("<more_details>"))
        #expect(framing.hasSuffix("</more_details>"))
        #expect(framing.contains("pressed More details"))
        #expect(framing.contains("the one that begins “Correct. The sample may have abundant mitochondrial material.”"))
        #expect(framing.contains("worked example"))
        #expect(framing.contains("do not ask a new review question"))
        #expect(framing.contains("Do not give its answer away"))
        #expect(framing.contains("Open question: Why is that result not sufficient by itself?"))
        #expect(!framing.contains("<side_question>"))
    }

    @Test("With nothing open, More details and a side question both drop the guard")
    func nothingOpenDropsTheGuard() {
        let details = ChatSideQuestion.framing(openQuestion: nil, aboutReply: "Good.", moreDetails: true)
        #expect(details.contains("pressed More details"))
        #expect(!details.contains("Do not give its answer away"))
        #expect(!details.contains("Open question:"))

        let aside = ChatSideQuestion.framing(openQuestion: nil, aboutReply: "Picard's patients show inefficient energy transformation.")
        #expect(aside.hasPrefix("<side_question>"))
        #expect(aside.contains("asked beside the conversation rather than as its next step"))
        #expect(aside.contains("about your reply — the one that begins “Picard's patients show inefficient energy transformation.”"))
        #expect(aside.contains("do not ask a review question of your own"))
        #expect(!aside.contains("Do not give its answer away"))
        #expect(!aside.contains("Open question:"))

        // The original shape is untouched: a side question while a question is open.
        let quiz = ChatSideQuestion.framing(openQuestion: "Why not dysfunction?")
        #expect(quiz.contains("asked while your question was still open. Answer it"))
        #expect(quiz.contains("Do not give its answer away"))
    }

    @Test("The tutor reads the More details mark and the reply it names, outside the reference wrapper")
    @MainActor
    func tutorIsToldAboutMoreDetails() {
        let contents = ReviewSessionManager.providerContentsForTesting(learnerTurns: [
            (
                visible: ChatSideQuestion.moreDetailsQuestion,
                context: ChatSideQuestion.contextContent(
                    openQuestion: "Why not dysfunction?",
                    aboutReply: "Good.",
                    moreDetails: true,
                    referenceContext: "> a quoted passage\n\nSource: Picard 2022"
                )
            ),
        ]).joined(separator: "\n")
        #expect(contents.contains("<more_details>"))
        #expect(contents.contains("the one that begins “Good.”"))
        #expect(contents.contains("Open question: Why not dysfunction?"))
        #expect(contents.contains("<reader_selection_context>"))
        #expect(!contents.contains("<flm_more_details/>"))
        #expect(!contents.contains("<flm_side_question/>"))
        let wrapperRange = contents.range(of: "<reader_selection_context>")!
        let wrapperEnd = contents.range(of: "</reader_selection_context>")!
        let insideWrapper = contents[wrapperRange.upperBound..<wrapperEnd.lowerBound]
        #expect(!insideWrapper.contains("About the reply:"))
        #expect(!insideWrapper.contains("<more_details>"))
    }

    @Test("The message after an aside with nothing open resumes the conversation rather than answering a question")
    @MainActor
    func closingAfterAsideWithNothingOpen() {
        let contents = ReviewSessionManager.providerContentsForTesting(learnerTurns: [
            (visible: "what is GDF15, actually?", context: ChatSideQuestion.contextContent(openQuestion: nil, aboutReply: "Good.")),
            (visible: "ok, tell me about the second paper", context: nil),
        ]).joined(separator: "\n")
        #expect(contents.contains("<side_question_closed>"))
        #expect(contents.contains("picking the conversation back up"))
        #expect(!contents.contains("learner's answer to the"))

        let quiz = ReviewSessionManager.providerContentsForTesting(learnerTurns: [
            (visible: "what is GDF15?", context: ChatSideQuestion.contextContent(openQuestion: "Why not dysfunction?")),
            (visible: "because ROS also signals", context: nil),
        ]).joined(separator: "\n")
        #expect(quiz.contains("learner's answer to the"))
        #expect(!quiz.contains("picking the conversation back up"))
    }

    // MARK: - Lanes under older replies

    @Test("A More details press hangs under the reply it names, and is still the newest section")
    @MainActor
    func moreDetailsLaneHangsUnderItsReply() {
        var messages = transcript()
        let firstReply = messages[0]
        messages.append(.init(
            role: .user, content: ChatSideQuestion.moreDetailsQuestion,
            contextualContent: ChatSideQuestion.contextContent(
                openQuestion: "Right. Next: what does GDF15 track?",
                aboutReply: ChatSideQuestion.replyLine(in: firstReply.content),
                moreDetails: true
            )
        ))
        messages.append(.init(role: .assistant, content: "The paper argues for phenotyping across levels because…"))

        let blocks = ReviewChatTranscriptBlock.grouping(messages)
        let sections = ReviewChatTranscriptSection.grouping(blocks)
        #expect(sections.map(\.isSideQuestion) == [false, true, false, false, true, false, false])
        let lane = sections[1]
        #expect(lane.isMoreDetails)
        #expect(lane.aboutBlockID == firstReply.id)
        #expect(lane.blocks.count == 2)
        #expect(lane.sideQuestionMessage?.isMoreDetailsRequest == true)
        #expect(lane.openQuestion == "Right. Next: what does GDF15 track?")
        // Newest by time, not by position.
        #expect(ReviewChatTranscriptSection.newest(in: sections, blocks: blocks)?.id == lane.id)
        #expect(sections.last?.id != lane.id)
        // The ordinary lane about the newest reply is unmoved.
        #expect(sections[4].aboutBlockID == messages[2].id)
        #expect(!sections[4].isMoreDetails)
        // A reply block is named the way the mark named it.
        #expect(ReviewChatTranscriptSection.replyLine(of: blocks[0]) == "Let's begin. What was the paper about?")
    }

    @Test("Asides about one older reply share its lane; an aside about another reply, or a More details press, starts its own")
    @MainActor
    func asidesAboutOlderRepliesHangUnderThem() {
        var messages = transcript()
        let firstLine = ChatSideQuestion.replyLine(in: messages[0].content)
        let thirdLine = ChatSideQuestion.replyLine(in: messages[2].content)
        messages.append(.init(role: .user, content: "which paper was it again?",
                              contextualContent: ChatSideQuestion.contextContent(openQuestion: nil, aboutReply: firstLine)))
        messages.append(.init(role: .assistant, content: "Picard and colleagues, 2022."))
        messages.append(.init(role: .user, content: "and the year?",
                              contextualContent: ChatSideQuestion.contextContent(openQuestion: nil, aboutReply: firstLine)))
        messages.append(.init(role: .assistant, content: "2022."))
        messages.append(.init(role: .user, content: "what did 'Good' refer to?",
                              contextualContent: ChatSideQuestion.contextContent(openQuestion: nil, aboutReply: thirdLine)))
        messages.append(.init(role: .assistant, content: "Your summary of the paper."))
        messages.append(.init(role: .user, content: ChatSideQuestion.moreDetailsQuestion,
                              contextualContent: ChatSideQuestion.contextContent(openQuestion: nil, aboutReply: thirdLine, moreDetails: true)))
        messages.append(.init(role: .assistant, content: "In more detail…"))

        let sections = ReviewChatTranscriptSection.grouping(ReviewChatTranscriptBlock.grouping(messages))
        #expect(sections.map(\.isSideQuestion) == [false, true, false, false, true, true, true, false, false])
        // Both asides about the first reply are one lane of four blocks under it.
        #expect(sections[1].aboutBlockID == messages[0].id)
        #expect(sections[1].blocks.count == 4)
        #expect(sections[1].sideQuestionTurns.map(\.text) == ["which paper was it again?", "Picard and colleagues, 2022.", "and the year?", "2022."])
        // The original aside about the third reply keeps its place; the new
        // aside about that reply and the More details press follow it, in
        // the order they were sent, each a lane of its own.
        #expect(sections[4].sideQuestionMessage?.content == "what do they see in patients?")
        #expect(sections[5].sideQuestionMessage?.content == "what did 'Good' refer to?")
        #expect(sections[5].aboutBlockID == messages[2].id)
        #expect(!sections[5].isMoreDetails)
        #expect(sections[6].isMoreDetails)
        #expect(sections[6].aboutBlockID == messages[2].id)
        #expect(sections[6].blocks.count == 2)
    }

    @Test("A mark that names a reply no longer in the transcript falls back to the reply above")
    @MainActor
    func unknownReplyLineFallsBackToTheReplyAbove() {
        var messages = Array(transcript().prefix(3))
        messages.append(.init(role: .user, content: "wait, what?",
                              contextualContent: ChatSideQuestion.contextContent(openQuestion: nil, aboutReply: "A reply that was deleted.")))
        let sections = ReviewChatTranscriptSection.grouping(ReviewChatTranscriptBlock.grouping(messages))
        #expect(sections.map(\.isSideQuestion) == [false, false, false, true])
        #expect(sections[3].aboutBlockID == messages[2].id)
        // The open question is still read off the reply above.
        #expect(sections[3].openQuestion == "Why can an increase in ROS not be read as dysfunction?")
    }
}
