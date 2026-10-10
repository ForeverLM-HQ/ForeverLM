import Foundation
import Testing
@testable import ForeverLM

/// `resolveNotebook()` (§5.2, bug b34): a merge or an emptying split leaves `mergedInto`, a move
/// into a space leaves `movedTo`, and whatever still names the old notebook lands in the survivor,
/// the heir or the space.
@Suite("Notebook resolution")
struct NotebookResolutionTests {
    static func resolver(_ zones: [SyncZoneName: [String: NotebookRedirects]]) -> (SyncRecordLocation) -> NotebookRedirects? {
        { location in zones[location.zone]?[location.id] }
    }

    @Test("The resolve vectors hold")
    func vectors() {
        SyncVectorRunner.expectCases("resolve")
    }

    @Test("mergedInto leads to the survivor, movedTo to the same id in the space, both in one walk")
    func mergedIntoAndMovedTo() {
        let redirects = Self.resolver([
            .library: ["a": NotebookRedirects(mergedInto: "b"), "b": NotebookRedirects(movedTo: "s1")],
            .space("s1"): ["b": NotebookRedirects()],
        ])
        let resolved = NotebookResolution.resolve(SyncRecordLocation(zone: .library, id: "a"), redirects: redirects)
        #expect(resolved == SyncRecordLocation(zone: .space("s1"), id: "b"))
    }

    @Test("mergedInto is followed before movedTo when a stub carries both")
    func mergeFirst() {
        let redirects = Self.resolver([
            .library: ["a": NotebookRedirects(mergedInto: "b", movedTo: "s1"), "b": NotebookRedirects()],
            .space("s1"): ["a": NotebookRedirects()],
        ])
        #expect(NotebookResolution.resolve(SyncRecordLocation(zone: .library, id: "a"), redirects: redirects) == SyncRecordLocation(zone: .library, id: "b"))
    }

    @Test("A notebook still moving is not followed, and a redirect to nowhere stops at the last notebook held")
    func stops() {
        let redirects = Self.resolver([
            .library: ["moving": NotebookRedirects(movingTo: "s1"), "dangling": NotebookRedirects(mergedInto: "gone"), "empty": NotebookRedirects(mergedInto: "")],
            .space("s1"): ["moving": NotebookRedirects()],
        ])
        for id in ["moving", "dangling", "empty", "unknown"] {
            #expect(NotebookResolution.resolve(SyncRecordLocation(zone: .library, id: id), redirects: redirects) == SyncRecordLocation(zone: .library, id: id))
        }
    }

    @Test("A cycle and a chain longer than 8 hops both end")
    func bounded() {
        var chain: [String: NotebookRedirects] = [:]
        for index in 0..<20 { chain["n\(index)"] = NotebookRedirects(mergedInto: "n\(index + 1)") }
        chain["n20"] = NotebookRedirects()
        let redirects = Self.resolver([.library: chain])
        #expect(NotebookResolution.resolve(SyncRecordLocation(zone: .library, id: "n0"), redirects: redirects).id == "n8")
        let loop = Self.resolver([.library: ["a": NotebookRedirects(mergedInto: "b"), "b": NotebookRedirects(mergedInto: "a")]])
        #expect(NotebookResolution.resolve(SyncRecordLocation(zone: .library, id: "a"), redirects: loop).id == "b")
    }
}
