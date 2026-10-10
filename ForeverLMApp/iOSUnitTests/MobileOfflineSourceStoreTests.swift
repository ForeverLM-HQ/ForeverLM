import Foundation
import XCTest
@testable import ForeverLM

/// The durable store is the whole promise of Save Offline: if a saved copy can be
/// lost, overwritten with nothing, or double-counted, the feature lies to the user
/// about what will open on a plane.
final class MobileOfflineSourceStoreTests: XCTestCase {
    private var root: URL!
    private var store: MobileOfflineSourceStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-store-\(UUID().uuidString)", isDirectory: true)
        store = MobileOfflineSourceStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        store = nil
        root = nil
        try super.tearDownWithError()
    }

    func testSavedTextRoundTripsPerSource() async throws {
        try await store.writeText("The first source's text.", sourceID: "https://example.com/one")
        try await store.writeText("The second source's text.", sourceID: "https://example.com/two")

        let first = await store.savedText(sourceID: "https://example.com/one")
        let second = await store.savedText(sourceID: "https://example.com/two")
        let missing = await store.savedText(sourceID: "https://example.com/three")

        XCTAssertEqual(first, "The first source's text.")
        XCTAssertEqual(second, "The second source's text.")
        XCTAssertNil(missing)
    }

    /// A CloudKit fetch that decodes to whitespace must not replace a good saved
    /// copy — or report a source as saved when nothing readable landed.
    func testRefusesToSaveEmptyText() async throws {
        try await store.writeText("Real readable text.", sourceID: "source-1")

        do {
            try await store.writeText("   \n\t ", sourceID: "source-1")
            XCTFail("Writing blank text should throw")
        } catch {
            XCTAssertTrue(error is MobileOfflineSaveError)
        }

        let saved = await store.savedText(sourceID: "source-1")
        XCTAssertEqual(saved, "Real readable text.")
    }

    func testSavedPDFIsCopiedAndReportedOnlyWhenPresent() async throws {
        let cached = root.appendingPathComponent("cached.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 2_048).write(to: cached)

        let beforeSave = await store.savedPDFURL(sourceID: "paper-1")
        XCTAssertNil(beforeSave)

        let durable = try await store.savePDF(copyingFrom: cached, sourceID: "paper-1")
        let resolved = await store.savedPDFURL(sourceID: "paper-1")

        XCTAssertEqual(resolved, durable)
        XCTAssertEqual(try Data(contentsOf: durable).count, 2_048)
        // The cache copy stays where it was: the reader may still be holding it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))
    }

    /// `fetchPDF` returns the durable copy once one exists, so a re-save can be
    /// handed the destination itself. Removing first and copying second would
    /// delete the document.
    func testSavingAPDFFromItsOwnDurableURLKeepsTheDocument() async throws {
        let cached = root.appendingPathComponent("cached.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 512).write(to: cached)
        let durable = try await store.savePDF(copyingFrom: cached, sourceID: "paper-1")

        let again = try await store.savePDF(copyingFrom: durable, sourceID: "paper-1")

        XCTAssertEqual(again, durable)
        XCTAssertEqual(try Data(contentsOf: again).count, 512)
    }

    func testByteCountCoversTextAndDocumentAndDropsToZeroAfterRemoval() async throws {
        let cached = root.appendingPathComponent("cached.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: cached)

        try await store.writeText(String(repeating: "a", count: 100), sourceID: "paper-1")
        _ = try await store.savePDF(copyingFrom: cached, sourceID: "paper-1")
        try await store.writeText(String(repeating: "b", count: 50), sourceID: "article-1")

        let counts = await store.byteCounts(sourceIDs: ["paper-1", "article-1", "never-saved"])
        XCTAssertEqual(counts["paper-1"], 4_196)
        XCTAssertEqual(counts["article-1"], 50)
        XCTAssertEqual(counts["never-saved"], 0)

        await store.remove(sourceID: "paper-1")

        let afterRemoval = await store.byteCount(sourceID: "paper-1")
        let survivor = await store.byteCount(sourceID: "article-1")
        let removedText = await store.savedText(sourceID: "paper-1")
        let removedPDF = await store.savedPDFURL(sourceID: "paper-1")
        XCTAssertEqual(afterRemoval, 0)
        XCTAssertEqual(survivor, 50)
        XCTAssertNil(removedText)
        XCTAssertNil(removedPDF)
    }

    /// A saved book chapter keeps its illustrated document, not just its text:
    /// without it the chapter comes back on a plane with every figure gone.
    func testSavedChapterDocumentRoundTripsAndIsRemovedWithTheSource() async throws {
        let chapter = "<h2>Chapter One</h2><img src=\"data:image/png;base64,AAAA\"/>"

        try await store.writeText("Chapter One text.", sourceID: "book-1")
        try await store.writeReaderHTML(chapter, sourceID: "book-1")

        let saved = await store.savedReaderHTML(sourceID: "book-1")
        let other = await store.savedReaderHTML(sourceID: "book-2")
        XCTAssertEqual(saved, chapter)
        XCTAssertNil(other)

        // Both halves count toward what the Offline screen reports.
        let bytes = await store.byteCount(sourceID: "book-1")
        XCTAssertEqual(bytes, Int64("Chapter One text.".utf8.count + chapter.utf8.count))

        await store.remove(sourceID: "book-1")
        let afterRemoval = await store.savedReaderHTML(sourceID: "book-1")
        XCTAssertNil(afterRemoval)
    }

    func testRefusesToSaveAnEmptyChapterDocument() async throws {
        try await store.writeReaderHTML("<p>Real chapter markup.</p>", sourceID: "book-1")

        do {
            try await store.writeReaderHTML("", sourceID: "book-1")
            XCTFail("Writing an empty chapter document should throw")
        } catch {
            XCTAssertTrue(error is MobileOfflineSaveError)
        }

        let saved = await store.savedReaderHTML(sourceID: "book-1")
        XCTAssertEqual(saved, "<p>Real chapter markup.</p>")
    }

    func testRemoveAllClearsEverythingAndStaysUsable() async throws {
        try await store.writeText("One.", sourceID: "source-1")
        try await store.writeText("Two.", sourceID: "source-2")

        await store.removeAll()

        let first = await store.savedText(sourceID: "source-1")
        let second = await store.savedText(sourceID: "source-2")
        XCTAssertNil(first)
        XCTAssertNil(second)

        // Removing the root must not brick the store: the next save recreates it.
        try await store.writeText("Three.", sourceID: "source-3")
        let third = await store.savedText(sourceID: "source-3")
        XCTAssertEqual(third, "Three.")
    }

    func testPinsPersistAsASetOfSourceIDs() {
        let suiteName = "offline-pins-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(MobileOfflinePins.saved(defaults: defaults).isEmpty)
        XCTAssertFalse(MobileOfflinePins.contains("source-1", defaults: defaults))

        MobileOfflinePins.write(["source-2", "source-1"], defaults: defaults)

        XCTAssertEqual(MobileOfflinePins.saved(defaults: defaults), ["source-1", "source-2"])
        XCTAssertTrue(MobileOfflinePins.contains("source-1", defaults: defaults))

        MobileOfflinePins.write([], defaults: defaults)
        XCTAssertTrue(MobileOfflinePins.saved(defaults: defaults).isEmpty)
    }
}

/// Two alerts asked to present in the same runloop turn abort the process:
/// UIKit runs one alert transition at a time and traps rather than queueing.
/// Every alert the phone raises on its own schedule therefore goes through
/// `MobileAsyncAlert`, so these tests guard the one invariant that keeps that
/// crash away — exactly one alert is ever allowed on screen.
final class MobileAsyncAlertTests: XCTestCase {
    func testNothingPendingPresentsNothing() {
        XCTAssertNil(MobileAsyncAlert.resolve())
    }

    func testEachAlertPresentsWhenItIsTheOnlyOnePending() {
        XCTAssertEqual(
            MobileAsyncAlert.resolve(textToSpeechCostPending: true),
            .textToSpeechCost
        )
        XCTAssertEqual(
            MobileAsyncAlert.resolve(bookContinuationPending: true),
            .bookContinuation
        )
        XCTAssertEqual(
            MobileAsyncAlert.resolve(offlineFailureSourceID: "source-a"),
            .offlineSaveFailure(sourceID: "source-a")
        )
    }

    /// The crash needs two alerts at once, so the case that matters is every
    /// alert landing together: exactly one may be chosen, and it is the same
    /// one whichever way the others are combined.
    func testOnlyTheHighestPriorityAlertPresentsWhenAllLandTogether() {
        XCTAssertEqual(
            MobileAsyncAlert.resolve(
                textToSpeechCostPending: true,
                bookContinuationPending: true,
                offlineFailureSourceID: "source-a"
            ),
            .textToSpeechCost
        )
        XCTAssertEqual(
            MobileAsyncAlert.resolve(
                bookContinuationPending: true,
                offlineFailureSourceID: "source-a"
            ),
            .bookContinuation
        )
    }

    /// Spending is asked about before anything else, and a failure notice —
    /// which stays pending until it is dismissed — waits for both.
    func testQueueDrainsInPriorityOrderAsEachAlertIsDismissed() {
        var textToSpeechPending = true
        var bookPending = true
        let failureID: String? = "source-a"

        XCTAssertEqual(
            MobileAsyncAlert.resolve(
                textToSpeechCostPending: textToSpeechPending,
                bookContinuationPending: bookPending,
                offlineFailureSourceID: failureID
            ),
            .textToSpeechCost
        )

        textToSpeechPending = false
        XCTAssertEqual(
            MobileAsyncAlert.resolve(
                textToSpeechCostPending: textToSpeechPending,
                bookContinuationPending: bookPending,
                offlineFailureSourceID: failureID
            ),
            .bookContinuation
        )

        bookPending = false
        XCTAssertEqual(
            MobileAsyncAlert.resolve(
                textToSpeechCostPending: textToSpeechPending,
                bookContinuationPending: bookPending,
                offlineFailureSourceID: failureID
            ),
            .offlineSaveFailure(sourceID: "source-a")
        )
    }

    /// A bulk save that fails for several sources at once is the plainest way
    /// to raise two alerts in one turn: one per failing row. Only the surfaced
    /// row may present, and it is stable rather than dependent on dictionary
    /// order.
    @MainActor
    func testConcurrentOfflineFailuresSurfaceOneRowAtATime() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-alerts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MobileOfflineLibrary(store: MobileOfflineSourceStore(root: root))
        XCTAssertNil(library.surfacedFailureSourceID)

        library.recordFailure("Ran out of space.", sourceID: "source-c")
        library.recordFailure("Ran out of space.", sourceID: "source-a")
        library.recordFailure("Ran out of space.", sourceID: "source-b")

        XCTAssertEqual(library.surfacedFailureSourceID, "source-a")

        library.clearFailure(sourceID: "source-a")
        XCTAssertEqual(library.surfacedFailureSourceID, "source-b")

        library.clearFailure(sourceID: "source-b")
        XCTAssertEqual(library.surfacedFailureSourceID, "source-c")

        library.clearFailure(sourceID: "source-c")
        XCTAssertNil(library.surfacedFailureSourceID)
    }
}
