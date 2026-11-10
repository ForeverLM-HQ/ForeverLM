// Figure titles, panel notes, JSON coding and figure mentions used by walkthroughs.
import Foundation

// MARK: - Figure titles

/// The title a figure prints at the head of its caption, for the panel to
/// show under a step (product owner, 2026-09-19: "for each figure it actually also
/// says the figure title in the walkthrough; that's probably helpful").
///
/// A caption opens with its label, a separator and a title sentence, then
/// the panel descriptions: "Fig. 1. Atlas of lysosomal changes … GPDs. (A)
/// Schematic …", "Figure 2 | A mitochondrial electron surplus induces sleep.
/// a, Schematic …". The title is what stands between the label and the first
/// sentence end that is not an abbreviation. This reads structure, not
/// meaning — the label the indexer already recognises, then a sentence — and
/// stops there.
enum PaperFigureCaptionTitle {
    static let maximumTitleCharacters = 220
    static let maximumPanelCaptionCharacters = 320

    /// The whole legend with its label taken off, on one line: "Fig. 1. Atlas
    /// of lysosomal changes during aging reveals accumulation of cystine and
    /// GPDs. (A) …" → "Atlas of lysosomal changes during aging reveals
    /// accumulation of cystine and GPDs. (A) …". Empty when only the label
    /// was printed.
    static func words(from caption: String) -> String {
        var text = collapsed(caption)
        if let regex = try? NSRegularExpression(
            pattern: #"^\s*(?:(?:supplementary|supplemental|extended\s+data)\s+)?(?:figure|fig\.?)\s*[A-Za-z]?\d+(?:[.\-–]\d+)?[A-Za-z]?\s*[.|:\-–—]?\s*"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: range), let labelRange = Range(match.range, in: text) {
                text.removeSubrange(labelRange)
            }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// "Fig. 1. Atlas of lysosomal changes during aging reveals accumulation
    /// of cystine and GPDs. (A) …" → "Atlas of lysosomal changes during aging
    /// reveals accumulation of cystine and GPDs". Nil when nothing follows the
    /// label.
    static func title(from caption: String) -> String? {
        let text = words(from: caption)
        guard !text.isEmpty else { return nil }
        var title = String(text[..<(sentenceEnd(in: text) ?? text.endIndex)])
        if let pipe = title.range(of: " | ") { title = String(title[..<pipe.lowerBound]) }
        title = title.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".:;,|"))
        guard !title.isEmpty else { return nil }
        if title.count > maximumTitleCharacters {
            title = String(title.prefix(maximumTitleCharacters)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return title
    }

    /// Whether a caption line is Nature's placeholder under a figure that
    /// fills its page — "Extended Data Fig. 1 | See next page for caption." —
    /// with the words printed on the page after. Such a row stays in the
    /// index as it is (its line is what the crop locator finds on the
    /// figure's page); whoever shows the words reads the continuation row
    /// instead (`PaperWalkthroughGeneratorService.displayCaption`).
    static func isContinuedCaption(_ caption: String) -> Bool {
        guard let body = title(from: caption)?.lowercased() else { return false }
        let stubs = ["see next page", "see the next page", "see following page", "see the following page",
                     "caption on next page", "legend on next page", "continued on next page", "caption overleaf",
                     "see previous page", "see the previous page", "see preceding page", "see the preceding page",
                     "caption on previous page", "legend on previous page"]
        return stubs.contains { body.hasPrefix($0) }
    }

    /// Whether a caption line prints its figure's label and none of its
    /// words: EMBO's "Figure 1." under a figure whose legend is set on the
    /// page before or after it (the EMBO cristae paper, 2026-09-28), or a
    /// pointer to that page, Nature's "Fig. 3 | See next page for caption."
    /// A stub is printed with the figure; the words are somewhere else.
    static func isStub(_ caption: String) -> Bool {
        title(from: caption) == nil || isContinuedCaption(caption)
    }

    /// Whether a caption is an entry in a list of figures: the label, the
    /// title, and a run of leader dots to the page number ("Figure 1.1 The
    /// cardiac action potential. ........ 20"). A legend never prints six dots
    /// in a row, prose does not, and the entry's title may wrap, so the dots
    /// are looked for in the whole caption. Until index version 8 a thesis's
    /// List of Figures was 76 figures, each a box over its page, beside the
    /// real ones.
    static func isContentsEntry(_ caption: String) -> Bool {
        guard let regex = contentsLeaderRegex else { return false }
        return regex.firstMatch(in: caption, range: NSRange(caption.startIndex..<caption.endIndex, in: caption)) != nil
    }

    private static let contentsLeaderRegex = try? NSRegularExpression(
        pattern: #"(?:\.[ \x{00A0}]?){6,}|\x{2026}[ \x{00A0}]?(?:\x{2026}[ \x{00A0}]?){1,}"#
    )

    /// Where a line's caption begins: after the marks some journals set
    /// before it. EMBO points from a legend to the page its figure is on —
    /// "◀ Figure 2. The DΨm-sensitive dye…" opens the page after Figure 2 —
    /// and until 2026-09-28 the arrow hid six of the cristae paper's eleven
    /// legends from the index. Nil when the line is only marks.
    static func captionStart(in line: String) -> String.Index? {
        line.firstIndex { character in
            !character.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.symbols.contains($0)
            }
        }
    }

    /// The label a caption line opens with — "Figure 3", "Extended Data
    /// Figure 1" — or nil for any other line. Marks before the caption
    /// (`captionStart`) are passed over.
    static func label(openingLine line: String) -> String? {

        // Textbooks number figures by chapter ("Figure 3-4", "Figure 3–4",
        // "Figure 3.4"); the joined number is the identifier, so a dash or dot
        // between the digits is part of the label rather than the end of it.
        //
        // The panel letters are matched case-*sensitively*, inside an otherwise
        // case-insensitive pattern, and that is the whole difference between a
        // caption and a sentence. Journals print panels lower case in prose
        // ("senescent cells (Fig. 2a, b)") and upper case in the rare caption
        // that stands alone ("Figure 3B | …"). Extracted page text breaks lines
        // mid-sentence, so a reference lands at the start of a line often
        // enough that a case-blind `[A-Z]?` indexed "Figure 2a", "Figure 5d" and
        // "Figure 11h" as figures of their own — labels that name nothing, and
        // that the tools then offered as available figures.
        //
        // A reference that happens to open a line is told from a caption by
        // what follows the number. A caption continues with a separator or its
        // title ("Fig. 2 | A mitochondrial…", "Figure 3. Regeneration",
        // "FIGURE 3–5 Fermentation"); a reference continues with the close of
        // its parenthesis, a list comma, or the rest of its sentence
        // ("(Extended Data\nFig. 2) offers", "Fig. 2). However", "Figure 2
        // shows"). Nature's extracted text opened two lines of one page of the
        // 2025 sleep-pressure paper with "Fig. 2)", the page before the figure:
        // both were indexed as Figure 2 there, so "Figure 2" resolved to prose,
        // and the same label twice on one page is what the index table refuses,
        // which cost the paper its whole index.
        //
        // Papers that print panels in capitals refer to them as ranges, and a
        // range closes like a reference too: "fig. 6 A-C, Sup. Table 9-11)"
        // and "Extended Data fig. 9B-C). A significant…" opened lines of a
        // bioRxiv preprint and were indexed as Figure 6 and Extended Data
        // Figure 9B (2026-11-09). A capital panel letter, or a range of them,
        // followed by a bracket, comma or the line's end is a reference; a
        // capital that begins a title ("Figure 2 – A model of…") is not.
        //
        // A paper's Extended Data and Supplementary figures are figures too
        // ("Extended Data Fig. 1 | Correlation matrix …", "Supplementary
        // Figure 2. Sensitivity …"): Nature prints the Extended Data at the
        // back of the same PDF, and a walkthrough should be able to point at
        // them wherever they help (product owner, 2026-09-20). The prefix is kept in
        // the label — "Extended Data Figure 1" is not "Figure 1" — so the two
        // never collide in the index, and "Fig." is normalised to "Figure" as
        // it is for a main figure. Until index version 2 these lines were
        // skipped, so a Nature paper lost every Extended Data figure.
        //
        // Journals' supplementary files label their figures more loosely than
        // the articles do, and a joined supplement (`PaperSupplementPDF`) is
        // read with the same pattern. Of 201 open-access supplements fetched for
        // the library on 2026-11-09, about 16 printed only "Supp. Fig. 1",
        // "Supplementary Fig S1", "Fig S1:", "Appendix Figure S1" (EMBO) or
        // "Supplementary Data Figure 1" (Nature Medicine), so their figures
        // never reached the index. "Fig" without its period is a caption under
        // the same test as "Figure" (what follows the number); "Supp." and
        // "Supplementary Data" are filed as "Supplementary", which is how the
        // article names them, and EMBO's Appendix keeps its own prefix because
        // the article cites "Appendix Fig S1".
        guard let regex = captionOpeningRegex, let start = captionStart(in: line) else { return nil }
        let line = String(line[start...])
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges > 2,
              let identifierRange = Range(match.range(at: 2), in: line) else { return nil }
        let prefix = Range(match.range(at: 1), in: line).map { normalizedFigurePrefix(String(line[$0])) }
        return ([prefix, "Figure \(line[identifierRange])"].compactMap { $0 }).joined(separator: " ")
    }

    private static let captionOpeningRegex = try? NSRegularExpression(
        pattern: #"^(?:(Extended\s+Data|Supplementary(?:\s+Data)?|Supplemental|Supp\.|Appendix)\s+)?(?:Figure|Fig\.?)\s+((?-i:[A-Z])?\d+(?:[.\-–]\d+)?(?-i:[A-Z])?)\b(?!\s*(?:[),;]|(?-i:[a-z]))|\s*[-–]\s*(?-i:[A-Z])\s*(?:[),;]|$)|\s+(?-i:[A-Z])\s*(?:[-–,]\s*(?-i:[A-Z])\s*)?(?:[),;]|$)).*"#,
        options: [.caseInsensitive]
    )

    /// "extended  data" → "Extended Data", "SUPPLEMENTARY" → "Supplementary":
    /// the prefix as the label prints it, whatever case the caption used.
    /// "Supp." and "Supplementary Data" → "Supplementary".
    private static func normalizedFigurePrefix(_ raw: String) -> String {
        let lowered = raw.lowercased()
        if lowered.hasPrefix("supp.") || lowered.hasPrefix("supplementary") { return "Supplementary" }
        return raw.split(whereSeparator: { $0.isWhitespace })
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    /// What the caption says about one panel: the text after "(A)", "A,", "A."
    /// or "a)" up to the next panel's marker or the caption's end. Nil when the
    /// caption does not describe panels that way.
    static func panelCaption(for panel: String, in caption: String) -> String? {
        guard let letter = PaperWalkthroughValidation.panelLetter(panel) else { return nil }
        let text = collapsed(caption)
        let escaped = NSRegularExpression.escapedPattern(for: letter)
        // The marker: "(A)" anywhere, or "A," / "A." / "A)" at a sentence start.
        guard let marker = try? NSRegularExpression(
            pattern: #"(?:\(\s*"# + escaped + #"\s*\)|(?:^|(?<=[.;:] ))"# + escaped + #"\s*[,.)])\s*"#,
            options: [.caseInsensitive]
        ), let next = try? NSRegularExpression(
            pattern: #"(?:\(\s*[A-Za-z]\s*\)|(?<=[.;:] )[A-Za-z]\s*[,.)] )"#
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = marker.firstMatch(in: text, range: range),
              let start = Range(match.range, in: text) else { return nil }
        let rest = String(text[start.upperBound...])
        let restRange = NSRange(rest.startIndex..<rest.endIndex, in: rest)
        var body = rest
        if let following = next.firstMatch(in: rest, range: restRange), let cut = Range(following.range, in: rest) {
            body = String(rest[..<cut.lowerBound])
        }
        body = body.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        if body.count > maximumPanelCaptionCharacters {
            body = String(body.prefix(maximumPanelCaptionCharacters)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return body
    }

    /// The index after the first sentence-ending period that is not an
    /// abbreviation ("E. coli", "et al.", "vs.", "Fig."), or nil when the text
    /// has none.
    static func sentenceEnd(in text: String) -> String.Index? {
        var searchStart = text.startIndex
        while let dot = text[searchStart...].firstIndex(of: ".") {
            let after = text.index(after: dot)
            let endsHere = after == text.endIndex || text[after].isWhitespace
            if endsHere {
                let before = text[..<dot]
                let lastWord = before.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
                let abbreviation = lastWord.count <= 1
                    || ["al", "vs", "fig", "figs", "approx", "ca", "cf", "e.g", "i.e", "no", "et", "spp", "sp"]
                        .contains(lastWord.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "()")))
                if !abbreviation { return dot }
            }
            searchStart = after
        }
        return nil
    }

    /// The caption as one line. A stored caption keeps the page's line breaks
    /// (`PDFTextExtractor.figureCaptionRecords(on:)`), and a word the column
    /// broke at a hyphen — "para-" / "aminoblebbistatin" — closes up again
    /// rather than reading "para- aminoblebbistatin".
    static func collapsed(_ text: String) -> String {
        var joined = text
        if let regex = try? NSRegularExpression(pattern: #"-[ \t]*\n[ \t]*(?=[a-z])"#) {
            let range = NSRange(joined.startIndex..<joined.endIndex, in: joined)
            joined = regex.stringByReplacingMatches(in: joined, range: range, withTemplate: "-")
        }
        return joined.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - A panel's own words

/// What the step itself says about one panel of a figure. The letter chips
/// over a figure step move the outline from panel to panel; pressing one has
/// to say what that panel shows as well as point at it (product owner, 2026-09-21:
/// "when I click A, it just shows the highlight over A, but it should really
/// show this short explanation of what it shows"). The figure's printed
/// caption answers first where it describes its panels
/// (`PaperFigureCaptionTitle.panelCaption`); where it does not, the step's own
/// body does. A figure step takes its panels in turn by name, so a panel's
/// note is the sentence that names it plus the sentences that carry on about
/// it, and it ends where the next panel is named.
///
/// This reads structure, not meaning: sentences, and the letters a sentence
/// names as a panel — "panel b", "panels a and b", "panels a–c", "(c)",
/// "Fig. 1d". A letter standing alone in prose is not a panel.
enum WalkthroughStepPanelNote {
    /// About a short paragraph. Longer than a caption's panel sentence
    /// because the step's own words run to two or three sentences a panel.
    static let maximumCharacters = 420

    /// The step's note for one panel, or nil when its body never names it.
    static func note(for panel: String, inBody body: String) -> String? {
        guard let letter = PaperWalkthroughValidation.panelLetter(panel) else { return nil }
        for paragraph in paragraphs(of: body) {
            let sentences = sentences(of: paragraph)
            guard let start = sentences.firstIndex(where: { panels(in: $0).contains(letter) }) else { continue }
            var note = sentences[start]
            var index = start + 1
            while index < sentences.count {
                let next = sentences[index]
                let named = panels(in: next)
                // A sentence that names another panel has left this one.
                guard named.isEmpty || named == [letter] else { break }
                guard note.count + 1 + next.count <= maximumCharacters else { break }
                note += " " + next
                index += 1
            }
            if note.count > maximumCharacters {
                note = String(note.prefix(maximumCharacters)).trimmingCharacters(in: .whitespaces) + "…"
            }
            return note
        }
        return nil
    }

    /// The panel letters a sentence names, upper case.
    static func panels(in sentence: String) -> Set<String> {
        var found: Set<String> = []
        let range = NSRange(sentence.startIndex..<sentence.endIndex, in: sentence)
        // "panel b", "panels a and b", "panels c, d", "panels a–c". The list
        // runs while letters are joined by a separator; "panel a, the plot"
        // captures "a, t" and keeps only the letter standing alone.
        // Each letter must stand alone: "panel a, the plot" stops at "a"
        // because "the" carries on, and "the panels validate" names nothing.
        if let list = try? NSRegularExpression(
            pattern: #"\bpanels?\s+([A-Za-z](?![A-Za-z])(?:\s*(?:,|and|&|or|to|through|–|—|-)\s*[A-Za-z](?![A-Za-z]))*)"#,
            options: [.caseInsensitive]
        ) {
            for match in list.matches(in: sentence, range: range) where match.numberOfRanges > 1 {
                guard let captured = Range(match.range(at: 1), in: sentence) else { continue }
                found.formUnion(letters(inList: String(sentence[captured])))
            }
        }
        // "(c)" on its own, and "Fig. 1d" / "Figure 2B".
        for pattern in [#"\(\s*([A-Za-z])\s*\)"#,
                        #"\b(?:fig(?:ure)?s?\.?\s*)[A-Za-z]?\d+(?:[.\-–]\d+)?([A-Za-z])\b"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: sentence, range: range) where match.numberOfRanges > 1 {
                guard let captured = Range(match.range(at: 1), in: sentence) else { continue }
                found.insert(String(sentence[captured]).uppercased())
            }
        }
        return found
    }

    /// The letters standing alone in a captured list, with "a–c" and "a to c"
    /// opened out into the letters between.
    private static func letters(inList list: String) -> Set<String> {
        var found: Set<String> = []
        guard let single = try? NSRegularExpression(pattern: #"(?<![A-Za-z])([A-Za-z])(?![A-Za-z])"#) else { return [] }
        let range = NSRange(list.startIndex..<list.endIndex, in: list)
        var standing: [String] = []
        for match in single.matches(in: list, range: range) {
            guard let captured = Range(match.range, in: list) else { continue }
            standing.append(String(list[captured]).uppercased())
        }
        found.formUnion(standing)
        if let span = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z])([A-Za-z])\s*(?:–|—|-|to|through)\s*([A-Za-z])(?![A-Za-z])"#,
            options: [.caseInsensitive]
        ) {
            for match in span.matches(in: list, range: range) where match.numberOfRanges > 2 {
                guard let first = Range(match.range(at: 1), in: list),
                      let last = Range(match.range(at: 2), in: list),
                      let from = String(list[first]).uppercased().unicodeScalars.first?.value,
                      let to = String(list[last]).uppercased().unicodeScalars.first?.value,
                      from < to, to - from < 12 else { continue }
                for value in from...to {
                    guard let scalar = Unicode.Scalar(value) else { continue }
                    found.insert(String(Character(scalar)))
                }
            }
        }
        return found
    }

    /// The body's paragraphs as plain one-line prose: blank lines separate,
    /// single newlines join, and Markdown's marks come off so a bold "**Panel
    /// b**" reads as words.
    static func paragraphs(of body: String) -> [String] {
        var paragraphs: [String] = []
        var current: [String] = []
        func flush() {
            let paragraph = plain(current.joined(separator: " "))
            if !paragraph.isEmpty { paragraphs.append(paragraph) }
            current.removeAll()
        }
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush() } else { current.append(line) }
        }
        flush()
        return paragraphs
    }

    /// Whether the step's body takes several panels in turn — the shape a
    /// walk written before 2026-09-21 gave a multi-panel figure, one step
    /// reading "panel a … panel b … panel c" under one outline. Only such a
    /// step has words for one panel that are not simply its opening; a step
    /// about one panel says it all in the bubble already.
    static func toursSeveralPanels(_ body: String) -> Bool {
        var named: Set<String> = []
        for paragraph in paragraphs(of: body) {
            for sentence in sentences(of: paragraph) {
                named.formUnion(panels(in: sentence))
                if named.count > 1 { return true }
            }
        }
        return false
    }

    private static func plain(_ text: String) -> String {
        var copy = text
        for mark in ["**", "__", "`", "*", "_"] { copy = copy.replacingOccurrences(of: mark, with: "") }
        if let leading = try? NSRegularExpression(pattern: #"^\s*(?:#{1,6}\s*|[-*+]\s+|>\s*|\d+\.\s+)"#) {
            let range = NSRange(copy.startIndex..<copy.endIndex, in: copy)
            if let match = leading.firstMatch(in: copy, range: range), let found = Range(match.range, in: copy) {
                copy.removeSubrange(found)
            }
        }
        return copy.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A paragraph cut into sentences. A full stop ends one when it is not an
    /// abbreviation (`PaperFigureCaptionTitle.sentenceEnd`) and what follows
    /// is space or the end, with a closing quote or bracket allowed between —
    /// papers write `“Time (min).”` mid-sentence.
    static func sentences(of paragraph: String) -> [String] {
        var sentences: [String] = []
        var start = paragraph.startIndex
        var index = paragraph.startIndex
        while index < paragraph.endIndex {
            let character = paragraph[index]
            var after = paragraph.index(after: index)
            if character == "." || character == "?" || character == "!" {
                while after < paragraph.endIndex, "”\"’')]".contains(paragraph[after]) {
                    after = paragraph.index(after: after)
                }
                let closes = after == paragraph.endIndex || paragraph[after].isWhitespace
                let abbreviation = character == "." && isAbbreviation(paragraph[start..<index])
                if closes && !abbreviation {
                    let sentence = paragraph[start..<after].trimmingCharacters(in: .whitespaces)
                    if !sentence.isEmpty { sentences.append(sentence) }
                    start = after
                    index = after
                    continue
                }
            }
            index = paragraph.index(after: index)
        }
        let tail = paragraph[start...].trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    /// Whether the word before a full stop is one that is written with one
    /// ("et al.", "vs.", "Fig.", "E. coli").
    private static func isAbbreviation<S: StringProtocol>(_ before: S) -> Bool {
        let word = String(before).components(separatedBy: .whitespaces).last ?? ""
        let bare = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "()“”\"‘’"))
        return bare.count <= 1
            || ["al", "vs", "fig", "figs", "approx", "ca", "cf", "e.g", "i.e", "no", "et", "spp", "sp", "ref", "refs"]
                .contains(bare)
    }
}

// MARK: - JSON

enum PaperWalkthroughCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func json(_ walkthrough: PaperWalkthrough) throws -> String {
        String(decoding: try encoder().encode(walkthrough), as: UTF8.self)
    }

    static func walkthrough(fromJSON json: String) throws -> PaperWalkthrough {
        try decoder().decode(PaperWalkthrough.self, from: Data(json.utf8))
    }
}

// MARK: - The text's own sentence about a figure

/// The sentence of a source's own text that cites a figure's panel — the
/// place where the authors say what Figure 1a shows — found without a model,
/// so a figure step can repeat the authors' words beside the outline
/// (product owner, 2026-09-21: "when it highlights e.g. figure 1a; perhaps it would
/// be helpful to also repeat the sentence in the paper where they explain
/// figure 1a").
///
/// A citation is read the way papers print one: the figure's number after
/// "Fig.", "Figs.", "Figure" or "Figures", with the panel glued to it or in
/// brackets ("Fig. 1a", "Figure 1A", "Fig. 1(a)") and any list or range that
/// follows ("Fig. 1a,b", "Figs. 1a and b", "Fig. 1a–c"). "Figure 12" is not
/// Figure 1, and a main figure's citation is never the extended-data or
/// supplementary figure of the same number, nor the other way round. The
/// caption is not a citation: it opens with the label, and the chip beside
/// the step already shows it.
enum PaperFigureMention {
    /// Words a sentence may run to and still be repeated whole; a longer one
    /// is passed over for the next.
    static let maximumWords = 120
    /// Fewer words than this is a fragment the splitter left, not a sentence.
    static let minimumWords = 4

    /// The first sentence of `text`, outside the figure's caption, that cites
    /// `panel` of the figure labelled `label`; when no sentence cites that
    /// panel, the first that cites the figure as a whole ("Fig. 1", no
    /// panel named); nil when nothing does. `panel` nil asks for the figure
    /// itself. The sentence comes back readable — line breaks closed,
    /// broken words joined — not case-folded.
    static func sentence(citing label: String, panel: String?, in text: String) -> String? {
        guard !text.isEmpty, let pattern = mentionPattern(for: label),
              let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let wanted = panel.flatMap(PaperWalkthroughValidation.panelLetter)?.lowercased()
        // A named panel ("DESIGN") is never cited by letter; the sentence
        // about the figure as a whole is the one that speaks for it.
        let asksForPanel = wanted != nil || panel.flatMap(PaperWalkthroughValidation.panelKey) != nil
        let canonical = PaperWalkthroughValidation.canonicalLabel(label)
        var wholeFigure: String?
        for sentence in sentences(in: text) {
            let range = NSRange(sentence.startIndex..., in: sentence)
            let matches = regex.matches(in: sentence, range: range)
            guard !matches.isEmpty else { continue }
            guard !isCaption(sentence, canonical: canonical, firstMatch: matches[0]) else { continue }
            let words = sentence.split(whereSeparator: { $0.isWhitespace }).count
            guard words >= minimumWords, words <= maximumWords else { continue }
            var citesPanel = false
            var citesFigure = false
            for match in matches {
                guard let end = Range(match.range, in: sentence)?.upperBound else { continue }
                let panels = panelsCited(in: sentence, after: end)
                if panels.isEmpty { citesFigure = true }
                if let wanted, panels.contains(wanted) { citesPanel = true }
            }
            if !asksForPanel {
                if citesFigure || !matches.isEmpty { return sentence }
            } else if citesPanel {
                return sentence
            } else if citesFigure, wholeFigure == nil {
                wholeFigure = sentence
            }
        }
        return wholeFigure
    }

    /// The panel letters a citation names, read off the text right after the
    /// figure's number, lower-cased: the first glued to the number or in
    /// brackets, the rest after commas, "and", "&" or a dash, a dash or "to"
    /// spanning a range ("a–c" is a, b and c). Empty when the citation is of
    /// the whole figure, or the next word is not a panel ("Fig. 1 and 2").
    static func panelsCited(in sentence: String, after start: String.Index) -> [String] {
        let rest = String(sentence[start...])
        guard let first = firstPanel.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) else { return [] }
        var letters: [String] = []
        var upperCase = false
        for group in 1...2 {
            if let range = Range(first.range(at: group), in: rest) {
                let letter = String(rest[range])
                upperCase = letter == letter.uppercased()
                letters.append(letter.lowercased())
            }
        }
        var cursor = Range(first.range, in: rest)!.upperBound
        while let next = nextPanel.firstMatch(in: rest, range: NSRange(cursor..., in: rest)) {
            guard let letterRange = Range(next.range(at: 2), in: rest),
                  let separatorRange = Range(next.range(at: 1), in: rest) else { break }
            let letter = String(rest[letterRange])
            // The list keeps one case: "Fig. 1A, B" names B, "Fig. 1A, a
            // decrease" does not.
            guard (letter == letter.uppercased()) == upperCase else { break }
            let lowered = letter.lowercased()
            // "a" and "i" are words as well as panels; after a separator they
            // count only when the list goes on or closes right after them.
            if lowered == "a" || lowered == "i" {
                let after = rest[letterRange.upperBound...].first
                guard after == nil || ",;.)]".contains(after!) || nextPanelContinues(rest, from: letterRange.upperBound) else { break }
            }
            let separator = rest[separatorRange].trimmingCharacters(in: .whitespaces).lowercased()
            if rangeSeparators.contains(separator), let last = letters.last, let from = last.unicodeScalars.first?.value,
               let to = lowered.unicodeScalars.first?.value, to > from, to - from < 26 {
                for value in (from + 1)...to {
                    if let scalar = Unicode.Scalar(value) { letters.append(String(Character(scalar))) }
                }
            } else {
                letters.append(lowered)
            }
            cursor = letterRange.upperBound
        }
        return letters
    }

    private static let rangeSeparators: Set<String> = ["–", "—", "-", "to", "through"]
    // Glued ("1a") or bracketed ("1(a)", "1 (a)"), a single letter with no
    // letter or digit after it.
    private static let firstPanel = try! NSRegularExpression(
        pattern: #"^(?:([A-Za-z])|\s*\(([A-Za-z])\))(?![A-Za-z0-9])"#
    )
    // ", b", " and b", " & b", "–c", "-c", " to c", ", and c", "(b)".
    private static let nextPanel = try! NSRegularExpression(
        pattern: #"^(\s*(?:,\s*(?:and|&)?|\s(?:and|&|to|through)|\s*[–—-])\s*)\(?([A-Za-z])\)?(?![A-Za-z0-9])"#,
        options: [.caseInsensitive]
    )

    private static func nextPanelContinues(_ rest: String, from index: String.Index) -> Bool {
        nextPanel.firstMatch(in: rest, range: NSRange(index..., in: rest)) != nil
    }

    /// A pattern matching a citation of the figure in running text — "Fig. 1",
    /// "Figure 1a", "Figs. 1a and c", "Extended Data Fig. 2" — and not the
    /// figure whose number merely begins with the same digits ("Figure 12")
    /// nor, for a main figure, the extended-data or supplementary figure of
    /// the same number. The match ends at the number, so what follows it can
    /// be read for panels. Nil when the label carries no number.
    static func mentionPattern(for label: String) -> String? {
        let canonical = PaperWalkthroughValidation.canonicalLabel(label)
        let words = canonical.split(separator: " ").map(String.init)
        guard let figureIndex = words.firstIndex(of: "figure"),
              figureIndex + 1 < words.count else { return nil }
        let number = words[figureIndex + 1]
        let digits = number.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let qualifier = words[..<figureIndex].joined(separator: " ")
        let figureWord = "(?:figs?\\.?|figures?)"
        if qualifier.isEmpty {
            // A bare "Figure 1": not "Extended Data Fig. 1" or "Supplementary Fig. 1".
            return "(?<!data\\s)(?<!supplementary\\s)(?<!supplemental\\s)\\b\(figureWord)\\s*\(digits)(?![0-9])"
        }
        let qualifierPattern = qualifier
            .split(separator: " ")
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s+")
        return "\\b\(qualifierPattern)\\s+\(figureWord)\\s*\(digits)(?![0-9])"
    }

    /// Whether a sentence is the figure's caption rather than a citation of
    /// it: it opens with the label — "Fig. 1 | Intracellular Na…", "Figure
    /// 1. Sleep in flies", "Figure 1 Sleep in flies" — and what follows the
    /// label is a separator, a capital or nothing. A body sentence opens
    /// with the label too ("Figure 2 shows the model", "Figs. 1 and 2
    /// summarise…") and goes on in lower case, and is kept.
    static func isCaption(_ sentence: String, canonical: String, firstMatch: NSTextCheckingResult) -> Bool {
        guard opensWithLabel(sentence, canonical: canonical),
              let matched = Range(firstMatch.range, in: sentence) else { return false }
        var rest = sentence[matched.upperBound...]
        // A glued panel letter ("Fig. 1a shows") is part of the citation.
        if let first = rest.first, first.isLetter, rest.dropFirst().first.map({ !$0.isLetter }) ?? true {
            rest = rest.dropFirst()
        }
        rest = rest.drop(while: { $0 == " " })
        guard let next = rest.first else { return true }
        return !(next.isLetter && next.isLowercase)
    }

    /// Whether a paragraph or sentence opens with the figure's label — "Fig.
    /// 1 | Intracellular Na…", "Figure 1. Sleep in flies" — the way a caption
    /// does. Both sides are canonicalised, so "Fig." and "Figure" agree, and
    /// the label must end where the next word begins, so "Figure 10" does
    /// not open with "figure 1".
    static func opensWithLabel(_ paragraph: String, canonical: String) -> Bool {
        let opening = paragraph
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(6)
            .joined(separator: " ")
        let canonicalOpening = PaperWalkthroughValidation.canonicalLabel(opening)
        return canonicalOpening == canonical || canonicalOpening.hasPrefix(canonical + " ")
    }

    /// The text as it reads: soft hyphens and ligatures resolved, a word the
    /// column broke at a hyphen closed up (a hyphen before a capital or a
    /// digit stays: "Na+-ATPase"), every run of white space one space.
    static func readable(_ text: String) -> String {
        var value = text
        value = value.replacingOccurrences(of: "\u{00AD}", with: "")
        value = value.replacingOccurrences(of: "\u{FB01}", with: "fi")
        value = value.replacingOccurrences(of: "\u{FB02}", with: "fl")
        value = value.replacingOccurrences(of: #"-[ \t]*\n[ \t]*(?=\p{Ll})"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"-[ \t]*\n[ \t]*"#, with: "-", options: .regularExpression)
        return value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The text's sentences, readable. A sentence ends at a full stop,
    /// question or exclamation mark (closing brackets and quotes taken along)
    /// followed by a space and a capital, a digit or an opening bracket or
    /// quote — unless the stop closes an abbreviation a paper prints ("Fig.",
    /// "et al.", "e.g.", "vs.", "Eq.") or an initial ("J. Smith").
    static func sentences(in text: String) -> [String] {
        let characters = Array(readable(text))
        var sentences: [String] = []
        var current = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            current.append(character)
            index += 1
            guard character == "." || character == "!" || character == "?" else { continue }
            while index < characters.count, closers.contains(characters[index]) {
                current.append(characters[index])
                index += 1
            }
            guard index + 1 < characters.count, characters[index] == " " else { continue }
            let next = characters[index + 1]
            guard next.isUppercase || next.isNumber || openers.contains(next) else { continue }
            if character == ".", endsWithAbbreviation(current) { continue }
            sentences.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
            index += 1
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    private static let closers: Set<Character> = [")", "]", "\"", "'", "\u{201D}", "\u{2019}"]
    private static let openers: Set<Character> = ["(", "[", "\"", "\u{201C}", "\u{2018}"]
    /// Abbreviations a paper closes with a full stop mid-sentence.
    private static let abbreviations: Set<String> = [
        "fig", "figs", "ref", "refs", "eq", "eqs", "eqn", "eqns", "no", "nos", "vs", "cf", "ca", "al",
        "e.g", "i.e", "viz", "etc", "approx", "resp", "dr", "prof", "mr", "mrs", "ms", "st", "vol", "vols",
        "pp", "p", "chap", "ch", "sec", "suppl", "supp", "sp", "spp", "min", "max", "mol", "wt", "conc",
    ]

    /// Whether the text so far ends in an abbreviation's stop: its last word,
    /// stop and brackets removed, is one a paper abbreviates or dotted
    /// letters ("U.S."; "0.05" is a number, and closes a sentence); or it is
    /// an initial — a bare capital and its stop ("J. Doe") — unless the word
    /// before it makes it a panel in a list ("Figs. 1E and F.", "Fig. 1A,
    /// B.").
    private static func endsWithAbbreviation(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard let last = words.last else { return false }
        let raw = String(last)
        if raw.count == 2, raw.last == ".", let letter = raw.first, letter.isLetter, letter.isUppercase {
            let before = words.dropLast().last.map(String.init)?.lowercased() ?? ""
            let listed = ["and", "&", "to", "through"].contains(before) || before.hasSuffix(",")
            return !listed
        }
        var word = raw
        while let end = word.last, end == "." || closers.contains(end) { word.removeLast() }
        while let first = word.first, openers.contains(first) { word.removeFirst() }
        guard !word.isEmpty else { return false }
        if word.contains("."), !word.contains(where: \.isNumber) { return true }
        return abbreviations.contains(word.lowercased())
    }
}
