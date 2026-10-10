import Foundation

/// Splits a server-sent events body into lines the way the event-stream
/// grammar defines them: at LF, at CR, and at CRLF, and nowhere else.
///
/// Foundation's `AsyncLineSequence` — what `URLSession.AsyncBytes.lines`
/// returns — is a *Unicode* line splitter, so it also ends a line at U+0085
/// NEL, U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR. Those three are
/// ordinary characters in a model's answer: they survive in text lifted out of
/// PDFs, which is most of what this app reads back to a provider, and a
/// provider may put them raw into the JSON of a `response.output_text.delta`.
/// Ending a line there cuts the payload in half inside a JSON string, and the
/// halves cannot be put back together — a literal newline inside a string is
/// not valid JSON — so the event was rejected and the whole answer died with
/// "a stream event ForeverLM could not read". Content must never be able to
/// frame the protocol that carries it.
struct SSELineSplitter {
    private var bytes: [UInt8] = []
    private var carriageReturnMaySwallowLineFeed = false

    /// The line this byte completed, or `nil` when the line is still open. A
    /// blank line completes as `""`, which is how an SSE event ends.
    mutating func consume(_ byte: UInt8) -> String? {
        if carriageReturnMaySwallowLineFeed {
            carriageReturnMaySwallowLineFeed = false
            // The LF half of a CRLF: the CR already ended the line.
            if byte == 0x0A { return nil }
        }

        switch byte {
        case 0x0A:
            return takeLine()
        case 0x0D:
            carriageReturnMaySwallowLineFeed = true
            return takeLine()
        default:
            bytes.append(byte)
            return nil
        }
    }

    /// Whatever the stream left unterminated. A body that ends without a final
    /// newline still carries a real line; a body that ends on one does not.
    mutating func finish() -> String? {
        carriageReturnMaySwallowLineFeed = false
        return bytes.isEmpty ? nil : takeLine()
    }

    private mutating func takeLine() -> String {
        defer { bytes.removeAll(keepingCapacity: true) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// `AsyncLineSequence`'s shape over `SSELineSplitter`'s rules.
struct AsyncSSELineSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    typealias Element = String

    let base: Base

    struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        var splitter = SSELineSplitter()

        mutating func next() async throws -> String? {
            while let byte = try await base.next() {
                if let line = splitter.consume(byte) { return line }
            }
            return splitter.finish()
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator())
    }
}

extension AsyncSequence where Element == UInt8 {
    /// The bytes read as SSE lines. Use this and never `.lines` on an
    /// event-stream body: see `SSELineSplitter` for what `.lines` does to a
    /// payload that happens to contain a Unicode line separator.
    var sseLines: AsyncSSELineSequence<Self> {
        AsyncSSELineSequence(base: self)
    }
}
