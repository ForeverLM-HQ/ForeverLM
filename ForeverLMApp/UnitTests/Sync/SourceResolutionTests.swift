import Foundation
import Testing
@testable import ForeverLM

/// `resolveSource()` (§4.2): a duplicate's loser stays as a redirect for ever, so highlights, cards
/// and history that name it show on the winner.
@Suite("Source resolution")
struct SourceResolutionTests {
    static func resolve(_ start: String, _ sources: [String: String?]) -> String {
        SourceResolution.resolve(start) { id in sources[id] }
    }

    @Test("The resolve vectors hold")
    func vectors() {
        SyncVectorRunner.expectCases("resolve")
    }

    @Test("A loser resolves to its winner, through a winner that lost again")
    func chains() {
        #expect(Self.resolve("src_b", ["src_b": "src_a", "src_a": nil]) == "src_a")
        #expect(Self.resolve("src_c", ["src_c": "src_b", "src_b": "src_a", "src_a": nil]) == "src_a")
    }

    @Test("An unknown source, a missing winner and a cycle stop where they are")
    func stops() {
        #expect(Self.resolve("src_z", [:]) == "src_z")
        #expect(Self.resolve("src_b", ["src_b": "src_x"]) == "src_b")
        #expect(Self.resolve("src_a", ["src_a": "src_b", "src_b": "src_a"]) == "src_b")
        #expect(Self.resolve("src_a", ["src_a": ""]) == "src_a")
    }

    @Test("At most 8 hops are followed")
    func bounded() {
        var sources: [String: String?] = [:]
        for index in 0..<12 { sources["s\(index)"] = "s\(index + 1)" }
        sources["s12"] = .some(nil)
        #expect(Self.resolve("s0", sources) == "s8")
    }
}
