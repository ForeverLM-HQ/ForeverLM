import Foundation

/// The attributes of HTML and XML start tags, read the way a browser's
/// tokenizer reads them.
///
/// Every page-head reader in the app asks the same question — the `content`
/// of the `<meta>` whose `name` is `author`, the `href` of a `<link>` — and
/// each used to answer it with a regular expression of its own. A pattern
/// laid over the page rather than over one tag can capture across tags:
/// before 2026-08-23 `PaperService` matched
/// `<meta … content="(.*?)" … name="author">` lazily from the first
/// `content="` in the head, and on pages that write `content` before `name`
/// (React Helmet and Next.js heads do) two articles in the production library
/// kept the 1,290 and 1,772 characters of head between the viewport tag and
/// the author tag as their author. A reader built on tags cannot do that.
///
/// A tag ends at its own `>` outside quotes. An attribute's value is the one
/// written after it, in any attribute order, quoted either way or not at all.
/// Names match exactly and case-insensitively, so `name` is never
/// `data-name`, and the first of a repeated attribute wins, as in a browser.
/// Comments, declarations and the text of `<script>` and `<style>` are passed
/// over, and a quote that never closes drops its own tag rather than
/// swallowing the rest of the page. Values come back as written: each caller
/// decodes character references the way it did before.
enum HTMLTagAttributes {
    /// One start tag.
    struct Tag: Sendable, Equatable {
        /// The element's name, lowercased.
        let name: String
        /// Attribute values by lowercased attribute name, as written. A bare
        /// attribute (`async`, `crossorigin`) has the empty value.
        let attributes: [String: String]

        /// The value of `attribute`, whose name is matched case-insensitively.
        subscript(attribute: String) -> String? {
            attributes[attribute.lowercased()]
        }
    }

    /// Every `<name …>` start tag in `markup`, in document order. `name` is
    /// matched case-insensitively (`META`, `Meta`, `meta`).
    static func tags(named name: String, in markup: String) -> [Tag] {
        let wanted = name.lowercased()
        var found: [Tag] = []
        scanStartTags(in: markup, reading: { $0 == wanted }) { found.append($0) }
        return found
    }

    // MARK: - Tokenizer

    /// Elements whose content is text, never markup, in an HTML document.
    private static let rawTextElements: Set<String> = ["script", "style"]

    private static func scanStartTags(
        in markup: String,
        reading: (String) -> Bool,
        found: (Tag) -> Void
    ) {
        let bytes = Array(markup.utf8)
        let count = bytes.count
        var index = 0
        while index < count {
            guard let open = firstIndex(of: .lessThan, in: bytes, from: index) else { return }
            var cursor = open + 1
            guard cursor < count else { return }
            let lead = bytes[cursor]
            if lead == .exclamation {
                // A comment, a CDATA section or a declaration: none holds a tag.
                if hasPrefix("--", in: bytes, at: cursor + 1) {
                    index = end(of: "-->", in: bytes, from: cursor + 3) ?? count
                } else if hasPrefix("[CDATA[", in: bytes, at: cursor + 1) {
                    index = end(of: "]]>", in: bytes, from: cursor + 8) ?? count
                } else {
                    index = end(of: ">", in: bytes, from: cursor + 1) ?? count
                }
                continue
            }
            if lead == .question || lead == .slash {
                // A processing instruction or an end tag: nothing to read.
                index = end(of: ">", in: bytes, from: cursor + 1) ?? count
                continue
            }
            guard isASCIILetter(lead) else {
                // `<` as text: `p < 0.05`, `Alan <> Zara`.
                index = cursor
                continue
            }

            let nameStart = cursor
            while cursor < count, !isSpace(bytes[cursor]),
                  bytes[cursor] != .slash, bytes[cursor] != .greaterThan {
                cursor += 1
            }
            let name = lowercasedASCII(bytes[nameStart..<cursor])
            let isWanted = reading(name)
            var attributes: [String: String] = [:]
            var closed = false
            var unterminatedQuote = false

            attributeLoop: while cursor < count {
                while cursor < count, isSpace(bytes[cursor]) || bytes[cursor] == .slash {
                    cursor += 1
                }
                guard cursor < count else { break }
                if bytes[cursor] == .greaterThan {
                    cursor += 1
                    closed = true
                    break
                }
                // The attribute's name runs to a space, `/`, `>` or `=`; its
                // first character belongs to it whatever it is, as in a browser.
                let attributeStart = cursor
                cursor += 1
                while cursor < count, !isSpace(bytes[cursor]),
                      bytes[cursor] != .slash, bytes[cursor] != .greaterThan,
                      bytes[cursor] != .equals {
                    cursor += 1
                }
                let attributeEnd = cursor
                var lookahead = cursor
                while lookahead < count, isSpace(bytes[lookahead]) { lookahead += 1 }
                var value = ""
                if lookahead < count, bytes[lookahead] == .equals {
                    lookahead += 1
                    while lookahead < count, isSpace(bytes[lookahead]) { lookahead += 1 }
                    if lookahead < count,
                       bytes[lookahead] == .doubleQuote || bytes[lookahead] == .singleQuote {
                        let quote = bytes[lookahead]
                        let valueStart = lookahead + 1
                        guard let valueEnd = firstIndex(of: quote, in: bytes, from: valueStart) else {
                            unterminatedQuote = true
                            break attributeLoop
                        }
                        if isWanted {
                            value = String(decoding: bytes[valueStart..<valueEnd], as: UTF8.self)
                        }
                        cursor = valueEnd + 1
                    } else {
                        let valueStart = lookahead
                        while lookahead < count, !isSpace(bytes[lookahead]),
                              bytes[lookahead] != .greaterThan {
                            lookahead += 1
                        }
                        if isWanted {
                            value = String(decoding: bytes[valueStart..<lookahead], as: UTF8.self)
                        }
                        cursor = lookahead
                    }
                }
                if isWanted {
                    let attributeName = lowercasedASCII(bytes[attributeStart..<attributeEnd])
                    if attributes[attributeName] == nil {
                        attributes[attributeName] = value
                    }
                }
            }

            guard closed, !unterminatedQuote else {
                // A quote that never closes, or a tag the input ends inside.
                // Drop this one tag and read on from just after its `<`, so
                // one broken attribute cannot carry the rest of the page.
                index = open + 1
                continue
            }
            if isWanted {
                found(Tag(name: name, attributes: attributes))
            }
            index = cursor
            if rawTextElements.contains(name),
               let endTag = endTagStart(of: name, in: bytes, from: cursor) {
                // A script or a style sheet holds text that can look like
                // tags (`'<meta content="' + x + '">'`); a browser never reads
                // it as markup, and neither does this.
                index = endTag
            }
        }
    }

    private static func firstIndex(of byte: UInt8, in bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            if bytes[index] == byte { return index }
            index += 1
        }
        return nil
    }

    /// The index just past the first `needle` at or after `start`.
    private static func end(of needle: String, in bytes: [UInt8], from start: Int) -> Int? {
        let pattern = Array(needle.utf8)
        guard !pattern.isEmpty else { return start }
        var index = max(0, start)
        while index + pattern.count <= bytes.count {
            if bytes[index] == pattern[0], hasPrefix(pattern, in: bytes, at: index) {
                return index + pattern.count
            }
            index += 1
        }
        return nil
    }

    private static func hasPrefix(_ prefix: String, in bytes: [UInt8], at start: Int) -> Bool {
        hasPrefix(Array(prefix.utf8), in: bytes, at: start)
    }

    private static func hasPrefix(_ prefix: [UInt8], in bytes: [UInt8], at start: Int) -> Bool {
        guard start >= 0, start + prefix.count <= bytes.count else { return false }
        for offset in 0..<prefix.count where bytes[start + offset] != prefix[offset] {
            return false
        }
        return true
    }

    /// Where the end tag `</name…>` begins, matched case-insensitively.
    private static func endTagStart(of name: String, in bytes: [UInt8], from start: Int) -> Int? {
        let lowered = Array(name.utf8)
        var index = start
        while let open = firstIndex(of: .lessThan, in: bytes, from: index) {
            let nameStart = open + 2
            if open + 1 < bytes.count, bytes[open + 1] == .slash,
               nameStart + lowered.count <= bytes.count {
                var matches = true
                for offset in 0..<lowered.count
                where lowercased(bytes[nameStart + offset]) != lowered[offset] {
                    matches = false
                    break
                }
                let after = nameStart + lowered.count
                if matches,
                   after == bytes.count || isSpace(bytes[after])
                    || bytes[after] == .slash || bytes[after] == .greaterThan {
                    return open
                }
            }
            index = open + 1
        }
        return nil
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    /// HTML's whitespace: space, tab, line feed, form feed, carriage return.
    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
    }

    private static func lowercasedASCII(_ slice: ArraySlice<UInt8>) -> String {
        String(decoding: slice.map(lowercased), as: UTF8.self)
    }
}

private extension UInt8 {
    static let lessThan = UInt8(ascii: "<")
    static let greaterThan = UInt8(ascii: ">")
    static let slash = UInt8(ascii: "/")
    static let equals = UInt8(ascii: "=")
    static let exclamation = UInt8(ascii: "!")
    static let question = UInt8(ascii: "?")
    static let doubleQuote = UInt8(ascii: "\"")
    static let singleQuote = UInt8(ascii: "'")
}
