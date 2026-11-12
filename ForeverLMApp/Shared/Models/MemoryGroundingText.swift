import Foundation

/// A source's text as a Memory anchor is checked against it: its words, and
/// none of how they were set. A quote grounds an item when its letters and
/// digits run, in order and case aside, from the start of a word of the text
/// to the end of one.
///
/// Stored text keeps its source's typesetting, and a quote read off the page
/// does not. A PDF breaks words at line ends — "STED micro-\nscopy" in the
/// Wolf et al. cristae paper, and "MICOS-\ncomplex" between the same hyphen
/// and newline — so the hyphen-plus-break is nothing in one and a hyphen in
/// the other. A transcript sets its time markers mid-sentence ("transported
/// on tracks [10:37] which are the microtubules") and capitalises a segment's
/// first word; get_source_content marks a PDF's pages "[page N]"; curly and
/// straight apostrophes differ. A quote that had to match the
/// text with only its whitespace collapsed failed 23 of the 284 quotes in
/// the product owner's course quizzes failed, 19 of them the source's own words: a
/// question missed on one of them never came back in review, and the quiz's
/// tutor told the learner so (question 23 of "Membranes, Dynamics, and
/// Cristae", on "deletion of MICOS-complex components or Opa1…").
///
/// Word edges keep a short quote from matching inside a longer word, and a
/// quote of a few words is too specific for the dropped separators to let
/// it land anywhere it was not printed.
///
/// Foundation only, and compiled into the iPhone app too (project.yml): a
/// mnemonic reading places each question after the passage its quote is in
/// by the same matcher that grounds its Memory item
/// (`MnemonicReadingPlacement`), on every client.
struct MemoryGroundingText {
    /// The text's letters and digits, lower case, in order.
    private let letters: [Unicode.Scalar]
    /// The offset in `letters` of each word's first letter, ascending.
    private let wordStarts: [Int]
    /// Whether a word ends at each offset of `letters`, its end included.
    private let endsWord: [Bool]

    init(_ text: String) {
        var letters: [Unicode.Scalar] = []
        var wordStarts: [Int] = []
        var endsWord = [false]
        var inWord = false
        let wordCharacters = CharacterSet.alphanumerics
        for scalar in Self.folded(text).unicodeScalars {
            if wordCharacters.contains(scalar) {
                if !inWord { wordStarts.append(letters.count) }
                inWord = true
                letters.append(scalar)
                endsWord.append(false)
            } else if inWord {
                endsWord[letters.count] = true
                inWord = false
            }
        }
        if inWord { endsWord[letters.count] = true }
        self.letters = letters
        self.wordStarts = wordStarts
        self.endsWord = endsWord
    }

    /// Whether the text has any words to quote.
    var isEmpty: Bool { letters.isEmpty }

    /// How many letters and digits the text has, the unit `offset(of:)`
    /// counts in.
    var letterCount: Int { letters.count }

    /// Whether `excerpt` is a run of this text's words.
    func contains(_ excerpt: String) -> Bool {
        offset(of: excerpt) != nil
    }

    /// Where the first run of this text's words that `excerpt` is begins, at
    /// or after `minimum`: the number of the text's letters and digits before
    /// it. Nil when the excerpt is nowhere there.
    func offset(of excerpt: String, from minimum: Int = 0) -> Int? {
        let needle = MemoryGroundingText(excerpt).letters
        guard let first = needle.first else { return nil }
        for start in wordStarts where start >= minimum && letters[start] == first {
            let end = start + needle.count
            guard end <= letters.count else { return nil }
            if endsWord[end], letters[start..<end].elementsEqual(needle) { return start }
        }
        return nil
    }

    /// Markers a tool or a transcript sets in the text, which are no part of
    /// what it says: "[12:34]", "[1:02:03]" and "[page 7]".
    private static let markers = try! NSRegularExpression(
        pattern: #"\[(?:\d{1,2}:\d{2}(?::\d{2})?|page \d+)\]"#,
        options: [.caseInsensitive]
    )

    /// Markers out, ligatures and compatibility forms expanded, lower case.
    private static func folded(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return markers.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
            .precomposedStringWithCompatibilityMapping
            .lowercased()
    }
}
