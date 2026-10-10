import Testing
import Foundation
@testable import ForeverLM

/// The Sources list's selection rules and the payload a drag from it carries.
///
/// The product owner, 2026-09-07: shift-selecting several sources did not persist, so
/// they could not be dragged into a Notebook as a group. The selection used to
/// collapse to one row when shift went up, and the drop targets re-read the
/// live selection under the modifier instead of the payload.
@Suite("Sidebar source selection")
struct SidebarSourceSelectionTests {
    private let known: Set<String> = ["a", "b", "c", "d"]
    private func isKnown(_ id: String) -> Bool { known.contains(id) }

    // MARK: Writes from the list

    @Test("a plain click selects the row and opens it")
    func plainClickSelectsAndOpens() {
        let resolution = SidebarSourceSelection.resolve(
            listSelection: ["b"],
            previousSelection: ["a"],
            usesMultiSelectModifier: false,
            isKnownSource: isKnown
        )
        #expect(resolution == .init(selection: ["b"], opensSource: "b"))
    }

    @Test("a plain click on one row of a multi-selection collapses to that row")
    func plainClickInsideMultiSelectionCollapses() {
        let resolution = SidebarSourceSelection.resolve(
            listSelection: ["b"],
            previousSelection: ["a", "b", "c"],
            usesMultiSelectModifier: false,
            isKnownSource: isKnown
        )
        #expect(resolution == .init(selection: ["b"], opensSource: "b"))
    }

    @Test("a shift-click keeps every row and opens nothing")
    func shiftClickExtendsWithoutOpening() {
        let resolution = SidebarSourceSelection.resolve(
            listSelection: ["a", "b", "c"],
            previousSelection: ["a"],
            usesMultiSelectModifier: true,
            isKnownSource: isKnown
        )
        #expect(resolution == .init(selection: ["a", "b", "c"], opensSource: nil))
    }

    @Test("a command-click that toggles a row off keeps the rest and opens nothing")
    func commandClickTogglesOff() {
        let resolution = SidebarSourceSelection.resolve(
            listSelection: ["a", "c"],
            previousSelection: ["a", "b", "c"],
            usesMultiSelectModifier: true,
            isKnownSource: isKnown
        )
        #expect(resolution == .init(selection: ["a", "c"], opensSource: nil))
    }

    @Test("a command-click that leaves one row does not open it")
    func commandClickDownToOneRowStaysSelectionOnly() {
        let resolution = SidebarSourceSelection.resolve(
            listSelection: ["a"],
            previousSelection: ["a", "b"],
            usesMultiSelectModifier: true,
            isKnownSource: isKnown
        )
        #expect(resolution == .init(selection: ["a"], opensSource: nil))
    }

    @Test("a rebuilt list echoing the selection with no modifier keeps it whole")
    func echoedMultiSelectionSurvivesWithoutModifier() {
        // The modifier has been released, the list was rebuilt, and it writes
        // back what this window already holds. Until 2026-09-07 this collapsed.
        let resolution = SidebarSourceSelection.resolve(
            listSelection: ["a", "b", "c"],
            previousSelection: ["a", "b", "c"],
            usesMultiSelectModifier: false,
            isKnownSource: isKnown
        )
        #expect(resolution == .init(selection: ["a", "b", "c"], opensSource: nil))
    }

    @Test("an echo pruned to the visible rows keeps those rows without opening one")
    func prunedEchoKeepsVisibleRows() {
        let resolution = SidebarSourceSelection.resolve(
            listSelection: ["a", "b"],
            previousSelection: ["a", "b", "c"],
            usesMultiSelectModifier: false,
            isKnownSource: isKnown
        )
        #expect(resolution == .init(selection: ["a", "b"], opensSource: nil))
    }

    @Test("a multi-row write with one new row and no modifier is a click on that row")
    func multiRowWriteWithOneNewRowIsTheClick() {
        let resolution = SidebarSourceSelection.resolve(
            listSelection: ["a", "b", "d"],
            previousSelection: ["a", "b"],
            usesMultiSelectModifier: false,
            isKnownSource: isKnown
        )
        #expect(resolution == .init(selection: ["d"], opensSource: "d"))
    }

    @Test("a presentation identity that is not a source is ignored")
    func unknownIdentityIsIgnored() {
        let resolution = SidebarSourceSelection.resolve(
            listSelection: ["Lecture 3"],
            previousSelection: ["a"],
            usesMultiSelectModifier: false,
            isKnownSource: isKnown
        )
        #expect(resolution == nil)
    }

    @Test("unknown identities are dropped from a real multi-selection")
    func unknownIdentitiesAreFilteredOut() {
        let resolution = SidebarSourceSelection.resolve(
            listSelection: ["a", "Lecture 3", "b"],
            previousSelection: [],
            usesMultiSelectModifier: true,
            isKnownSource: isKnown
        )
        #expect(resolution == .init(selection: ["a", "b"], opensSource: nil))
    }

    // MARK: The row gesture

    @Test("the row tap does not open a row the click left inside a multi-selection")
    func rowTapInsideMultiSelectionDoesNotOpen() {
        // Shift released before mouse-up: the selection is the only evidence.
        #expect(SidebarSourceSelection.rowTapOpens(
            sourceID: "b", selection: ["a", "b"], usesMultiSelectModifier: false
        ) == false)
    }

    @Test("the row tap does not open a row the click toggled off")
    func rowTapWithModifierDoesNotOpen() {
        #expect(SidebarSourceSelection.rowTapOpens(
            sourceID: "b", selection: ["a"], usesMultiSelectModifier: true
        ) == false)
    }

    @Test("the row tap opens a plain click")
    func rowTapOpensPlainClick() {
        #expect(SidebarSourceSelection.rowTapOpens(
            sourceID: "b", selection: ["b"], usesMultiSelectModifier: false
        ))
    }

    // MARK: Escape

    @Test("Escape collapses a multi-selection to the source the Reader shows")
    func escapeCollapsesToReaderSource() {
        #expect(SidebarSourceSelection.selectionAfterEscape(
            selection: ["a", "b", "c"], readerSourceID: "b"
        ) == ["b"])
    }

    @Test("Escape clears a multi-selection when the Reader shows none of it")
    func escapeClearsWithoutReaderSource() {
        #expect(SidebarSourceSelection.selectionAfterEscape(
            selection: ["a", "b"], readerSourceID: "z"
        ) == [])
        #expect(SidebarSourceSelection.selectionAfterEscape(
            selection: ["a", "b"], readerSourceID: nil
        ) == [])
    }

    @Test("Escape leaves a single selection alone")
    func escapeIgnoresSingleSelection() {
        #expect(SidebarSourceSelection.selectionAfterEscape(
            selection: ["a"], readerSourceID: "a"
        ) == nil)
        #expect(SidebarSourceSelection.selectionAfterEscape(
            selection: [], readerSourceID: nil
        ) == nil)
    }

    // MARK: What a drag picks up

    @Test("dragging a row inside the selection drags the whole selection in display order")
    func dragFromSelectedRowCarriesSelection() {
        let ids = SidebarSourceSelection.dragSourceIDs(
            startingWith: "c",
            selection: ["a", "b", "c"],
            displayOrder: { selection in ["a", "b", "c", "d"].filter(selection.contains) }
        )
        #expect(ids == ["a", "b", "c"])
    }

    @Test("dragging a row outside the selection drags that row alone")
    func dragFromUnselectedRowCarriesOnlyThatRow() {
        let ids = SidebarSourceSelection.dragSourceIDs(
            startingWith: "d",
            selection: ["a", "b"],
            displayOrder: { _ in Issue.record("display order is not consulted"); return [] }
        )
        #expect(ids == ["d"])
    }

    @Test("dragging the only selected row drags that row alone")
    func dragFromSingleSelectionCarriesOnlyThatRow() {
        let ids = SidebarSourceSelection.dragSourceIDs(
            startingWith: "a",
            selection: ["a"],
            displayOrder: { _ in Issue.record("display order is not consulted"); return [] }
        )
        #expect(ids == ["a"])
    }
}

/// The transfer a source drag writes to the pasteboard, and what a drop reads
/// back out of it.
@Suite("Source drag payload")
struct SourceDragPayloadTests {
    private func makeArticle(id: String, title: String) -> StudioArticle {
        StudioArticle(url: "https://example.com/\(id)", title: title, sourceType: .article, id: id)
    }

    @Test("a multi-selection drag carries every id in order and names the count")
    func multiSelectionPayloadCarriesEveryID() throws {
        let article = makeArticle(id: "b", title: "Second")
        let transfer = StudioArticleTransfer.dragging(article, draggedIDs: ["a", "b", "c"])
        #expect(transfer.articleId == "b")
        #expect(transfer.articleIds == ["a", "b", "c"])
        #expect(transfer.title == "3 sources")
        #expect(transfer.sourceType == "selection")

        // What crosses the pasteboard is the codable form; the drop reads the
        // list back from it, never from live selection state.
        let data = try JSONEncoder().encode(transfer)
        let decoded = try JSONDecoder().decode(StudioArticleTransfer.self, from: data)
        #expect(decoded.draggedSourceIDs == ["a", "b", "c"])
    }

    @Test("a single drag carries the article itself")
    func singleDragCarriesTheArticle() throws {
        let article = makeArticle(id: "a", title: "First")
        let transfer = StudioArticleTransfer.dragging(article, draggedIDs: ["a"])
        #expect(transfer.articleId == "a")
        #expect(transfer.articleIds == nil)
        #expect(transfer.title == "First")
        #expect(transfer.url == article.url)

        let data = try JSONEncoder().encode(transfer)
        let decoded = try JSONDecoder().decode(StudioArticleTransfer.self, from: data)
        #expect(decoded.draggedSourceIDs == ["a"])
    }

    @Test("blank ids never make a drag look like a selection")
    func blankIDsAreDropped() {
        let article = makeArticle(id: "a", title: "First")
        #expect(StudioArticleTransfer.dragging(article, draggedIDs: ["a", " ", ""]).articleIds == nil)
        #expect(StudioArticleTransfer.dragging(article, draggedIDs: []).draggedSourceIDs == ["a"])
    }

    @Test("a payload with an empty id list still names the row under the pointer")
    func emptyIDListFallsBackToTheRow() {
        let transfer = StudioArticleTransfer(articleId: "a", articleIds: [], title: "First", sourceType: "article")
        #expect(transfer.draggedSourceIDs == ["a"])
    }
}
