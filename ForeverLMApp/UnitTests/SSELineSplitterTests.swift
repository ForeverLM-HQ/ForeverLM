import Foundation
import Testing
@testable import ForeverLM

/// A model's own answer must never be able to frame the stream that carries
/// it. `URLSession.AsyncBytes.lines` let it: Foundation ends a line at U+0085,
/// U+2028 and U+2029 as well as at LF/CR/CRLF, so an answer containing any of
/// those — routine in text lifted out of a PDF — cut a `data:` payload in half
/// and the chat died with "a stream event ForeverLM could not read".
@Suite("SSE line splitting")
struct SSELineSplitterTests {

    private func lines(of body: String) -> [String] {
        var splitter = SSELineSplitter()
        var lines: [String] = []
        for byte in Array(body.utf8) {
            if let line = splitter.consume(byte) { lines.append(line) }
        }
        if let last = splitter.finish() { lines.append(last) }
        return lines
    }

    @Test("Unicode line separators stay inside the line")
    func unicodeSeparatorsDoNotEndALine() {
        #expect(lines(of: "a\u{2028}b\n") == ["a\u{2028}b"])
        #expect(lines(of: "a\u{2029}b\n") == ["a\u{2029}b"])
        #expect(lines(of: "a\u{85}b\n") == ["a\u{85}b"])
    }

    @Test("LF, CR and CRLF each end exactly one line")
    func onlyTheEventStreamTerminatorsEndALine() {
        #expect(lines(of: "one\ntwo\n") == ["one", "two"])
        #expect(lines(of: "one\rtwo\r") == ["one", "two"])
        #expect(lines(of: "one\r\ntwo\r\n") == ["one", "two"])
        #expect(lines(of: "one\r\n\r\ntwo\r\n") == ["one", "", "two"])
    }

    @Test("a body that ends without a terminator still yields its last line")
    func unterminatedTailIsEmitted() {
        #expect(lines(of: "one\ntwo") == ["one", "two"])
        #expect(lines(of: "one\n") == ["one"])
    }

    @Test("a delta carrying U+2028 survives as one readable event")
    func deltaWithLineSeparatorParses() throws {
        let text = "First line\u{2028}second line"
        let payload = try #require(
            String(
                data: try JSONSerialization.data(
                    withJSONObject: ["type": "response.output_text.delta", "delta": text]
                ),
                encoding: .utf8
            )
        )
        let body = "event: response.output_text.delta\ndata: \(payload)\n\n"

        var accumulator = AIStreamEventAccumulator()
        var events: [[String]] = []
        for line in lines(of: body) {
            if let event = accumulator.consume(line) { events.append(event) }
        }
        if let event = accumulator.finish() { events.append(event) }

        #expect(events.count == 1)
        let joined = try #require(events.first).joined(separator: "\n")
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(joined.utf8)) as? [String: Any]
        )
        #expect(AIStreamDeltaExtractor.text(from: json) == text)
    }

    @Test("a half-received event is not mistaken for a whole one")
    func truncatedTrailingEventIsIncomplete() {
        var accumulator = AIStreamEventAccumulator()
        _ = accumulator.consume(#"data: {"type":"response.output_text.delta","item_id":"msg_0"#)
        #expect(accumulator.payloadIsComplete == false)

        var whole = AIStreamEventAccumulator()
        _ = whole.consume(#"data: {"type":"response.output_text.delta","delta":"hi"}"#)
        #expect(whole.payloadIsComplete)
    }

    @Test("the async wrapper splits a byte stream the same way")
    func asyncSequenceMatchesTheSplitter() async throws {
        let body = "data: {\"delta\":\"a\u{2028}b\"}\r\n\r\ndata: [DONE]\n"
        let stream = AsyncStream<UInt8> { continuation in
            for byte in Array(body.utf8) { continuation.yield(byte) }
            continuation.finish()
        }

        var received: [String] = []
        for try await line in stream.sseLines { received.append(line) }
        #expect(received == ["data: {\"delta\":\"a\u{2028}b\"}", "", "data: [DONE]"])
    }
}
