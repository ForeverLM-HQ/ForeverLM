import Foundation
import Testing
@testable import ForeverLM

/// The iPhone's notebooks, against the Mac's own rules (docs/notebooks-design.md,
/// "iPhone"): the chat checkboxes' synced row is the one the Mac's
/// `NotebookChatSelection` and `PreferenceStore` write, byte for byte; a
/// notebook chat reads whole sources and never cuts one; Home's order, the
/// notebook a launch reopens, the links the phone follows, the Docs and chats
/// a notebook lists, and the models a chat may pick.
@Suite("Notebooks on the phone")
struct MobileNotebookTests {

    // MARK: - Fixtures

    private func source(_ id: String, title: String? = nil, type: String = "paper", words: Int? = nil) -> MobileCloudSource {
        MobileCloudSource(
            id: id,
            title: title ?? "Source \(id)",
            subtitle: nil,
            sourceType: type,
            dateAdded: Date(timeIntervalSinceReferenceDate: 0),
            hasAudio: false,
            isArchived: false,
            wordCount: words
        )
    }

    private func notebook(
        _ id: String,
        title: String? = nil,
        sources: [String] = [],
        updatedAt: Date = Date(timeIntervalSinceReferenceDate: 0),
        isArchived: Bool = false
    ) -> MobileCloudNotebook {
        MobileCloudNotebook(
            id: id,
            title: title ?? "Notebook \(id)",
            instructions: nil,
            sourceIDs: sources,
            isArchived: isArchived,
            updatedAt: updatedAt
        )
    }

    // MARK: - Chat checkboxes: the Mac's rows

    @Test("The phone keys a notebook's two rows as the Mac does, and the Mac syncs both")
    func preferenceKeyMatchesTheMac() {
        #expect(MobileNotebookChatSelection.preferenceKeyPrefix == NotebookChatSelection.preferenceKeyPrefix)
        #expect(MobileNotebookChatSelection.preferenceKey(notebookID: "p1") == NotebookChatSelection.preferenceKey(notebookID: "p1"))
        #expect(MobileNotebookChatSelection.preferenceKey(notebookID: "p1") == "notebook.chatExcluded.p1")
        // The phone's rows follow the account as preference rows under generation 1; under generation 2
        // they are fields of the member's NotebookState, never preference rows.
        #expect(SyncedPreferenceKeys.isSynced(MobileNotebookChatSelection.preferenceKey(notebookID: "p1"), for: .one))
        #expect(!SyncedPreferenceKeys.isSynced(MobileNotebookChatSelection.preferenceKey(notebookID: "p1"), for: .two))
        #expect(MobileNotebookChatSelection.contextNotebooksKey(notebookID: "p1") == NotebookChatContext.preferenceKey(notebookID: "p1"))
        #expect(MobileNotebookChatSelection.contextNotebooksKey(notebookID: "p1") == "notebook.chatContextNotebooks.p1")
        #expect(SyncedPreferenceKeys.isSynced(MobileNotebookChatSelection.contextNotebooksKey(notebookID: "p1"), for: .one))
        #expect(!SyncedPreferenceKeys.isSynced(MobileNotebookChatSelection.contextNotebooksKey(notebookID: "p1"), for: .two))
    }

    /// The shared vectors every client runs (the web's twin in
    /// library-notebooks.js, the Mac's `NotebookChatContext`).
    private struct ContextVectors: Decodable {
        struct Linked: Decodable {
            let id: String
            let sources: [String]
        }

        struct Action: Decodable {
            let kind: String
            let ids: [String]?
            let inChat: Bool?
            let through: String?
            let sourceIDs: [String]?
            let contextNotebookIDs: [String]?
        }

        struct Expect: Decodable {
            let chatPool: [String]
            let chatSourceIDs: [String]
            let linkedPool: [String]
            let excluded: [String]
            let context: [String]
            let tallies: [String: [Int]?]
        }

        struct Case: Decodable {
            let name: String
            let own: [String]
            let linked: [Linked]
            let excluded: [String]
            let context: [String]
            let action: Action?
            let expect: Expect
        }

        let cases: [Case]
    }

    private static func contextVectors() throws -> ContextVectors {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UnitTests
            .deletingLastPathComponent()   // ForeverLMApp
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repo.appendingPathComponent("docs-site/website/test/notebook-chat-context-vectors.json"))
        return try JSONDecoder().decode(ContextVectors.self, from: data)
    }

    @Test("Every shared vector reads the same through the phone's notebook, its boxes and its changes")
    func sharedContextVectors() throws {
        let vectors = try Self.contextVectors()
        #expect(vectors.cases.count >= 16)
        for vector in vectors.cases {
            // The notebook as the catalog hands it to the phone's views.
            let notebook = MobileCloudNotebook(
                id: "p",
                title: "Notebook",
                instructions: nil,
                sourceIDs: vector.own,
                relatedNotebookIDs: vector.linked.map(\.id),
                poolSourceIDs: vector.own,
                contextNotebooks: vector.linked.map {
                    MobileCloudContextNotebook(id: $0.id, title: $0.id, sourceIDs: $0.sources, poolSourceIDs: $0.sources)
                },
                isArchived: false,
                updatedAt: .distantPast
            )
            let own = MobileNotebookChatSelection.own(of: notebook)
            let linked = MobileNotebookChatSelection.linked(of: notebook)
            let rows = NotebookChatContext.Selection(excluded: Set(vector.excluded), contextNotebookIDs: Set(vector.context))
            var next = rows
            if let action = vector.action {
                switch action.kind {
                case "sources":
                    next = MobileNotebookChatSelection.applying(
                        .sources(action.ids ?? [], inChat: action.inChat ?? true, through: action.through),
                        own: own, linked: linked, to: rows
                    )
                case "contextNotebooks":
                    next = MobileNotebookChatSelection.applying(
                        .contextNotebooks(action.ids ?? [], inChat: action.inChat ?? true),
                        own: own, linked: linked, to: rows
                    )
                case "all":
                    next = MobileNotebookChatSelection.applying(.all(inChat: true), own: own, linked: linked, to: rows)
                case "none":
                    next = MobileNotebookChatSelection.applying(.all(inChat: false), own: own, linked: linked, to: rows)
                case "only":
                    // MCP's mode only; the phone has no box for it.
                    next = NotebookChatContext.keepingOnly(
                        sourceIDs: action.sourceIDs ?? [],
                        contextNotebookIDs: action.contextNotebookIDs ?? [],
                        own: own, linked: linked, selection: rows
                    )
                default:
                    Issue.record("unknown action \(action.kind) in \(vector.name)")
                }
            }
            let written = MobileNotebookChatSelection.stored(next, own: own, linked: linked)
            let expect = vector.expect
            #expect(written.excluded.sorted() == expect.excluded, "\(vector.name)")
            #expect(written.contextNotebookIDs.sorted() == expect.context, "\(vector.name)")
            #expect(MobileNotebookChatSelection.chatPool(of: notebook, selection: written) == expect.chatPool, "\(vector.name)")
            #expect(MobileNotebookChatSelection.chatSourceIDs(of: notebook, selection: written) == expect.chatSourceIDs, "\(vector.name)")
            #expect(MobileNotebookChatSelection.linkedPool(of: notebook) == expect.linkedPool, "\(vector.name)")

            let board = MobileNotebookChatBoard(notebook: notebook, selection: written)
            for id in expect.linkedPool {
                #expect(board.isInChat(id) == expect.chatSourceIDs.contains(id), "\(vector.name): \(id)'s box")
            }
            for (id, tally) in expect.tallies {
                let shown = vector.linked.first { $0.id == id }?.sources ?? []
                let state = board.state(ofContextNotebook: id, shown: shown)
                if let tally {
                    #expect(board.isInChats(contextNotebook: id), "\(vector.name): \(id) is in")
                    let expected: MobileNotebookTickState = tally[1] == 0
                        ? .checked
                        : MobileNotebookTickState.of(ticked: tally[0], total: tally[1])
                    #expect(state == expected, "\(vector.name): \(id)'s box")
                } else {
                    #expect(!board.isInChats(contextNotebook: id), "\(vector.name): \(id) is out")
                    #expect(state == .unchecked, "\(vector.name): \(id)'s box")
                }
            }
        }
    }

    /// A notebook linking to two others, as the catalog builds it.
    private func contextNotebook(_ id: String, _ sources: [String]) -> MobileCloudContextNotebook {
        MobileCloudContextNotebook(id: id, title: "Notebook \(id)", sourceIDs: sources, poolSourceIDs: sources)
    }

    private func notebook(own: [String], context: [MobileCloudContextNotebook]) -> MobileCloudNotebook {
        MobileCloudNotebook(
            id: "p",
            title: "Mito Phenotyping",
            instructions: nil,
            sourceIDs: own,
            relatedNotebookIDs: context.map(\.id),
            poolSourceIDs: own,
            contextNotebooks: context,
            isArchived: false,
            updatedAt: .distantPast
        )
    }

    private func groups(of notebook: MobileCloudNotebook) -> [MobileNotebookContextGroup] {
        notebook.contextNotebooks.map { MobileNotebookContextGroup(notebook: $0, sources: $0.sourceIDs.map { source($0) }) }
    }

    private func written(
        _ change: MobileNotebookChatSelection.Change,
        in notebook: MobileCloudNotebook,
        from rows: NotebookChatContext.Selection
    ) -> NotebookChatContext.Selection {
        let own = MobileNotebookChatSelection.own(of: notebook)
        let linked = MobileNotebookChatSelection.linked(of: notebook)
        return MobileNotebookChatSelection.stored(
            MobileNotebookChatSelection.applying(change, own: own, linked: linked, to: rows),
            own: own,
            linked: linked
        )
    }

    @Test("Linked context notebooks no one put in reach nothing: the chats read and count only the notebook's own ticked sources")
    func linkedButOutReadsOnlyOwn() {
        let mito = notebook(own: ["a", "b", "c"], context: [contextNotebook("aging", ["c", "d"]), contextNotebook("gdf15", ["e"])])
        let rows = NotebookChatContext.Selection(excluded: ["b"])
        #expect(MobileNotebookChatSelection.chatSourceIDs(of: mito, selection: rows) == ["a", "c"])

        let board = MobileNotebookChatBoard(notebook: mito, selection: rows)
        let own = ["a", "b", "c"].map { source($0) }
        #expect(board.chatSources(own: own, groups: groups(of: mito)).map(\.id) == ["a", "c"])
        #expect(board.isInChat("c"), "a source the notebook holds itself is its own box")
        #expect(!board.isInChat("d"))
        #expect(!board.isInChat("e"))
        #expect(board.state(ofContextNotebook: "aging", shown: ["c", "d"]) == .unchecked)
        #expect(board.state(ofContextNotebook: "gdf15", shown: ["e"]) == .unchecked)

        let tally = MobileNotebookChatTally(board: board, own: own, groups: groups(of: mito))
        #expect(tally.sourcesLine(own: 3) == "3 sources · 2 in chat")
        #expect(tally.ofLine(own: 3) == "2 of 3 in chat")
        #expect(tally.state == .mixed)

        // Before the rows are read, the notebook's own count and no tally.
        let unread = MobileNotebookChatTally(board: nil, own: own, groups: groups(of: mito))
        #expect(unread.sourcesLine(own: 3) == "3 sources")
        #expect(unread.state == .unchecked)
        #expect(unread.hasRows(own: 3))
    }

    @Test("Putting a context notebook in adds its sources as it was left, its box then ticks them all, unticking one of them leaves it out, and Take Out of Context drops it")
    func contextNotebookInOutAndTakenOut() {
        let mito = notebook(own: ["a", "b", "c"], context: [contextNotebook("aging", ["c", "d", "f"]), contextNotebook("gdf15", ["e"])])
        let own = ["a", "b", "c"].map { source($0) }
        let start = NotebookChatContext.Selection(excluded: ["b", "f"])

        let putIn = written(.contextNotebooks(["aging"], inChat: true), in: mito, from: start)
        #expect(putIn.contextNotebookIDs == ["aging"])
        #expect(putIn.excluded == ["b", "f"], "put in, f stays unticked")
        #expect(MobileNotebookChatSelection.chatSourceIDs(of: mito, selection: putIn) == ["a", "c", "d"])
        var board = MobileNotebookChatBoard(notebook: mito, selection: putIn)
        #expect(board.state(ofContextNotebook: "aging", shown: ["c", "d", "f"]) == .mixed)
        #expect(MobileNotebookChatTally(board: board, own: own, groups: groups(of: mito)).sourcesLine(own: 3)
            == "5 sources · 3 in chat")

        let allOfIt = written(.contextNotebooks(["aging"], inChat: true), in: mito, from: putIn)
        #expect(allOfIt.excluded == ["b"], "its box, once it is in, ticks every source of it")
        #expect(MobileNotebookChatSelection.chatSourceIDs(of: mito, selection: allOfIt) == ["a", "c", "d", "f"])
        board = MobileNotebookChatBoard(notebook: mito, selection: allOfIt)
        #expect(board.state(ofContextNotebook: "aging", shown: ["c", "d", "f"]) == .checked)
        #expect(MobileNotebookChatTally(board: board, own: own, groups: groups(of: mito)).sourcesLine(own: 3)
            == "5 sources · 4 in chat")

        let unticked = written(.sources(["d"], inChat: false, through: "aging"), in: mito, from: allOfIt)
        #expect(unticked.excluded == ["b", "d"])
        #expect(MobileNotebookChatSelection.chatSourceIDs(of: mito, selection: unticked) == ["a", "c", "f"])
        board = MobileNotebookChatBoard(notebook: mito, selection: unticked)
        #expect(board.state(ofContextNotebook: "aging", shown: ["c", "d", "f"]) == .mixed)
        #expect(!board.isInChat("d"))

        // Select all ticks what the chats draw on and leaves gdf15 out.
        let all = written(.all(inChat: true), in: mito, from: unticked)
        #expect(all == NotebookChatContext.Selection(contextNotebookIDs: ["aging"]))

        // Take Out of Context: the link goes, then its id leaves the row, and
        // the unticks only it held go with it.
        let unlinked = notebook(own: ["a", "b", "c"], context: [contextNotebook("gdf15", ["e"])])
        let takenOut = written(.contextNotebooks(["aging"], inChat: false), in: unlinked, from: unticked)
        #expect(takenOut.contextNotebookIDs.isEmpty)
        #expect(takenOut.excluded == ["b"])
        #expect(MobileNotebookChatSelection.chatSourceIDs(of: unlinked, selection: takenOut) == ["a", "c"])
    }

    @Test("A box ticked in a group that is out puts that notebook in with that source alone")
    func tickInAnOutGroup() {
        let mito = notebook(own: ["a"], context: [contextNotebook("aging", ["b", "c"]), contextNotebook("gdf15", ["c", "e"])])
        let through = written(.sources(["c"], inChat: true, through: "gdf15"), in: mito, from: .init())
        #expect(through.contextNotebookIDs == ["gdf15"], "the group whose box was ticked")
        #expect(through.excluded == ["e"])
        #expect(MobileNotebookChatSelection.chatSourceIDs(of: mito, selection: through) == ["a", "c"])
    }

    @Test("A stale id in either row is ignored; a write drops it from the unticked row and keeps it in the context row")
    func staleRowIDs() {
        let mito = notebook(own: ["a"], context: [contextNotebook("aging", ["b"])])
        let stale = NotebookChatContext.Selection(excluded: ["zz"], contextNotebookIDs: ["gone"])
        #expect(MobileNotebookChatSelection.chatSourceIDs(of: mito, selection: stale) == ["a"])
        #expect(!MobileNotebookChatBoard(notebook: mito, selection: stale).isInChats(contextNotebook: "gone"))
        // A notebook this phone does not know is linked may be one another
        // device linked and put in: only an unlink takes it out of the row.
        #expect(written(.sources([], inChat: true, through: nil), in: mito, from: stale)
            == NotebookChatContext.Selection(contextNotebookIDs: ["gone"]))
        #expect(written(.contextNotebooks(["gone"], inChat: false), in: mito, from: stale) == NotebookChatContext.Selection())
    }

    @Test("Add a Notebook to Context puts one in as it was left, and leaves one already in as it is")
    func addPutsInWithoutTicking() {
        let mito = notebook(own: ["a"], context: [contextNotebook("aging", ["b", "c"])])
        let putIn = written(.putIn(["aging"]), in: mito, from: .init(excluded: ["c"]))
        #expect(putIn == NotebookChatContext.Selection(excluded: ["c"], contextNotebookIDs: ["aging"]))
        #expect(MobileNotebookChatBoard(notebook: mito, selection: putIn).state(ofContextNotebook: "aging", shown: ["b", "c"]) == .mixed)
        #expect(written(.putIn(["aging"]), in: mito, from: putIn) == putIn, "one already in is left as it is")
        #expect(written(.putIn(["unlinked"]), in: mito, from: .init()) == NotebookChatContext.Selection(), "a notebook not linked is not put in")
    }

    @Test("A context notebook in the chats with none of its sources here yet is ticked, so its box takes it out")
    func inGroupWithNothingListed() {
        let mito = MobileCloudNotebook(
            id: "p",
            title: "Mito",
            instructions: nil,
            sourceIDs: ["a"],
            relatedNotebookIDs: ["aging", "unsynced"],
            poolSourceIDs: ["a"],
            contextNotebooks: [contextNotebook("aging", [])],
            isArchived: false,
            updatedAt: .distantPast
        )
        let rows = NotebookChatContext.Selection(contextNotebookIDs: ["aging", "unsynced"])
        let board = MobileNotebookChatBoard(notebook: mito, selection: rows)
        #expect(board.state(ofContextNotebook: "aging", shown: []) == .checked)
        // A link this phone has no record of keeps its place in the row.
        #expect(MobileNotebookChatSelection.linked(of: mito).map(\.id) == ["aging", "unsynced"])
        #expect(written(.sources([], inChat: true, through: nil), in: mito, from: rows).contextNotebookIDs == ["aging", "unsynced"])
    }

    @Test("A tick's row reaches CloudKit as the bytes the Mac writes, and reads back on both sides")
    func tickRowBytesEqualTheMacPlist() throws {
        let pool = ["src-3", "src-1", "src-2", "zoom:examplefellowship.zoom.us#7"]
        let mito = notebook(own: pool, context: [contextNotebook("r2", ["x"]), contextNotebook("r1", ["y"])])
        let rows = written(.sources(["src-2", "zoom:examplefellowship.zoom.us#7"], inChat: false, through: nil), in: mito, from: .init())
        let phone = rows.excluded.sorted()
        #expect(phone == ["src-2", "zoom:examplefellowship.zoom.us#7"])

        let phoneXML = try #require(MobileNotebookChatSelection.rowValueXML(excluded: phone))
        let macXML = try #require(PreferenceStore.encodePlist(phone))
        #expect(phoneXML == macXML)
        #expect(Data(phoneXML.utf8) == Data(macXML.utf8))

        // The phone's store writes every row through the same encoder.
        #expect(MobilePreferencePlist.encode(phone) == macXML)
        #expect(PreferenceStore.decodePlist(phoneXML) as? [String] == phone)
        #expect(MobilePreferencePlist.decode(macXML) as? [String] == phone)

        // The context notebooks' row, sorted as the Mac writes it.
        let both = written(.contextNotebooks(["r2", "r1"], inChat: true), in: mito, from: rows)
        let context = both.contextNotebookIDs.sorted()
        #expect(context == ["r1", "r2"])
        #expect(MobilePreferencePlist.encode(context) == PreferenceStore.encodePlist(context))
    }

    @Test("Every value kind the phone writes encodes as the Mac's PreferenceStore does")
    func preferencePlistMatchesTheMacForEveryKind() {
        let values: [Any] = [["a", "b"], true, false, 42, "claude-sonnet-5", Data([0x7b, 0x7d]), [String]()]
        for value in values {
            #expect(MobilePreferencePlist.encode(value) == PreferenceStore.encodePlist(value))
        }
        #expect(MobilePreferencePlist.decode("") == nil)
        #expect(MobilePreferencePlist.decode("not a plist") == nil)
    }

    @Test("Ticking every box removes the row rather than writing an empty one")
    func allTickedIsNoRow() {
        let mito = notebook(own: ["a", "b"], context: [])
        let cleared = written(.all(inChat: true), in: mito, from: .init(excluded: ["a"]))
        #expect(cleared.excluded.isEmpty)
        #expect(MobileNotebookChatSelection.rowValueXML(excluded: cleared.excluded.sorted()) == nil)
        #expect(MobileNotebookChatSelection.rowValueXML(excluded: ["a"]) != nil)
    }

    /// The account's Preference rows, as the phone reads and writes them.
    private actor Rows {
        private(set) var values: [String: [String]] = [:]
        private(set) var writes: [[String]] = []

        func read(_ key: String) -> [String]? { values[key] }

        func write(_ key: String, _ value: [String]) {
            writes.append(value)
            values[key] = value.isEmpty ? nil : value
        }

        func set(_ key: String, _ value: [String]?) { values[key] = value }
    }

    @Test("A source the phone adds to a notebook leaves its row, by every route, and the rest of the row stays")
    func phoneAddTicksArrivals() async throws {
        let rows = Rows()
        let key = MobileNotebookChatSelection.preferenceKey(notebookID: "p1")
        // b was unticked, then removed, on any device; d is a deliberate untick.
        await rows.set(key, ["b", "d"])
        let read: (String) async throws -> [String]? = { key in await rows.read(key) }
        let write: (String, [String]) async throws -> Void = { key, value in await rows.write(key, value) }

        #expect(try await MobileNotebookChatSelection.tickArrivals(["b", "z"], notebookID: "p1", read: read, write: write))
        #expect(await rows.read(key) == ["d"], "b comes back ticked; d's untick is not the add's to undo")

        #expect(try await !MobileNotebookChatSelection.tickArrivals(["z"], notebookID: "p1", read: read, write: write),
                "a row naming none of the arrivals is not written")
        #expect(try await !MobileNotebookChatSelection.tickArrivals(["b"], notebookID: "p2", read: read, write: write),
                "a notebook with no row has every box ticked already")

        #expect(try await MobileNotebookChatSelection.tickArrivals(["d"], notebookID: "p1", read: read, write: write))
        #expect(await rows.read(key) == nil, "the last untick leaving removes the row")
        #expect(await rows.writes == [["d"], []])

        // The row is the Mac's: what the phone leaves is what the Mac's tick would.
        let pool = ["a", "b", "c", "d"]
        #expect(Set(MobileNotebookChatSelection.afterArrivals(["b", "d"], arriving: ["b"]))
                == NotebookChatContext.settingSources(
                    ["b"], inChat: true, own: pool, linked: [],
                    selection: NotebookChatContext.Selection(excluded: ["b", "d"])
                ).excluded)
    }

    @Test("A conversation on a notebook reads its own sources, and Talk narrows to what its chats read, context notebooks included")
    func poolAndNarrowing() {
        let mito = MobileCloudNotebook(
            id: "p",
            title: "Mitochondria",
            instructions: "Be brief.",
            sourceIDs: ["a", "b"],
            relatedNotebookIDs: ["q"],
            poolSourceIDs: ["a", "b", "archived"],
            contextNotebooks: [contextNotebook("q", ["c"])],
            linkedCourseIDs: ["course"],
            isArchived: false,
            updatedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        #expect(mito.contextSourceIDs == ["a", "b"], "unspecified, a conversation reads the notebook's own sources")
        #expect(MobileNotebookChatSelection.own(of: mito) == ["a", "b", "archived"])
        #expect(MobileNotebookChatSelection.linkedPool(of: mito) == ["a", "b", "archived", "c"])

        let rows = NotebookChatContext.Selection(excluded: ["b"], contextNotebookIDs: ["q"])
        let ticked = MobileNotebookChatSelection.chatSourceIDs(of: mito, selection: rows)
        #expect(ticked == ["a", "archived", "c"])
        let narrowed = mito.narrowed(toSourceIDs: ticked)
        #expect(narrowed.id == "p")
        #expect(narrowed.title == "Mitochondria")
        #expect(narrowed.instructions == "Be brief.")
        #expect(narrowed.sourceIDs == ["a"])
        #expect(narrowed.contextSourceIDs == ["a", "archived", "c"], "exactly what the chats read, in their order")
        #expect(narrowed.linkedCourseIDs == ["course"])
        #expect(narrowed.contextNotebooks == mito.contextNotebooks)

        let plain = notebook("x", sources: ["a"])
        #expect(plain.poolSourceIDs == ["a"], "an unspecified pool is the notebook's own sources")
        #expect(plain.contextNotebooks.isEmpty)
    }

    @Test("A notebook built from its records carries its context notebooks in link order, each with its rows and the Mac's ids")
    func contextNotebooksFromRecords() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func record(_ id: String, _ title: String, sources: [String], links: [String] = [], status: String = "active") throws -> MobileCloudNotebook {
            let goal = LearningGoalRecord(
                id: id,
                title: title,
                startAt: now,
                endAt: LearningGoalRecord.openEndedEndAt,
                createdAt: now,
                updatedAt: now,
                status: status,
                items: sources.enumerated().map { LearningGoalItem(id: "\(id)-\($0.offset)", goalID: id, sourceID: $0.element, addedAt: now) },
                kind: LearningGoalRecord.companionKind,
                relatedNotebookIDs: links
            )
            let data = try JSONEncoder().encode(CloudKitLearningGoalPayload(goal: goal))
            return try #require(MobileNotebookCatalogParser.notebook(fromPayloadData: data))
        }
        let mito = try record("p", "Mito Phenotyping", sources: ["a", "b"], links: ["gdf15", "unsynced", "aging"])
        let gdf15 = try record("gdf15", "GDF15", sources: ["c", "hidden"])
        // Archived, still linked: the Mac's pool counts it, so its group shows.
        let agingRecord = try record("aging", "🧬 Landscape of Aging", sources: ["s1", "b"], status: "archived")
        // This phone holds aging's s1 under another id.
        var phoneCopy = source("phone-s1")
        phoneCopy.url = "https://example.org/a"
        let aging = MobileNotebookSourceIdentityResolver.remap(
            notebook: agingRecord,
            identities: [MobileMemorySourceIdentity(sourceID: "s1", url: "https://example.org/a", normalizedURL: nil, doi: nil, publishedDOI: nil)],
            sources: [phoneCopy],
            normalizeURL: { $0 }
        )
        let built = MobileNotebookCatalog.notebook(
            mito,
            records: [mito.id: mito, gdf15.id: gdf15, aging.id: aging],
            isListed: { $0 != "hidden" }
        )
        #expect(built.relatedNotebookIDs == ["gdf15", "unsynced", "aging"])
        #expect(built.contextNotebooks.map(\.id) == ["gdf15", "aging"], "in link order; a link with no record here has no group")
        #expect(built.contextNotebooks.map(\.title) == ["GDF15", "🧬 Landscape of Aging"])
        #expect(built.contextNotebooks.map(\.sourceIDs) == [["c"], ["phone-s1", "b"]], "a group's rows are what this phone lists")
        #expect(built.contextNotebooks.map(\.poolSourceIDs) == [["c", "hidden"], ["s1", "phone-s1", "b"]],
                "its boxes keep the Mac's ids, this phone's beside them")
        #expect(MobileNotebookChatSelection.linked(of: built) == [
            NotebookChatContext.ContextNotebook(id: "gdf15", sourceIDs: ["c", "hidden"]),
            NotebookChatContext.ContextNotebook(id: "unsynced", sourceIDs: []),
            NotebookChatContext.ContextNotebook(id: "aging", sourceIDs: ["s1", "phone-s1", "b"]),
        ])
        #expect(built.sourceIDs == ["a", "b"])
        #expect(built.contextSourceIDs == ["a", "b"], "a conversation on the notebook reads its own sources")
        #expect(built.poolSourceIDs == ["a", "b"])
        // Linked and out, as every existing link starts: its own sources alone.
        #expect(MobileNotebookChatSelection.chatSourceIDs(of: built, selection: .init()) == ["a", "b"])
        let agingIn = NotebookChatContext.Selection(contextNotebookIDs: ["aging"])
        #expect(MobileNotebookChatSelection.chatSourceIDs(of: built, selection: agingIn) == ["a", "b", "s1", "phone-s1"])
    }

    @Test("A notebook's Share counts the approved sources its record names, a hidden one and one this phone holds under another id included, as the Mac's popover counts them")
    func shareCountsTheApprovedSources() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let goal = LearningGoalRecord(
            id: "p",
            title: "Mito",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now,
            updatedAt: now,
            status: "active",
            items: [
                LearningGoalItem(id: "p-1", goalID: "p", sourceID: "a", addedAt: now),
                LearningGoalItem(id: "p-2", goalID: "p", sourceID: "s1", addedAt: now, reviewState: LearningGoalItemReviewState.approved.rawValue),
                LearningGoalItem(id: "p-3", goalID: "p", sourceID: "hidden", addedAt: now),
                LearningGoalItem(id: "p-4", goalID: "p", sourceID: "suggested", addedAt: now, origin: LearningGoalItemOrigin.discovered.rawValue, reviewState: LearningGoalItemReviewState.pending.rawValue),
            ],
            kind: LearningGoalRecord.companionKind
        )
        let data = try JSONEncoder().encode(CloudKitLearningGoalPayload(goal: goal))
        let record = try #require(MobileNotebookCatalogParser.notebook(fromPayloadData: data))
        // This phone holds s1 under another id.
        var phoneCopy = source("phone-s1")
        phoneCopy.url = "https://example.org/a"
        let remapped = MobileNotebookSourceIdentityResolver.remap(
            notebook: record,
            identities: [MobileMemorySourceIdentity(sourceID: "s1", url: "https://example.org/a", normalizedURL: nil, doi: nil, publishedDOI: nil)],
            sources: [phoneCopy],
            normalizeURL: { $0 }
        )
        let built = MobileNotebookCatalog.notebook(remapped, records: [remapped.id: remapped], isListed: { $0 != "hidden" })
        #expect(built.approvedSourceCount == goal.approvedSourceIDs.count)
        #expect(built.approvedSourceCount == 3)
        #expect(built.sourceIDs == ["a", "phone-s1"], "the rows this phone lists leave the hidden one out")
        #expect(built.poolSourceIDs.count == 4, "the boxes' pool carries this phone's id beside the Mac's")
        #expect(NotebookShareLine.text(sourceCount: built.approvedSourceCount) == "Shares the notebook and its 3 sources")
    }

    @Test("Add a Notebook to Context offers every other notebook not linked yet")
    func contextPickerCandidates() {
        let mito = MobileCloudNotebook(
            id: "p", title: "Mito", instructions: nil, sourceIDs: [],
            relatedNotebookIDs: ["aging"], isArchived: false, updatedAt: .distantPast
        )
        let notebooks = [mito, notebook("aging"), notebook("gdf15"), notebook("old", isArchived: true), notebook("sleep")]
        #expect(MobileNotebookContextPicker.candidates(for: mito, in: notebooks).map(\.id) == ["gdf15", "sleep"])
        #expect(MobileNotebookContextPicker.hasCandidates(for: mito, in: notebooks))
        #expect(!MobileNotebookContextPicker.hasCandidates(for: mito, in: [mito, notebook("aging")]))
    }

    @Test("A box for several sources is ticked, mixed or clear")
    func tickState() {
        #expect(MobileNotebookTickState.of(ticked: 3, total: 3) == .checked)
        #expect(MobileNotebookTickState.of(ticked: 1, total: 3) == .mixed)
        #expect(MobileNotebookTickState.of(ticked: 0, total: 3) == .unchecked)
        #expect(MobileNotebookTickState.of(ticked: 0, total: 0) == .unchecked)
    }

    // MARK: - Grounding: whole sources, nothing cut

    @Test("Ticked sources load whole in the notebook's order while they fit")
    func groundingLoadsWholeSourcesInOrder() {
        let plan = MobileNotebookChatGrounding.plan(
            [.init(sourceID: "a", characterCount: 100), .init(sourceID: "b", characterCount: 200), .init(sourceID: "c", characterCount: 300)],
            budget: 1_000
        )
        #expect(plan.loaded == ["a", "b", "c"])
        #expect(plan.notLoaded.isEmpty)
        #expect(plan.isComplete)
        #expect(MobileNotebookChatGrounding.composerNotice(plan) == nil)
    }

    @Test("A source that does not fit is passed over whole, and a shorter one after it still loads")
    func groundingNeverCutsASource() {
        let counts = ["a": 400, "big": 700, "b": 300, "c": 400]
        let plan = MobileNotebookChatGrounding.plan(
            ["a", "big", "b", "c"].map { .init(sourceID: $0, characterCount: counts[$0]) },
            budget: 1_000
        )
        #expect(plan.loaded == ["a", "b"])
        #expect(plan.notLoaded == [.init(sourceID: "big", reason: .doesNotFit), .init(sourceID: "c", reason: .doesNotFit)])
        #expect(plan.loaded.map { counts[$0] ?? 0 }.reduce(0, +) <= 1_000)
        #expect(plan.tickedCount == 4)
        #expect(MobileNotebookChatGrounding.composerNotice(plan) == "Reads 2 of 4 ticked sources; untick some to fit the rest.")
    }

    @Test("A source longer than the whole budget is never loaded in part")
    func groundingOversizedSource() {
        let plan = MobileNotebookChatGrounding.plan([.init(sourceID: "book", characterCount: 240_001)])
        #expect(plan.loaded.isEmpty)
        #expect(plan.notLoaded == [.init(sourceID: "book", reason: .doesNotFit)])
        let exact = MobileNotebookChatGrounding.plan([.init(sourceID: "fits", characterCount: 240_000)])
        #expect(exact.loaded == ["fits"])
    }

    @Test("A source whose text has not reached the phone is listed, not guessed")
    func groundingUnavailableSource() {
        let plan = MobileNotebookChatGrounding.plan([
            .init(sourceID: "a", characterCount: 10),
            .init(sourceID: "missing", characterCount: nil),
            .init(sourceID: "a", characterCount: 10),
        ])
        #expect(plan.loaded == ["a"], "a repeated id counts once")
        #expect(plan.notLoaded == [.init(sourceID: "missing", reason: .textUnavailable)])
        #expect(MobileNotebookChatGrounding.composerNotice(plan) == "1 source's text has not reached this iPhone yet.")
    }

    @Test("A word count rules a source out only when its text could not possibly fit")
    func certainlyExceedsIsALowerBound() {
        // W words are at least 2W - 1 characters.
        #expect(MobileNotebookChatGrounding.certainlyExceeds(wordCount: 600, remaining: 1_198))
        #expect(!MobileNotebookChatGrounding.certainlyExceeds(wordCount: 600, remaining: 1_199))
        #expect(!MobileNotebookChatGrounding.certainlyExceeds(wordCount: nil, remaining: 0))
        #expect(!MobileNotebookChatGrounding.certainlyExceeds(wordCount: 0, remaining: 0))
        // A passed-over source is planned at that bound, which still exceeds
        // what was left, so the plan keeps the same verdict.
        let bound = MobileNotebookChatGrounding.minimumCharacters(wordCount: 600)
        #expect(bound == 1_199)
        let plan = MobileNotebookChatGrounding.plan([.init(sourceID: "w", characterCount: bound)], budget: 1_198)
        #expect(plan.notLoaded == [.init(sourceID: "w", reason: .doesNotFit)])
    }

    @Test("The prompt carries every loaded source whole and names the ones it could not load")
    func promptCarriesWholeSources() {
        let first = "Ouabain stops the pump.\n\nSodium rises within minutes." + String(repeating: " mito", count: 2_000)
        let second = "Calcium follows sodium out of the mitochondria."
        let prompt = MobileNotebookChatPrompt.system(
            notebookTitle: "Cardiac sodium",
            instructions: "Answer as for a cardiologist.",
            loaded: [
                .init(source: source("s1", title: "Ouabain paper"), text: first),
                .init(source: source("s2", title: "Calcium review", type: "article"), text: second),
            ],
            notLoaded: [
                .init(source: source("s3", title: "Textbook chapter", type: "book"), reason: .doesNotFit),
                .init(source: source("s4", title: "Podcast"), reason: .textUnavailable),
            ]
        )
        #expect(prompt.contains(first), "the first source whole")
        #expect(prompt.contains(second), "the second source whole")
        #expect(prompt.contains("ID: s1") && prompt.contains("ID: s2"))
        #expect(prompt.contains("Answer as for a cardiologist."))
        #expect(prompt.contains("Notebook: Cardiac sodium"))
        #expect(prompt.contains("IN THE NOTEBOOK, NOT LOADED"))
        #expect(prompt.contains("Textbook chapter (ID: s3): too long to load beside the others"))
        #expect(prompt.contains("Podcast (ID: s4): its text has not reached this device"))
        #expect(prompt.contains("[Title](foreverlm://source/ID)"))
        let firstStart = prompt.range(of: "BEGIN SOURCE 1")?.lowerBound
        let secondStart = prompt.range(of: "BEGIN SOURCE 2")?.lowerBound
        #expect(firstStart != nil && secondStart != nil && firstStart! < secondStart!, "in the notebook's order")
    }

    @Test("A notebook chat is titled by its first message, on one line, cut at a word")
    func chatTitle() {
        #expect(MobileNotebookChatPrompt.chatTitle(firstQuestion: "Why does sodium rise?", fallback: "N") == "Why does sodium rise?")
        #expect(MobileNotebookChatPrompt.chatTitle(firstQuestion: "  \n ", fallback: "Notebook") == "Notebook")
        #expect(MobileNotebookChatPrompt.chatTitle(firstQuestion: nil, fallback: "Notebook") == "Notebook")
        #expect(MobileNotebookChatPrompt.chatTitle(firstQuestion: "Line one\nline two", fallback: "N") == "Line one line two")
        let long = String(repeating: "word ", count: 30)
        let title = MobileNotebookChatPrompt.chatTitle(firstQuestion: long, fallback: "N")
        #expect(title.hasSuffix("…"))
        #expect(title.count <= 81)
        #expect(!title.dropLast().hasSuffix(" "))
    }

    // MARK: - Home's order

    @Test("Home lists notebooks by their latest change or chat, newest first")
    func ordering() {
        let old = Date(timeIntervalSinceReferenceDate: 100)
        let newer = Date(timeIntervalSinceReferenceDate: 200)
        let newest = Date(timeIntervalSinceReferenceDate: 300)
        let a = notebook("a", title: "Alpha", updatedAt: newer)
        let b = notebook("b", title: "Beta", updatedAt: old)
        let c = notebook("c", title: "Gamma", updatedAt: old)
        let d = notebook("d", title: "Delta", updatedAt: old)
        let sorted = MobileNotebookOrdering.sorted([a, b, c, d], lastChatAt: ["b": newest, "a": old])
        #expect(sorted.map(\.id) == ["b", "a", "d", "c"], "a chat moves its notebook up; ties go by title")
        #expect(MobileNotebookOrdering.lastActivity(of: a, lastChatAt: ["a": old]) == newer)
        #expect(MobileNotebookOrdering.lastActivity(of: b, lastChatAt: ["b": newest]) == newest)
    }

    // MARK: - The last notebook

    @Test("A launch reopens the notebook last worked in, and Home otherwise")
    func lastNotebookRestore() {
        let notebooks = [notebook("p1"), notebook("p2"), notebook("gone", isArchived: true)]
        #expect(MobileNotebookResume.restoredNotebookID(stored: "p2", notebooks: notebooks) == "p2")
        #expect(MobileNotebookResume.restoredNotebookID(stored: nil, notebooks: notebooks) == nil, "a new learner sees Home")
        #expect(MobileNotebookResume.restoredNotebookID(stored: "p2", notebooks: []) == nil, "no notebooks: Home")
        #expect(MobileNotebookResume.restoredNotebookID(stored: "deleted", notebooks: notebooks) == nil)
        #expect(MobileNotebookResume.restoredNotebookID(stored: "gone", notebooks: notebooks) == nil, "archived: Home")
        #expect(MobileNotebookResume.restoredNotebookID(stored: "  ", notebooks: notebooks) == nil)

        #expect(MobileShellRoute.launchPath(current: [], restoredNotebookID: "p2") == [.notebook("p2")], "pushed over Home")
        #expect(MobileShellRoute.launchPath(current: [], restoredNotebookID: nil).isEmpty)
        #expect(
            MobileShellRoute.launchPath(current: [.cardReview(.allNotebooks)], restoredNotebookID: "p2") == [.cardReview(.allNotebooks)],
            "a link that came first wins"
        )
    }

    @Test("The last notebook is remembered on this device only, and forgotten with its notebook")
    func lastNotebookStore() throws {
        let suiteName = "MobileNotebookTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MobileLastNotebookStore(defaults: defaults)
        #expect(store.notebookID == nil)
        store.remember("p1")
        #expect(store.notebookID == "p1")
        #expect(defaults.string(forKey: MobileNotebookResume.defaultsKey) == "p1")
        #expect(!SyncedPreferenceKeys.isSynced(MobileNotebookResume.defaultsKey), "never a synced row")
        store.forget("other")
        #expect(store.notebookID == "p1", "forgetting another notebook leaves it")
        store.remember("p2")
        store.forget("p2")
        #expect(store.notebookID == nil)
    }

    // MARK: - Links

    @Test("The phone reads the foreverlm:// links the Mac writes")
    func deepLinkParsing() throws {
        func parse(_ string: String) throws -> MobileDeepLink? {
            MobileDeepLink.parse(try #require(URL(string: string)))
        }
        #expect(try parse("foreverlm://today") == .today)
        #expect(try parse("foreverlm://review") == .review)
        #expect(try parse("foreverlm://notebook/goal-123") == .notebook("goal-123"))
        #expect(try parse("foreverlm://project/goal-123") == .notebook("goal-123"), "the address before the rename still opens the notebook")
        #expect(try parse("foreverlm://source/src_abc") == .source("src_abc"))
        #expect(try parse("FOREVERLM://Notebook/Goal-ABC") == .notebook("Goal-ABC"), "scheme and host ignore case; the id keeps it")
        #expect(try parse("foreverlm://source/zoom%3Aexamplefellowship%20x") == .source("zoom:examplefellowship x"), "percent-decoded")
        #expect(try parse("foreverlm://source/zoom:abc") == .source("zoom:abc"))
        #expect(try parse("foreverlm://notebook/") == nil)
        #expect(try parse("foreverlm://doc/abc") == .doc("abc"), "a page's link and its Copy Link")
        #expect(try parse("foreverlm://doc/") == nil)
        #expect(try parse("foreverlm://idea/abc") == nil, "an Idea is the Mac's")
        #expect(try parse("https://foreverlm.com/notebook/abc") == nil)
        let runtime = "\(ForeverLMRuntimeIdentity.urlScheme)://notebook/p9"
        #expect(try parse(runtime) == .notebook("p9"), "the running build's own scheme too")
    }

    @Test("A link opens where it should: a source inside the notebook it was followed in")
    func followingLinks() {
        let inNotebook: [MobileShellRoute] = [.notebook("p1")]
        #expect(
            MobileShellRoute.following(.source("s1"), from: inNotebook, fromInsideApp: true)
                == [.notebook("p1"), .source("s1", notebookID: "p1")]
        )
        let inDoc: [MobileShellRoute] = [.notebook("p1"), .doc("d1", notebookID: "p1")]
        #expect(MobileShellRoute.following(.source("s2"), from: inDoc, fromInsideApp: true).last == .source("s2", notebookID: "p1"))
        #expect(MobileShellRoute.following(.source("s3"), from: [.library], fromInsideApp: false) == [.library, .source("s3", notebookID: nil)])
        #expect(MobileShellRoute.following(.notebook("p2"), from: inNotebook, fromInsideApp: false) == [.notebook("p2")], "from outside: Back is Home")
        #expect(MobileShellRoute.following(.notebook("p2"), from: inNotebook, fromInsideApp: true) == [.notebook("p1"), .notebook("p2")])
        #expect(
            MobileShellRoute.following(.notebook("p1"), from: inDoc, fromInsideApp: true) == [.notebook("p1")],
            "a link to the notebook it is in goes back to it rather than opening it twice"
        )
        #expect(MobileShellRoute.following(.today, from: inDoc, fromInsideApp: false).isEmpty)
        #expect(MobileShellRoute.notebookInScope(of: [.notebook("p1"), .source("s", notebookID: nil)]) == "p1")
        #expect(MobileShellRoute.notebookInScope(of: [.library, .settings]) == nil)
    }

    @Test("A page's link opens the page over where it was followed, and goes back to one already open")
    func followingPageLinks() {
        let inSpace: [MobileShellRoute] = [.space(nil), .space(.all), .page("a")]
        #expect(MobileShellRoute.following(.doc("b"), from: inSpace, fromInsideApp: true) == inSpace + [.page("b")])
        #expect(MobileShellRoute.following(.doc("a"), from: inSpace + [.page("b")], fromInsideApp: true) == inSpace,
                "a link back to a page on the stack goes back to it")
        let inDoc: [MobileShellRoute] = [.notebook("p1"), .doc("d1", notebookID: "p1")]
        #expect(MobileShellRoute.following(.doc("d1"), from: inDoc + [.page("d2")], fromInsideApp: true) == inDoc,
                "a notebook's page is the same page")
        #expect(MobileShellRoute.following(.doc("d2"), from: inDoc, fromInsideApp: false) == [.page("d2")], "from outside: Back is Home")
        #expect(MobileShellRoute.notebookInScope(of: inDoc + [.page("d2")]) == "p1", "a source from a page linked in a notebook opens in it")
        #expect(MobileShellRoute.notebookInScope(of: [.space(.pages), .page("d2")]) == nil)
        #expect(MobileShellRoute.page("x").opensPage("x") && MobileShellRoute.doc("x", notebookID: "p").opensPage("x"))
        #expect(!MobileShellRoute.space(.trash).opensPage("x"))
    }

    @Test("foreverlm://review, the widget, Siri and the reminder open today's card review over every notebook")
    func reviewLinkOpensTheCardReview() throws {
        let url = try #require(URL(string: "foreverlm://review"))
        let link = try #require(MobileDeepLink.parse(url))
        #expect(link == .review)
        let inDoc: [MobileShellRoute] = [.notebook("p1"), .doc("d1", notebookID: "p1")]
        #expect(MobileShellRoute.following(link, from: inDoc, fromInsideApp: false) == [.cardReview(.allNotebooks)])
        #expect(MobileShellRoute.following(link, from: [], fromInsideApp: true) == [.cardReview(.allNotebooks)])
        // A card's Reader opens in the notebook the review is narrowed to.
        #expect(MobileShellRoute.notebookInScope(of: [.cardReview(.notebook("p3"))]) == "p3")
        #expect(MobileShellRoute.notebookInScope(of: [.notebook("p1"), .notebookPractice(notebookID: "p1")]) == "p1")
        #expect(MobileShellRoute.notebookInScope(of: [.cardReview(.allNotebooks)]) == nil)
        #expect(
            MobileShellRoute.following(.source("s1"), from: [.notebook("p1"), .notebookPractice(notebookID: "p1")], fromInsideApp: true).last
                == .source("s1", notebookID: "p1")
        )
        // Home's Memory strip opens the Memory screen, whose Start Review and
        // Practice push the card review over every notebook; the links still
        // go straight into the review.
        #expect(MobileShellRoute.following(link, from: [.memory], fromInsideApp: false) == [.cardReview(.allNotebooks)])
        #expect(MobileShellRoute.notebookInScope(of: [.memory]) == nil)
        #expect(MobileShellRoute.notebookInScope(of: [.memory, .cardPractice(.allNotebooks)]) == nil)
        #expect(MobileShellRoute.notebookInScope(of: [.memory, .cardPractice(.notebook("p3"))]) == "p3")
        #expect(
            MobileShellRoute.following(.source("s2"), from: [.memory], fromInsideApp: true) == [.memory, .source("s2", notebookID: nil)],
            "a card's source opens outside any notebook"
        )
    }

    // MARK: - Docs

    private func artifactPayload(_ record: ArtifactRecord, revision: String? = "rev-1") throws -> Data {
        try JSONEncoder().encode(CloudKitArtifactPayload(artifact: record, bodyRevision: revision))
    }

    @Test("A Doc the Mac saved reaches the notebook's Studio with every field it lists")
    func artifactParserRoundTrip() throws {
        let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let updated = Date(timeIntervalSinceReferenceDate: 800_000_600)
        let record = ArtifactRecord(
            id: "doc-1",
            title: "Briefing: sodium",
            homeNotebookID: "p1",
            linkedNotebookIDs: ["p2", "p2", "p3"],
            isDraft: true,
            sourceIDs: ["s1", "s2"],
            createdAt: created,
            updatedAt: updated
        )
        let doc = try #require(MobileArtifactCatalogParser.artifact(fromPayloadData: artifactPayload(record)))
        #expect(doc.id == "doc-1")
        #expect(doc.title == "Briefing: sodium")
        #expect(doc.kind == nil)
        #expect(doc.homeNotebookID == "p1")
        #expect(doc.linkedNotebookIDs == ["p2", "p3"])
        #expect(doc.sourceIDs == ["s1", "s2"])
        #expect(doc.isDraft)
        #expect(doc.createdAt == created)
        #expect(doc.updatedAt == updated)
        #expect(doc.bodyRevision == "rev-1")
        #expect(doc.isDoc)
        #expect(doc.belongs(toNotebookID: "p1") && doc.belongs(toNotebookID: "p3"))
        #expect(!doc.belongs(toNotebookID: "p9"))
    }

    @Test("Archived records leave the Studio; sites, animations and overviews are not Docs")
    func artifactKinds() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let archived = ArtifactRecord(id: "a", title: "Old", homeNotebookID: "p", linkedNotebookIDs: [], archivedAt: now, createdAt: now, updatedAt: now)
        #expect(MobileArtifactCatalogParser.artifact(fromPayloadData: try artifactPayload(archived)) == nil)

        let animation = ArtifactRecord(id: "an", title: "Pump", homeNotebookID: "p", linkedNotebookIDs: [], kind: .animation, createdAt: now, updatedAt: now)
        let parsedAnimation = try #require(MobileArtifactCatalogParser.artifact(fromPayloadData: artifactPayload(animation)))
        #expect(parsedAnimation.kind == "animation")
        #expect(!parsedAnimation.isDoc)

        let overview = ArtifactRecord(id: "o", title: "Overview", homeNotebookID: "p", linkedNotebookIDs: [], kind: .audioOverview, createdAt: now, updatedAt: now)
        #expect(try #require(MobileArtifactCatalogParser.artifact(fromPayloadData: artifactPayload(overview))).isDoc == false)

        let google = ArtifactRecord(id: "g", title: "Shared notes", homeNotebookID: nil, linkedNotebookIDs: ["p"], linkedURL: "https://docs.google.com/document/d/abc/edit", createdAt: now, updatedAt: now)
        let parsedGoogle = try #require(MobileArtifactCatalogParser.artifact(fromPayloadData: artifactPayload(google)))
        #expect(parsedGoogle.isGoogleDoc)
        #expect(parsedGoogle.isDoc, "a linked Google Doc is filed under Docs")

        let site = ArtifactRecord(id: "s", title: "Claude page", homeNotebookID: "p", linkedNotebookIDs: [], linkedURL: "https://claude.ai/code/artifact/3f2a9c1e-7b4d", createdAt: now, updatedAt: now)
        #expect(try #require(MobileArtifactCatalogParser.artifact(fromPayloadData: artifactPayload(site))).isDoc == false)

        #expect(MobileArtifactCatalogParser.artifact(fromPayloadData: Data("{}".utf8)) == nil)
    }

    @Test("The phone's Docs are the Mac's Docs section, link by link and kind by kind")
    func docsAreTheMacsDocsSection() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let links: [String?] = [
            nil,
            "https://docs.google.com/document/d/abc/edit",
            "https://docs.google.com/spreadsheets/d/abc",
            "https://example.org/some/page",
            "https://claude.ai/code/artifact/0123abcd-ef45",
            "https://claude.ai/public/artifacts/0123abcd-ef45",
            "https://claude.ai/chat/0123abcd-ef45",
            "https://atlas-notes.team.chatgpt.site/",
            "https://chatgpt.site/",
            "https://sites.foreverlm.com/mito-notes/",
            "https://sites.foreverlm.com/",
            "foreverlm-site://abcdef12-3456/",
        ]
        let kinds: [ArtifactKind?] = [nil, .animation, .audioOverview]
        for (index, link) in links.enumerated() {
            for kind in kinds {
                let record = ArtifactRecord(
                    id: "a\(index)",
                    title: "Record",
                    homeNotebookID: "p",
                    linkedNotebookIDs: [],
                    linkedURL: link,
                    kind: kind,
                    createdAt: now,
                    updatedAt: now
                )
                let parsed = try #require(MobileArtifactCatalogParser.artifact(fromPayloadData: artifactPayload(record)))
                let macListsAsDoc = NotebookOutputs.kind(of: record, isAudioOverview: false) == .doc
                #expect(parsed.isDoc == macListsAsDoc, "\(link ?? "no link"), kind \(kind?.rawValue ?? "none")")
            }
        }

        // A kind the Mac retired decodes there as a kindless Doc.
        let lessonPayload = Data(#"{"artifact":{"id":"l","title":"Lesson","homeNotebookID":"p","linkedNotebookIDs":[],"kind":"lesson","createdAt":800000000,"updatedAt":800000000}}"#.utf8)
        #expect(try #require(MobileArtifactCatalogParser.artifact(fromPayloadData: lessonPayload)).isDoc)

        // A team member's private draft is not listed, as on the Mac.
        let draft = ArtifactRecord(id: "draft_team-doc", title: "Draft", homeNotebookID: "p", linkedNotebookIDs: [], createdAt: now, updatedAt: now)
        let parsedDraft = try #require(MobileArtifactCatalogParser.artifact(fromPayloadData: artifactPayload(draft)))
        #expect(parsedDraft.isListed == NotebookOutputs.isListed(draft))
        #expect(!parsedDraft.isListed)
        let own = ArtifactRecord(id: "doc-9", title: "Mine", homeNotebookID: "p", linkedNotebookIDs: [], createdAt: now, updatedAt: now)
        #expect(try #require(MobileArtifactCatalogParser.artifact(fromPayloadData: artifactPayload(own))).isListed)
    }

    @Test("A notebook's outputs are ordered as the Mac's Studio orders them: by when made, undated last, then title")
    func outputsOrderAsTheMacsStudio() {
        let early = Date(timeIntervalSinceReferenceDate: 100)
        let late = Date(timeIntervalSinceReferenceDate: 200)
        let rows: [(id: String, title: String, date: Date?)] = [
            ("doc:1", "Briefing", early),
            ("course:2", "Aging course", nil),
            ("walkthrough:3", "Ouabain paper", late),
            ("explainer:4", "Calcium review", late),
            ("doc:5", "beta notes", nil),
            ("doc:6", "Alpha notes", early),
        ]
        let phone = MobileNotebookOutputOrder.ordered(rows) {
            MobileNotebookOutputOrder.Key(id: $0.id, title: $0.title, madeAt: $0.date)
        }.map(\.id)
        let mac = NotebookOutputs.ordered(rows.map { row in
            let parts = row.id.split(separator: ":").map(String.init)
            return NotebookOutput(
                kind: NotebookOutput.Kind(rawValue: parts[0])!,
                targetID: parts[1],
                title: row.title,
                sourceIDs: [],
                date: row.date
            )
        }).map(\.id)
        #expect(phone == mac)
        #expect(phone == ["explainer:4", "walkthrough:3", "doc:6", "doc:1", "course:2", "doc:5"])
    }

    @Test("The phone's Studio tiles are the Mac's where the Mac has them, and only what the phone can run")
    func studioTilesFollowTheMacs() {
        #expect(MobileNotebookStudioTile.allCases == [.explainer, .walkthrough, .reviewMe, .quiz])
        // Of the Mac's tiles the phone draws only Explainer, under its title,
        // glyph and menu; making overviews, cards, reports, research, courses
        // and notes stays on the Mac.
        let macTitles = Set(NotebookStudioTile.allCases.map(\.title))
        #expect(Set(MobileNotebookStudioTile.allCases.map(\.title)).intersection(macTitles) == ["Explainer"])
        #expect(MobileNotebookStudioTile.explainer.title == NotebookStudioTile.explainer.title)
        #expect(MobileNotebookStudioTile.explainer.symbolName == NotebookStudioTile.explainer.symbolName)
        #expect(MobileNotebookStudioTile.explainer.isMenu == NotebookStudioTile.explainer.isMenu)
        // The phone's own take the glyph the Mac gives their feature.
        let walk = NotebookOutput(kind: .walkthrough, targetID: "s", title: "Walk", sourceIDs: ["s"], date: nil)
        #expect(MobileNotebookStudioTile.walkthrough.symbolName == walk.symbolName)
        #expect(!MobileNotebookStudioTile.reviewMe.isMenu)
        #expect(MobileNotebookStudioTile.quiz.isMenu && MobileNotebookStudioTile.walkthrough.isMenu)
        #expect(Set(MobileNotebookStudioTile.allCases.map(\.accessibilityIdentifier)).count == 4)
    }

    @Test("A Studio output row reads as the Mac's: its kind's glyph and \"Doc · 4 sources · 3 days ago\"")
    func studioOutputRowsReadAsTheMacs() {
        func mac(_ kind: NotebookOutput.Kind) -> String {
            NotebookOutput(kind: kind, targetID: "t", title: "T", sourceIDs: [], date: nil).symbolName
        }
        #expect(MobileNotebookOutputGlyph.audioOverview == mac(.audioOverview))
        #expect(MobileNotebookOutputGlyph.doc == mac(.doc))
        #expect(MobileNotebookOutputGlyph.walkthrough == mac(.walkthrough))
        #expect(MobileNotebookOutputGlyph.explainer == mac(.explainer))
        #expect(MobileNotebookOutputGlyph.course == mac(.course))
        #expect(MobileNotebookOutputGlyph.mnemonicReading == mac(.mnemonicReading))
        #expect(MobileNotebookOutputLine.audioOverviewKind == AudioOverviewScript.kindLabel)

        for count in [0, 1, 6] {
            #expect(MobileNotebookOutputLine.sourcesLabel(count: count) == NotebookOutputs.sourcesLabel(count: count))
            for kind in ["Page", "Course", "Explainer"] {
                #expect(MobileNotebookOutputLine.subtitle(kind: kind, sourceCount: count)
                    == NotebookOutputs.subtitle(kind: kind, sourceCount: count))
            }
        }
        #expect(MobileNotebookOutputLine.line(kind: "Course", sourceCount: 0, madeAt: nil) == "Course")
        #expect(MobileNotebookOutputLine.line(kind: "Page", sourceCount: 4, madeAt: .distantPast) == "Page · 4 sources")
        // The date is the Mac row's, relative and named in full: "2 hours
        // ago", never "2 hr. ago".
        let made = Date().addingTimeInterval(-2 * 3_600)
        #expect(MobileNotebookOutputLine.line(kind: "Page", sourceCount: 4, madeAt: made)
            == "Page · 4 sources · \(made.formatted(.relative(presentation: .named)))")
        #expect(MobileNotebookOutputLine.line(kind: "Audio overview", sourceCount: 6, length: "12 min", madeAt: nil)
            == "Audio overview · 6 sources · 12 min")
    }

    @Test("An audio overview's row shows how far it was listened and its length only from what is known")
    func audioOverviewListening() {
        // Nothing known, nothing played, played out, or so near the end that
        // Play starts again: no bar.
        #expect(MobileAudioOverviewListening.listenedFraction(position: nil, duration: 600) == nil)
        #expect(MobileAudioOverviewListening.listenedFraction(position: 120, duration: nil) == nil)
        #expect(MobileAudioOverviewListening.listenedFraction(position: 0, duration: 600) == nil)
        #expect(MobileAudioOverviewListening.listenedFraction(position: 600, duration: 600) == nil)
        #expect(MobileAudioOverviewListening.listenedFraction(position: 596, duration: 600) == nil)
        #expect(MobileAudioOverviewListening.listenedFraction(position: .nan, duration: 600) == nil)
        #expect(MobileAudioOverviewListening.listenedFraction(position: 150, duration: 600) == 0.25)
        #expect(MobileAudioOverviewListening.listenedFraction(position: 594, duration: 600) == 0.99)

        #expect(MobileAudioOverviewListening.lengthLabel(duration: nil) == nil)
        #expect(MobileAudioOverviewListening.lengthLabel(duration: 0) == nil)
        #expect(MobileAudioOverviewListening.lengthLabel(duration: 20) == "1 min")
        #expect(MobileAudioOverviewListening.lengthLabel(duration: 12 * 60 + 20) == "12 min")
        #expect(MobileAudioOverviewListening.lengthLabel(duration: 65 * 60) == "1 hr 5 min")
        #expect(MobileAudioOverviewListening.lengthLabel(duration: 120 * 60) == "2 hr")
    }

    @Test("A notebook's course links ride beside the goal, and survive the identity remap")
    func linkedCourseIDs() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let goal = LearningGoalRecord(
            id: "p1",
            title: "Aging",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now,
            updatedAt: now,
            status: "active",
            items: [LearningGoalItem(id: "i1", goalID: "p1", sourceID: "s1", addedAt: now)],
            kind: LearningGoalRecord.companionKind
        )
        let data = try JSONEncoder().encode(CloudKitLearningGoalPayload(goal: goal, linkedCourseIDs: ["c1", "c2", "c1"]))
        let parsed = try #require(MobileNotebookCatalogParser.notebook(fromPayloadData: data))
        #expect(parsed.linkedCourseIDs == ["c1", "c2"])
        #expect(parsed.poolSourceIDs == ["s1"])

        // This phone holds the source under another id: the remap rebuilds
        // the notebook and must carry its course links and its boxes' pool.
        var phoneCopy = source("phone-s1")
        phoneCopy.url = "https://example.org/a"
        let remapped = MobileNotebookSourceIdentityResolver.remap(
            notebook: parsed,
            identities: [MobileMemorySourceIdentity(sourceID: "s1", url: "https://example.org/a", normalizedURL: nil, doi: nil, publishedDOI: nil)],
            sources: [phoneCopy],
            normalizeURL: { $0 }
        )
        #expect(remapped.sourceIDs == ["phone-s1"])
        // The boxes' pool keeps the Mac's id, which the synced row names, and
        // adds this phone's after it: a tick here never prunes the Mac's untick.
        #expect(remapped.poolSourceIDs == ["s1", "phone-s1"])
        #expect(remapped.linkedCourseIDs == ["c1", "c2"])
        let remappedAgain = MobileNotebookSourceIdentityResolver.remap(
            notebook: remapped,
            identities: [MobileMemorySourceIdentity(sourceID: "s1", url: "https://example.org/a", normalizedURL: nil, doi: nil, publishedDOI: nil)],
            sources: [phoneCopy],
            normalizeURL: { $0 }
        )
        #expect(remappedAgain.poolSourceIDs == ["s1", "phone-s1"], "remapping twice changes nothing")
        // The Mac unticked s1; any write here keeps that untick.
        let macRows = NotebookChatContext.Selection(excluded: ["s1"])
        #expect(
            MobileNotebookChatSelection.stored(
                MobileNotebookChatSelection.applying(
                    .sources([], inChat: true, through: nil),
                    own: MobileNotebookChatSelection.own(of: remapped),
                    linked: MobileNotebookChatSelection.linked(of: remapped),
                    to: macRows
                ),
                own: MobileNotebookChatSelection.own(of: remapped),
                linked: MobileNotebookChatSelection.linked(of: remapped)
            ) == macRows,
            "the phone's pool keeps the Mac's untick"
        )

        let older = try JSONEncoder().encode(CloudKitLearningGoalPayload(goal: goal))
        #expect(try #require(MobileNotebookCatalogParser.notebook(fromPayloadData: older)).linkedCourseIDs.isEmpty)
    }

    @Test("A Doc reads on the phone: pictures by their words, links the phone can follow kept")
    func docMarkdownReadable() {
        let markdown = """
        # Sodium

        See ![Figure 1: the pump](foreverlm://image/fig1) and ![](foreverlm://image/x).
        The [ouabain paper](foreverlm://source/src-1 "Ouabain") explains it; [the notebook](foreverlm://notebook/p1).
        Another [doc](foreverlm://doc/d2) and [the web](https://example.org/page).
        Cited again: [paper](foreverlm://source/src-1) and [review](foreverlm://source/src-2?t=10).
        """
        let readable = MobileDocMarkdown.readable(markdown)
        #expect(readable.text.contains("[picture: Figure 1: the pump]"))
        #expect(readable.text.contains("[picture]"))
        #expect(readable.text.contains("[ouabain paper](foreverlm://source/src-1)"))
        #expect(readable.text.contains("[the notebook](foreverlm://notebook/p1)"))
        #expect(readable.text.contains("Another [doc](foreverlm://doc/d2) and"), "a page's link opens the page on the phone too")
        #expect(readable.text.contains("[the web](https://example.org/page)"))
        #expect(!readable.text.contains("foreverlm://image"))
        #expect(readable.citedSourceIDs == ["src-1", "src-2"])
    }

    @Test("A Doc's text is read as headings, paragraphs, lists, quotes, code and rules")
    func docMarkdownBlocks() {
        let text = """
        # Title
        Intro line one
        line two

        - first
        - second
        1. one
        2) two
        > quoted
        ---
        ```
        let x = 1
        ```
        ## Next
        """
        #expect(MobileDocMarkdown.blocks(text) == [
            .heading(level: 1, text: "Title"),
            .paragraph("Intro line one\nline two"),
            .bullets(["first", "second"]),
            .numbered(["one", "two"]),
            .quote("quoted"),
            .rule,
            .code("let x = 1"),
            .heading(level: 2, text: "Next"),
        ])
    }

    @Test("A page's footnotes are numbered by first reference, whatever their labels, and listed under a rule at the end")
    func docFootnotesNumberedByFirstReference() {
        let markdown = """
        Sodium leaks in[^b] and is pumped out[^a].
        Calcium[^Smith] follows.

        [^a]: The pump.
        [^b]: The leak.
        [^smith]: Smith 2020.
        """
        let text = MobileDocMarkdown.readable(markdown).text
        #expect(text == "Sodium leaks in¹ and is pumped out².\nCalcium³ follows.\n\n---\n\n1. The leak.\n2. The pump.\n3. Smith 2020.")
        #expect(MobileDocMarkdown.blocks(text) == [
            .paragraph("Sodium leaks in¹ and is pumped out².\nCalcium³ follows."),
            .rule,
            .numbered(["The leak.", "The pump.", "Smith 2020."]),
        ])

        var page = ""
        var notes = ""
        for number in 1...11 {
            page += "w\(number)[^n\(number)] "
            notes += "[^n\(number)]: Note \(number).\n"
        }
        let eleven = MobileDocMarkdown.readable(page + "\n\n" + notes).text
        #expect(eleven.hasPrefix("w1¹ w2² w3³ w4⁴ w5⁵ w6⁶ w7⁷ w8⁸ w9⁹ w10¹⁰ w11¹¹"))
    }

    @Test("A footnote referenced twice shows the same number both times")
    func docFootnoteRepeatedReference() {
        let text = MobileDocMarkdown.readable("One[^n] and two[^m] and one again[^n].\n\n[^n]: N.\n[^m]: M.").text
        #expect(text == "One¹ and two² and one again¹.\n\n---\n\n1. N.\n2. M.")
    }

    @Test("A footnote written in the middle of a page moves to the end")
    func docFootnoteDefinedMidPage() {
        let markdown = """
        Intro[^1].

        [^1]: The note.

        ## Next
        More text.
        """
        #expect(MobileDocMarkdown.blocks(MobileDocMarkdown.readable(markdown).text) == [
            .paragraph("Intro¹."),
            .heading(level: 2, text: "Next"),
            .paragraph("More text."),
            .rule,
            .numbered(["The note."]),
        ])
    }

    @Test("A footnote over several lines and paragraphs reads as one line, and a new block ends it")
    func docFootnoteJoinedLines() {
        let markdown = """
        Text[^long] and[^short].

        [^long]: First line
        lazy line
            indented line

            Second paragraph.

        After the note.
        [^short]: Short
        - a list item, not the note
        """
        let text = MobileDocMarkdown.readable(markdown).text
        #expect(text == "Text¹ and².\n\n\nAfter the note.\n- a list item, not the note\n\n---\n\n1. First line lazy line indented line Second paragraph.\n2. Short")
    }

    @Test("A footnote nothing references is listed after the referenced ones")
    func docFootnoteUnreferencedLast() {
        let text = MobileDocMarkdown.readable("A[^2].\n\n[^1]: Unused.\n[^2]: Used.").text
        #expect(text == "A¹.\n\n---\n\n1. Used.\n2. Unused.")
    }

    @Test("A reference with no footnote, or one inside code, stays as written")
    func docFootnoteLiteralReferences() {
        #expect(MobileDocMarkdown.readable("See [^x] and [^1].\n\n[^1]: One.").text == "See [^x] and ¹.\n\n---\n\n1. One.")

        let markdown = """
        Inline `a[^1]` and ``b`[^1]`` and real[^1].

        ```
        x[^1]
        [^1]: not a definition
        ```

        [^1]: The note.
        """
        let text = MobileDocMarkdown.readable(markdown).text
        #expect(text == "Inline `a[^1]` and ``b`[^1]`` and real¹.\n\n```\nx[^1]\n[^1]: not a definition\n```\n\n---\n\n1. The note.")
    }

    @Test("A page without footnotes reads exactly as it did before")
    func docWithoutFootnotesUnchanged() {
        #expect(MobileDocMarkdown.readable("Plain [^x](https://example.org) text\r\nline two").text == "Plain [^x](https://example.org) text\nline two")
        #expect(MobileDocMarkdown.readable("`[^1]: in code`\n```\n[^1]: fenced\n```").text == "`[^1]: in code`\n```\n[^1]: fenced\n```")
    }

    @Test("A footnote reference before brackets is never a link, and a note's links are read like the page's")
    func docFootnoteLinks() {
        let markdown = """
        text[^1](see) and [a link](https://example.org)[^2].

        [^1]: Note with [web](https://example.org/n), [a page](foreverlm://doc/d1) and ![fig](foreverlm://image/f).
        [^2]: Cites [paper](foreverlm://source/src-9).
        """
        let readable = MobileDocMarkdown.readable(markdown)
        #expect(readable.text == "text¹(see) and [a link](https://example.org)².\n\n---\n\n1. Note with [web](https://example.org/n), [a page](foreverlm://doc/d1) and [picture: fig].\n2. Cites [paper](foreverlm://source/src-9).")
        #expect(readable.citedSourceIDs == ["src-9"])
    }

    // MARK: - Chats

    @Test("A saved chat reads as the Mac draws it, and an older phone chat as the learner asking")
    func transcriptTurns() {
        let macChat = MobileChatTranscriptTurns.turns(sessionID: "session-1", exchanges: [
            .init(sequenceNumber: 2, question: "", userAnswer: "And calcium?", evaluation: "It follows."),
            .init(sequenceNumber: 1, question: "", userAnswer: "Why sodium?", evaluation: "The pump stops."),
        ])
        #expect(macChat == [
            .init(role: .user, content: "Why sodium?"),
            .init(role: .assistant, content: "The pump stops."),
            .init(role: .user, content: "And calcium?"),
            .init(role: .assistant, content: "It follows."),
        ])

        let voice = MobileChatTranscriptTurns.turns(sessionID: "ios-live-abc", exchanges: [
            .init(sequenceNumber: 1, question: RealtimeExchangeLedger.openConversationQuestion, userAnswer: "Hi", evaluation: "Hello."),
        ])
        #expect(voice == [.init(role: .user, content: "Hi"), .init(role: .assistant, content: "Hello.")])

        let review = MobileChatTranscriptTurns.turns(sessionID: "mac-1", exchanges: [
            .init(sequenceNumber: 1, question: "What does ouabain do?", userAnswer: "Stops the pump", evaluation: "Right."),
        ])
        #expect(review.map(\.role) == [.assistant, .user, .assistant])

        let olderPhoneReadingChat = MobileChatTranscriptTurns.turns(sessionID: "ios-1234", exchanges: [
            .init(sequenceNumber: 1, question: "What is Figure 2?", userAnswer: "", evaluation: "A dose curve."),
        ])
        #expect(olderPhoneReadingChat == [
            .init(role: .user, content: "What is Figure 2?"),
            .init(role: .assistant, content: "A dose curve."),
        ])
    }

    @Test("A saved chat reads without the Mac's row chrome: a walk's step lines and a review's source turns")
    func transcriptDropsTheMacsRowChrome() {
        let step = WalkthroughStepTurn.line(.init(sourceID: "paper-1", stepID: "s2", index: 1, count: 4))
        let sourceTurn = MemoryReviewSourceTurn.line(sourceID: "paper-1")
        let turns = MobileChatTranscriptTurns.turns(sessionID: "mac-walk-1", exchanges: [
            .init(sequenceNumber: 1, question: "\(step)\n\nThe pump stops.", userAnswer: "Why?", evaluation: "\(sourceTurn)\nSodium builds up."),
            .init(sequenceNumber: 2, question: step, userAnswer: "", evaluation: nil),
        ])
        #expect(turns == [
            .init(role: .assistant, content: "The pump stops."),
            .init(role: .user, content: "Why?"),
            .init(role: .assistant, content: "Sodium builds up."),
        ])
        #expect(!turns.contains { $0.content.contains("<flm_") })
    }

    @Test("A continued chat's model reads a Mac reply without its pages' and saved cards' lines, which the transcript still shows")
    func continuedChatReadsTheReplyWithoutItsStoredLines() {
        let page = ChatWrittenPage(id: "doc 1(x)", title: "Notes [draft]")
        let cards = ChatSavedCards(cardIDs: ["c-1"], sourceIDs: ["src-1"], notSavedCount: 1)
        let reply = "I wrote it up.\n\nRead it when you can."
        let stored = ChatWrittenPage.storing(ChatSavedCards.storing(reply, with: cards), with: [page])
        // The Mac's own rule, line for line.
        #expect(MobileChatTranscriptTurns.modelLine(stored) == ChatSavedCards.prose(of: ChatWrittenPage.prose(of: stored)))
        #expect(MobileChatTranscriptTurns.modelLine(stored) == reply)
        // A page link the reply wrote itself, and a reply with neither line, stay as they are.
        let inline = "See [Notes](foreverlm://doc/doc-1?card=page) for more."
        #expect(MobileChatTranscriptTurns.modelLine(inline) == inline)
        #expect(MobileChatTranscriptTurns.modelLine("[Notes](foreverlm://doc/doc-1)") == "[Notes](foreverlm://doc/doc-1)")
        #expect(MobileChatTranscriptTurns.modelLine("  Plain.\n") == "  Plain.\n")

        // The transcript shows the lines, and the reply asked again as the
        // next question, stored without them, is not drawn twice.
        let turns = MobileChatTranscriptTurns.turns(sessionID: "mac-1", exchanges: [
            .init(sequenceNumber: 1, question: "", userAnswer: "Write it up", evaluation: stored),
            .init(sequenceNumber: 2, question: reply, userAnswer: "Thanks", evaluation: "Any time."),
        ])
        #expect(turns == [
            .init(role: .user, content: "Write it up"),
            .init(role: .assistant, content: stored),
            .init(role: .user, content: "Thanks"),
            .init(role: .assistant, content: "Any time."),
        ])
    }

    @Test("A chat's kind comes from what recorded it")
    func chatKinds() {
        #expect(MobileNotebookChatSummary.kind(sessionID: "ios-live-1", isMemoryReview: false) == .voice)
        #expect(MobileNotebookChatSummary.kind(sessionID: "mac-live-1", isMemoryReview: false) == .voice)
        #expect(MobileNotebookChatSummary.kind(sessionID: "ios-1", isMemoryReview: false) == .text)
        #expect(MobileNotebookChatSummary.kind(sessionID: "memory-2026-10-01", isMemoryReview: true) == .memory)
    }

    // MARK: - The notebook guide

    private func chatSummary(_ id: String, minutesAgo: Double = 0) -> MobileNotebookChatSummary {
        let at = Date(timeIntervalSinceReferenceDate: 1_000_000 - minutesAgo * 60)
        return MobileNotebookChatSummary(id: id, title: "Chat \(id)", kind: .text, turnCount: 1, startedAt: at, lastActivityAt: at)
    }

    @Test("The phone's guide lists as many chats as the Mac's and sends the Mac's Suggest questions")
    func guideMatchesTheMac() {
        #expect(MobileNotebookChatGuide.recentChatLimit == NotebookChatGuide.recentChatLimit)
        #expect(MobileNotebookChatGuide.suggestQuestionsPrompt == NotebookChatGuide.suggestQuestionsPrompt)

        let chats = (0..<6).map { chatSummary("c\($0)", minutesAgo: Double($0)) }
        #expect(MobileNotebookChatGuide.recentChats(chats).map(\.id) == ["c0", "c1", "c2", "c3"])
        #expect(MobileNotebookChatGuide.hasMoreChats(chats))
        #expect(MobileNotebookChatGuide.recentChats(Array(chats.prefix(4))).count == 4)
        #expect(!MobileNotebookChatGuide.hasMoreChats(Array(chats.prefix(4))), "four chats are all listed, with no All chats")
        #expect(MobileNotebookChatGuide.recentChats([]).isEmpty)
    }

    @Test("The phone's All chats search finds what the Mac's finds: by title, ignoring case and accents, in order")
    @MainActor
    func allChatsSearchMatchesTheMac() {
        let titles = ["Alzheimer’s and Blood Flow", "Ontogeny of microglia", "Reprogramming Microglia"]
        let phone = titles.enumerated().map { index, title in
            MobileNotebookChatSummary(id: "c\(index)", title: title, kind: .text, turnCount: 1, startedAt: .distantPast, lastActivityAt: .distantPast)
        }
        let mac = titles.enumerated().map { index, title in
            NotebookChatGuide.RecentChat(id: "c\(index)", title: title, date: .distantPast)
        }
        for query in ["", "  ", "MICROGLIA", " alzheimer ", "ontogény", "thyroid"] {
            #expect(MobileNotebookChatGuide.chats(phone, matching: query).map(\.id)
                    == NotebookChatGuide.chats(mac, matching: query).map(\.id), "query \"\(query)\"")
        }
        #expect(MobileNotebookChatGuide.chats(phone, matching: "microglia").map(\.id) == ["c1", "c2"])
        #expect(MobileNotebookChatGuide.chats(phone, matching: "thyroid").isEmpty)
    }

    // MARK: - Continuing a saved chat

    @Test("A conversation is continued on the phone; a memory review, a review, a quiz and a walk's chat are read")
    func whichChatsContinue() {
        func shape(_ id: String = "ios-1", kind: String? = nil, memory: Bool = false, cards: Bool = false,
                   score: Double? = nil, exchanges: [ReviewableChat.Exchange] = []) -> MobileNotebookChatContinuation.Shape {
            MobileNotebookChatContinuation.shape(
                sessionID: id, kind: kind, isMemoryReview: memory, hasCardIDs: cards,
                overallScore: score, exchanges: exchanges
            )
        }
        let talk = ReviewableChat.Exchange(sequenceNumber: 1, question: "", userAnswer: "Why sodium?", evaluation: "The pump stops.")
        #expect(shape(exchanges: [talk]) == .chat, "a phone chat")
        #expect(shape("mac-1", kind: ReviewSessionKind.chat.rawValue, exchanges: [talk]) == .chat, "a Mac chat")
        #expect(shape("ios-live-1", exchanges: [talk]) == .chat, "a spoken chat is a conversation too")

        #expect(shape("memory-2026-10-01", memory: true) == .memoryReview)
        #expect(shape("mac-2", kind: ReviewSessionKind.memory.rawValue) == .memoryReview)
        #expect(shape("mac-3", kind: ReviewSessionKind.review.rawValue, exchanges: [talk]) == .tutoredReview)
        #expect(shape("course-quiz-q1-\(UUID().uuidString)") == .tutoredReview)
        let graded = ReviewableChat.Exchange(sequenceNumber: 1, question: "What does ouabain do?", userAnswer: "Stops it", evaluation: "Right.", score: 1)
        #expect(shape("mac-4", exchanges: [graded]) == .tutoredReview, "a graded turn makes a review, kind or not")
        #expect(shape("mac-5", score: 0.8, exchanges: [talk]) == .tutoredReview)
        #expect(shape("mac-6", cards: true, exchanges: [talk]) == .tutoredReview)

        let step = WalkthroughStepTurn.line(.init(sourceID: "paper-1", stepID: "s1", index: 0, count: 3))
        let walk = ReviewableChat.Exchange(sequenceNumber: 1, question: "\(step)\n\nThe figure.", userAnswer: "", evaluation: nil)
        #expect(shape(exchanges: [walk, talk]) == .walkthrough)

        let here: Set<String> = ["s1", "s2"]
        let onPhone: (String) -> Bool = { here.contains($0) }
        #expect(MobileNotebookChatContinuation.verdict(shape: .chat, sourceIDs: ["s1", "gone"], isOnPhone: onPhone) == .continuable,
                "one of its sources here is enough; the composer names the rest")
        #expect(MobileNotebookChatContinuation.verdict(shape: .chat, sourceIDs: ["gone"], isOnPhone: onPhone)
            == .readOnly("This chat's sources have not reached this iPhone yet."))
        #expect(MobileNotebookChatContinuation.verdict(shape: .chat, sourceIDs: [], isOnPhone: onPhone)
            == .readOnly("This chat read no sources; it continues on your Mac."))
        for kept in [MobileNotebookChatContinuation.Shape.memoryReview, .tutoredReview, .walkthrough] {
            guard case .readOnly(let line) = MobileNotebookChatContinuation.verdict(shape: kept, sourceIDs: ["s1"], isOnPhone: onPhone) else {
                Issue.record("\(kept) must be read-only")
                continue
            }
            #expect(line.hasSuffix("continue on your Mac."))
        }
    }

    @Test("A continued chat reads the sources the saved one read, in its order, whole, and says what it lacks")
    func continuedChatGrounding() {
        let library = ["a": source("a"), "b": source("b"), "c": source("c")]
        let found = MobileNotebookChatContinuation.sources(of: ["c", "gone", "a", "c", "lost"]) { library[$0] }
        #expect(found.onPhone.map(\.id) == ["c", "a"], "the chat's order, once each — never the ticks")
        #expect(found.missingCount == 2)

        // The same whole-source rule as a new chat: nothing is cut.
        let plan = MobileNotebookChatGrounding.plan([
            .init(sourceID: "c", characterCount: 200_000),
            .init(sourceID: "a", characterCount: 50_000),
        ])
        #expect(plan.loaded == ["c"])
        #expect(MobileNotebookChatContinuation.notice(plan, missingCount: 1)
            == "Reads 1 of this chat's 3 sources; the rest do not fit whole beside them. 1 of its sources is not on this iPhone yet.")
        #expect(MobileNotebookChatContinuation.notice(plan, missingCount: 0)?.contains("untick") == false,
                "the ticks have no say in a chat under way")

        let whole = MobileNotebookChatGrounding.plan([.init(sourceID: "c", characterCount: 10), .init(sourceID: "a", characterCount: 10)])
        #expect(MobileNotebookChatContinuation.notice(whole, missingCount: 0) == nil)
        #expect(MobileNotebookChatContinuation.notice(whole, missingCount: 2) == "2 of its sources are not on this iPhone yet.")
        let noText = MobileNotebookChatGrounding.plan([.init(sourceID: "c", characterCount: nil)])
        #expect(MobileNotebookChatContinuation.notice(noText, missingCount: 0) == "1 source's text has not reached this iPhone yet.")
        let tooLong = MobileNotebookChatGrounding.plan([.init(sourceID: "c", characterCount: 300_000)])
        #expect(tooLong.loaded.isEmpty, "a source longer than the bound is never loaded in part")
        #expect(MobileNotebookChatContinuation.notice(tooLong, missingCount: 0) == "None of this chat's sources fits whole in a chat.")
    }

    /// A Mac chat's payload as the Mac's mapper writes it, read back as JSON
    /// the way the phone's recorder reads the record.
    private func macChatPayload(
        kind: String? = ReviewSessionKind.chat.rawValue,
        teamID: String? = nil,
        modelEffort: String? = "high"
    ) throws -> [String: Any] {
        let identity = CloudKitSourceIdentityPayload(sourceID: "s1", url: "https://example.org/a", normalizedURL: "example.org/a", doi: nil, publishedDOI: nil)
        let payload = CloudKitReviewSessionPayload(
            id: "mac-chat-1",
            topic: "Why does sodium rise?",
            startedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            endedAt: Date(timeIntervalSinceReferenceDate: 2_000),
            status: "completed",
            overallScore: nil,
            summary: "A chat about the pump.",
            sourceIDs: ["s1", "s2"],
            cardIDs: [],
            exchangeCount: 2,
            modelProvider: "OpenRouter",
            modelID: "anthropic/claude-sonnet",
            modelEffort: modelEffort,
            modelSpeed: nil,
            goalID: "notebook-1",
            exchanges: [
                CloudKitReviewExchangePayload(
                    id: "mac-ex-a", sessionID: "mac-chat-1", sequenceNumber: 1, question: "",
                    userAnswer: "Why does sodium rise?", evaluation: "The pump stops.", score: nil,
                    sourceRefs: ["s1", "s2"], knowledgeNote: "Mac", answeredAt: Date(timeIntervalSinceReferenceDate: 1_500),
                    contextContent: "> the passage", rating: "liked", ratedAt: Date(timeIntervalSinceReferenceDate: 1_600)
                ),
                CloudKitReviewExchangePayload(
                    id: "mac-ex-b", sessionID: "mac-chat-1", sequenceNumber: 2, question: "",
                    userAnswer: "And calcium?", evaluation: "It follows.", score: nil,
                    sourceRefs: ["s1", "s2"], knowledgeNote: "Mac", answeredAt: Date(timeIntervalSinceReferenceDate: 1_900)
                ),
            ],
            sourceIdentities: [identity],
            docLinks: [CloudKitArtifactChatLinkPayload(
                id: "link-1", artifactID: "doc-1", anchorRevision: "r1", anchorStart: 0, anchorEnd: 4,
                anchorQuote: "pump", sectionTitle: "Intro", createdAt: Date(timeIntervalSinceReferenceDate: 900)
            )],
            kind: kind,
            teamID: teamID
        )
        let data = try JSONEncoder().encode(payload)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("A continued chat's turns join the saved session after its own, and the Mac reads every field it wrote")
    func continuedChatAppendsToTheMacsRecord() throws {
        let stored = try macChatPayload()
        let sitting = "sit-1"
        let added = [
            MobileNotebookChatContinuation.AddedExchange(
                id: MobileNotebookChatContinuation.exchangeID(sessionID: "mac-chat-1", sitting: sitting, index: 1),
                userAnswer: "And potassium?", evaluation: "It leaves the cell.",
                answeredAt: Date(timeIntervalSinceReferenceDate: 3_000)
            ),
        ]
        let appended = try MobileNotebookChatContinuation.payload(
            stored, sessionID: "mac-chat-1", appending: added,
            knowledgeNote: "Recorded from a notebook chat on iOS.",
            modelProvider: "OpenRouter", modelID: "openai/gpt-phone",
            endedAt: Date(timeIntervalSinceReferenceDate: 3_100)
        )
        let data = try JSONSerialization.data(withJSONObject: appended, options: [.sortedKeys])
        let mac = try JSONDecoder().decode(CloudKitReviewSessionPayload.self, from: data)

        // The saved chat's own fields, as the Mac wrote them.
        #expect(mac.id == "mac-chat-1")
        #expect(mac.topic == "Why does sodium rise?", "the chat keeps its title")
        #expect(mac.summary == "A chat about the pump.")
        #expect(mac.kind == ReviewSessionKind.chat.rawValue)
        #expect(mac.goalID == "notebook-1" && mac.goalIDFieldIsPresent)
        #expect(mac.sourceIDs == ["s1", "s2"], "a chat keeps the sources it began with")
        #expect(mac.sourceIdentities.map(\.sourceID) == ["s1"])
        #expect(mac.docLinks?.map(\.id) == ["link-1"])
        #expect(mac.startedAt == Date(timeIntervalSinceReferenceDate: 1_000))

        // Its turns untouched, the new one after them.
        #expect(mac.exchanges.map(\.id) == ["mac-ex-a", "mac-ex-b", "mac-chat-1::continued::sit-1::0001"])
        #expect(mac.exchanges.map(\.sequenceNumber) == [1, 2, 3])
        #expect(mac.exchanges[0].contextContent == "> the passage")
        #expect(mac.exchanges[0].rating == "liked")
        #expect(mac.exchanges[0].ratedAt == Date(timeIntervalSinceReferenceDate: 1_600))
        let turn = mac.exchanges[2]
        #expect(turn.sessionID == "mac-chat-1")
        #expect(turn.question == "", "the Mac's chat exchange: no tutor question")
        #expect(turn.userAnswer == "And potassium?")
        #expect(turn.evaluation == "It leaves the cell.")
        #expect(turn.score == nil, "nothing here tested anyone")
        #expect(turn.sourceRefs == ["s1", "s2"])
        #expect(turn.knowledgeNote == "Recorded from a notebook chat on iOS.")
        #expect(turn.answeredAt == Date(timeIntervalSinceReferenceDate: 3_000))
        #expect(mac.exchangeCount == 3)
        #expect(mac.status == "completed")
        #expect(mac.endedAt == Date(timeIntervalSinceReferenceDate: 3_100))

        // The model that answered; the Mac's effort was for another model.
        #expect(mac.modelID == "openai/gpt-phone")
        #expect(mac.modelTuningFieldIsPresent && mac.modelEffort == nil && mac.modelSpeed == nil)

        // The read-only transcript reads the continued chat in order.
        let turns = MobileChatTranscriptTurns.turns(sessionID: mac.id, exchanges: mac.exchanges.map {
            .init(sequenceNumber: $0.sequenceNumber, question: $0.question, userAnswer: $0.userAnswer, evaluation: $0.evaluation)
        })
        #expect(turns.map(\.content) == ["Why does sodium rise?", "The pump stops.", "And calcium?", "It follows.", "And potassium?", "It leaves the cell."])
    }

    @Test("Saving a sitting again replaces its own turns, never doubles them, and never moves the chat's end back")
    func continuedChatSavesAgainInPlace() throws {
        let stored = try macChatPayload(modelEffort: "high")
        func turn(_ index: Int, _ words: String) -> MobileNotebookChatContinuation.AddedExchange {
            .init(
                id: MobileNotebookChatContinuation.exchangeID(sessionID: "mac-chat-1", sitting: "sit-2", index: index),
                userAnswer: words, evaluation: "Reply to \(words)",
                answeredAt: Date(timeIntervalSinceReferenceDate: 3_000 + Double(index))
            )
        }
        let first = try MobileNotebookChatContinuation.payload(
            stored, sessionID: "mac-chat-1", appending: [turn(1, "One")], knowledgeNote: "iOS",
            modelProvider: "OpenRouter", modelID: "anthropic/claude-sonnet", endedAt: Date(timeIntervalSinceReferenceDate: 3_001)
        )
        // The next save of the sitting carries both of its turns, and its
        // clock is behind the saved end.
        let second = try MobileNotebookChatContinuation.payload(
            first, sessionID: "mac-chat-1", appending: [turn(1, "One"), turn(2, "Two")], knowledgeNote: "iOS",
            modelProvider: "OpenRouter", modelID: "anthropic/claude-sonnet", endedAt: Date(timeIntervalSinceReferenceDate: 2_500)
        )
        let mac = try JSONDecoder().decode(
            CloudKitReviewSessionPayload.self,
            from: JSONSerialization.data(withJSONObject: second, options: [.sortedKeys])
        )
        #expect(mac.exchanges.map(\.userAnswer) == ["Why does sodium rise?", "And calcium?", "One", "Two"])
        #expect(mac.exchanges.map(\.sequenceNumber) == [1, 2, 3, 4])
        #expect(Set(mac.exchanges.map(\.id)).count == 4)
        #expect(mac.endedAt == Date(timeIntervalSinceReferenceDate: 3_001))
        #expect(mac.modelEffort == "high", "the same model keeps the effort the Mac chose")

        // A sitting's ids never collide with another sitting's or the Mac's.
        #expect(MobileNotebookChatContinuation.exchangeID(sessionID: "mac-chat-1", sitting: "a", index: 1)
            != MobileNotebookChatContinuation.exchangeID(sessionID: "mac-chat-1", sitting: "b", index: 1))
    }

    @Test("A late whole-chat save keeps the turns a continuation appended")
    func lateSnapshotKeepsContinuedTurns() throws {
        func exchange(_ id: String, _ sequence: Int, _ words: String) -> [String: Any] {
            ["id": id, "sessionID": "ios-chat-1", "sequenceNumber": sequence, "question": "", "userAnswer": words]
        }
        let continued1 = MobileNotebookChatContinuation.exchangeID(sessionID: "ios-chat-1", sitting: "s", index: 1)
        let continued2 = MobileNotebookChatContinuation.exchangeID(sessionID: "ios-chat-1", sitting: "s", index: 2)
        let stored: [String: Any] = [
            "id": "ios-chat-1",
            "endedAt": 5_000.0,
            "exchanges": [
                exchange("ios-chat-1-1", 1, "First"),
                exchange("ios-chat-1-2", 2, "Second"),
                exchange(continued1, 3, "Continued one"),
                exchange(continued2, 4, "Continued two"),
            ],
        ]
        // The Reader's Ask sheet, still open, saves its own transcript whole:
        // its two turns and one more of its own, numbered 3.
        let snapshot: [String: Any] = [
            "id": "ios-chat-1",
            "endedAt": 4_000.0,
            "exchangeCount": 3,
            "exchanges": [
                exchange("ios-chat-1-1", 1, "First"),
                exchange("ios-chat-1-2", 2, "Second"),
                exchange("ios-chat-1-3", 3, "Third, from the sheet"),
            ],
        ]
        let merged = try #require(MobileNotebookChatContinuation.keepingContinuedTurns(snapshot: snapshot, stored: stored))
        let exchanges = merged["exchanges"] as? [[String: Any]] ?? []
        #expect(exchanges.compactMap { $0["userAnswer"] as? String }
            == ["First", "Second", "Third, from the sheet", "Continued one", "Continued two"])
        #expect(exchanges.compactMap { ($0["sequenceNumber"] as? NSNumber)?.intValue } == [1, 2, 3, 4, 5],
                "a continued turn whose number the snapshot took moves past it")
        #expect(merged["exchangeCount"] as? Int == 5)
        #expect((merged["endedAt"] as? NSNumber)?.doubleValue == 5_000, "the end never moves back")

        // Nothing continued, or the continued turns already in the snapshot:
        // the snapshot is saved as it is.
        var plain = stored
        plain["exchanges"] = [exchange("ios-chat-1-1", 1, "First")]
        #expect(MobileNotebookChatContinuation.keepingContinuedTurns(snapshot: snapshot, stored: plain) == nil)
        var holding = snapshot
        holding["exchanges"] = stored["exchanges"]
        #expect(MobileNotebookChatContinuation.keepingContinuedTurns(snapshot: holding, stored: stored) == nil)
        // A record of another chat is never mixed in.
        var other = stored
        other["id"] = "ios-chat-2"
        #expect(MobileNotebookChatContinuation.keepingContinuedTurns(snapshot: snapshot, stored: other) == nil)
    }

    @Test("A team's transcript, a review and another chat's record are never appended to")
    func continuationRefusals() throws {
        let one = MobileNotebookChatContinuation.AddedExchange(id: "x", userAnswer: "Hi", evaluation: "Hello.", answeredAt: Date())
        func append(_ stored: [String: Any], sessionID: String = "mac-chat-1") throws {
            _ = try MobileNotebookChatContinuation.payload(
                stored, sessionID: sessionID, appending: [one], knowledgeNote: "iOS",
                modelProvider: "OpenRouter", modelID: "m", endedAt: Date()
            )
        }
        #expect(throws: MobileNotebookChatContinuation.Refusal.teamTranscript) { try append(try macChatPayload(teamID: "team-1")) }
        #expect(throws: MobileNotebookChatContinuation.Refusal.notAChat) { try append(try macChatPayload(kind: ReviewSessionKind.review.rawValue)) }
        #expect(throws: MobileNotebookChatContinuation.Refusal.notAChat) { try append(try macChatPayload(kind: ReviewSessionKind.memory.rawValue)) }
        #expect(throws: MobileNotebookChatContinuation.Refusal.otherSession) { try append(try macChatPayload(), sessionID: "mac-chat-2") }
        // A chat recorded before the kind column still continues.
        #expect(throws: Never.self) { try append(try macChatPayload(kind: nil)) }
    }

    // MARK: - Models

    @Test("The model chip offers the default first, then the models the learner offers on the Mac")
    func offeredModels() throws {
        let defaultRoute = AIModelRoutePreference(provider: "Anthropic (Claude)", model: "claude-sonnet-5", effort: "high")
        let custom = try JSONEncoder().encode([["id": "moonshotai/kimi-k3", "name": "Kimi K3"]])
        let names = MobileOfferedChatModels.customNames(from: custom)
        let choices = MobileOfferedChatModels.choices(
            enabledIDs: [
                "openai|gpt-5.6",
                "anthropic|claude-sonnet-5",
                "openrouter|moonshotai/kimi-k3",
                "groq|llama-3",
                "malformed",
                "gemini|",
            ],
            customNames: names,
            defaultPreference: defaultRoute,
            freeModeOn: false
        )
        #expect(choices.map(\.id) == [
            "Anthropic (Claude)|claude-sonnet-5",
            "OpenAI (GPT)|gpt-5.6",
            "OpenRouter|moonshotai/kimi-k3",
        ])
        #expect(choices.first?.preference.effort == "high", "the default keeps its own effort")
        #expect(choices.last?.name == "Kimi K3")

        let onlyDefault = MobileOfferedChatModels.choices(enabledIDs: nil, customNames: [:], defaultPreference: defaultRoute, freeModeOn: false)
        #expect(onlyDefault.map(\.id) == ["Anthropic (Claude)|claude-sonnet-5"], "nothing the learner did not offer")

        let free = MobileOfferedChatModels.choices(
            enabledIDs: ["openrouter|openrouter/free", "openai|gpt-5.6"],
            customNames: [:],
            defaultPreference: AIModelRoutePreference(provider: "OpenRouter", model: "openrouter/free"),
            freeModeOn: true
        )
        #expect(free.map(\.id) == ["OpenRouter|openrouter/free"], "Free mode offers only free models")
    }

    @Test("A model with no directory name reads as words")
    func modelDisplayNames() {
        #expect(MobileOfferedChatModels.displayName(model: "claude-haiku-4-5", customNames: [:]) == "Claude Haiku 4.5")
        #expect(MobileOfferedChatModels.displayName(model: "claude-sonnet-5", customNames: [:]) == "Claude Sonnet 5")
        #expect(MobileOfferedChatModels.displayName(model: "gpt-5.6", customNames: [:]) == "GPT 5.6")
        #expect(MobileOfferedChatModels.displayName(model: "x-ai/grok-4.3", customNames: [:]) == "Grok 4.3")
        #expect(MobileOfferedChatModels.displayName(model: "a/b", customNames: ["a/b": "Named"]) == "Named")
    }

    // MARK: - Cards and search

    private func item(_ id: String, goalID: String? = nil, sources: [String]) -> MemoryItem {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        return MemoryItem(
            id: id,
            kind: .concept,
            target: "target",
            rubricJSON: "{}",
            goalID: goalID,
            status: .active,
            sources: sources.enumerated().map { index, sourceID in
                MemoryItemSource(id: "\(id)-\(index)", memoryItemID: id, sourceID: sourceID, excerpt: "", sourceSHA256: "", sortIndex: index)
            },
            createdAt: now,
            updatedAt: now
        )
    }

    @Test("A notebook's cards are the Mac's: one anchor in the notebook, or filed under it or one of its Goals")
    func notebookCards() {
        let members: Set<String> = ["a", "b"]
        let goalParents = ["goal-1": "p"]
        let items = [
            item("1", sources: ["a"]),
            item("2", sources: ["a", "b"]),
            item("3", sources: ["a", "z"]),
            item("4", sources: []),
            item("5", goalID: "p", sources: ["z"]),
            item("6", sources: ["z"]),
            item("7", goalID: "goal-1", sources: ["z"]),
            item("8", goalID: "other", sources: ["z"]),
        ]
        let scope = MemoryCardScope(notebookID: "p", memberSourceIDs: Array(members), goalParents: goalParents)
        for memoryItem in items {
            #expect(
                MobileNotebookCards.belongs(memoryItem, notebookID: "p", memberSourceIDs: members, goalParents: goalParents)
                    == scope.contains(memoryItem),
                "item \(memoryItem.id)"
            )
        }
        #expect(MobileNotebookCards.belongs(items[2], notebookID: "p", memberSourceIDs: members), "one anchor in the notebook is enough")
        #expect(!MobileNotebookCards.belongs(items[5], notebookID: "p", memberSourceIDs: members))
        #expect(MobileNotebookCards.belongs(items[6], notebookID: "p", memberSourceIDs: members, goalParents: goalParents), "a Goal's notebook")
    }

    @Test("What belongs to a notebook follows homing's two rules, as the Mac asks them")
    func membershipMatchesTheMac() {
        let goalParents = ["g1": "p"]
        for ids in [[nil], ["p"], ["q", "p"], ["g1"], ["g2"], [nil, "q"], [""]] as [[String?]] {
            #expect(
                MobileNotebookMembership.isFiled(in: "p", notebookIDs: ids, goalParents: goalParents)
                    == NotebookMembership.isFiled(in: "p", notebookIDs: NotebookMembership.filingNotebookIDs(ids, goalParents: goalParents)),
                "filed under \(ids)"
            )
        }
        let members: Set<String> = ["s1", "s2"]
        for sourceID in ["s1", "s3"] {
            #expect(
                MobileNotebookMembership.isDerived(sourceID: sourceID, memberSourceIDs: members)
                    == NotebookMembership.isDerived(sourceID: sourceID, from: members)
            )
        }
    }

    @Test("Home's library search keeps the words' matches first and adds meaning's after, once each")
    func homeSearch() {
        let a = source("a"), b = source("b"), c = source("c")
        #expect(MobileHomeSearch.merged(lexical: [a, b], semantic: [b, c]).map(\.id) == ["a", "b", "c"])
        #expect(MobileHomeSearch.merged(lexical: [a, b, c], semantic: [], limit: 2).map(\.id) == ["a", "b"])
        #expect(MobileHomeSearch.needsSemantic(lexicalCount: 4))
        #expect(!MobileHomeSearch.needsSemantic(lexicalCount: 5))
        let notebooks = [
            MobileCloudNotebook(id: "1", title: "Mitochondria", instructions: "Focus on Complex I", summary: "Energy", sourceIDs: [], isArchived: false, updatedAt: .distantPast),
            MobileCloudNotebook(id: "2", title: "Aging", instructions: nil, sourceIDs: [], isArchived: false, updatedAt: .distantPast),
        ]
        #expect(MobileHomeSearch.notebooks(notebooks, matching: "complex mito").map(\.id) == ["1"])
        #expect(MobileHomeSearch.notebooks(notebooks, matching: "ENERGY").map(\.id) == ["1"])
        #expect(MobileHomeSearch.notebooks(notebooks, matching: "").map(\.id) == ["1", "2"])
    }

    @Test("A notebook's Sources search lists its own matches, then the library's it does not list, each once")
    func notebookSourcesSearch() {
        let own = source("own", title: "Complex I assembly")
        let lent = source("lent", title: "Complex I and aging")
        let elsewhere = source("lib", title: "Complex I inhibitors")
        let unrelated = source("sleep", title: "Why we sleep")
        let shelved = MobileCloudSource(
            id: "shelf", title: "Complex I behind a paywall", subtitle: nil, sourceType: "paper",
            dateAdded: Date(timeIntervalSinceReferenceDate: 0), hasAudio: false, isArchived: false,
            isPaywalled: true
        )
        let library = [own, lent, elsewhere, unrelated, shelved]
        // The notebook holds `own`; a related notebook lends its chat `lent`.
        let rows = [own, lent]
        let candidates = MobileNotebookSourceSearch.libraryCandidates(library, notListedIn: rows, held: ["own"])
        #expect(candidates.map(\.id) == ["lib", "sleep"], "neither the notebook's rows nor the paywall shelf")

        let found = MobileNotebookSourceSearch.sections(notebook: rows, candidates: candidates, query: "complex", meaning: .init())
        #expect(found.inNotebook.map(\.id) == ["own", "lent"])
        #expect(found.inLibrary.map(\.id) == ["lib"])

        // Meaning's ranking for this very query follows the words' matches,
        // each source once; one run on an earlier query is not used.
        let ranked = MobileNotebookSourceSearch.Meaning(query: "complex", sources: [unrelated, elsewhere])
        #expect(MobileNotebookSourceSearch.sections(notebook: rows, candidates: candidates, query: "complex", meaning: ranked)
            .inLibrary.map(\.id) == ["lib", "sleep"])
        let stale = MobileNotebookSourceSearch.Meaning(query: "compl", sources: [unrelated])
        #expect(MobileNotebookSourceSearch.sections(notebook: rows, candidates: candidates, query: "complex", meaning: stale)
            .inLibrary.map(\.id) == ["lib"])

        // Added, a source is the notebook's and leaves the library's section,
        // even when a ranking from before the add still names it.
        let grown = [own, lent, elsewhere]
        let fewer = MobileNotebookSourceSearch.libraryCandidates(library, notListedIn: grown, held: ["own", "lib"])
        let after = MobileNotebookSourceSearch.sections(notebook: grown, candidates: fewer, query: "complex", meaning: ranked)
        #expect(after.inNotebook.map(\.id) == ["own", "lent", "lib"])
        #expect(after.inLibrary.map(\.id) == ["sleep"])

        // A source the words never found, found by meaning and added with +,
        // moves up to the notebook's section rather than leaving both.
        let withSleep = [own, lent, unrelated]
        let rest = MobileNotebookSourceSearch.libraryCandidates(library, notListedIn: withSleep, held: ["own", "sleep"])
        let movedUp = MobileNotebookSourceSearch.sections(notebook: withSleep, candidates: rest, query: "complex", meaning: ranked)
        #expect(movedUp.inNotebook.map(\.id) == ["own", "lent", "sleep"])
        #expect(movedUp.inLibrary.map(\.id) == ["lib"])

        // No words, no library rows; and the words reach a chapter by its book.
        #expect(MobileNotebookSourceSearch.sections(notebook: rows, candidates: candidates, query: "  ", meaning: ranked).inLibrary.isEmpty)
        let chapter = MobileCloudSource(
            id: "ch1", title: "Chapter 3", subtitle: nil, sourceType: "book",
            dateAdded: Date(timeIntervalSinceReferenceDate: 0), hasAudio: false, isArchived: false,
            parentGroup: "book-1"
        )
        let bookTitle: (MobileCloudSource) -> String? = { $0.parentGroup == "book-1" ? "Power, Sex, Suicide" : nil }
        #expect(MobileNotebookSourceSearch.libraryMatches(in: [chapter], query: "suicide", meaning: .init(), groupTitle: bookTitle)
            .map(\.id) == ["ch1"])

        // The Add sources sheet offers what the notebook does not hold itself.
        #expect(MobileNotebookSourceSearch.libraryCandidates(library, excluding: ["own"]).map(\.id) == ["lent", "lib", "sleep"])

        // Meaning ranks only when the words find fewer than five.
        #expect(MobileNotebookSourceSearch.needsMeaning(in: candidates, query: "complex"))
        #expect(!MobileNotebookSourceSearch.needsMeaning(in: candidates, query: " "))
        let many = (0..<5).map { source("m\($0)", title: "Complex \($0)") }
        #expect(!MobileNotebookSourceSearch.needsMeaning(in: many, query: "complex"))
    }
}
