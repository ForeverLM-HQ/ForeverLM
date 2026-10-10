import Foundation
import Testing
@testable import ForeverLM

/// Order keys (rocicorp-compatible base 62): a reorder writes one key between its neighbours, and
/// keys sort as plain bytes on every client.
@Suite("Fractional index")
struct FractionalIndexTests {
    @Test("The fractional-index vectors hold")
    func vectors() {
        SyncVectorRunner.expectCases("fractional-index")
    }

    @Test("Repeated inserts at the front, at the back and in one gap stay ordered and valid")
    func repeatedInserts() throws {
        var keys = [try FractionalIndex.key(between: nil, and: nil)]
        for _ in 0..<300 { keys.append(try FractionalIndex.key(between: keys.last, and: nil)) }
        for _ in 0..<300 { keys.insert(try FractionalIndex.key(between: nil, and: keys.first), at: 0) }
        var low = keys[300]
        let high = keys[301]
        for _ in 0..<200 {
            let middle = try FractionalIndex.key(between: low, and: high)
            #expect(low.utf8.lexicographicallyPrecedes(middle.utf8) && middle.utf8.lexicographicallyPrecedes(high.utf8))
            low = middle
        }
        for (a, b) in zip(keys, keys.dropFirst()) {
            #expect(a.utf8.lexicographicallyPrecedes(b.utf8))
            #expect(FractionalIndex.isValid(a))
        }
    }

    @Test("n keys between two keys are distinct, sorted and between them")
    func nKeys() throws {
        let keys = try FractionalIndex.keys(between: "a0", and: "a1", count: 50)
        #expect(keys.count == 50)
        #expect(Set(keys).count == 50)
        #expect(keys == keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        #expect("a0".utf8.lexicographicallyPrecedes(keys[0].utf8) && keys[49].utf8.lexicographicallyPrecedes("a1".utf8))
        #expect(try FractionalIndex.keys(between: nil, and: nil, count: 0).isEmpty)
    }

    @Test("Invalid keys are refused: a character outside base 62, a trailing zero, a bad head, a wrong order")
    func refusals() {
        #expect(throws: FractionalIndex.InvalidKey.self) { try FractionalIndex.key(between: "a0-", and: nil) }
        #expect(throws: FractionalIndex.InvalidKey.self) { try FractionalIndex.key(between: "a10", and: nil) }
        #expect(throws: FractionalIndex.InvalidKey.self) { try FractionalIndex.key(between: "!0", and: nil) }
        #expect(throws: FractionalIndex.InvalidKey.self) { try FractionalIndex.key(between: "a2", and: "a1") }
        #expect(!FractionalIndex.isValid(""))
        #expect(FractionalIndex.isValid("a0V"))
    }
}
