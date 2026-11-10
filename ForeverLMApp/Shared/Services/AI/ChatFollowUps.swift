import Foundation

/// The suggested questions a chat reply ends with (docs/chat-design.md,
/// "Suggested questions under the answer"). The tutor writes up to three
/// questions the learner could ask next as a tail block after its answer
/// (`Prompts.followUpQuestions`):
///
///     <flm_follow_ups>
///     Why does the gradient collapse?
///     …
///     </flm_follow_ups>
///
/// The block is never prose. The manager splits it off when a turn settles,
/// keeps the questions on the reply's row in memory, and stores and shows
/// only the prose; while the reply streams, the block is hidden as it
/// arrives. The renderer's `splitFollowUps` (chat-markdown.js) reads the same
/// grammar on the same fixtures, so a block that reaches a page anyway is
/// dropped there too.
///
/// A cheaper model dresses the block up in ways the prompt does not ask for:
/// a "Suggested questions:" line over it, a code fence around it, or the
/// sample lines of an older prompt's template. The line over it and a fence
/// opened for it go with the block, and no such line is a question.
enum ChatFollowUps {
    static let openTag = "<flm_follow_ups>"
    static let closeTag = "</flm_follow_ups>"
    /// The cards under an answer.
    static let maximumQuestions = 3
    /// A line longer than this is not a question a card can carry.
    static let maximumQuestionLength = 160

    /// The reply without its blocks, and the questions of the last complete
    /// one. An unterminated block, or a trailing piece of the opening tag, is
    /// cut off and yields nothing.
    static func split(_ text: String) -> (prose: String, questions: [String]) {
        let scan = scanned(text)
        return (scan.prose, scan.lastBlock.map { questions(inBlock: $0) } ?? [])
    }

    /// The prose `split` would keep, for text that is still streaming: a
    /// complete block, an unterminated one and a trailing partial tag are all
    /// hidden, so the learner never watches the block type itself out.
    static func hidingBlock(in text: String) -> String {
        scanned(text).prose
    }

    // MARK: - Scanning

    private static func scanned(_ text: String) -> (prose: String, lastBlock: Substring?) {
        // Runs on every message of the transcript each time a streamed token
        // lands (`visibleAssistantText`), so prose with no tag at all is a
        // memchr over its bytes.
        guard containsAngleBracket(text) else { return (trimmingTrailingWhitespace(text), nil) }
        var prose = ""
        var lastBlock: Substring?
        var rest = text[...]
        while let open = rest.range(of: openTag) {
            let lead = rest[..<open.lowerBound]
            guard let close = rest.range(of: closeTag, range: open.upperBound..<rest.endIndex) else {
                // Still streaming: whatever follows is the block.
                prose += strippingLeadIn(lead)
                rest = rest[rest.endIndex...]
                break
            }
            var before = droppingLastLine(of: lead, where: isLabelLine) ?? lead
            lastBlock = rest[open.upperBound..<close.lowerBound]
            var after = rest[close.upperBound...]
            // A fence opened for the block and closed after it would be an
            // empty code box once the block is gone. So would one whose
            // closing has not arrived yet, or never does.
            if let unfenced = droppingOpeningFence(of: before),
               let unclosed = droppingFirstLine(of: after, where: isFenceClosing)
                ?? (isFenceStillArriving(after) ? after[after.endIndex...] : nil) {
                before = droppingLastLine(of: unfenced, where: isLabelLine) ?? unfenced
                after = unclosed
            }
            prose += before
            rest = after
        }
        prose += rest
        if let lastOpen = trailingPartialOpenTag(in: prose) {
            prose = String(strippingLeadIn(prose[..<lastOpen]))
        }
        return (trimmingTrailingWhitespace(prose), lastBlock)
    }

    /// The start of `Answer.\n<flm_fol` while the tag is still arriving: two
    /// characters of it or more, with no `>` yet.
    private static func trailingPartialOpenTag(in text: String) -> String.Index? {
        guard let lastOpen = text.lastIndex(of: "<") else { return nil }
        let fragment = text[lastOpen...]
        guard fragment.count >= 2, fragment.count < openTag.count, openTag.hasPrefix(fragment) else { return nil }
        return lastOpen
    }

    /// What comes before a block still streaming in, without the label line
    /// over it or a fence opened for it, which would draw as an empty code
    /// box running to the end.
    private static func strippingLeadIn(_ before: Substring) -> Substring {
        let unlabelled = droppingLastLine(of: before, where: isLabelLine) ?? before
        guard let unfenced = droppingOpeningFence(of: unlabelled) else { return unlabelled }
        return droppingLastLine(of: unfenced, where: isLabelLine) ?? unfenced
    }

    /// `text` without its last line when that line opens a code fence: a
    /// fence line after an even number of them. The fence that closes a code
    /// block the reply really wrote stays.
    private static func droppingOpeningFence(of text: Substring) -> Substring? {
        guard let unfenced = droppingLastLine(of: text, where: isFenceLine) else { return nil }
        let fencesBefore = unfenced.split(whereSeparator: \.isNewline).filter { isFenceLine($0) }.count
        return fencesBefore.isMultiple(of: 2) ? unfenced : nil
    }

    /// Nothing after a block but blanks and the start of a closing fence.
    private static func isFenceStillArriving(_ text: Substring) -> Bool {
        text.allSatisfy { $0.isWhitespace || $0 == "`" || $0 == "~" }
    }

    /// `text` up to its last line that is not blank, when `matches` accepts
    /// that line; nil when it does not.
    private static func droppingLastLine(of text: Substring, where matches: (Substring) -> Bool) -> Substring? {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace {
            end = text.index(before: end)
        }
        guard end > text.startIndex else { return nil }
        let start = text[..<end].lastIndex(where: \.isNewline).map { text.index(after: $0) } ?? text.startIndex
        guard matches(text[start..<end]) else { return nil }
        return text[..<start]
    }

    /// `text` after its first line that is not blank, when `matches` accepts
    /// that line; nil when it does not.
    private static func droppingFirstLine(of text: Substring, where matches: (Substring) -> Bool) -> Substring? {
        guard let start = text.firstIndex(where: { !$0.isWhitespace }) else { return nil }
        let end = text[start...].firstIndex(where: \.isNewline) ?? text.endIndex
        guard matches(text[start..<end]) else { return nil }
        return text[end...]
    }

    // The renderer's `splitFollowUps` uses these same patterns.

    /// "Suggested questions:", "**Follow-up questions**", "### Suggested
    /// follow-up questions": a label a model writes over the block.
    private static let labelLine = try! NSRegularExpression(
        pattern: #"^\s*(?:#{1,6}\s*)?(?:\*\*|__|\*|_)?\s*(?:suggested\s+(?:follow[- ]?up\s+)?|follow[- ]?up\s+)questions?\s*:?\s*(?:\*\*|__|\*|_)?\s*:?\s*$"#,
        options: [.caseInsensitive]
    )
    /// A code fence line, opening (with or without a language) or closing.
    private static let fenceLine = try! NSRegularExpression(pattern: #"^\s*(?:`{3,}|~{3,})[\w-]*\s*$"#)
    /// A fence line with no language, as a closing fence is written.
    private static let fenceClosingLine = try! NSRegularExpression(pattern: #"^\s*(?:`{3,}|~{3,})\s*$"#)
    /// The sample lines of the block's first template, "First question?" to
    /// "Third question?", in case a model still echoes them.
    private static let placeholderLine = try! NSRegularExpression(
        pattern: #"^(?:first|second|third) question\??$"#,
        options: [.caseInsensitive]
    )

    private static func isLabelLine(_ line: Substring) -> Bool { matches(labelLine, line) }
    private static func isFenceLine(_ line: Substring) -> Bool { matches(fenceLine, line) }
    private static func isFenceClosing(_ line: Substring) -> Bool { matches(fenceClosingLine, line) }

    private static func matches(_ pattern: NSRegularExpression, _ line: Substring) -> Bool {
        let line = String(line)
        return pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let before = text.index(before: end)
            guard text[before].isWhitespace else { break }
            end = before
        }
        return end == text.endIndex ? text : String(text[..<end])
    }

    static func containsAngleBracket(_ text: String) -> Bool {
        var copy = text
        return copy.withUTF8 { bytes in
            guard let base = bytes.baseAddress else { return false }
            return memchr(base, Int32(UInt8(ascii: "<")), bytes.count) != nil
        }
    }

    // MARK: - Questions

    private static func questions(inBlock block: Substring) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in block.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard let question = question(fromLine: line),
                  seen.insert(question.lowercased()).inserted else { continue }
            result.append(question)
            if result.count == maximumQuestions { break }
        }
        return result
    }

    /// One line of a block as a card's question, or nil for a line no card
    /// should carry: empty, a link or tag (the card is plain text), too long
    /// to be a question at all, or the block's dressing (a label, a fence, a
    /// template's sample line).
    private static func question(fromLine line: Substring) -> String? {
        var text = line.trimmingCharacters(in: .whitespaces)
        text = strippingListMarker(text)
        text = strippingWrappingQuotes(text)
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty,
              !text.contains("]("),
              !text.contains("<"),
              text.count <= maximumQuestionLength,
              !isLabelLine(text[...]),
              !isFenceLine(text[...]),
              !matches(placeholderLine, text[...]) else { return nil }
        return text
    }

    /// One leading `-`, `*`, `•`, `2.` or `2)` and the space after it.
    private static func strippingListMarker(_ text: String) -> String {
        guard let first = text.first else { return text }
        var marker = text.startIndex
        if first == "-" || first == "*" || first == "•" {
            marker = text.index(after: marker)
        } else {
            let digits = text.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.endIndex < text.endIndex,
                  text[digits.endIndex] == "." || text[digits.endIndex] == ")" else { return text }
            marker = text.index(after: digits.endIndex)
        }
        guard marker < text.endIndex, text[marker].isWhitespace else { return text }
        return String(text[marker...].drop { $0.isWhitespace })
    }

    /// `"Why?"` or `“Why?”` as `Why?`. Any straight or curly quote counts at
    /// either end, as in the renderer's copy.
    private static func strippingWrappingQuotes(_ text: String) -> String {
        let quotes: Set<Character> = ["\"", "“", "”", "'", "‘", "’"]
        guard text.count >= 2, let first = text.first, let last = text.last,
              quotes.contains(first), quotes.contains(last) else { return text }
        return text.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
    }
}
