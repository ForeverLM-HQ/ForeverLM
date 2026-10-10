import Foundation
import Testing
@testable import ForeverLM

/// Answering a mnemonic reading's question keeps it as a Memory card at once,
/// with that grade as its first attempt; later grades follow the card review's
/// rules; and the reading reads its state from Memory (docs/memory-design.md,
/// "Mnemonic reading").
@Suite("Mnemonic reading: answers in Memory")
struct MnemonicReadingMemoryTests {
    static let text = """
    System 1 operates automatically and quickly, with little or no effort and no sense of voluntary control.
    System 2 allocates attention to the effortful mental activities that demand it.
    """
    static let answeredAt = Date(timeIntervalSinceReferenceDate: 812_000_000)
    static let day = MemoryTutorScheduler.secondsPerDay

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static let question = MnemonicQuestion.mint(
        sourceID: "chapter-1",
        quote: "System 1 operates automatically and quickly",
        question: "In Kahneman's account, which system operates automatically and quickly?",
        answer: "System 1.",
        why: "It works with little or no effort.",
        difficulty: .easy
    )

    private func makeStore() throws -> KnowledgeStore {
        let store = try KnowledgeStore(inMemory: true)
        var source = StudioArticle(url: "https://example.com/book/1", title: "The Characters of the Story", sourceType: .article, discoveryOrigin: .manual, id: "chapter-1")
        source.normalizedURL = URLNormalizer.normalize(source.url)
        source.content = Self.text
        source.state = .ready
        try store.saveSource(source)
        return store
    }

    @Test("Remembered and Forgot each keep the card at once, the grade as its first attempt, and the card comes back by Memory's schedule")
    func firstAnswerKeepsTheCard() throws {
        for remembered in [true, false] {
            let store = try makeStore()
            let answer = try store.recordMnemonicReadingAnswer(
                Self.question, remembered: remembered, sittingKey: "reading-r1-a", at: Self.answeredAt, calendar: Self.calendar
            )
            #expect(answer.outcome == .kept)
            let item = try #require(try store.loadMemoryItem(Self.question.memoryItemID))
            #expect(MemoryCard(storedIn: item) == Self.question.card)
            #expect(MemoryCard(storedIn: item)?.origin == .reading)
            #expect(item.target == "System 1.")
            #expect(item.sources.map(\.excerpt) == [Self.question.quote])
            #expect(item.sources.map(\.sourceID) == ["chapter-1"])
            #expect(item.goalID == nil)

            let attempts = try store.loadMemoryAttempts(memoryItemID: item.id)
            #expect(attempts.count == 1)
            let first = try #require(attempts.first)
            #expect(first.id == MemoryTutorIdentity.selfGradedAttemptID(sessionKey: "reading-r1-a", memoryItemID: item.id))
            #expect(first.attemptType == .discovery)
            #expect(first.gradeState == .graded)
            #expect(first.scheduleRating == (remembered ? .good : .again))
            #expect(first.score == (remembered ? 1 : 0))
            #expect(first.prompt == Self.question.question)
            #expect(first.learnerAnswer == MemoryAttempt.selfGradedAnswer)

            #expect(answer.memory.itemID == item.id)
            #expect(answer.memory.lastRemembered == remembered)
            #expect(answer.memory.dueAt == MemoryTutorScheduler.schedule(item: item, attempts: attempts, calendar: Self.calendar).dueAt)
            // Never due on the day it was answered.
            #expect(answer.memory.dueAt >= Self.calendar.startOfDay(for: Self.answeredAt).addingTimeInterval(Self.day))
            #expect(!answer.memory.isDue(at: Self.answeredAt))
        }
    }

    @Test("Answering on two Macs before they sync makes one card: the same item, the same curriculum, attempts that never collide")
    func twoMacsMakeOneItem() throws {
        let mac1 = try makeStore()
        let mac2 = try makeStore()
        _ = try mac1.recordMnemonicReadingAnswer(Self.question, remembered: true, sittingKey: "reading-r1-mac1", at: Self.answeredAt, calendar: Self.calendar)
        _ = try mac2.recordMnemonicReadingAnswer(Self.question, remembered: false, sittingKey: "reading-r1-mac2", at: Self.answeredAt.addingTimeInterval(90), calendar: Self.calendar)
        let one = try #require(try mac1.loadMemoryItem(Self.question.memoryItemID))
        let other = try #require(try mac2.loadMemoryItem(Self.question.memoryItemID))
        #expect(one.id == other.id)
        // CloudKit takes the two as one record: their immutable curriculum agrees.
        #expect(MemoryTutorIdentity.hasSameImmutableCurriculum(one, other))
        #expect(MemoryTutorIdentity.immutableCurriculumFingerprint(one) == MemoryTutorIdentity.immutableCurriculumFingerprint(other))
        let ids = try mac1.loadMemoryAttempts(memoryItemID: one.id).map(\.id) + mac2.loadMemoryAttempts(memoryItemID: other.id).map(\.id)
        #expect(Set(ids).count == 2)

        // On one Mac, answering again in another sitting keeps the one card
        // and writes nothing while it is not due.
        let again = try mac1.recordMnemonicReadingAnswer(Self.question, remembered: false, sittingKey: "reading-r1-b", at: Self.answeredAt.addingTimeInterval(60), calendar: Self.calendar)
        #expect(again.outcome == .notCounted)
        #expect(try mac1.loadMemoryAttempts(memoryItemID: one.id).count == 1)
        #expect(again.memory.lastRemembered == true)
    }

    @Test("A later grade follows Memory's rules: written when the card is due, once a sitting, never for a retired card")
    func laterGrades() throws {
        let store = try makeStore()
        let kept = try store.recordMnemonicReadingAnswer(Self.question, remembered: true, sittingKey: "reading-r1-a", at: Self.answeredAt, calendar: Self.calendar)
        let due = kept.memory.dueAt.addingTimeInterval(60)

        let onTime = try store.recordMnemonicReadingAnswer(Self.question, remembered: false, sittingKey: "reading-r1-b", at: due, calendar: Self.calendar)
        #expect(onTime.outcome == .recorded)
        #expect(onTime.memory.lastRemembered == false)
        #expect(onTime.memory.dueAt > due)
        let attempts = try store.loadMemoryAttempts(memoryItemID: Self.question.memoryItemID)
        #expect(attempts.count == 2)
        #expect(attempts.last?.attemptType == .review)
        #expect(attempts.last?.id == MemoryTutorIdentity.selfGradedAttemptID(sessionKey: "reading-r1-b", memoryItemID: Self.question.memoryItemID))

        let repeated = try store.recordMnemonicReadingAnswer(Self.question, remembered: true, sittingKey: "reading-r1-b", at: due.addingTimeInterval(30), calendar: Self.calendar)
        #expect(repeated.outcome == .alreadyRecorded)
        #expect(try store.loadMemoryAttempts(memoryItemID: Self.question.memoryItemID).count == 2)

        try store.retireMemoryCard(memoryItemID: Self.question.memoryItemID)
        let retired = try store.recordMnemonicReadingAnswer(Self.question, remembered: true, sittingKey: "reading-r1-c", at: due.addingTimeInterval(30 * Self.day), calendar: Self.calendar)
        #expect(retired.outcome == .retired)
        #expect(retired.memory.isRetired)
        #expect(try store.loadMemoryAttempts(memoryItemID: Self.question.memoryItemID).count == 2)
    }

    @Test("A question whose quote its source does not print is refused, and nothing is written")
    func ungroundedIsRefused() throws {
        let store = try makeStore()
        let stray = MnemonicQuestion.mint(sourceID: "chapter-1", quote: "words this chapter never prints", question: "What?", answer: "Nothing.")
        #expect(throws: KnowledgeStoreError.self) {
            try store.recordMnemonicReadingAnswer(stray, remembered: true, sittingKey: "reading-r1-a", at: Self.answeredAt)
        }
        #expect(try store.loadMemoryItem(stray.memoryItemID) == nil)
        #expect(try store.loadMemoryAttempts(memoryItemID: stray.memoryItemID).isEmpty)
        let elsewhere = MnemonicQuestion.mint(sourceID: "not-in-library", quote: "System 1 operates", question: "Q?", answer: "A.")
        #expect(throws: KnowledgeStoreError.self) {
            try store.recordMnemonicReadingAnswer(elsewhere, remembered: true, sittingKey: "reading-r1-a", at: Self.answeredAt)
        }
        #expect(throws: KnowledgeStoreError.self) {
            try store.recordMnemonicReadingAnswer(Self.question, remembered: true, sittingKey: "  ", at: Self.answeredAt)
        }
        #expect(try store.loadMemoryItem(Self.question.memoryItemID) == nil)
    }

    @Test("The reading reads what was answered from Memory: only the kept questions, with their standing, and nothing is written")
    func readsItsStateFromMemory() throws {
        let store = try makeStore()
        let second = MnemonicQuestion.mint(
            sourceID: "chapter-1",
            quote: "System 2 allocates attention to the effortful mental activities that demand it",
            question: "Which system allocates attention to effortful mental activities?",
            answer: "System 2."
        )
        let reading = MnemonicReading(title: "R", sections: [
            .init(sourceID: "chapter-1", title: "One", isWritten: true, questions: [Self.question, second]),
        ])
        #expect(try store.mnemonicReadingMemory(for: reading.questions).isEmpty)
        _ = try store.recordMnemonicReadingAnswer(second, remembered: false, sittingKey: "reading-r1-a", at: Self.answeredAt, calendar: Self.calendar)
        let memory = try store.mnemonicReadingMemory(for: reading.questions, calendar: Self.calendar)
        #expect(Array(memory.keys) == [second.id])
        #expect(memory[second.id]?.lastRemembered == false)
        #expect(memory[second.id]?.itemID == second.memoryItemID)
        let before = try store.loadMemoryAttempts(memoryItemID: second.memoryItemID).count
        _ = try store.mnemonicReadingMemory(for: reading.questions, calendar: Self.calendar)
        #expect(try store.loadMemoryAttempts(memoryItemID: second.memoryItemID).count == before)

        let counts = MnemonicReadingProgress.counts(of: reading, memory: memory, now: Self.answeredAt)
        #expect(counts == .init(questions: 2, answered: 1, due: 0))
        let later = MnemonicReadingProgress.counts(of: reading, memory: memory, now: Self.answeredAt.addingTimeInterval(3 * Self.day))
        #expect(later.due == 1)
    }
}
