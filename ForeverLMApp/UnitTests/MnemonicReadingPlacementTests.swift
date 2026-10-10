import Foundation
import Testing
@testable import ForeverLM

/// Where a mnemonic reading's questions stand in their source's text, and
/// what the reading shows of the learner's answers (docs/memory-design.md,
/// "Mnemonic reading").
@Suite("Mnemonic reading: placing the questions")
struct MnemonicReadingPlacementTests {
    static let chapter = """
    # The Characters of the Story

    To observe your mind in automatic mode, glance at the image below.
    System 1 operates automatically and quickly, with little or no effort.

    System 2 allocates attention to the effortful mental activities that demand it.
    - Orient to the source of a sudden sound.
    - Detect hostility in a voice.
    ![A woman's angry face](foreverlm://image/face)
    * * *
    The highly diverse operations of System 2 have one feature in common: they require attention.
    """

    static func question(_ quote: String, _ text: String = "Q?", source: String = "chapter-1") -> MnemonicQuestion {
        MnemonicQuestion.mint(sourceID: source, quote: quote, question: text, answer: "A.")
    }

    @Test("The text is set as the Reader's prose form sets it: a line a block, Markdown headings, lists, figures and breaks marked")
    func blocks() {
        let blocks = MnemonicReadingPlacement.blocks(of: Self.chapter)
        #expect(blocks.map(\.kind) == [
            .heading(level: 1), .paragraph, .paragraph, .paragraph,
            .listItem(marker: "-"), .listItem(marker: "-"), .figure, .rule, .paragraph,
        ])
        #expect(blocks.map(\.index) == Array(0..<9))
        #expect(blocks[0].text == "The Characters of the Story")
        #expect(blocks[4].text == "Orient to the source of a sudden sound.")
        #expect(blocks[6].text == "A woman's angry face")
        #expect(MnemonicReadingPlacement.blocks(of: "1. One\n12) Twelve\n2008. A year").map(\.kind) == [
            .listItem(marker: "1."), .listItem(marker: "12)"), .paragraph,
        ])
        #expect(MnemonicReadingPlacement.blocks(of: "#Not a heading\n####### Seven").map(\.kind) == [.paragraph, .paragraph])
    }

    @Test("A hard-wrapped page reads as its paragraphs: a line broken mid-sentence or in a hyphen runs on into a line in lower case")
    func hardWrappedLines() {
        let page = "The cristae were imaged with STED micro-\nscopy, which resolves the\ninner membrane.\nA new paragraph starts here.\r\nAnother one,\u{0C}after a page break."
        let blocks = MnemonicReadingPlacement.blocks(of: page)
        #expect(blocks.map(\.text) == [
            "The cristae were imaged with STED micro-scopy, which resolves the inner membrane.",
            "A new paragraph starts here.",
            "Another one, after a page break.",
        ])
        #expect(blocks[0].stored == "The cristae were imaged with STED micro-\nscopy, which resolves the\ninner membrane.")
        // A heading line, a line ending a sentence and a capitalised line never run on.
        #expect(MnemonicReadingPlacement.blocks(of: "Chapter One\nIt was late.\nthen it rained.").count == 3)
        #expect(!MnemonicReadingPlacement.runsOn("It was late.", into: "then"))
        #expect(MnemonicReadingPlacement.runsOn("It was", into: "late"))
        #expect(!MnemonicReadingPlacement.runsOn("It was", into: "Late"))
    }

    @Test("A question lands after the paragraph that holds its quote, whatever the quote's case, punctuation or line breaks")
    func placesAfterItsParagraph() {
        let first = Self.question("system 1 operates automatically and quickly, with little or no effort")
        let second = Self.question("they require ATTENTION")
        let third = Self.question("Detect hostility in a voice")
        let wrapped = Self.question("STED microscopy, which resolves the inner membrane")
        let layout = MnemonicReadingPlacement.layout(text: Self.chapter, questions: [first, third, second])
        #expect(layout.questionsAfter[2] == [first])
        #expect(layout.questionsAfter[5] == [third])
        #expect(layout.questionsAfter[8] == [second])
        #expect(layout.unplaced.isEmpty)
        #expect(layout.orderedQuestions == [first, third, second])

        let page = "The cristae were imaged with STED micro-\nscopy, which resolves the\ninner membrane.\nA new paragraph."
        let pageLayout = MnemonicReadingPlacement.layout(text: page, questions: [wrapped])
        #expect(pageLayout.questionsAfter[0] == [wrapped])
    }

    @Test("A question whose quote the text no longer prints goes to the end of its source's text, in its order")
    func unmatchedGoesToTheEnd() {
        let lost = Self.question("a sentence the chapter was re-fetched without")
        let found = Self.question("Orient to the source of a sudden sound")
        let alsoLost = Self.question("another sentence gone")
        let layout = MnemonicReadingPlacement.layout(text: Self.chapter, questions: [lost, found, alsoLost])
        #expect(layout.unplaced == [lost, alsoLost])
        #expect(layout.questionsAfter[4] == [found])
        #expect(layout.orderedQuestions == [found, lost, alsoLost])
        // A text with nothing in it places nothing.
        #expect(MnemonicReadingPlacement.layout(text: "", questions: [found]).unplaced == [found])
    }

    @Test("Questions keep reading order: two after one paragraph keep the body's order, and a phrase the text repeats lands where the reading has got to")
    func readingOrder() {
        let text = "It rained.\nThe end of the beginning.\nIt rained.\nThe end."
        let early = Self.question("The end of the beginning", "First?")
        let firstRain = Self.question("It rained", "Second?")
        let secondRain = Self.question("it rained", "Third?")
        let layout = MnemonicReadingPlacement.layout(text: text, questions: [firstRain, early, secondRain])
        // The first "It rained" is found from the start; the second is found
        // after where the reading has got to.
        #expect(layout.questionsAfter[0] == [firstRain])
        #expect(layout.questionsAfter[1] == [early])
        #expect(layout.questionsAfter[2] == [secondRain])

        let both = [Self.question("System 2 allocates attention", "A?"), Self.question("effortful mental activities that demand it", "B?")]
        #expect(MnemonicReadingPlacement.layout(text: Self.chapter, questions: both).questionsAfter[3] == both)

        // Several sources: each section's questions in its own text, the
        // sections in the body's order.
        let reading = MnemonicReading(title: "R", sections: [
            .init(sourceID: "chapter-1", title: "One", isWritten: true, questions: [both[0]]),
            .init(sourceID: "chapter-2", title: "Two", isWritten: true, questions: [Self.question("It rained", source: "chapter-2")]),
        ])
        #expect(reading.questions.map(\.sourceID) == ["chapter-1", "chapter-2"])
    }

    @Test("A text's letters are its blocks' letters, timestamps, page marks and ligatures included, so an offset reads in either")
    func offsetsAgree() {
        let text = "[0:00] Transported on tracks [10:37] which are the microtubules.\n\n[page 3]\nThe ﬁrst ﬁgure shows it.\u{0C}STED micro-\nscopy."
        let blocks = MnemonicReadingPlacement.blocks(of: text)
        let total = blocks.reduce(0) { $0 + MemoryGroundingText($1.stored).letterCount }
        #expect(total == MemoryGroundingText(text).letterCount)
        let question = Self.question("transported on tracks which are the microtubules")
        #expect(MnemonicReadingPlacement.layout(text: text, questions: [question]).questionsAfter[0] == [question])
        let figure = Self.question("The first figure shows it")
        #expect(MnemonicReadingPlacement.layout(text: text, questions: [figure]).questionsAfter[2] == [figure])
    }

    @Test("The reading counts its questions, those answered and those due, and goes to the next unanswered one round to the start")
    func progress() {
        let reading = MnemonicReading(title: "R", sections: [
            .init(sourceID: "s1", title: "One", isWritten: true, questions: [
                Self.question("a", "One?", source: "s1"), Self.question("b", "Two?", source: "s1"),
            ]),
            .init(sourceID: "s2", title: "Two", isWritten: true, questions: [Self.question("c", "Three?", source: "s2")]),
        ])
        let ids = reading.questions.map(\.id)
        let now = Date(timeIntervalSinceReferenceDate: 812_000_000)
        let memory: [String: MnemonicQuestionMemory] = [
            ids[0]: MnemonicQuestionMemory(itemID: "i0", lastRemembered: true, dueAt: now.addingTimeInterval(-60), isRetired: false),
            ids[2]: MnemonicQuestionMemory(itemID: "i2", lastRemembered: false, dueAt: now.addingTimeInterval(86_400), isRetired: false),
        ]
        let counts = MnemonicReadingProgress.counts(of: reading, memory: memory, now: now)
        #expect(counts == .init(questions: 3, answered: 2, due: 1))
        #expect(MnemonicReadingProgress.line(counts) == "3 questions · 2 answered · 1 due")
        #expect(MnemonicReadingProgress.line(.init(questions: 1, answered: 0, due: 0)) == "1 question · 0 answered")

        let answered = Set(memory.keys)
        #expect(MnemonicReadingProgress.nextUnanswered(in: ids, answered: answered, after: nil) == ids[1])
        #expect(MnemonicReadingProgress.nextUnanswered(in: ids, answered: answered, after: ids[1]) == ids[1])
        #expect(MnemonicReadingProgress.nextUnanswered(in: ids, answered: [ids[0]], after: ids[1]) == ids[2])
        #expect(MnemonicReadingProgress.nextUnanswered(in: ids, answered: [ids[0], ids[2]], after: ids[2]) == ids[1])
        #expect(MnemonicReadingProgress.nextUnanswered(in: ids, answered: Set(ids), after: nil) == nil)
        #expect(MnemonicReadingProgress.nextUnanswered(in: [], answered: [], after: nil) == nil)
    }

    @Test("A question's standing in Memory is read from its item and attempts: the latest grade, when it comes back, retired or not")
    func memoryStanding() throws {
        let question = Self.question("System 1 operates automatically and quickly")
        let keptAt = Date(timeIntervalSinceReferenceDate: 812_000_000)
        let anchor = MemorySourceAnchorValidation(sourceID: "chapter-1", excerpt: question.quote, sourceSHA256: "sha")
        let item = try question.card.memoryItem(id: question.memoryItemID, anchors: [anchor], at: keptAt)
        let first = MemoryAttempt(
            id: "a1", memoryItemID: item.id, attemptType: .discovery, prompt: question.question,
            learnerAnswer: MemoryAttempt.selfGradedAnswer, score: 1, scheduleRating: .good, gradeState: .graded, attemptedAt: keptAt
        )
        let standing = MnemonicQuestionMemory(item: item, attempts: [first])
        #expect(standing.itemID == question.memoryItemID)
        #expect(standing.lastRemembered == true)
        #expect(standing.dueAt == MemoryTutorScheduler.schedule(item: item, attempts: [first]).dueAt)
        #expect(standing.dueAt > keptAt.addingTimeInterval(3 * 86_400))
        #expect(!standing.isDue(at: keptAt))
        #expect(standing.isDue(at: standing.dueAt))

        let forgot = MemoryAttempt(
            id: "a2", memoryItemID: item.id, prompt: question.question, learnerAnswer: MemoryAttempt.selfGradedAnswer,
            score: 0, scheduleRating: .again, gradeState: .graded, attemptedAt: standing.dueAt
        )
        #expect(MnemonicQuestionMemory(item: item, attempts: [first, forgot]).lastRemembered == false)
        let retired = MemoryItem(
            id: item.id, kind: item.kind, target: item.target, rubricJSON: item.rubricJSON,
            status: .retired, sources: item.sources, createdAt: keptAt, updatedAt: keptAt
        )
        let standingRetired = MnemonicQuestionMemory(item: retired, attempts: [first])
        #expect(standingRetired.isRetired)
        #expect(!standingRetired.isDue(at: standingRetired.dueAt))
    }
}
