import Foundation
import Testing
@testable import ForeverLM

/// The notebook chat checkboxes (`NotebookChatSelection`): the unticked
/// sources and the context notebooks put into a notebook's chats, kept in the
/// member's NotebookState. Every test that writes binds its own state
/// (`NotebookStateStore.$override`), never the store the Dev build and
/// parallel suites share. The tick rule itself is `ChatTickRuleTests`.
@Suite("Notebook chat selection")
struct NotebookChatSelectionTests {

    private func withCleanState(_ body: (NotebookStateStore.Box) throws -> Void) rethrows {
        let box = NotebookStateStore.Box()
        try NotebookStateStore.$override.withValue(box) {
            try body(box)
        }
    }

    @Test("A chat reads the pool in its own order, minus the unticked")
    func chatSourceIDsKeepPoolOrder() {
        let pool = ["c", "a", "d", "b"]
        #expect(NotebookChatSelection.chatSourceIDs(pool: pool, excluded: []) == pool)
        #expect(NotebookChatSelection.chatSourceIDs(pool: pool, excluded: ["a", "b"]) == ["c", "d"])
        #expect(NotebookChatSelection.chatSourceIDs(pool: pool, excluded: Set(pool)).isEmpty)
        #expect(NotebookChatSelection.chatSourceIDs(pool: pool, excluded: ["not-in-pool"]) == pool)
    }

    @Test("Ticking and unticking keep the exclusion sorted and inside the pool")
    func updatedTicksUnticksAndPrunes() {
        let pool = ["a", "b", "c", "d"]
        #expect(NotebookChatSelection.updated([], setting: ["c", "a"], inChat: false, pool: pool) == ["a", "c"])
        #expect(NotebookChatSelection.updated(["a", "c"], setting: ["c"], inChat: true, pool: pool) == ["a"])
        #expect(
            NotebookChatSelection.updated(["a"], setting: ["gone", "d"], inChat: false, pool: pool) == ["a", "d"],
            "an id outside the pool is never stored"
        )
        #expect(
            NotebookChatSelection.updated(["a", "removed-since"], setting: [], inChat: true, pool: pool) == ["a"],
            "a source that left the pool drops its box, so it comes back ticked"
        )
        #expect(NotebookChatSelection.updated(Set(pool), setting: pool, inChat: true, pool: pool).isEmpty)
    }

    @Test("Writing an empty exclusion leaves the notebook with none")
    func writeEmptyLeavesNoExclusion() {
        withCleanState { box in
            #expect(NotebookChatSelection.preferenceKey(notebookID: "p1") == "notebook.chatExcluded.p1")

            NotebookChatSelection.write(["a", "b"], notebookID: "p1")
            #expect(box.snapshot.excluded["p1"] == ["a", "b"])
            #expect(NotebookChatSelection.excluded(notebookID: "p1") == ["a", "b"])

            NotebookChatSelection.write([], notebookID: "p1")
            #expect(NotebookChatSelection.excluded(notebookID: "p1").isEmpty)

            NotebookChatSelection.write(["a"], notebookID: "p1")
            NotebookChatSelection.writeContextNotebooks(["r1"], notebookID: "p1")
            NotebookChatSelection.forget(notebookID: "p1")
            #expect(NotebookChatSelection.excluded(notebookID: "p1").isEmpty)
            #expect(NotebookChatSelection.contextNotebookIDs(notebookID: "p1").isEmpty, "a deleted notebook's ticks and context notebooks both go")
        }
    }

    @Test("The context notebooks put in are kept apart from the unticked sources, and none is none")
    func contextNotebooksAreTheirOwn() {
        withCleanState { box in
            #expect(NotebookChatContext.preferenceKey(notebookID: "p1") == "notebook.chatContextNotebooks.p1")
            #expect(NotebookChatSelection.contextNotebookIDs(notebookID: "p1").isEmpty, "nothing put in: no context notebook is read")

            NotebookChatSelection.writeContextNotebooks(["r1", "r2"], notebookID: "p1")
            #expect(box.snapshot.contextNotebooks["p1"] == ["r1", "r2"])
            #expect(NotebookChatSelection.selection(notebookID: "p1") == NotebookChatContext.Selection(contextNotebookIDs: ["r1", "r2"]))
            NotebookChatSelection.write(["x"], notebookID: "p2")
            #expect(NotebookChatSelection.contextNotebooksFromDefaults().filter { !$0.value.isEmpty } == ["p1": ["r1", "r2"]],
                    "the unticked sources are not read as context notebooks")

            NotebookChatSelection.writeContextNotebooks([], notebookID: "p1")
            #expect(NotebookChatSelection.contextNotebookIDs(notebookID: "p1").isEmpty)
        }
    }

    @Test("A notebook's context notebooks are one per link, in link order, never itself, and none of a link's own links")
    func contextNotebooksAreOneLevelDeep() {
        // A links B and C (and, by a bad record, itself); B links D. A's
        // chats never reach D, whatever A's row names.
        let a = notebook("A", sources: ["a1"], related: ["B", "A", "C", "unknown"])
        let b = notebook("B", sources: ["b1", "a1"], related: ["D"])
        let c = notebook("C", sources: ["c1"])
        let d = notebook("D", sources: ["d1"])
        let records = ["B": b, "C": c, "D": d]
        let linked = NotebookChatSelection.contextNotebooks(of: a) { records[$0]?.approvedSourceIDs }
        #expect(linked == [
            .init(id: "B", sourceIDs: ["b1", "a1"]),
            .init(id: "C", sourceIDs: ["c1"]),
            .init(id: "unknown", sourceIDs: []),
        ])
        let everything = NotebookChatContext.Selection(contextNotebookIDs: ["B", "C", "D", "unknown"])
        #expect(NotebookChatContext.chatPool(own: a.approvedSourceIDs, linked: linked, selection: everything) == ["a1", "b1", "c1"])
        #expect(NotebookChatContext.stored(everything, own: a.approvedSourceIDs, linked: linked).contextNotebookIDs == ["B", "C", "D", "unknown"],
                "a write keeps every id the row names: D, not linked here, is passed over by the readers")
    }

    @Test("Every notebook's unticked sources are read at once")
    func exclusionsReadEveryNotebook() {
        withCleanState { _ in
            NotebookChatSelection.write(["a"], notebookID: "p1")
            NotebookChatSelection.write(["b", "c"], notebookID: "p2")
            NotebookChatSelection.write([], notebookID: "p3")

            #expect(NotebookChatSelection.exclusionsFromDefaults().filter { !$0.value.isEmpty } == ["p1": ["a"], "p2": ["b", "c"]])
        }
    }

    private func notebook(_ id: String, sources: [String], related: [String]? = nil) -> LearningGoalRecord {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        return LearningGoalRecord(
            id: id,
            title: id,
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now,
            updatedAt: now,
            status: "active",
            items: sources.map { LearningGoalItem(id: "item-\(id)-\($0)", goalID: id, sourceID: $0, addedAt: now) },
            kind: LearningGoalRecord.companionKind,
            relatedNotebookIDs: related
        )
    }

    // MARK: - Arrivals from another device

    private func item(_ notebookID: String, _ sourceID: String, addedAt: Date, state: LearningGoalItemReviewState? = nil) -> LearningGoalItem {
        LearningGoalItem(
            id: "item-\(notebookID)-\(sourceID)",
            goalID: notebookID,
            sourceID: sourceID,
            addedAt: addedAt,
            reviewState: state?.rawValue
        )
    }

    private func notebook(_ id: String, items: [LearningGoalItem], updatedAt: Date, related: [String]? = nil) -> LearningGoalRecord {
        var record = notebook(id, sources: [], related: related)
        record.items = items
        record.updatedAt = updatedAt
        return record
    }

    @Test("An inbound change brings the sources a notebook did not hold, each with the earliest it can have joined")
    func inboundArrivalsNameNewMembersAndWhenTheyJoined() {
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let removed = t0.addingTimeInterval(30)
        let t1 = t0.addingTimeInterval(60)
        let t2 = t0.addingTimeInterval(120)
        // This Mac held a; b had been removed (rejected) and c only suggested,
        // in the version it last saw, written when b was removed.
        let before = notebook("N", items: [
            item("N", "a", addedAt: t0),
            item("N", "b", addedAt: t0, state: .rejected),
            item("N", "c", addedAt: t0, state: .pending),
        ], updatedAt: removed)
        // The phone added b back, approved c and added d, a new item.
        let after = notebook("N", items: [
            item("N", "a", addedAt: t0),
            item("N", "b", addedAt: t0, state: .approved),
            item("N", "c", addedAt: t0, state: .approved),
            item("N", "d", addedAt: t1),
        ], updatedAt: t2)
        let renamedOnly = notebook("R", items: [item("R", "x", addedAt: t0)], updatedAt: t0)
        var renamed = renamedOnly
        renamed.title = "Renamed"
        renamed.updatedAt = t2
        let newHere = notebook("New", items: [item("New", "y", addedAt: t1)], updatedAt: t1)

        let arrivals = NotebookChatSelection.inboundArrivals(before: [before, renamedOnly], after: [after, renamed, newHere])

        #expect(arrivals == ["N": [
            .init(sourceID: "b", joinedAt: removed),
            .init(sourceID: "c", joinedAt: removed),
            .init(sourceID: "d", joinedAt: t1),
        ]], "an item that was there was approved after the version this Mac held, never later than t2 but no earlier than that version; a new item joined when added; a rename brings nothing; a notebook new to this Mac is not compared")
    }
}

/// Which context notebooks a notebook's chats read, and how a box changes
/// the two rows (`NotebookChatContext`), on the vectors the web's twin in
/// library-notebooks.js runs too (docs-site/website/test/notebook-chat-context-vectors.json).
/// The iPhone compiles the same file.
@Suite("Notebook chat context")
struct NotebookChatContextTests {
    private struct Vectors: Decodable {
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

    private static func vectors() throws -> Vectors {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UnitTests
            .deletingLastPathComponent()   // ForeverLMApp
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repo.appendingPathComponent("docs-site/website/test/notebook-chat-context-vectors.json"))
        return try JSONDecoder().decode(Vectors.self, from: data)
    }

    @Test("Every shared vector reads and writes the rows as the web's twin does")
    func sharedVectors() throws {
        let vectors = try Self.vectors()
        #expect(vectors.cases.count >= 16)
        for vector in vectors.cases {
            let linked = vector.linked.map { NotebookChatContext.ContextNotebook(id: $0.id, sourceIDs: $0.sources) }
            var selection = NotebookChatContext.Selection(excluded: Set(vector.excluded), contextNotebookIDs: Set(vector.context))
            if let action = vector.action {
                switch action.kind {
                case "sources":
                    selection = NotebookChatContext.settingSources(
                        action.ids ?? [], inChat: action.inChat ?? true, through: action.through,
                        own: vector.own, linked: linked, selection: selection
                    )
                case "contextNotebooks":
                    selection = NotebookChatContext.settingContextNotebooks(
                        action.ids ?? [], inChat: action.inChat ?? true, linked: linked, selection: selection
                    )
                case "only":
                    selection = NotebookChatContext.keepingOnly(
                        sourceIDs: action.sourceIDs ?? [], contextNotebookIDs: action.contextNotebookIDs ?? [],
                        own: vector.own, linked: linked, selection: selection
                    )
                case "all", "none":
                    let pool = NotebookChatContext.chatPool(own: vector.own, linked: linked, selection: selection)
                    selection = NotebookChatContext.settingSources(
                        pool, inChat: action.kind == "all", own: vector.own, linked: linked, selection: selection
                    )
                default:
                    Issue.record("\(vector.name): unknown action \(action.kind)")
                }
            }
            let stored = NotebookChatContext.stored(selection, own: vector.own, linked: linked)
            #expect(stored.excluded == vector.expect.excluded, "\(vector.name)")
            #expect(stored.contextNotebookIDs == vector.expect.context, "\(vector.name)")
            let rows = NotebookChatContext.Selection(excluded: Set(stored.excluded), contextNotebookIDs: Set(stored.contextNotebookIDs))
            let chat = NotebookChatContext.chatSourceIDs(own: vector.own, linked: linked, selection: rows)
            #expect(NotebookChatContext.chatPool(own: vector.own, linked: linked, selection: rows) == vector.expect.chatPool, "\(vector.name)")
            #expect(chat == vector.expect.chatSourceIDs, "\(vector.name)")
            #expect(NotebookChatContext.linkedPool(own: vector.own, linked: linked) == vector.expect.linkedPool, "\(vector.name)")
            for id in vector.expect.linkedPool {
                #expect(NotebookChatContext.isInChat(id, own: vector.own, linked: linked, selection: rows) == chat.contains(id), "\(vector.name): \(id)")
            }
            for (notebookID, tally) in vector.expect.tallies {
                let read = NotebookChatContext.tally(of: notebookID, linked: linked, selection: rows).map { [$0.ticked, $0.total] }
                #expect(read == tally, "\(vector.name): \(notebookID)")
            }
        }
    }

    @Test("A context notebook's box counts only the sources a caller shows")
    func tallyCountsShownSources() {
        let linked = [NotebookChatContext.ContextNotebook(id: "r1", sourceIDs: ["a", "b", "hidden"])]
        let selection = NotebookChatContext.Selection(excluded: ["b"], contextNotebookIDs: ["r1"])
        let tally = NotebookChatContext.tally(of: "r1", linked: linked, selection: selection) { $0 != "hidden" }
        #expect(tally?.ticked == 1)
        #expect(tally?.total == 2)
    }

    @Test("Add a Notebook to Context puts one in as it was left, never ticking a source, even one the row already named")
    func puttingInNeverTicks() {
        let linked = [NotebookChatContext.ContextNotebook(id: "r1", sourceIDs: ["a", "b"])]
        let unticked = NotebookChatContext.Selection(excluded: ["b"])
        #expect(NotebookChatContext.puttingIn(["r1"], linked: linked, selection: unticked)
            == NotebookChatContext.Selection(excluded: ["b"], contextNotebookIDs: ["r1"]))
        // An older build's unlink left r1 in the row; linked again and added,
        // its box's tick-everything does not apply.
        let leftOver = NotebookChatContext.Selection(excluded: ["b"], contextNotebookIDs: ["r1"])
        #expect(NotebookChatContext.puttingIn(["r1"], linked: linked, selection: leftOver) == leftOver)
        #expect(NotebookChatContext.puttingIn(["elsewhere"], linked: linked, selection: unticked) == unticked,
                "a notebook not linked is not put in")
    }
}
