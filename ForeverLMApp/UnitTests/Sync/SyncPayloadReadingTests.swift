import Compression
import Foundation
import Testing
@testable import ForeverLM

/// How the Swift core reads payload bytes, where it must read exactly as the JS core does
/// (docs/cloudkit-schema-design.md §3.2, §6.5; the WP3 and WP4b blocks of "Corrections made while
/// building"): `SyncJSONReader` is `parseJSON`'s twin, and `SyncGzip` requires the stream's end.
@Suite("Payload reading")
struct SyncPayloadReadingTests {
    private func parse(_ text: String) throws -> SyncJSON {
        try SyncJSON(parsing: Data(text.utf8))
    }

    @Test("Every number token reads as Double(_:) reads it, including the fractions JSONSerialization reads a few ulps off")
    func numbersAreCorrectlyRounded() throws {
        var generator = SystemRandomNumberGenerator()
        var offByJSONSerialization = 0
        for _ in 0..<2_000 {
            let value = Double.random(in: 0.0001..<0.1, using: &generator)
            let text = "\(value)"
            #expect(try parse(text) == .number(value), "\(text)")
            let foundation = (try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) as? NSNumber)?.doubleValue
            if foundation != value { offByJSONSerialization += 1 }
        }
        // Not an expectation about Foundation, which may be fixed: a record of why the reader exists.
        print("JSONSerialization read \(offByJSONSerialization) of 2000 fractions differently")
        #expect(try parse("[-0, 1e2, 1E-2, 9007199254740993, -1e400]") == .array([.number(-0.0), 100, 0.01, .number(9007199254740992), .number(-.infinity)]))
        #expect(try parse("{\"a\":1.5e-7}")["a"] == .number(1.5e-7))
    }

    @Test("A number the grammar refuses, or one too large for a double, is not read")
    func malformedNumbers() {
        for text in ["01", "-", "1.", ".5", "1e", "+1", "1e400", "0x10", "1.2.3", "- 1", "NaN", "Infinity"] {
            #expect(throws: SyncJSON.ParseError.self, "\(text)") { try parse(text) }
        }
    }

    @Test("Only UTF-8 is read: UTF-16 and UTF-32 text, and bytes that are not UTF-8, are refused")
    func onlyUTF8() throws {
        let object = "{\"a\":1}"
        #expect(try parse(object) == ["a": 1])
        for encoding in [String.Encoding.utf16BigEndian, .utf16LittleEndian, .utf16, .utf32] {
            let bytes = try #require(object.data(using: encoding))
            #expect(throws: SyncJSON.ParseError.self, "\(encoding)") { try SyncJSON(parsing: bytes) }
        }
        #expect(throws: SyncJSON.ParseError.self) { try SyncJSON(parsing: Data([0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xFF, 0x22, 0x7D])) }
        // One leading byte-order mark is skipped, as JSON.parse after a non-fatal decode keeps it and parseJSON skips it.
        #expect(try SyncJSON(parsing: Data([0xEF, 0xBB, 0xBF]) + Data(object.utf8)) == ["a": 1])
    }

    @Test("The readers' other rules: first key wins, trailing commas, lone surrogates, 512 levels, a leading U+FEFF in strings")
    func sharedRules() throws {
        #expect(try parse("{\"a\":1,\"a\":2}") == ["a": 1])
        #expect(try parse("[1,2,]") == [1, 2])
        #expect(try parse("{\"a\":1,}") == ["a": 1])
        #expect(throws: SyncJSON.ParseError.self) { try parse("[,]") }
        #expect(throws: SyncJSON.ParseError.self) { try parse("\"\\ud83d\"") }
        #expect(throws: SyncJSON.ParseError.self) { try parse("\"\\ude00\"") }
        #expect(try parse("\"\\ud83d\\ude00\"") == .string("😀"))
        #expect(try parse("\"\\ufeffx\"") == .string("x"))
        #expect(try parse("{\"\u{FEFF}k\":true}") == ["k": true])
        #expect(try parse(String(repeating: "[", count: 512) + String(repeating: "]", count: 512)) != .null)
        #expect(throws: SyncJSON.ParseError.self) {
            try parse(String(repeating: "[", count: 513) + String(repeating: "]", count: 513))
        }
        #expect(throws: SyncJSON.ParseError.self) { try parse("{\"a\":1} x") }
        #expect(throws: SyncJSON.ParseError.self) { try parse("\"tab\there\"") }
        #expect(try parse(" \t\r\n null ") == .null)
    }

    @Test("A payload in UTF-16 is not an envelope")
    func utf16PayloadIsRefused() throws {
        let envelope = SyncEnvelope(type: "Notebook", id: "nb-1", saltID: "3fa9c2d1")
        let text = String(decoding: envelope.json.serialized(), as: UTF8.self)
        #expect(try SyncEnvelope(storedPayload: Data(text.utf8)).id == "nb-1")
        let utf16 = try #require(text.data(using: .utf16LittleEndian))
        #expect(throws: SyncEnvelopeError.notAnEnvelope) { try SyncEnvelope(storedPayload: utf16) }
    }

    @Test("Gzip whose DEFLATE stream stops before its final block is refused, even when its trailer matches what was decoded")
    func gzipNeedsTheStreamsEnd() throws {
        let text = Data((0..<4_000).map { "line \($0) of a long payload\n" }.joined().utf8)
        let whole = try SyncGzip.compress(text)
        #expect(try SyncGzip.decompress(whole, maxBytes: 1 << 20) == text)
        let deflate = Array(whole[10..<(whole.count - 8)])
        var refusedCuts = 0
        for cut in stride(from: deflate.count / 4, to: deflate.count, by: max(1, deflate.count / 40)) {
            let truncated = Array(deflate[0..<cut])
            // What a bounded one-shot decode hands back for the cut stream.
            var partial = [UInt8](repeating: 0, count: text.count)
            let written = truncated.withUnsafeBufferPointer { input in
                partial.withUnsafeMutableBufferPointer { output in
                    compression_decode_buffer(output.baseAddress!, output.count, input.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
                }
            }
            let decoded = Data(partial[0..<written])
            var member = Data(whole[0..<10])
            member.append(contentsOf: truncated)
            for value in [SyncGzip.crc32(decoded), UInt32(decoded.count)] {
                for shift in stride(from: 0, to: 32, by: 8) { member.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
            }
            #expect(throws: SyncGzip.Failure.self, "cut at \(cut) of \(deflate.count)") {
                try SyncGzip.decompress(member, maxBytes: 1 << 20)
            }
            refusedCuts += 1
        }
        #expect(refusedCuts > 10)
    }

    @Test("Gzip that inflates past its claim, or past the limit, is still refused")
    func gzipBounds() throws {
        let text = Data(String(repeating: "x", count: 10_000).utf8)
        var member = try SyncGzip.compress(text)
        #expect(throws: SyncGzip.Failure.self) { try SyncGzip.decompress(member, maxBytes: 9_999) }
        // The trailer understates the size by one.
        let sizeAt = member.count - 4
        member[sizeAt] = member[sizeAt] &- 1
        #expect(throws: SyncGzip.Failure.self) { try SyncGzip.decompress(member, maxBytes: 1 << 20) }
        #expect(try SyncGzip.decompress(try SyncGzip.compress(Data()), maxBytes: 10) == Data())
    }
}
