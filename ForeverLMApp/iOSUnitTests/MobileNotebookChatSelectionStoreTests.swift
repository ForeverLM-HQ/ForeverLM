import Foundation
import XCTest
@testable import ForeverLM

/// A notebook's chat boxes on the phone keep the Mac's two synced rows
/// (`notebook.chatExcluded.<notebookID>` and
/// `notebook.chatContextNotebooks.<notebookID>`, docs/notebooks-design.md,
/// "iPhone"): a tap reads both rows again, applies the Mac's rule
/// (`NotebookChatContext`) and writes only a row that changed, the unticked
/// one first; an empty row is removed, a source gone from the pool drops out
/// of the unticked row, a context notebook this phone does not know is
/// linked stays in its row, and a failed write shows the rows as they stand.
@MainActor
final class MobileNotebookChatSelectionStoreTests: XCTestCase {
    /// The account's Preference rows, as the store reads and writes them.
    private actor Rows {
        struct Write: Equatable {
            let key: String
            let value: [String]
        }

        private(set) var values: [String: [String]] = [:]
        private(set) var writes: [Write] = []
        private var failsWrites = false

        func read(_ key: String) -> [String]? { values[key] }

        func write(_ key: String, _ value: [String]) throws {
            if failsWrites { throw URLError(.notConnectedToInternet) }
            writes.append(Write(key: key, value: value))
            values[key] = value.isEmpty ? nil : value
        }

        func set(_ key: String, _ value: [String]?) { values[key] = value }
        func failWrites() { failsWrites = true }
    }

    private let key = MobileNotebookChatSelection.preferenceKey(notebookID: "p1")
    private let contextKey = MobileNotebookChatSelection.contextNotebooksKey(notebookID: "p1")
    private let pool = ["d", "a", "c", "b"]

    /// A notebook of `pool`, linked to two notebooks no one put in yet.
    private var notebook: MobileCloudNotebook {
        MobileCloudNotebook(
            id: "p1",
            title: "Notebook",
            instructions: nil,
            sourceIDs: pool,
            relatedNotebookIDs: ["r2", "r1"],
            contextNotebooks: [
                MobileCloudContextNotebook(id: "r2", title: "Aging", sourceIDs: ["x", "y"], poolSourceIDs: ["x", "y"]),
                MobileCloudContextNotebook(id: "r1", title: "GDF15", sourceIDs: ["z"], poolSourceIDs: ["z"]),
            ],
            isArchived: false,
            updatedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    private func store(_ rows: Rows) -> MobileNotebookChatSelectionStore {
        MobileNotebookChatSelectionStore(
            read: { key in await rows.read(key) },
            write: { key, value in try await rows.write(key, value) }
        )
    }

    func testLoadingReadsBothRows() async {
        let rows = Rows()
        await rows.set(key, ["a"])
        await rows.set(contextKey, ["r1"])
        let selection = store(rows)
        XCTAssertFalse(selection.isLoaded)
        XCTAssertEqual(selection.chatSourceIDs(of: notebook), [], "nothing is read before the rows are")

        await selection.load(notebookID: "p1")
        XCTAssertEqual(selection.excluded, ["a"])
        XCTAssertEqual(selection.contextNotebookIDs, ["r1"])
        XCTAssertEqual(selection.chatSourceIDs(of: notebook), ["d", "c", "b", "z"])
    }

    func testATapRereadsTheRowAndWritesTheMacsExclusion() async {
        let rows = Rows()
        let selection = store(rows)
        await selection.load(notebookID: "p1")
        XCTAssertEqual(selection.excluded, [], "no row is every box ticked")
        XCTAssertEqual(selection.contextNotebookIDs, [], "no row is no context notebook put in")

        // Another device unticked b after the notebook opened here.
        await rows.set(key, ["b"])
        await selection.set(["d", "a"], inChat: false, in: notebook)

        let writes = await rows.writes
        XCTAssertEqual(writes, [.init(key: key, value: ["a", "b", "d"])], "sorted, the other device's untick kept, and only the row that changed")
        XCTAssertEqual(selection.excluded, ["a", "b", "d"])
        let board = selection.board(for: notebook)
        XCTAssertEqual(board?.isInChat("a"), false)
        XCTAssertEqual(board?.isInChat("c"), true)
        XCTAssertEqual(board?.isInChat("x"), false, "a context notebook no one put in reads nothing")
    }

    func testTickingEveryBoxRemovesTheRow() async {
        let rows = Rows()
        await rows.set(key, ["a"])
        let selection = store(rows)
        await selection.load(notebookID: "p1")
        XCTAssertEqual(selection.excluded, ["a"])

        await selection.setAll(inChat: true, in: notebook)

        let writes = await rows.writes
        XCTAssertEqual(writes, [.init(key: key, value: [])], "an empty exclusion is written as the row's removal")
        let row = await rows.read(key)
        XCTAssertNil(row)
        XCTAssertEqual(selection.excluded, [])
        XCTAssertEqual(selection.contextNotebookIDs, [], "Select all puts no context notebook in")
    }

    func testTheSameExclusionAgainWritesNothing() async {
        let rows = Rows()
        await rows.set(key, ["a"])
        let selection = store(rows)
        await selection.load(notebookID: "p1")

        await selection.set(["a"], inChat: false, in: notebook)

        let writes = await rows.writes
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(selection.excluded, ["a"])
    }

    func testASourceGoneFromThePoolDropsOutOfTheRow() async {
        let rows = Rows()
        await rows.set(key, ["gone"])
        let selection = store(rows)
        await selection.load(notebookID: "p1")

        // Any tap re-normalises the unticked row against the pool, as the
        // Mac's does.
        await selection.set(["c"], inChat: true, in: notebook)

        let writes = await rows.writes
        XCTAssertEqual(writes, [.init(key: key, value: [])])
        XCTAssertEqual(selection.excluded, [])
    }

    func testATapKeepsAContextNotebookAnotherDevicePutIn() async {
        let rows = Rows()
        // The Mac linked r9 and put it in; this phone's catalog has not
        // caught up with the link yet.
        await rows.set(contextKey, ["r1", "r9"])
        let selection = store(rows)
        await selection.load(notebookID: "p1")
        XCTAssertEqual(selection.chatSourceIDs(of: notebook), ["d", "a", "c", "b", "z"], "a notebook not linked here reads nothing")

        await selection.set(["a"], inChat: false, in: notebook)
        await selection.setContextNotebooks(["r2"], inChat: true, in: notebook)
        await selection.setAll(inChat: true, in: notebook)

        let writes = await rows.writes
        XCTAssertEqual(writes, [
            .init(key: key, value: ["a"]),
            .init(key: contextKey, value: ["r1", "r2", "r9"]),
            .init(key: key, value: []),
        ], "no box drops r9")
        XCTAssertEqual(selection.contextNotebookIDs, ["r1", "r2", "r9"])
        XCTAssertEqual(selection.board(for: notebook)?.isInChats(contextNotebook: "r9"), false)

        // Only taking it out of context removes it.
        await selection.setContextNotebooks(["r9"], inChat: false, in: notebook)
        let row = await rows.read(contextKey)
        XCTAssertEqual(row, ["r1", "r2"])
    }

    func testPuttingAContextNotebookInKeepsWhatWasUntickedInIt() async {
        let rows = Rows()
        // x, one of Aging's sources, was unticked while Aging was in.
        await rows.set(key, ["x"])
        let selection = store(rows)
        await selection.load(notebookID: "p1")

        // Its box puts it back in as it was left: x stays unticked, the box mixed.
        await selection.setContextNotebooks(["r2"], inChat: true, in: notebook)
        var writes = await rows.writes
        XCTAssertEqual(writes, [.init(key: contextKey, value: ["r2"])], "only the context row")
        XCTAssertEqual(selection.excluded, ["x"])
        XCTAssertEqual(selection.chatSourceIDs(of: notebook), ["d", "a", "c", "b", "y"])
        XCTAssertEqual(selection.board(for: notebook)?.state(ofContextNotebook: "r2", shown: ["x", "y"]), .mixed)

        // Its box again, while it is in, ticks every source of it.
        await selection.setContextNotebooks(["r2"], inChat: true, in: notebook)
        XCTAssertEqual(selection.excluded, [])
        XCTAssertEqual(selection.board(for: notebook)?.state(ofContextNotebook: "r2", shown: ["x", "y"]), .checked)

        // Add a Notebook to Context puts one in without ticking anything
        // (`MobileNotebookContextLinks.add`).
        await rows.set(key, ["z"])
        await selection.apply(
            .putIn(["r1"]),
            notebookID: "p1",
            own: MobileNotebookChatSelection.own(of: notebook),
            linked: MobileNotebookChatSelection.linked(of: notebook)
        )
        writes = await rows.writes
        XCTAssertEqual(writes.last, Rows.Write(key: contextKey, value: ["r1", "r2"]))
        let unticked = await rows.read(key)
        XCTAssertEqual(unticked, ["z"], "z stays unticked")
        XCTAssertEqual(selection.board(for: notebook)?.state(ofContextNotebook: "r1", shown: ["z"]), .unchecked)
    }

    func testTheContextNotebooksRowIsSortedAndRemovedWhenEmpty() async {
        let rows = Rows()
        let selection = store(rows)
        await selection.load(notebookID: "p1")

        await selection.setContextNotebooks(["r2", "r1"], inChat: true, in: notebook)
        XCTAssertEqual(selection.chatSourceIDs(of: notebook), ["d", "a", "c", "b", "x", "y", "z"])
        await selection.setContextNotebooks(["r2"], inChat: false, in: notebook)
        await selection.setContextNotebooks(["r1"], inChat: false, in: notebook)

        let writes = await rows.writes
        XCTAssertEqual(writes, [
            .init(key: contextKey, value: ["r1", "r2"]),
            .init(key: contextKey, value: ["r1"]),
            .init(key: contextKey, value: []),
        ])
        let row = await rows.read(contextKey)
        XCTAssertNil(row, "no context notebook put in is no row")
        XCTAssertEqual(selection.chatSourceIDs(of: notebook), pool)
    }

    func testATickInAGroupWritesBothRowsTheUntickedFirst() async {
        let rows = Rows()
        let selection = store(rows)
        await selection.load(notebookID: "p1")

        // y's box in Aging's group, which the chats do not read yet: Aging
        // comes in with y alone.
        await selection.set(["y"], inChat: true, through: "r2", in: notebook)

        let writes = await rows.writes
        XCTAssertEqual(writes, [.init(key: key, value: ["x"]), .init(key: contextKey, value: ["r2"])])
        XCTAssertEqual(selection.chatSourceIDs(of: notebook), ["d", "a", "c", "b", "y"])
        XCTAssertEqual(selection.board(for: notebook)?.state(ofContextNotebook: "r2", shown: ["x", "y"]), .mixed)

        // The group's own box, while mixed, ticks the rest of it.
        await selection.setContextNotebooks(["r2"], inChat: true, in: notebook)
        XCTAssertEqual(selection.excluded, [])
        XCTAssertEqual(selection.board(for: notebook)?.state(ofContextNotebook: "r2", shown: ["x", "y"]), .checked)
    }

    func testTakingANotebookOutOfContextDropsItAndTheUnticksOnlyItHeld() async {
        let rows = Rows()
        await rows.set(key, ["a", "x"])
        await rows.set(contextKey, ["r1", "r2"])
        let selection = store(rows)
        await selection.load(notebookID: "p1")

        // What Take Out of Context writes once the link is gone
        // (`MobileNotebookContextLinks.takeOut`): r2 out, kept to the links left.
        let unlinked = MobileCloudNotebook(
            id: "p1",
            title: "Notebook",
            instructions: nil,
            sourceIDs: pool,
            relatedNotebookIDs: ["r1"],
            contextNotebooks: [MobileCloudContextNotebook(id: "r1", title: "GDF15", sourceIDs: ["z"], poolSourceIDs: ["z"])],
            isArchived: false,
            updatedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        await selection.apply(
            .contextNotebooks(["r2"], inChat: false),
            notebookID: "p1",
            own: MobileNotebookChatSelection.own(of: unlinked),
            linked: MobileNotebookChatSelection.linked(of: unlinked)
        )

        let writes = await rows.writes
        XCTAssertEqual(writes, [.init(key: key, value: ["a"]), .init(key: contextKey, value: ["r1"])])
        XCTAssertEqual(selection.chatSourceIDs(of: unlinked), ["d", "c", "b", "z"])
    }

    func testAnAddTakesItsSourcesOutOfTheRowAndTheBoxesFollow() async throws {
        let rows = Rows()
        // b was unticked before it last left the notebook; d is unticked now.
        await rows.set(key, ["b", "d"])
        let selection = store(rows)
        await selection.load(notebookID: "p1")
        XCTAssertEqual(selection.board(for: notebook)?.isInChat("b"), false)

        // What every add on the phone does after the membership write
        // (`MobileAudioReviewViewModel.addSources`).
        let wrote = try await MobileNotebookChatSelection.tickArrivals(
            ["b"],
            notebookID: "p1",
            read: { key in await rows.read(key) },
            write: { key, value in try await rows.write(key, value) }
        )
        XCTAssertTrue(wrote)
        let row = await rows.read(key)
        XCTAssertEqual(row, ["d"], "b comes back ticked and d's untick stays")

        await selection.tickArrivals(["b"], in: notebook)

        let board = selection.board(for: notebook)
        XCTAssertEqual(board?.isInChat("b"), true)
        XCTAssertEqual(board?.isInChat("d"), false)
        let writes = await rows.writes
        XCTAssertEqual(writes, [.init(key: key, value: ["d"])], "the boxes follow the row without writing it again")
        XCTAssertEqual(selection.contextNotebookIDs, [], "an arrival puts no context notebook in")
    }

    func testAFailedWriteShowsTheRowAsItStands() async {
        let rows = Rows()
        let selection = store(rows)
        await selection.load(notebookID: "p1")
        await rows.failWrites()

        await selection.set(["a"], inChat: false, in: notebook)

        XCTAssertEqual(selection.excluded, [], "the box goes back to what the row says")
        XCTAssertNotNil(selection.writeError)
        selection.clearWriteError()
        XCTAssertNil(selection.writeError)

        await selection.setContextNotebooks(["r1"], inChat: true, in: notebook)
        XCTAssertEqual(selection.contextNotebookIDs, [], "a group's box goes back too")
        XCTAssertNotNil(selection.writeError)
    }
}

/// A notebook chat on the phone is the notebook's: it needs a source it could
/// load whole, names the notebook, and starts on the learner's question.
@MainActor
final class MobileNotebookChatViewModelTests: XCTestCase {
    private func source(_ id: String, title: String) -> MobileCloudSource {
        MobileCloudSource(
            id: id,
            title: title,
            subtitle: nil,
            sourceType: "paper",
            dateAdded: Date(timeIntervalSinceReferenceDate: 0),
            hasAudio: false,
            isArchived: false
        )
    }

    func testANotebookChatIsTheNotebooksAndNeedsALoadedSource() throws {
        let notebook = MobileCloudNotebook(
            id: "p1",
            title: "Cardiac sodium",
            instructions: nil,
            sourceIDs: ["s1", "s2"],
            isArchived: false,
            updatedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let ouabain = source("s1", title: "Ouabain paper")
        let textbook = source("s2", title: "Textbook")

        let nothingLoaded = MobileNotebookChatContext(
            notebook: notebook,
            loaded: [],
            notLoaded: [.init(source: textbook, reason: .doesNotFit)]
        )
        XCTAssertNil(MobileChatViewModel(notebook: nothingLoaded, initialPrompt: "Why does sodium rise?"))

        let context = MobileNotebookChatContext(
            notebook: notebook,
            loaded: [.init(source: ouabain, text: "The pump stops.")],
            notLoaded: [.init(source: textbook, reason: .doesNotFit)]
        )
        let chat = try XCTUnwrap(MobileChatViewModel(notebook: context, initialPrompt: "  Why does sodium rise?  "))
        XCTAssertEqual(chat.title, "Cardiac sodium")
        XCTAssertEqual(chat.notebook?.id, "p1", "filed under the notebook")
        XCTAssertEqual(chat.source.id, "s1", "the first source it read leads the saved session")
        XCTAssertEqual(chat.notebookContext?.tickedCount, 2)
        XCTAssertEqual(chat.draft, "Why does sodium rise?")
        XCTAssertNil(chat.modelOverride, "the account's default chat model unless the chip picks one")

        let reading = MobileChatViewModel(source: ouabain, sourceText: "The pump stops.", selection: nil, notebook: notebook)
        XCTAssertEqual(reading.title, "Ouabain paper", "the Reader's Ask keeps its source's name")
        XCTAssertEqual(reading.notebook?.id, "p1", "and is filed under the notebook it was asked in")
        XCTAssertNil(reading.notebookContext)
    }
}
