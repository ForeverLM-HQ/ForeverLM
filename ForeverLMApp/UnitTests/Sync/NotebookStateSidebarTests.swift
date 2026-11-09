import Foundation
import Testing
@testable import ForeverLM

/// The rail's order, pins and folds as the member's NotebookStates under generation 2
/// (docs/cloudkit-schema-design.md §3.5.20, §10, WP12b): an order gives sidebar keys moving the fewest, a
/// pin or a fold flips only what changed, and the state reads back as the three lists generation 1 kept.
@Suite("NotebookState sidebar")
struct NotebookStateSidebarTests {
    typealias F = NotebookSyncFixture

    @Test("An order keys its notebooks, and a drag of one notebook sends one NotebookState")
    func orderMovesFewestKeys() throws {
        let (root, store) = try F.makeStore("sidebar-order")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        for id in ["nb-a", "nb-b", "nb-c", "nb-d"] { try F.addNotebook(store, id) }
        try store.setNotebookSidebarOrder(["nb-a", "nb-b", "nb-c", "nb-d"])
        #expect(try store.notebookSidebarState().order == ["nb-a", "nb-b", "nb-c", "nb-d"])
        try F.sendAll(store)

        try store.setNotebookSidebarOrder(["nb-a", "nb-c", "nb-d", "nb-b"])
        #expect(try store.notebookSidebarState().order == ["nb-a", "nb-c", "nb-d", "nb-b"])
        let moved = try F.pending(store).keys.filter { $0.hasPrefix("NotebookState:") }
        #expect(moved == ["NotebookState:ns:nb-b"], "only the dragged notebook takes a new key")

        try F.sendAll(store)
        try store.setNotebookSidebarOrder(["nb-a", "nb-c", "nb-d", "nb-b"])
        #expect(try F.pending(store).isEmpty, "the same order writes nothing")
    }

    @Test("Pins and folds flip only the notebooks whose flag changed, and read back as generation 1's lists")
    func pinsAndFolds() throws {
        let (root, store) = try F.makeStore("sidebar-pins")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        for id in ["nb-a", "nb-b", "nb-c"] { try F.addNotebook(store, id) }
        try store.setNotebookSidebarOrder(["nb-c", "nb-a", "nb-b"])
        try store.setNotebookPinned(["nb-a", "nb-c"])
        try store.setNotebookExpanded(["nb-b"])
        let state = try store.notebookSidebarState()
        #expect(state.pinned == ["nb-c", "nb-a"], "in the rail's order")
        #expect(state.expanded == ["nb-b"])
        try F.sendAll(store)

        try store.setNotebookPinned(["nb-c"])
        let pending = try F.pending(store)
        #expect(Set(pending.keys) == ["NotebookState:ns:nb-a"])
        #expect(F.savedFields(pending["NotebookState:ns:nb-a"])?["pinned"] == .bool(false))
    }
}
