import Foundation

/// Order keys for `Entry.orderKey`, `Lesson.orderKey` and every other fractional position:
/// rocicorp/fractional-indexing's base-62 keys (an integer part whose head letter gives its length,
/// then a fraction with no trailing zero), so the website and the gateway, which use the JS port,
/// mint the same keys. Keys sort as plain byte strings, never by a locale collation; SQL compares
/// them with BINARY. A reorder writes one key between its neighbours. Vectors:
/// `schema/vectors/fractional-index.json`.
enum FractionalIndex {
    struct InvalidKey: Error, Equatable {
        let reason: String
    }

    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    private static let zero = UInt8(ascii: "0")
    private static let smallestInteger = [UInt8(ascii: "A")] + [UInt8](repeating: UInt8(ascii: "0"), count: 26)

    /// A key between `a` and `b` (nil is an open end); `a < b` when both are given.
    static func key(between a: String?, and b: String?) throws -> String {
        let a = a.map { Array($0.utf8) }
        let b = b.map { Array($0.utf8) }
        if let a { try validate(a) }
        if let b { try validate(b) }
        if let a, let b, !a.lexicographicallyPrecedes(b) {
            throw InvalidKey(reason: "\(text(a)) is not before \(text(b))")
        }
        return text(try between(a, b))
    }

    /// `count` keys in order between `a` and `b`: consecutive integers at an open end, short keys
    /// between two keys.
    static func keys(between a: String?, and b: String?, count: Int) throws -> [String] {
        if count <= 0 { return [] }
        if count == 1 { return [try key(between: a, and: b)] }
        if b == nil {
            var key = try key(between: a, and: nil)
            var result = [key]
            for _ in 1..<count {
                key = try self.key(between: key, and: nil)
                result.append(key)
            }
            return result
        }
        if a == nil {
            var key = try key(between: nil, and: b)
            var result = [key]
            for _ in 1..<count {
                key = try self.key(between: nil, and: key)
                result.append(key)
            }
            return result.reversed()
        }
        let middleIndex = count / 2
        let middle = try key(between: a, and: b)
        return try keys(between: a, and: middle, count: middleIndex) + [middle]
            + keys(between: middle, and: b, count: count - middleIndex - 1)
    }

    static func isValid(_ key: String) -> Bool {
        (try? validate(Array(key.utf8))) != nil
    }

    // MARK: - The algorithm

    private static func between(_ a: [UInt8]?, _ b: [UInt8]?) throws -> [UInt8] {
        guard let a else {
            guard let b else { return [UInt8(ascii: "a"), zero] }
            let integerB = try integerPart(b)
            let fractionB = Array(b[integerB.count...])
            if integerB == smallestInteger { return integerB + midpoint([], fractionB) }
            if integerB.count < b.count { return integerB }
            guard let decremented = decrement(integerB) else { throw InvalidKey(reason: "cannot decrement any more") }
            return decremented
        }
        guard let b else {
            let integerA = try integerPart(a)
            let fractionA = Array(a[integerA.count...])
            if let incremented = increment(integerA) { return incremented }
            return integerA + midpoint(fractionA, nil)
        }
        let integerA = try integerPart(a)
        let fractionA = Array(a[integerA.count...])
        let integerB = try integerPart(b)
        let fractionB = Array(b[integerB.count...])
        if integerA == integerB { return integerA + midpoint(fractionA, fractionB) }
        guard let incremented = increment(integerA) else { throw InvalidKey(reason: "cannot increment any more") }
        if incremented.lexicographicallyPrecedes(b) { return incremented }
        return integerA + midpoint(fractionA, nil)
    }

    /// A fraction between `a` and `b` (nil is the end); neither has a trailing zero.
    private static func midpoint(_ a: [UInt8], _ b: [UInt8]?) -> [UInt8] {
        if let b {
            // Drop the common prefix, reading a missing digit of `a` as zero.
            var shared = 0
            while shared < b.count, (shared < a.count ? a[shared] : zero) == b[shared] { shared += 1 }
            if shared > 0 {
                return Array(b[..<shared]) + midpoint(shared < a.count ? Array(a[shared...]) : [], Array(b[shared...]))
            }
        }
        let digitA = a.first.map(digitValue) ?? 0
        let digitB = b.flatMap { $0.first }.map(digitValue) ?? digits.count
        if digitB - digitA > 1 {
            return [digits[(digitA + digitB + 1) / 2]]
        }
        if let b, b.count > 1 { return [b[0]] }
        return [digits[digitA]] + midpoint(a.isEmpty ? [] : Array(a.dropFirst()), nil)
    }

    private static func integerLength(_ head: UInt8) throws -> Int {
        if (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(head) { return Int(head - UInt8(ascii: "a")) + 2 }
        if (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(head) { return Int(UInt8(ascii: "Z") - head) + 2 }
        throw InvalidKey(reason: "invalid order key head")
    }

    private static func integerPart(_ key: [UInt8]) throws -> [UInt8] {
        guard let head = key.first else { throw InvalidKey(reason: "empty order key") }
        let length = try integerLength(head)
        guard length <= key.count else { throw InvalidKey(reason: "order key shorter than its integer part") }
        return Array(key[..<length])
    }

    private static func validate(_ key: [UInt8]) throws {
        guard key.dropFirst().allSatisfy(digits.contains) else { throw InvalidKey(reason: "order key holds a character outside base 62") }
        if key == smallestInteger { throw InvalidKey(reason: "the smallest integer is not a key") }
        let integer = try integerPart(key)
        if key.count > integer.count, key.last == zero { throw InvalidKey(reason: "order key ends in a zero") }
    }

    private static func increment(_ integer: [UInt8]) -> [UInt8]? {
        let head = integer[0]
        var tail = Array(integer.dropFirst())
        var carry = true
        var index = tail.count - 1
        while carry, index >= 0 {
            let next = digitValue(tail[index]) + 1
            if next == digits.count {
                tail[index] = zero
            } else {
                tail[index] = digits[next]
                carry = false
            }
            index -= 1
        }
        guard carry else { return [head] + tail }
        if head == UInt8(ascii: "Z") { return [UInt8(ascii: "a"), zero] }
        if head == UInt8(ascii: "z") { return nil }
        let newHead = head + 1
        if newHead > UInt8(ascii: "a") {
            tail.append(zero)
        } else {
            tail.removeLast()
        }
        return [newHead] + tail
    }

    private static func decrement(_ integer: [UInt8]) -> [UInt8]? {
        let head = integer[0]
        var tail = Array(integer.dropFirst())
        var borrow = true
        var index = tail.count - 1
        while borrow, index >= 0 {
            let next = digitValue(tail[index]) - 1
            if next == -1 {
                tail[index] = digits[digits.count - 1]
            } else {
                tail[index] = digits[next]
                borrow = false
            }
            index -= 1
        }
        guard borrow else { return [head] + tail }
        if head == UInt8(ascii: "a") { return [UInt8(ascii: "Z"), digits[digits.count - 1]] }
        if head == UInt8(ascii: "A") { return nil }
        let newHead = head - 1
        if newHead < UInt8(ascii: "Z") {
            tail.append(digits[digits.count - 1])
        } else {
            tail.removeLast()
        }
        return [newHead] + tail
    }

    private static func digitValue(_ byte: UInt8) -> Int {
        digits.firstIndex(of: byte) ?? 0
    }

    private static func text(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}
