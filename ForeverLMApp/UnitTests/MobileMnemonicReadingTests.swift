import Foundation
import Testing
@testable import ForeverLM

/// A mnemonic reading on the iPhone, against the Mac's own store
/// (docs/memory-design.md, "Mnemonic reading (2026-10-03)"): the phone knows a
/// reading by its kind or its marker, lists it as one, and an answer there
/// writes exactly what `recordMnemonicReadingAnswer` writes — the same item,
/// the same first attempt under the same id, and later answers only when the
/// Mac's store would — and reads where each question stands as the store does.
@Suite("Mnemonic reading on the phone")
struct MobileMnemonicReadingTests {
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

    static let second = MnemonicQuestion.mint(
        sourceID: "chapter-1",
        quote: "System 2 allocates attention",
        question: "Which system allocates attention to effortful mental activities?",
        answer: "System 2."
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

    // MARK: - Recognising

    @Test("A reading is known by its kind, or with no kind by its marker; a Doc and another kind are not")
    func recognisesAReading() {
        let body = MnemonicReading(title: "Thinking with questions", sections: [
            .init(sourceID: "chapter-1", title: "The Characters", isWritten: true, questions: [Self.question]),
        ]).markdown
        #expect(MobileMnemonicReading.isReading(kind: "mnemonic_reading", markdown: nil))
        #expect(MobileMnemonicReading.isReading(kind: nil, markdown: body))
        #expect(MobileMnemonicReading.isReading(kind: nil, markdown: "\n\n" + body), "the marker is the first non-empty line")
        #expect(!MobileMnemonicReading.isReading(kind: nil, markdown: "# A Doc\n\nSome words."))
        #expect(!MobileMnemonicReading.isReading(kind: nil, markdown: nil))
        #expect(!MobileMnemonicReading.isReading(kind: "audio_overview", markdown: body), "another kind is that kind")
        #expect(MobileMnemonicReading.kind == ArtifactKind.mnemonicReading.rawValue)

        let reading = artifact(kind: "mnemonic_reading")
        #expect(reading.isMnemonicReading)
        #expect(reading.isDoc, "the Mac files it among the Docs")
        #expect(!artifact(kind: nil).isMnemonicReading)
    }

    @Test("Its Studio row says what it is, how many sources, and when, as the Mac's outputs line does")
    func studioLine() {
        #expect(MobileNotebookOutputGlyph.mnemonicReading == ArtifactKind.mnemonicReadingSymbolName)
        #expect(MobileMnemonicReading.outputLine(sourceCount: 12, madeAt: nil) == "Mnemonic reading · 12 sources")
        #expect(MobileMnemonicReading.outputLine(sourceCount: 1, madeAt: nil) == "Mnemonic reading · 1 source")
        #expect(MobileMnemonicReading.outputLine(sourceCount: 0, madeAt: nil) == "Mnemonic reading")
        #expect(MobileMnemonicReading.outputLine(sourceCount: 3, madeAt: Date()).hasPrefix("Mnemonic reading · 3 sources · "))
        #expect(MobileMnemonicReading.sittingKey(readingID: "art-1", token: "ab12") == "reading-art-1-ab12")
        #expect(MobileMnemonicReading.sha256(Self.text) == PaperContentPreparationService.sha256(Self.text))
    }

    // MARK: - Answering

    @Test("A first answer keeps the very item and first attempt the Mac's store keeps, Remembered and Forgot alike")
    func firstAnswerMatchesTheStore() throws {
        for remembered in [true, false] {
            let store = try makeStore()
            let decision = try MobileMnemonicReadingAnswer.decide(
                Self.question, remembered: remembered, sittingKey: "reading-r1-phone",
                heldItem: nil, history: [], sourceText: Self.text, at: Self.answeredAt, calendar: Self.calendar
            )
            guard case .keep(let item, let attempt) = decision else {
                Issue.record("a question with no item is kept")
                continue
            }
            let mac = try store.recordMnemonicReadingAnswer(
                Self.question, remembered: remembered, sittingKey: "reading-r1-phone", at: Self.answeredAt, calendar: Self.calendar
            )
            #expect(mac.outcome == .kept)
            let stored = try #require(try store.loadMemoryItem(Self.question.memoryItemID))
            #expect(item.id == stored.id)
            #expect(MemoryTutorIdentity.hasSameImmutableCurriculum(item, stored))
            #expect(MemoryTutorIdentity.immutableCurriculumFingerprint(item) == MemoryTutorIdentity.immutableCurriculumFingerprint(stored))
            #expect(MemoryCard(storedIn: item) == MemoryCard(storedIn: stored))
            #expect(MemoryCard(storedIn: item)?.origin == .reading)
            #expect(item.sources.map(\.excerpt) == stored.sources.map(\.excerpt))
            #expect(item.sources.map(\.sourceSHA256) == stored.sources.map(\.sourceSHA256))
            #expect(item.sources.map(\.id) == stored.sources.map(\.id))

            let written = try store.loadMemoryAttempts(memoryItemID: stored.id)
            #expect(written == [attempt], "the very attempt the Mac's store writes")
            #expect(attempt.attemptType == .discovery)
            #expect(attempt.scheduleRating == (remembered ? .good : .again))

            // And where it stands after: as the store reads it.
            let phone = MobileMnemonicReadingMemory.standing(of: [Self.question], items: [item], attempts: [attempt], calendar: Self.calendar)
            #expect(phone == [Self.question.id: mac.memory])
        }
    }

    @Test("A first answer is refused, as the Mac's store refuses it, when the text does not print the quote or the answer has no sitting")
    func refusalsMatchTheStore() throws {
        let store = try makeStore()
        let gone = MnemonicQuestion.mint(
            sourceID: "chapter-1", quote: "A sentence the chapter never printed", question: "What was never printed?", answer: "Nothing."
        )
        #expect(throws: MobileMnemonicReadingAnswer.Refusal.passageNotFound) {
            try MobileMnemonicReadingAnswer.decide(gone, remembered: true, sittingKey: "s", heldItem: nil, history: [], sourceText: Self.text, at: Self.answeredAt)
        }
        #expect(throws: (any Error).self) {
            try store.recordMnemonicReadingAnswer(gone, remembered: true, sittingKey: "s", at: Self.answeredAt)
        }
        #expect(try store.loadMemoryItem(gone.memoryItemID) == nil)

        #expect(throws: MobileMnemonicReadingAnswer.Refusal.noText) {
            try MobileMnemonicReadingAnswer.decide(Self.question, remembered: true, sittingKey: "s", heldItem: nil, history: [], sourceText: nil, at: Self.answeredAt)
        }
        #expect(throws: MobileMnemonicReadingAnswer.Refusal.noText) {
            try MobileMnemonicReadingAnswer.decide(Self.question, remembered: true, sittingKey: "s", heldItem: nil, history: [], sourceText: "  \n", at: Self.answeredAt)
        }
        #expect(throws: MobileMnemonicReadingAnswer.Refusal.noSitting) {
            try MobileMnemonicReadingAnswer.decide(Self.question, remembered: true, sittingKey: " ", heldItem: nil, history: [], sourceText: Self.text, at: Self.answeredAt)
        }
        #expect(throws: (any Error).self) {
            try store.recordMnemonicReadingAnswer(Self.question, remembered: true, sittingKey: " ", at: Self.answeredAt)
        }
    }

    @Test("Later answers to a kept card are written exactly when, and as, the Mac's store writes them")
    func laterAnswersFollowTheStore() throws {
        let store = try makeStore()
        _ = try store.recordMnemonicReadingAnswer(
            Self.question, remembered: true, sittingKey: "reading-r1-a", at: Self.answeredAt, calendar: Self.calendar
        )
        let itemID = Self.question.memoryItemID

        /// The phone decides from the item and history the store holds; the store records; they must agree.
        func answer(_ remembered: Bool, _ sitting: String, at date: Date) throws -> MemoryCardAnswerOutcome? {
            let held = try #require(try store.loadMemoryItem(itemID))
            let history = try store.loadMemoryAttempts(memoryItemID: itemID)
            let decision = try MobileMnemonicReadingAnswer.decide(
                Self.question, remembered: remembered, sittingKey: sitting,
                heldItem: held, history: history, sourceText: nil, at: date, calendar: Self.calendar
            )
            let mac = try store.recordMnemonicReadingAnswer(
                Self.question, remembered: remembered, sittingKey: sitting, at: date, calendar: Self.calendar
            )
            switch decision {
            case .keep:
                Issue.record("a held card is never kept again")
                return nil
            case .write(let attempt):
                #expect(mac.outcome == .recorded, "the phone writes \(attempt.id) where the Mac would")
                let written = try #require(try store.loadMemoryAttempts(memoryItemID: itemID).first { $0.id == attempt.id })
                #expect(written == attempt, "the very attempt the Mac's store writes")
                return .recorded
            case .skip(let outcome):
                #expect(mac.outcome == MnemonicReadingAnswerOutcome(outcome))
                return outcome
            }
        }

        #expect(try answer(true, "reading-r1-a", at: Self.answeredAt.addingTimeInterval(60)) == .alreadyRecorded, "once a sitting")
        #expect(try answer(false, "reading-r1-b", at: Self.answeredAt.addingTimeInterval(120)) == .notCounted, "not due on the day it was answered")
        let held = try #require(try store.loadMemoryItem(itemID))
        let dueAt = MemoryTutorScheduler.schedule(item: held, attempts: try store.loadMemoryAttempts(memoryItemID: itemID), calendar: Self.calendar).dueAt
        #expect(try answer(false, "reading-r1-c", at: dueAt.addingTimeInterval(60)) == .recorded, "due, so it counts")
        #expect(try answer(true, "reading-r1-c", at: dueAt.addingTimeInterval(120)) == .alreadyRecorded)
    }

    // MARK: - Reading the learner's answers

    @Test("Where each question stands is read from the items and attempts the phone holds, as the Mac's store reads it")
    func standingMatchesTheStore() throws {
        let store = try makeStore()
        _ = try store.recordMnemonicReadingAnswer(
            Self.question, remembered: false, sittingKey: "reading-r1-a", at: Self.answeredAt, calendar: Self.calendar
        )
        let item = try #require(try store.loadMemoryItem(Self.question.memoryItemID))
        let attempts = try store.loadMemoryAttempts(memoryItemID: item.id)
        let unrelated = MemoryAttempt.selfGraded(id: "other", memoryItemID: "another-item", prompt: "?", remembered: true, at: Self.answeredAt)

        let phone = MobileMnemonicReadingMemory.standing(
            of: [Self.question, Self.second], items: [item], attempts: attempts + [unrelated], calendar: Self.calendar
        )
        let mac = try store.mnemonicReadingMemory(for: [Self.question, Self.second], calendar: Self.calendar)
        #expect(phone == mac)
        #expect(phone[Self.second.id] == nil, "an unanswered question is absent")
        let standing = try #require(phone[Self.question.id])
        #expect(standing.lastRemembered == false)

        #expect(MobileMnemonicReadingMemory.standingLine(standing, now: standing.dueAt) == "Forgot · due now")
        #expect(MobileMnemonicReadingMemory.standingLine(standing, now: Self.answeredAt).hasPrefix("Forgot · back "))
        let retired = MnemonicQuestionMemory(itemID: item.id, lastRemembered: true, dueAt: Self.answeredAt, isRetired: true)
        #expect(MobileMnemonicReadingMemory.standingLine(retired) == "Retired")
        let remembered = MnemonicQuestionMemory(itemID: item.id, lastRemembered: true, dueAt: Self.answeredAt.addingTimeInterval(4 * Self.day), isRetired: false)
        #expect(MobileMnemonicReadingMemory.standingLine(remembered, now: Self.answeredAt).hasPrefix("Remembered · back "))
    }

    @Test("A question can be answered once its text is read and places it, or once it is kept; never while its passage is gone")
    func canAnswer() {
        let gone = MnemonicQuestion.mint(sourceID: "chapter-1", quote: "never printed here", question: "Gone?", answer: "Yes.")
        let layout = MnemonicReadingPlacement.layout(text: Self.text, questions: [Self.question, gone])
        let texts: [String: MnemonicReadingSourceText] = ["chapter-1": .loaded(layout)]
        #expect(MobileMnemonicReadingMemory.canAnswer(Self.question.id, sourceID: "chapter-1", memory: [:], texts: texts))
        #expect(!MobileMnemonicReadingMemory.canAnswer(gone.id, sourceID: "chapter-1", memory: [:], texts: texts))
        #expect(!MobileMnemonicReadingMemory.canAnswer(Self.question.id, sourceID: "chapter-1", memory: [:], texts: ["chapter-1": .loading]))
        let kept = MnemonicQuestionMemory(itemID: gone.memoryItemID, lastRemembered: true, dueAt: Self.answeredAt, isRetired: false)
        #expect(MobileMnemonicReadingMemory.canAnswer(gone.id, sourceID: "chapter-1", memory: [gone.id: kept], texts: texts))
    }

    // MARK: - Fixtures

    private func artifact(kind: String?) -> MobileCloudArtifact {
        MobileCloudArtifact(
            id: "art-1",
            title: "Thinking, Fast and Slow with questions",
            kind: kind,
            homeNotebookID: "nb-1",
            linkedNotebookIDs: [],
            sourceIDs: ["chapter-1", "chapter-2"],
            linkedURL: nil,
            isDraft: false,
            teamID: nil,
            createdAt: Self.answeredAt,
            updatedAt: Self.answeredAt,
            bodyRevision: nil
        )
    }
}
