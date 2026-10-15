import Foundation
import Testing
@testable import ForeverLM

/// A mnemonic reading's body (docs/memory-design.md, "Mnemonic reading"): the
/// questions only, in reading order, under a marker a build that does not know
/// the kind still reads as a Doc listing them.
@Suite("Mnemonic reading: the body")
struct MnemonicReadingFormatTests {
    static func question(
        _ source: String = "chapter-1",
        quote: String = "System 1 operates automatically and quickly.",
        question: String = "In Kahneman's account, which system operates automatically and quickly?",
        answer: String = "System 1.",
        why: String? = "It works with little or no effort and no sense of voluntary control."
    ) -> MnemonicQuestion {
        MnemonicQuestion.mint(sourceID: source, quote: quote, question: question, answer: answer, why: why)
    }

    static let reading = MnemonicReading(title: "Thinking, Fast and Slow with questions", sections: [
        .init(sourceID: "chapter-1", title: "The Characters of the Story", isWritten: true, questions: [
            question(),
            question(
                quote: "System 2 allocates attention to the effortful mental activities that demand it.",
                question: "Which system allocates attention to effortful mental activities?",
                answer: "System 2,\nincluding complex computations.",
                why: nil
            ),
        ]),
        .init(sourceID: "chapter-2", title: "Attention and Effort", isWritten: false),
        .init(sourceID: "chapter-3", title: "The Lazy Controller", isWritten: true, questions: [
            question(
                "chapter-3",
                quote: "Self-control and deliberate thought apparently draw on the same limited budget of effort.",
                question: "According to the chapter, what do self-control and deliberate thought draw on?",
                answer: "The same limited budget of effort."
            ),
        ]),
    ])

    @Test("A body writes and reads back as the same reading: title, sections in order, pending ones, every question whole")
    func roundTrip() {
        let markdown = Self.reading.markdown
        let parsed = MnemonicReading.parse(markdown, fallbackTitle: "Fallback")
        #expect(parsed == Self.reading)
        #expect(parsed.sections.map(\.sourceID) == ["chapter-1", "chapter-2", "chapter-3"])
        #expect(parsed.pendingSourceIDs == ["chapter-2"])
        #expect(parsed.questions.count == 3)
        #expect(parsed.questions[1].answer == "System 2,\nincluding complex computations.")
        #expect(parsed.question(id: Self.reading.questions[2].id)?.sourceID == "chapter-3")
        // Writing what was read changes nothing.
        #expect(parsed.markdown == markdown)
    }

    @Test("A reading written when questions carried a drafted difficulty still reads, the line read past")
    func oldDifficultyLineIsReadPast() {
        let markdown = Self.reading.markdown
        let written = Self.reading.questions[0]
        let quoted = "Asked after: \u{201C}System 1 operates automatically and quickly.\u{201D}"
        #expect(markdown.contains(quoted))
        let old = markdown.replacingOccurrences(of: quoted, with: quoted + "\nDifficulty: easy")
        let parsed = MnemonicReading.parse(old, fallbackTitle: "Fallback")
        #expect(parsed == Self.reading)
        #expect(parsed.questions[0] == written)
        #expect(!parsed.markdown.contains("Difficulty:"))
    }

    @Test("The marker leads the body, and only a reading's body is a reading's")
    func marker() throws {
        let markdown = Self.reading.markdown
        #expect(markdown.hasPrefix(MnemonicReading.formatMarker + "\n"))
        #expect(MnemonicReading.isReadingMarkdown(markdown))
        #expect(MnemonicReading.isReadingMarkdown("\n\n" + markdown))
        #expect(!MnemonicReading.isReadingMarkdown("# A Doc\n\nSome text."))
        #expect(!MnemonicReading.isReadingMarkdown(FlashcardDeck(title: "Cards to check: X").markdown))
        #expect(!MnemonicReading.isReadingMarkdown("Text first\n" + markdown))

        let kindless = ArtifactRecord(id: "a1", title: "T", homeNotebookID: nil, linkedNotebookIDs: [], createdAt: Date(), updatedAt: Date())
        #expect(kindless.isMnemonicReading(markdown: markdown))
        #expect(!kindless.isMnemonicReading(markdown: "# A Doc"))
        #expect(!kindless.isMnemonicReading)
        var kinded = kindless
        kinded.kind = .mnemonicReading
        #expect(kinded.isMnemonicReading)
        #expect(kinded.isMnemonicReading(markdown: nil))
        var overview = kindless
        overview.kind = .audioOverview
        #expect(!overview.isMnemonicReading(markdown: markdown))

        // The kind rides the record's payload under its raw value and reads back.
        let encoded = try JSONEncoder().encode(kinded)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"kind\":\"mnemonic_reading\""))
        #expect(try JSONDecoder().decode(ArtifactRecord.self, from: encoded).kind == .mnemonicReading)
        #expect(ArtifactKind.mnemonicReading.label == "Mnemonic reading")
        #expect(kinded.section == .docs)
        #expect(kinded.kindLabel == "Mnemonic reading")
    }

    @Test("A question's id is minted from its source, quote and words, case and spacing aside; its card is a reading's")
    func identity() {
        let one = Self.question()
        let again = Self.question()
        #expect(one.id == again.id)
        #expect(one.id.hasPrefix("mq-"))
        #expect(one.id.count == 35)
        let spaced = MnemonicQuestion.mint(
            sourceID: "chapter-1",
            quote: "System 1  operates automatically\nand quickly.",
            question: "in kahneman's account,   which system operates automatically and quickly?",
            answer: "Another answer"
        )
        #expect(spaced.id == one.id)
        #expect(Self.question("chapter-9").id != one.id)
        #expect(Self.question(quote: "Another sentence of the text.").id != one.id)
        #expect(Self.question(question: "What does System 1 do?").id != one.id)

        #expect(one.memoryItemID == MemoryTutorIdentity.cardItemID(cardID: one.id))
        let card = one.card
        #expect(card.cardID == one.id)
        #expect(card.front == one.question)
        #expect(card.back == "System 1.")
        #expect(card.why == ["It works with little or no effort and no sense of voluntary control."])
        #expect(card.origin == .reading)
        #expect(card.origin.rawValue == "reading")
        #expect(card.deckID == nil)
    }

    @Test("A question with no quote or no answer is dropped on reading; one its body cannot carry is refused on writing")
    func dropsWhatCannotStand() {
        let body = """
        \(MnemonicReading.formatMarker)
        # Reading

        ## Chapter
        <!-- source:chapter-1 -->

        ### A question with no quote?
        <!-- question:mq-1 -->
        An answer.

        ### A question with no answer?
        <!-- question:mq-2 -->

        Asked after: “Some words.”

        ### A question written by hand?
        Its answer.

        Asked after: "Some other words."

        ## A section with no source line

        ### Lost?
        Yes.

        Asked after: “Lost words.”
        """
        let parsed = MnemonicReading.parse(body, fallbackTitle: "F")
        #expect(parsed.sections.count == 1)
        #expect(parsed.questions.count == 1)
        let handWritten = parsed.questions[0]
        #expect(handWritten.quote == "Some other words.")
        #expect(handWritten.id == MnemonicQuestion.id(sourceID: "chapter-1", quote: "Some other words.", question: "A question written by hand?"))

        // An answer line that reads as a heading or as metadata does not come back whole.
        #expect(MnemonicReading.readBack(Self.question(answer: "System 1.\n### Not an answer")) == nil)
        #expect(MnemonicReading.readBack(Self.question(answer: "System 1.\nDifficulty: hard")) == nil)
        #expect(MnemonicReading.readBack(Self.question(answer: "System 1.\nAsked after: “x”")) == nil)
        #expect(MnemonicReading.readBack(Self.question(answer: "System 1.\n## Not an answer")) == nil)
        #expect(MnemonicReading.readBack(MnemonicQuestion.mint(sourceID: "", quote: "q", question: "Q?", answer: "A")) == nil)
        #expect(MnemonicReading.readBack(Self.question()) == Self.question())
        // A quote in quotation marks of its own still reads back.
        let quoted = Self.question(quote: "He said “yes” and \"no\"")
        #expect(MnemonicReading.readBack(quoted)?.quote == "He said “yes” and \"no\"")
    }

    @Test("A body an older build reads as a Doc lists the chapters and their questions as headings")
    func readsAsADoc() {
        let outline = ChatDocAttachment.outline(from: Self.reading.markdown)
        #expect(outline == [
            "Thinking, Fast and Slow with questions",
            "  The Characters of the Story",
            "    In Kahneman's account, which system operates automatically and quickly?",
            "    Which system allocates attention to effortful mental activities?",
            "  Attention and Effort",
            "  The Lazy Controller",
            "    According to the chapter, what do self-control and deliberate thought draw on?",
        ])
        let markdown = Self.reading.markdown
        #expect(markdown.contains("Asked after: “System 1 operates automatically and quickly.”"))
        #expect(markdown.contains("> Why: It works with little or no effort and no sense of voluntary control."))
        #expect(markdown.contains("<!-- source:chapter-2 pending -->"))
    }

    @Test("Writing a section adds only new questions, marks it written and changes nothing else; a new source gets a section at the end")
    func writingASection() {
        let fresh = Self.question("chapter-2", quote: "A failure of System 2.", question: "What is a lapse of attention a failure of?", answer: "System 2.")
        let written = Self.reading.writing([fresh, Self.question()], in: "chapter-2", title: "Attention and Effort")
        #expect(written.added == [fresh])
        #expect(written.alreadyWritten == [Self.question()])
        #expect(written.reading.pendingSourceIDs.isEmpty)
        #expect(written.reading.section(sourceID: "chapter-2")?.questions == [fresh])
        #expect(written.reading.sections.map(\.sourceID) == ["chapter-1", "chapter-2", "chapter-3"])
        #expect(written.reading.section(sourceID: "chapter-1") == Self.reading.section(sourceID: "chapter-1"))

        let bad = Self.question("chapter-2", answer: "A\n### B")
        #expect(Self.reading.writing([bad], in: "chapter-2").unreadable == [bad])

        let extra = Self.reading.writing([Self.question("chapter-4")], in: "chapter-4", title: "Chapter 4")
        #expect(extra.reading.sections.last?.sourceID == "chapter-4")
        #expect(extra.reading.sections.last?.title == "Chapter 4")
        #expect(extra.reading.sections.last?.isWritten == true)
    }

    @Test("Two copies merge question by question: a section either wrote is written, and nothing is held for a choice")
    func union() throws {
        let mine = Self.reading
        let fresh = Self.question("chapter-2", quote: "A failure of System 2.", question: "What is a lapse of attention a failure of?", answer: "System 2.")
        var theirs = Self.reading.writing([fresh], in: "chapter-2").reading
        theirs = theirs.writing([Self.question("chapter-5")], in: "chapter-5", title: "Chapter 5").reading

        let merged = try #require(MnemonicReading.union(mine: mine.markdown, theirs: theirs.markdown))
        let reading = MnemonicReading.parse(merged, fallbackTitle: "F")
        #expect(reading.pendingSourceIDs.isEmpty)
        #expect(reading.section(sourceID: "chapter-2")?.questions == [fresh])
        #expect(reading.sections.map(\.sourceID) == ["chapter-1", "chapter-2", "chapter-3", "chapter-5"])
        // The other way round gives the same questions.
        let back = try #require(MnemonicReading.union(mine: theirs.markdown, theirs: mine.markdown))
        #expect(Set(MnemonicReading.parse(back, fallbackTitle: "F").questions.map(\.id)) == Set(reading.questions.map(\.id)))
        // Nothing new: mine as it was.
        #expect(MnemonicReading.union(mine: theirs.markdown, theirs: mine.markdown) == theirs.markdown)
        #expect(MnemonicReading.union(mine: "# Doc", theirs: mine.markdown) == nil)
    }

    @Test("A reading asks about one question for every 350 words, fewer or more on request, at least one and at most a chapter's cap")
    func density() {
        #expect(MnemonicReadingDensity.auto.questionCount(words: 3_500) == 10)
        #expect(MnemonicReadingDensity.fewer.questionCount(words: 3_500) == 5)
        #expect(MnemonicReadingDensity.more.questionCount(words: 3_500) == 18)
        #expect(MnemonicReadingDensity.auto.questionCount(words: 40) == 1)
        #expect(MnemonicReadingDensity.auto.questionCount(words: 60_000) == 24)
        #expect(MnemonicReadingDensity.more.questionCount(words: 60_000) == 40)
        #expect(MnemonicReadingDensity.fewer.questionCount(words: 60_000) == 12)
        #expect(MnemonicReadingDensity.allCases.map(\.rawValue) == ["fewer", "auto", "more"])
        #expect(MnemonicReading.title(forSubject: "Thinking, Fast and Slow") == "Thinking, Fast and Slow with questions")
        #expect(MnemonicReading.title(forSubject: "  ") == "Mnemonic reading")
    }
}
