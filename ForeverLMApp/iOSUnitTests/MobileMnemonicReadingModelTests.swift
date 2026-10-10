import Foundation
import XCTest
@testable import ForeverLM

/// A mnemonic reading open on the phone (docs/memory-design.md, "Mnemonic
/// reading (2026-10-03)"): opening reads and writes nothing; a source's text
/// is read only when asked for, and its questions placed in it; a first
/// answer keeps the card with its first attempt in one write; a later one is
/// written only by the card review's rules; a question whose passage is gone
/// cannot be kept; a failed write is said on the card; Next goes round the
/// unanswered questions.
@MainActor
final class MobileMnemonicReadingModelTests: XCTestCase {
    private let day = MemoryTutorScheduler.secondsPerDay
    private let now = Date(timeIntervalSinceReferenceDate: 812_000_000)

    private static let text = """
    System 1 operates automatically and quickly, with little or no effort and no sense of voluntary control.

    System 2 allocates attention to the effortful mental activities that demand it.
    """

    private let placed = MnemonicQuestion.mint(
        sourceID: "chapter-1",
        quote: "System 1 operates automatically and quickly",
        question: "Which system operates automatically and quickly?",
        answer: "System 1."
    )
    private let later = MnemonicQuestion.mint(
        sourceID: "chapter-1",
        quote: "System 2 allocates attention",
        question: "Which system allocates attention to effortful activities?",
        answer: "System 2."
    )
    private let gone = MnemonicQuestion.mint(
        sourceID: "chapter-1",
        quote: "A sentence this chapter no longer prints",
        question: "What did the chapter once say?",
        answer: "Something else."
    )

    private var body: String {
        MnemonicReading(title: "Thinking with questions", sections: [
            .init(sourceID: "chapter-1", title: "The Characters", isWritten: true, questions: [later, placed, gone]),
            .init(sourceID: "chapter-2", title: "Attention and Effort", isWritten: false),
        ]).markdown
    }

    /// What the catalog holds and what the reading wrote.
    @MainActor
    private final class Library {
        var items: [MemoryItem] = []
        var attempts: [MemoryAttempt] = []
        var kept: [(item: MemoryItem, attempt: MemoryAttempt, identities: [MobileReviewSourceIdentityPayload])] = []
        var written: [(attempt: MemoryAttempt, fingerprint: String)] = []
        var textReads: [String] = []
        var failsWrites = false
        var keepResult: MobileMemoryAttemptRecorder.KeepResult = .kept
        var awake = 0

        func backend(body: String, now: Date) -> MobileMnemonicReadingModel.Backend {
            MobileMnemonicReadingModel.Backend(
                body: { body },
                text: { sourceID in
                    self.textReads.append(sourceID)
                    guard sourceID == "chapter-1" else { throw URLError(.fileDoesNotExist) }
                    return MobileMnemonicReadingModelTests.text
                },
                title: { ["chapter-1": "The Characters of the Story", "chapter-2": "Attention and Effort"][$0] },
                identity: { MobileReviewSourceIdentityPayload(sourceID: $0, url: "https://example.com/\($0)", normalizedURL: nil, doi: nil, publishedDOI: nil) },
                held: { ids in
                    (self.items.filter { ids.contains($0.id) }, self.attempts.filter { ids.contains($0.memoryItemID) })
                },
                keep: { item, identities, attempt in
                    if self.failsWrites { throw URLError(.notConnectedToInternet) }
                    self.kept.append((item, attempt, identities))
                    return self.keepResult
                },
                write: { attempt, fingerprint in
                    if self.failsWrites { throw URLError(.notConnectedToInternet) }
                    self.written.append((attempt, fingerprint))
                    return .recorded
                },
                noteKept: { item, attempt in
                    self.items.append(item)
                    self.attempts.append(attempt)
                },
                noteRecorded: { self.attempts.append($0) },
                keepAwake: {
                    self.awake += 1
                    return { self.awake -= 1 }
                },
                now: { now }
            )
        }
    }

    private func open(_ library: Library, at date: Date? = nil) async -> MobileMnemonicReadingModel {
        let model = MobileMnemonicReadingModel(
            readingID: "reading-1",
            fallbackTitle: "Reading",
            sittingToken: "t1",
            backend: library.backend(body: body, now: date ?? now)
        )
        await model.load()
        return model
    }

    func testOpeningReadsNoTextAndWritesNothing() async {
        let library = Library()
        let model = await open(library)
        XCTAssertEqual(model.reading?.title, "Thinking with questions")
        XCTAssertEqual(model.sittingKey, "reading-reading-1-t1")
        XCTAssertEqual(model.rows.map(\.id), [
            "heading:chapter-1", "loading:chapter-1",
            "heading:chapter-2", "pending:chapter-2", "loading:chapter-2",
        ])
        XCTAssertEqual(MnemonicReadingProgress.line(model.counts()), "3 questions · 0 answered")
        XCTAssertTrue(library.textReads.isEmpty, "a source's text is read only as its place comes into view")
        XCTAssertTrue(library.kept.isEmpty)
        XCTAssertTrue(library.written.isEmpty)
        if case .heading(_, let title) = model.rows[0] {
            XCTAssertEqual(title, "The Characters of the Story", "the library's own title")
        } else {
            XCTFail("a source starts under its title")
        }
    }

    func testTextPlacesEachQuestionAfterItsPassage() async {
        let library = Library()
        let model = await open(library)
        await model.loadText(of: "chapter-1")
        await model.loadText(of: "chapter-1")
        XCTAssertEqual(library.textReads, ["chapter-1"], "read once")
        XCTAssertEqual(model.rows.map(\.id), [
            "heading:chapter-1",
            "block:chapter-1:0", MnemonicReadingRow.questionRowID(placed.id),
            "block:chapter-1:1", MnemonicReadingRow.questionRowID(later.id),
            MnemonicReadingRow.questionRowID(gone.id),
            "heading:chapter-2", "pending:chapter-2", "loading:chapter-2",
        ])
        XCTAssertTrue(model.rows.contains(.question(gone, isUnplaced: true)))
        XCTAssertTrue(model.canAnswer(placed.id))
        XCTAssertFalse(model.canAnswer(gone.id), "its passage is gone, so it cannot be kept")

        await model.loadText(of: "chapter-2")
        XCTAssertTrue(model.rows.contains(.unavailable(sourceID: "chapter-2", reason: "This source's text has not reached this iPhone yet.")))
    }

    func testFirstAnswerKeepsTheCardWithItsFirstAttempt() async throws {
        let library = Library()
        let model = await open(library)
        await model.loadText(of: "chapter-1")
        model.reveal(placed.id)
        await model.answer(placed, remembered: true)

        XCTAssertEqual(library.kept.count, 1)
        let kept = try XCTUnwrap(library.kept.first)
        XCTAssertEqual(kept.item.id, MemoryTutorIdentity.cardItemID(cardID: placed.id))
        XCTAssertEqual(MemoryCard(storedIn: kept.item)?.origin, .reading)
        XCTAssertEqual(kept.item.sources.map(\.excerpt), [placed.quote])
        XCTAssertEqual(kept.item.sources.map(\.sourceSHA256), [MobileMnemonicReading.sha256(Self.text)])
        XCTAssertEqual(kept.attempt.id, MemoryTutorIdentity.selfGradedAttemptID(sessionKey: model.sittingKey, memoryItemID: kept.item.id))
        XCTAssertEqual(kept.attempt.attemptType, .discovery)
        XCTAssertEqual(kept.attempt.scheduleRating, .good)
        XCTAssertEqual(kept.identities.map(\.sourceID), ["chapter-1"])
        XCTAssertEqual(library.awake, 0, "the app is let go once the write lands")

        let standing = try XCTUnwrap(model.memory[placed.id])
        XCTAssertEqual(standing.lastRemembered, true)
        XCTAssertFalse(model.revealed.contains(placed.id), "the card folds")
        XCTAssertEqual(MnemonicReadingProgress.line(model.counts()), "3 questions · 1 answered")

        // Not due on the day it was answered: a second grade writes nothing.
        await model.answer(placed, remembered: false)
        XCTAssertEqual(library.kept.count, 1)
        XCTAssertTrue(library.written.isEmpty)

        // The memory survives a fresh read of the catalog.
        await model.refreshMemory()
        XCTAssertNotNil(model.memory[placed.id])
    }

    func testAKeptCardIsAnsweredByTheCardReviewsRules() async throws {
        let library = Library()
        let first = MobileMnemonicReadingAnswer.firstAttempt(placed, remembered: true, sittingKey: "reading-reading-1-before", at: now)
        let item = try MobileMnemonicReadingAnswer.keptItem(placed, sourceText: Self.text, at: now)
        library.items = [item]
        library.attempts = [first]
        let dueAt = MemoryTutorScheduler.schedule(item: item, attempts: [first]).dueAt
        let model = await open(library, at: dueAt.addingTimeInterval(60))
        XCTAssertNotNil(model.memory[placed.id], "answered on another device")

        // Due: written as the card review writes it, on the kept item, with no text read.
        await model.answer(placed, remembered: false)
        XCTAssertTrue(library.kept.isEmpty)
        let written = try XCTUnwrap(library.written.first)
        XCTAssertEqual(written.attempt.attemptType, .review)
        XCTAssertEqual(written.attempt.scheduleRating, .again)
        XCTAssertEqual(written.fingerprint, MemoryTutorIdentity.immutableCurriculumFingerprint(item))
        XCTAssertTrue(library.textReads.isEmpty)

        // Once a sitting.
        await model.answer(placed, remembered: true)
        XCTAssertEqual(library.written.count, 1)
    }

    func testAFailedWriteIsSaidAndKeepsNothing() async {
        let library = Library()
        library.failsWrites = true
        let model = await open(library)
        await model.loadText(of: "chapter-1")
        await model.answer(placed, remembered: true)
        XCTAssertNotNil(model.answerErrors[placed.id])
        XCTAssertNil(model.memory[placed.id])
        XCTAssertEqual(library.awake, 0)

        // A question whose passage is gone is refused before anything is written.
        library.failsWrites = false
        await model.answer(gone, remembered: true)
        XCTAssertTrue(library.kept.isEmpty)
        XCTAssertNotNil(model.answerErrors[gone.id])
    }

    func testACardKeptElsewhereFirstStandsAnswered() async throws {
        let library = Library()
        let elsewhere = try MobileMnemonicReadingAnswer.keptItem(placed, sourceText: Self.text, at: now.addingTimeInterval(-60))
        library.keepResult = .keptElsewhere(elsewhere, .recorded)
        let model = await open(library)
        await model.loadText(of: "chapter-1")
        await model.answer(placed, remembered: false)
        XCTAssertEqual(library.kept.count, 1)
        XCTAssertEqual(model.memory[placed.id]?.lastRemembered, false)
    }

    func testNextGoesRoundTheUnansweredQuestionsInReadingOrder() async {
        let library = Library()
        let model = await open(library)
        await model.loadText(of: "chapter-1")
        XCTAssertEqual(model.nextUnansweredQuestionID(), placed.id, "placed order, not the body's")
        model.currentQuestionID = placed.id
        XCTAssertEqual(model.nextUnansweredQuestionID(), later.id)
        await model.answer(later, remembered: true)
        XCTAssertEqual(model.nextUnansweredQuestionID(), gone.id)
    }
}
