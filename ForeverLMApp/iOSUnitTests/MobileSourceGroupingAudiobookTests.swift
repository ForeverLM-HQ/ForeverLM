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
}
