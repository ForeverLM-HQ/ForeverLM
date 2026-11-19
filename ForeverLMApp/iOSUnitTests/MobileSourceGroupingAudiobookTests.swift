import Foundation
import XCTest
@testable import ForeverLM

/// The headphones on a book's row in Sources → Books: shown only when every
/// chapter still in the book has text-to-speech audio on the phone.
final class MobileSourceGroupingAudiobookTests: XCTestCase {
    private func chapter(
        _ id: String,
        book: String = "book-1",
        hasAudio: Bool,
        isArchived: Bool = false
    ) -> MobileCloudSource {
        MobileCloudSource(
            id: id,
            title: "Chapter \(id)",
            subtitle: nil,
            sourceType: "book",
            dateAdded: Date(timeIntervalSinceReferenceDate: 0),
            hasAudio: hasAudio,
            isArchived: isArchived,
            parentGroup: book
        )
    }

    func testEveryChapterWithAudioIsAFinishedAudiobook() {
        let chapters = [
            chapter("1", hasAudio: true),
            chapter("2", hasAudio: true),
            chapter("3", hasAudio: true)
        ]
        XCTAssertTrue(MobileSourceGrouping.isAudiobookComplete(chapters: chapters))
    }

    func testOneChapterWithoutAudioIsNot() {
        let chapters = [
            chapter("1", hasAudio: true),
            chapter("2", hasAudio: false),
            chapter("3", hasAudio: true)
        ]
        XCTAssertFalse(MobileSourceGrouping.isAudiobookComplete(chapters: chapters))
    }

    func testArchivedChaptersAreNotPartOfTheBook() {
        let chapters = [
            chapter("1", hasAudio: true),
            chapter("2", hasAudio: false, isArchived: true)
        ]
        XCTAssertTrue(MobileSourceGrouping.isAudiobookComplete(chapters: chapters))
    }

    func testABookWithNothingToNarrateIsNotFinished() {
        XCTAssertFalse(MobileSourceGrouping.isAudiobookComplete(chapters: []))
        XCTAssertFalse(MobileSourceGrouping.isAudiobookComplete(
            chapters: [chapter("1", hasAudio: true, isArchived: true)]
        ))
    }

    func testGroupedBooksCarryTheAnswer() {
        var collections = MobileCatalogCollections()
        collections.booksByID["done"] = MobileCloudBook(id: "done", title: "Done", author: nil)
        collections.booksByID["half"] = MobileCloudBook(id: "half", title: "Half", author: nil)
        let sources = [
            chapter("d1", book: "done", hasAudio: true),
            chapter("d2", book: "done", hasAudio: true),
            chapter("h1", book: "half", hasAudio: true),
            chapter("h2", book: "half", hasAudio: false)
        ]

        let split = MobileSourceGrouping.groups(ofType: "book", in: sources, collections: collections)
        let byID = Dictionary(uniqueKeysWithValues: split.groups.map { ($0.id, $0) })
        XCTAssertEqual(byID["done"]?.isAudiobookComplete, true)
        XCTAssertEqual(byID["half"]?.isAudiobookComplete, false)
    }

    // MARK: - Generate Audiobook

    private func pendingIDs(
        _ chapters: [MobileCloudSource],
        preparing: Set<String> = [],
        listeningTo: String? = nil
    ) -> [String] {
        MobileAudiobookPlan.pendingChapters(
            chapters,
            hasAudio: \.hasAudio,
            isPreparing: { preparing.contains($0.id) },
            listeningTo: listeningTo
        ).map(\.id)
    }

    func testAWholeBookIsGeneratedInReadingOrder() {
        let chapters = [
            chapter("1", hasAudio: false),
            chapter("2", hasAudio: true),
            chapter("3", hasAudio: false),
            chapter("4", hasAudio: false, isArchived: true)
        ]
        XCTAssertEqual(pendingIDs(chapters), ["1", "3"])
    }

    /// What the listener reaches next is made first; the chapters behind them
    /// come round at the end.
    func testGenerationStartsAfterTheChapterBeingListenedTo() {
        let chapters = (1...5).map { chapter("\($0)", hasAudio: $0 == 3) }
        XCTAssertEqual(pendingIDs(chapters, listeningTo: "3"), ["4", "5", "1", "2"])
        XCTAssertEqual(pendingIDs(chapters, listeningTo: "not-in-this-book"), ["1", "2", "4", "5"])
    }

    func testAChapterAlreadyBeingGeneratedOrNotYetReadableIsLeftOut() {
        var notReady = chapter("2", hasAudio: false)
        notReady.state = "processing"
        let chapters = [chapter("1", hasAudio: false), notReady, chapter("3", hasAudio: false)]
        XCTAssertEqual(pendingIDs(chapters, preparing: ["1"]), ["3"])
    }

    func testThePlanCountsWhatIsLeftAndWhatIsDone() throws {
        var first = chapter("1", hasAudio: false)
        first.listenableCharacterCount = 9_000
        var second = chapter("2", hasAudio: false)
        second.wordCount = 1_000
        let unsized = chapter("3", hasAudio: false)
        let plan = try XCTUnwrap(MobileAudiobookPlan.plan(
            bookID: "book-1",
            title: "A Book",
            chapters: [first, second, unsized, chapter("4", hasAudio: true)],
            hasAudio: \.hasAudio,
            isPreparing: { _ in false },
            listeningTo: nil,
            provider: "openrouter",
            modelID: "a-model-this-build-has-no-price-for"
        ))
        XCTAssertEqual(plan.chapterIDs, ["1", "2", "3"])
        XCTAssertEqual(plan.readyChapterCount, 1)
        XCTAssertEqual(plan.estimate.sourceCount, 3)
        // A measured length as it stands, a word count at the fallback ratio,
        // and nothing invented for the chapter that has neither.
        XCTAssertEqual(
            plan.estimate.characters,
            9_000 + Int(1_000 * ArticleSpeechCostEstimate.fallbackCharactersPerWord)
        )
        // An unknown price is asked about, never taken for free.
        XCTAssertTrue(plan.isBillable)
        XCTAssertTrue(plan.confirmationMessage.contains("3 chapters"))
        XCTAssertTrue(plan.confirmationMessage.contains("1 chapter is already narrated"))
    }

    func testABookWithAllItsAudioHasNoPlan() {
        XCTAssertNil(MobileAudiobookPlan.plan(
            bookID: "book-1",
            title: "A Book",
            chapters: [chapter("1", hasAudio: true), chapter("2", hasAudio: true)],
            hasAudio: \.hasAudio,
            isPreparing: { _ in false },
            listeningTo: nil,
            provider: "openrouter",
            modelID: "any"
        ))
    }

    func testTheProgressLineNamesTheChapterInHand() {
        var run = MobileAudiobookGeneration(
            runID: UUID(),
            bookID: "book-1",
            title: "A Book",
            readyChapters: 3,
            totalChapters: 12
        )
        XCTAssertEqual(run.statusLabel, "3 of 12 chapters")
        run.currentChapterTitle = "4. The human side"
        XCTAssertEqual(run.statusLabel, "3 of 12 chapters · 4. The human side")
        run.isWaitingToResume = true
        XCTAssertEqual(run.statusLabel, "Waiting to resume · 3 of 12 chapters")
        XCTAssertEqual(run.fractionCompleted, 0.25, accuracy: 0.0001)
    }

    // MARK: - The player stays off a screen's bottom toolbar

    /// A phone 870 points tall: the home indicator's safe area ends at 836,
    /// and the player rests from 766 to 836.
    func testThePlayerRisesAboveAScreensBottomToolbar() {
        let reader = MobileShellBarLift.Screen(safeBottom: 792, fullBottom: 870)
        XCTAssertEqual(MobileShellBarLift.lift(barTop: 766, barBottom: 836, screens: [reader]), 44 + MobileShellBarLift.toolbarClearance)
    }

    func testAScreenWithoutAToolbarLeavesThePlayerWhereItRests() {
        let home = MobileShellBarLift.Screen(safeBottom: 836, fullBottom: 870)
        XCTAssertEqual(MobileShellBarLift.lift(barTop: 766, barBottom: 836, screens: [home]), 0)
        XCTAssertEqual(MobileShellBarLift.lift(barTop: 766, barBottom: 836, screens: []), 0)
    }

    /// Where the system hands the bar's inset on, the screen and its toolbar
    /// already end at the bar's top.
    func testAScreenThatEndsAtThePlayerDoesNotLiftIt() {
        let inset = MobileShellBarLift.Screen(safeBottom: 722, fullBottom: 766)
        XCTAssertEqual(MobileShellBarLift.lift(barTop: 766, barBottom: 836, screens: [inset]), 0)
    }

    func testAnEmptyBarIsNotLifted() {
        let reader = MobileShellBarLift.Screen(safeBottom: 792, fullBottom: 870)
        XCTAssertEqual(MobileShellBarLift.lift(barTop: 836, barBottom: 836, screens: [reader]), 0)
    }
}
