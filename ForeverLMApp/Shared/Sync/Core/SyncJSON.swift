import Foundation

/// A JSON value as the sync core holds it: what a payload's fields carry, and what the shared
/// shapes (§3.3) are made of. Numbers are IEEE doubles, as they are in the JS core, so integers
/// below 2^53 (epoch milliseconds) are exact and `1` equals `1.0` everywhere.
///
/// Booleans are their own case, never a number 0 or 1. Text is read by `SyncJSONReader`, the twin
/// of the JS core's `parseJSON`, not by `JSONSerialization` (see there for why).
enum SyncJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([SyncJSON])
    case object([String: SyncJSON])
}

extension SyncJSON {
    struct ParseError: Error, Equatable {}

    /// Parses UTF-8 JSON text; any JSON value may be at the top level. Read as the JS core's
    /// `parseJSON` reads it (`SyncJSONReader`), so a payload means the same on every client.
    init(parsing data: Data) throws {
        self = try SyncJSONReader.parse(data)
    }

    /// Compact JSON text with sorted keys, so equal values serialize to equal bytes.
    func serialized() -> Data {
        var text = ""
        write(to: &text)
        return Data(text.utf8)
    }

    private func write(to text: inout String) {
        switch self {
        case .null:
            text += "null"
        case .bool(let value):
            text += value ? "true" : "false"
        case .number(let value):
            text += Self.numberText(value)
        case .string(let value):
            Self.writeString(value, to: &text)
        case .array(let values):
            text += "["
            for (index, value) in values.enumerated() {
                if index > 0 { text += "," }
                value.write(to: &text)
            }
            text += "]"
        case .object(let values):
            text += "{"
            for (index, key) in values.keys.sorted().enumerated() {
                if index > 0 { text += "," }
                Self.writeString(key, to: &text)
                text += ":"
                values[key]!.write(to: &text)
            }
            text += "}"
        }
    }

    /// Integers below 2^53 print as integers (`1759400000123`, never `1.759400000123e12`); other
    /// numbers print in Swift's shortest round-trip form, which any JSON reader parses back to the
    /// same double. A non-finite number cannot come from JSON and is written as `null`, as
    /// `JSON.stringify` writes it.
    static func numberText(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == value.rounded(.towardZero), abs(value) < 9_007_199_254_740_992 {
            return String(Int64(value))
        }
        return "\(value)"
    }

    private static func writeString(_ value: String, to text: inout String) {
        text += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": text += "\\\""
            case "\\": text += "\\\\"
            case "\n": text += "\\n"
            case "\r": text += "\\r"
            case "\t": text += "\\t"
            case "\u{08}": text += "\\b"
            case "\u{0C}": text += "\\f"
            default:
                if scalar.value < 0x20 {
                    text += String(format: "\\u%04x", scalar.value)
                } else {
                    text.unicodeScalars.append(scalar)
                }
            }
        }
        text += "\""
    }
}

// MARK: - Reading values

extension SyncJSON {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [SyncJSON]? {
        if case .array(let values) = self { return values }
        return nil
    }

    var objectValue: [String: SyncJSON]? {
        if case .object(let values) = self { return values }
        return nil
    }

    var isNull: Bool { self == .null }

    /// A number with no fraction that fits `Int64` (milliseconds, counts, revisions).
    var int64Value: Int64? {
        // `Double(Int64.max)` is 2^63 exactly; every double below it converts.
        guard case .number(let value) = self, value == value.rounded(.towardZero),
              abs(value) < Double(Int64.max)
        else { return nil }
        return Int64(value)
    }

    var intValue: Int? { int64Value.flatMap { Int(exactly: $0) } }

    subscript(key: String) -> SyncJSON? { objectValue?[key] }

    init(_ value: Int64) { self = .number(Double(value)) }
    init(_ value: Int) { self = .number(Double(value)) }
}

extension SyncJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int64) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: SyncJSON...) { self = .array(elements) }

    init(dictionaryLiteral elements: (String, SyncJSON)...) {
        var values: [String: SyncJSON] = [:]
        for (key, value) in elements { values[key] = value }
        self = .object(values)
    }
}

// MARK: - Reading text

/// JSON text into `SyncJSON`, read exactly as the JS core's `parseJSON` (`schema/js/json.js`) reads
/// it, so a payload means the same on the Mac, the iPhone, the web and the hosted MCP
/// (docs/cloudkit-schema-design.md §3.2, §6.5):
/// - only UTF-8 text is read (a UTF-16 or UTF-32 payload, which `JSONSerialization` would take, is
///   refused), and one leading U+FEFF is skipped;
/// - the first of two equal keys wins; a trailing comma before `]` or `}` is read past; an escaped
///   lone surrogate is refused; containers nest at most 512 levels;
/// - every string, key or value, loses one leading U+FEFF, as Foundation's reader drops it;
/// - each number token is read with `Double(_:)`, which rounds correctly (`JSONSerialization` reads
///   some fractions with leading zeros 1 to 6 ulps off, so a Swift client would see a change that is
///   not there and send it again); a number too large for a double is refused, except a negative one,
///   which reads as -infinity as Foundation's does and is written back as `null`.
struct SyncJSONReader {
    static let maximumDepth = 512

    static func parse(_ data: Data) throws -> SyncJSON {
        let text = String(decoding: data, as: UTF8.self)
        // Bytes that are not UTF-8 decode to U+FFFD and no longer encode to themselves.
        guard text.utf8.elementsEqual(data) else { throw SyncJSON.ParseError() }
        var reader = SyncJSONReader(Array(text.utf16))
        return try reader.document()
    }

    private let units: [UInt16]
    private var index = 0

    private init(_ units: [UInt16]) {
        self.units = units
        if units.first == 0xFEFF { index = 1 }
    }

    private func unit(at position: Int) -> UInt16? {
        position < units.count ? units[position] : nil
    }

    private mutating func document() throws -> SyncJSON {
        let value = try value()
        skipSpace()
        guard index == units.count else { throw SyncJSON.ParseError() }
        return value
    }

    private mutating func skipSpace() {
        while let code = unit(at: index), code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D {
            index += 1
        }
    }

    /// A container being read: its elements so far, or its members and the key of the next one.
    private struct Open {
        let isArray: Bool
        var elements: [SyncJSON] = []
        // Assigned one by one, the first of two equal keys kept. Swift's String equality is
        // canonical equivalence, so two spellings of one key (`café` in NFC and in NFD) are one key
        // here, where the JS core keeps both; keys on the wire are ids, field names and enum values,
        // all ASCII.
        var members: [String: SyncJSON] = [:]
        var key: String?

        var close: UInt16 { isArray ? 0x5D : 0x7D }
        var value: SyncJSON { isArray ? .array(elements) : .object(members) }

        mutating func add(_ value: SyncJSON) {
            if isArray {
                elements.append(value)
            } else if let key {
                if members[key] == nil { members[key] = value }
                self.key = nil
            }
        }
    }

    /// One value, its containers read with a stack of their own rather than by recursion, so 512
    /// levels never reach the end of a thread's stack.
    private mutating func value() throws -> SyncJSON {
        var open: [Open] = []
        while true {
            // Inside an object, the next member's key comes first.
            if let top = open.last, !top.isArray {
                skipSpace()
                guard unit(at: index) == 0x22 else { throw SyncJSON.ParseError() }
                let key = try string()
                skipSpace()
                guard unit(at: index) == 0x3A else { throw SyncJSON.ParseError() }
                index += 1
                open[open.count - 1].key = key
            }
            skipSpace()
            guard let code = unit(at: index) else { throw SyncJSON.ParseError() }
            var finished: SyncJSON?
            switch code {
            case 0x7B, 0x5B:
                guard open.count < Self.maximumDepth else { throw SyncJSON.ParseError() }
                let container = Open(isArray: code == 0x5B)
                index += 1
                skipSpace()
                if unit(at: index) == container.close {
                    index += 1
                    finished = container.value
                } else {
                    open.append(container)
                    continue
                }
            case 0x22:
                finished = .string(try string())
            case 0x2D, 0x30...0x39:
                finished = .number(try number())
            default:
                for (literal, value) in [("true", SyncJSON.bool(true)), ("false", .bool(false)), ("null", .null)] where matches(literal) {
                    index += literal.utf16.count
                    finished = value
                    break
                }
                guard finished != nil else { throw SyncJSON.ParseError() }
            }
            // A value is done: it goes into the container it stands in, which may then close too.
            while var value = finished {
                guard !open.isEmpty else { return value }
                open[open.count - 1].add(value)
                skipSpace()
                let close = open[open.count - 1].close
                let next = unit(at: index)
                if next == close {
                    index += 1
                    value = open.removeLast().value
                    finished = value
                    continue
                }
                guard next == 0x2C else { throw SyncJSON.ParseError() }
                index += 1
                skipSpace()
                if unit(at: index) == close {
                    index += 1
                    finished = open.removeLast().value
                    continue
                }
                finished = nil
            }
        }
    }

    private func matches(_ literal: String) -> Bool {
        let expected = Array(literal.utf16)
        guard index + expected.count <= units.count else { return false }
        return Array(units[index..<(index + expected.count)]) == expected
    }

    private mutating func string() throws -> String {
        index += 1
        var result: [UInt16] = []
        while true {
            guard let code = unit(at: index) else { throw SyncJSON.ParseError() }
            if code == 0x22 {
                index += 1
                if result.first == 0xFEFF { result.removeFirst() }
                return String(decoding: result, as: UTF16.self)
            }
            guard code >= 0x20 else { throw SyncJSON.ParseError() }
            guard code == 0x5C else {
                result.append(code)
                index += 1
                continue
            }
            guard let escape = unit(at: index + 1) else { throw SyncJSON.ParseError() }
            index += 2
            switch escape {
            case 0x22, 0x5C, 0x2F: result.append(escape)
            case 0x62: result.append(0x08)
            case 0x66: result.append(0x0C)
            case 0x6E: result.append(0x0A)
            case 0x72: result.append(0x0D)
            case 0x74: result.append(0x09)
            case 0x75:
                guard let high = hexUnit(at: index) else { throw SyncJSON.ParseError() }
                index += 4
                if (0xDC00...0xDFFF).contains(high) { throw SyncJSON.ParseError() }
                if (0xD800...0xDBFF).contains(high) {
                    guard unit(at: index) == 0x5C, unit(at: index + 1) == 0x75, let low = hexUnit(at: index + 2),
                          (0xDC00...0xDFFF).contains(low)
                    else { throw SyncJSON.ParseError() }
                    index += 6
                    result.append(high)
                    result.append(low)
                } else {
                    result.append(high)
                }
            default:
                throw SyncJSON.ParseError()
            }
        }
    }

    private func hexUnit(at position: Int) -> UInt16? {
        guard position + 4 <= units.count else { return nil }
        var value: UInt16 = 0
        for code in units[position..<(position + 4)] {
            let digit: UInt16
            switch code {
            case 0x30...0x39: digit = code - 0x30
            case 0x41...0x46: digit = code - 0x41 + 10
            case 0x61...0x66: digit = code - 0x61 + 10
            default: return nil
            }
            value = value << 4 | digit
        }
        return value
    }

    /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`, read by `Double(_:)`.
    private mutating func number() throws -> Double {
        let start = index
        func digits() -> Int {
            let first = index
            while let code = unit(at: index), (0x30...0x39).contains(code) { index += 1 }
            return index - first
        }
        if unit(at: index) == 0x2D { index += 1 }
        guard let lead = unit(at: index), (0x30...0x39).contains(lead) else { throw SyncJSON.ParseError() }
        if lead == 0x30 {
            index += 1
            // `01` is not a number; the reader stops at the 0 and refuses the rest.
            if let next = unit(at: index), (0x30...0x39).contains(next) { throw SyncJSON.ParseError() }
        } else {
            _ = digits()
        }
        if unit(at: index) == 0x2E {
            let dot = index
            index += 1
            if digits() == 0 { index = dot }
        }
        if let marker = unit(at: index), marker == 0x65 || marker == 0x45 {
            let exponent = index
            index += 1
            if let sign = unit(at: index), sign == 0x2B || sign == 0x2D { index += 1 }
            if digits() == 0 { index = exponent }
        }
        let literal = String(decoding: units[start..<index], as: UTF16.self)
        guard let value = Double(literal), !value.isNaN, value != .infinity else { throw SyncJSON.ParseError() }
        return value
    }
}

extension SyncJSON {
    /// The value a stored column's JSON text holds; nil for no text, or text that does not parse.
    static func stored(_ text: String?) -> SyncJSON? {
        text.flatMap { try? SyncJSON(parsing: Data($0.utf8)) }
    }

    /// The JSON text a column stores for a value; nil for no value or a JSON null.
    static func storedText(_ json: SyncJSON?) -> String? {
        guard let json, !json.isNull else { return nil }
        return String(decoding: json.serialized(), as: UTF8.self)
    }
}
