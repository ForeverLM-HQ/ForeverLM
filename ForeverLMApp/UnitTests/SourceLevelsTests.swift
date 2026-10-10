import Foundation
import Testing
@testable import ForeverLM

/// Levels in the Reader (docs/sensemaking-design.md): the numbered text the
/// levels are written over, the model's answer read and checked, anchors
/// taken from the text, staleness by the text's SHA-256, a long source's
/// parts joined in order, and which section is under the page on screen.
@Suite("Source levels")
struct SourceLevelsTests {

    // MARK: Fixtures

    /// A paper's text as the cleaned PDF keeps it: the column's physical
    /// lines, no blank lines between paragraphs.
    static let wrappedPaper = """
    Mitochondrial membrane potential in aging
    Introduction
    Mitochondria make most of the cell's ATP by pumping protons across
    their inner membrane, which builds a voltage of about 150 millivolts.
    This voltage drives the ATP synthase.
    Cells that lose this voltage are cleared by mitophagy, a quality
    control pathway that depends on PINK1 and Parkin to tag damaged
    mitochondria for removal.
    Results
    We measured the membrane potential with TMRM in fibroblasts from
    young and old donors and found a 20 percent drop with age.
    """

    /// A web article's text: a paragraph a line, Markdown headings.
    static let article = """
    # How cells sense damage

    Mitochondria are the cell's power plants, and they keep a voltage across their inner membrane that the cell reads as a sign of health.

    When the voltage falls, a kinase called PINK1 stops being imported and builds up on the outer membrane instead.

    ## The PINK1 pathway

    PINK1 recruits Parkin, which tags the damaged mitochondrion with ubiquitin so the cell can digest it by mitophagy.
    """

    static func source(_ text: String, id: String = "src-1") -> SourceLevelsSource {
        SourceLevelsSource(sourceID: id, title: "Membrane potential", sourceType: "paper", kindLabel: "research paper", text: text)
    }

    // MARK: Numbering

    @Test("A PDF's wrapped column lines become numbered paragraphs under the text's own headings")
    func wrappedTextIsNumberedByParagraph() throws {
        let blocks = SourceLevelsText.blocks(of: Self.wrappedPaper)
        #expect(blocks.map(\.kind) == [.heading, .heading, .paragraph, .paragraph, .heading, .paragraph])
        try #require(blocks.count == 6)
        #expect(blocks[0].text == "Mitochondrial membrane potential in aging", "the title above Introduction is kept, as a heading")
        #expect(blocks[1].text == "Introduction")
        #expect(blocks[2].number == 1)
        #expect(blocks[2].text.hasPrefix("Mitochondria make most of the cell's ATP"))
        #expect(blocks[2].text.hasSuffix("drives the ATP synthase."))
        #expect(blocks[3].number == 2)
        #expect(blocks[3].text.hasSuffix("mitochondria for removal."))
        #expect(blocks[4].text == "Results")
        #expect(blocks[5].number == 3)
        #expect(blocks.allSatisfy { $0.page == nil }, "no form feeds, no pages")
        #expect(blocks[2].position < blocks[3].position && blocks[3].position < blocks[5].position)
    }

    @Test("A paragraph-a-line text keeps each line, and Markdown headings head")
    func articleTextIsNumberedByLine() {
        let blocks = SourceLevelsText.blocks(of: Self.article)
        #expect(blocks.map(\.kind) == [.heading, .paragraph, .paragraph, .heading, .paragraph])
        #expect(blocks.compactMap(\.number) == [1, 2, 3])
        #expect(blocks[3].text == "The PINK1 pathway")
        let numbered = SourceLevelsText.numberedText(blocks)
        #expect(numbered.contains("# How cells sense damage\n\n¶1 Mitochondria are the cell's power plants"))
        #expect(numbered.contains("¶3 PINK1 recruits Parkin"))
    }

    @Test("Form feeds give each paragraph its page, and a page number alone on a line is not prose")
    func formFeedsGivePages() {
        let text = [
            "The first page opens with a claim about membrane voltage in neurons.",
            "12",
            "\u{000C}The second page tests that claim in cultured cells and finds it holds.",
            "\u{000C}The third page discusses what this means for aging tissue.",
        ].joined(separator: "\n")
        let paragraphs = SourceLevelsText.paragraphs(SourceLevelsText.blocks(of: text))
        #expect(paragraphs.map(\.page) == [0, 1, 2])
        #expect(paragraphs.map(\.number) == [1, 2, 3])
        #expect(!paragraphs[0].text.contains("12"))
    }

    @Test("A run of text with no break is cut at sentence ends into paragraphs of at most about 220 words")
    func longRunsAreCutAtSentences() {
        let sentence = "The membrane potential falls with age in every tissue we measured so far."
        let text = Array(repeating: sentence, count: 60).joined(separator: " ")
        let paragraphs = SourceLevelsText.paragraphs(SourceLevelsText.blocks(of: text))
        #expect(paragraphs.count > 1)
        for paragraph in paragraphs {
            #expect(paragraph.text.split(separator: " ").count <= SourceLevelsText.maximumParagraphWords)
            #expect(paragraph.text.hasSuffix("."))
        }
        #expect(paragraphs.map(\.text).joined(separator: " ") == text)
    }

    @Test("A list of short items after a colon stays prose rather than becoming headings, and no word is lost")
    func listsStayParagraphs() {
        let text = """
        We followed these steps to measure the potential in every sample:
        Isolate mitochondria
        Load the TMRM dye
        Image with confocal microscopy
        Then we compared the mean intensity across the groups and found the old donors lower.
        The difference held after we corrected for the mitochondrial mass in each cell.
        The difference was largest in the cells that divided least during the culture.
        Our controls showed no change in dye loading between the groups at any point.
        """
        let blocks = SourceLevelsText.blocks(of: text)
        #expect(!blocks.contains { $0.kind == .heading })
        for item in ["Isolate mitochondria", "Load the TMRM dye", "Image with confocal microscopy"] {
            #expect(blocks.contains { $0.kind == .paragraph && $0.text.contains(item) }, "\(item)")
        }
        // Wrapped as a PDF's column, the items join the prose around them.
        let wrapped = """
        We measured the potential in every sample after the following steps, which we
        repeated for each donor in the same order and on the same day:
        Isolate mitochondria
        Load the TMRM dye
        Image with confocal microscopy
        Then we compared the mean intensity across the groups and found the old donors
        lower than the young ones in every tissue that we were able to sample here.
        The difference held after we corrected for the mitochondrial mass in each cell
        and for the size of each cell, which we measured from the same images.
        """
        let wrappedBlocks = SourceLevelsText.blocks(of: wrapped)
        #expect(!wrappedBlocks.contains { $0.kind == .heading })
        #expect(wrappedBlocks.contains { $0.text.contains("Isolate mitochondria Load the TMRM dye Image with confocal microscopy Then we compared") })
    }

    @Test("A line ends a sentence at its stop, behind a citation number, but not at a decimal")
    func sentenceEnds() {
        #expect(SourceLevelsText.endsSentence("in damaged cells."))
        #expect(SourceLevelsText.endsSentence("in damaged cells.12"))
        #expect(SourceLevelsText.endsSentence("in damaged cells.12,13"))
        #expect(SourceLevelsText.endsSentence("as they put it.\u{201D}"))
        #expect(!SourceLevelsText.endsSentence("the potential was 5.4"))
        #expect(!SourceLevelsText.endsSentence("pumping protons across"))
    }

    // MARK: Parsing and checking

    @Test("The model's answer is read leniently and checked: indexes out of range dropped, the first of a duplicate kept, caps applied")
    func parsingDropsWhatIsOutOfRange() throws {
        let response = """
        Here are the levels:
        ```json
        {"gist": "  Old cells lose   membrane potential. ", "why": "It explains why aged tissue clears damaged mitochondria slowly.",
         "findings": [{"text": "A", "section": 1}, {"text": "B", "section": 9}, {"text": "C"}, {"text": "D", "section": "2"}, {"text": "E", "section": 1}],
         "sections": [{"start": 3, "title": "Results", "line": "Old donors' cells sit 20 percent lower."},
                      {"start": 2, "title": "Introduction", "line": "Voltage marks health."},
                      {"start": 99, "title": "Nowhere", "line": "x"},
                      {"start": "¶3", "title": "Duplicate", "line": "y"}],
         "paragraphs": [{"n": 1, "line": "One."}, {"n": "¶2", "line": "Two."}, {"n": 2, "line": "Two again."}, {"n": 0, "line": "Zero."}, {"n": 7, "line": "Seven."}],
         "terms": [{"term": "TMRM", "definition": "A dye.", "paragraph": 3}, {"term": "tmrm", "definition": "Again.", "paragraph": 3},
                   {"term": "PINK1", "definition": "A kinase.", "paragraph": 40}]}
        ```
        """
        let whole = try SourceLevelsBuilder.parseWhole(response, paragraphs: 1...3)
        #expect(whole.gist == "Old cells lose membrane potential.")
        #expect(whole.lines == [1: "One.", 2: "Two."])
        #expect(whole.sections.map(\.start) == [3, 2, 3])
        #expect(whole.terms.map(\.term) == ["TMRM", "PINK1"])
        #expect(whole.terms[1].paragraph == nil, "a paragraph past the text is dropped")

        let blocks = SourceLevelsText.blocks(of: Self.wrappedPaper)
        let levels = SourceLevelsBuilder.levels(
            whole: whole,
            source: Self.source(Self.wrappedPaper),
            paragraphs: SourceLevelsText.paragraphs(blocks),
            model: "test-model"
        )
        // Ordered, one a start, the first moved to ¶1.
        #expect(levels.sections.map(\.title) == ["Introduction", "Results"])
        #expect(levels.sections.map(\.firstParagraph) == [1, 3])
        #expect(levels.sections[0].paragraphs.map(\.index) == [1, 2])
        #expect(levels.paragraph(3)?.line == "", "a paragraph the model wrote no line for keeps an empty line")
        #expect(levels.findings.count == SourceLevelsBuilder.maximumFindings)
        // "section 1" was the model's first section, which starts at ¶3: Results.
        #expect(levels.findings[0].sectionIndex == 1)
        #expect(levels.findings[1].sectionIndex == nil, "a section the model never wrote")
        #expect(levels.findings[3].sectionIndex == 0)
        #expect(levels.model == "test-model")
    }

    @Test("An answer with no gist, or no JSON, is refused")
    func unreadableAnswersAreRefused() {
        #expect(throws: SourceLevelsError.self) { try SourceLevelsBuilder.parseWhole("{\"why\": \"x\"}", paragraphs: 1...3) }
        #expect(throws: SourceLevelsError.self) { try SourceLevelsBuilder.parseWhole("I could not read it.", paragraphs: 1...3) }
        #expect(throws: SourceLevelsError.self) { try SourceLevelsBuilder.parsePart("{\"summary\": \"x\"}", paragraphs: 1...3) }
    }

    @Test("At most twelve terms are kept, each once")
    func termsAreCapped() throws {
        let terms = (1...20).map { "{\"term\": \"Term \($0)\", \"definition\": \"Meaning \($0).\"}" }.joined(separator: ",")
        let whole = try SourceLevelsBuilder.parseWhole("{\"gist\": \"g\", \"terms\": [\(terms)]}", paragraphs: 1...3)
        let levels = SourceLevelsBuilder.levels(
            whole: whole,
            source: Self.source(Self.wrappedPaper),
            paragraphs: SourceLevelsText.paragraphs(SourceLevelsText.blocks(of: Self.wrappedPaper)),
            model: nil
        )
        #expect(levels.terms.count == SourceLevelsBuilder.maximumTerms)
        #expect(levels.terms.first?.term == "Term 1")
    }

    // MARK: Anchors

    @Test("Every anchor is the text's own words, never what the model wrote")
    func anchorsComeFromTheText() throws {
        let response = """
        {"gist": "g", "sections": [{"start": 1, "title": "Introduction", "line": "l", "anchor": "INVENTED BY THE MODEL"}],
         "paragraphs": [{"n": 1, "line": "One.", "anchor": "INVENTED"}, {"n": 2, "line": "Two.", "quote": "INVENTED"}],
         "terms": [{"term": "PINK1", "definition": "A kinase that marks damaged mitochondria.", "paragraph": 1, "quote": "INVENTED"},
                   {"term": "membrane potential", "definition": "The voltage across the inner membrane.", "paragraph": 3}]}
        """
        let paragraphs = SourceLevelsText.paragraphs(SourceLevelsText.blocks(of: Self.wrappedPaper))
        let levels = SourceLevelsBuilder.levels(
            whole: try SourceLevelsBuilder.parseWhole(response, paragraphs: 1...3),
            source: Self.source(Self.wrappedPaper),
            paragraphs: paragraphs,
            model: nil
        )
        let first = try #require(levels.paragraph(1))
        #expect(first.anchor == "Mitochondria make most of the cell's ATP by pumping protons across their")
        #expect(first.anchor.split(separator: " ").count == SourceLevelsText.anchorWords)
        #expect(levels.sections[0].anchor == first.anchor)
        #expect(!levels.sections.flatMap(\.paragraphs).contains { $0.anchor.contains("INVENTED") })

        // PINK1 is named in ¶2, not the ¶1 the model gave: it moves there,
        // and its anchor is the sentence that names it, verbatim.
        let pink1 = try #require(levels.terms.first { $0.term == "PINK1" })
        #expect(pink1.paragraphIndex == 2)
        #expect(pink1.anchor?.hasPrefix("Cells that lose this voltage are cleared by mitophagy") == true)
        #expect(paragraphs[1].text.contains(pink1.anchor ?? "nothing"))

        // Named in ¶3 ("the membrane potential"), as the model said.
        let potential = try #require(levels.terms.first { $0.term == "membrane potential" })
        #expect(potential.paragraphIndex == 3)
        #expect(potential.anchor?.contains("membrane potential") == true)
    }

    // MARK: Staleness and storage

    @Test("Levels are kept against the text's SHA-256 and read stale once the text changes")
    func stalenessBySHA() throws {
        let source = Self.source(Self.wrappedPaper)
        #expect(source.contentSHA256 == PaperContentPreparationService.sha256(Self.wrappedPaper))
        let levels = SourceLevelsBuilder.levels(
            whole: SourceLevelsBuilder.WrittenWhole(gist: "g", why: "w", findings: [], sections: [], lines: [:], terms: []),
            source: source,
            paragraphs: SourceLevelsText.paragraphs(SourceLevelsText.blocks(of: Self.wrappedPaper)),
            model: nil
        )
        #expect(!levels.isStale(currentSHA256: PaperContentPreparationService.sha256(Self.wrappedPaper)))
        #expect(levels.isStale(currentSHA256: PaperContentPreparationService.sha256(Self.wrappedPaper + " Edited.")))

        // Round trip through the table, keyed by the row.
        let store = try KnowledgeStore(inMemory: true)
        try store.saveSourceLevelsRow(try SourceLevelsCoding.row(for: levels))
        let row = try #require(try store.sourceLevelsRow(sourceID: "src-1"))
        #expect(row.contentSHA256 == source.contentSHA256)
        #expect(try SourceLevelsCoding.levels(from: row) == levels)

        var broken = row
        broken.payloadJSON = "{\"gist\": 1}"
        #expect(throws: SourceLevelsCoding.Unreadable.self) { try SourceLevelsCoding.levels(from: broken) }
    }

    // MARK: A long source

    /// 250 paragraphs, a Markdown heading every 25.
    static let longText: String = {
        var lines: [String] = []
        for paragraph in 1...250 {
            if (paragraph - 1) % 25 == 0 { lines.append("## Section \((paragraph - 1) / 25 + 1)"); lines.append("") }
            lines.append("Paragraph \(paragraph) says one thing about the membrane potential of aging cells, plainly.")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }()

    @Test("A long text is cut into parts before headings, each within the request's paragraph cap")
    func longTextIsSplitAtHeadings() throws {
        let blocks = SourceLevelsText.blocks(of: Self.longText)
        #expect(SourceLevelsText.paragraphs(blocks).count == 250)
        let parts = try #require(SourceLevelsBuilder.parts(of: blocks, fixedCharacters: 1_000, inputBudget: nil))
        #expect(parts.count == 3)
        for part in parts {
            #expect(part.first?.kind == .heading, "each part starts at a heading")
            #expect(part.filter { $0.kind == .paragraph }.count <= SourceLevelsBuilder.maximumParagraphsPerRequest)
        }
        #expect(parts.flatMap { $0 } == blocks, "the parts joined are the text")

        // A small window cuts further; one with no room for a part refuses.
        let narrow = try #require(SourceLevelsBuilder.parts(of: blocks, fixedCharacters: 1_000, inputBudget: 7_000))
        #expect(narrow.count > 3)
        #expect(SourceLevelsBuilder.parts(of: blocks, fixedCharacters: 1_000, inputBudget: 2_000) == nil)
        // A short one is one request.
        #expect(SourceLevelsBuilder.parts(of: SourceLevelsText.blocks(of: Self.article), fixedCharacters: 1_000, inputBudget: 50_000)?.count == 1)
    }

    @Test("A long text is written in parts, joined in the text's order whatever order they finish in, then merged")
    func mapReduceKeepsOrder() async throws {
        let backend = CannedLevelsBackend()
        let levels = try await SourceLevelsBuilder.write(Self.source(Self.longText), system: "system", backend: backend)

        let calls = await backend.recorder.calls
        #expect(calls.filter { $0.contains("Write: part") }.count == 3)
        let merge = try #require(calls.last)
        #expect(merge.contains("Write: the whole source from its parts"))
        // Part 1 finished last, but the merge reads the parts in order.
        let summaries = merge.components(separatedBy: "\n").filter { $0.hasPrefix("Part ") }
        #expect(summaries == ["Part 1: Summary of part 1.", "Part 2: Summary of part 2.", "Part 3: Summary of part 3."])
        #expect(merge.contains("S1 Section 1 — Line of section 1."))
        #expect(merge.contains("S10 Section 10 — Line of section 10."))

        #expect(levels.gist == "Old cells hold a lower voltage.")
        #expect(levels.sections.count == 10)
        #expect(levels.sections.map(\.firstParagraph) == Array(stride(from: 1, through: 226, by: 25)))
        #expect(levels.paragraphCount == 250)
        #expect(levels.paragraph(250)?.line == "Line 250.")
        #expect(levels.findings.first?.sectionIndex == 1, "S2 is the second section")
        // The merge chose the terms and their order; each keeps the paragraph its part found it in.
        #expect(levels.terms.map(\.term) == ["Term 3", "Term 1"])
        #expect(levels.terms.first?.definition == "Sharper meaning 3.")
        #expect(levels.terms.last?.definition == "Meaning 1.", "a chosen term with no definition keeps its candidate's")
        #expect(levels.terms.last?.paragraphIndex == 1)
        #expect(levels.model == "canned")
    }

    @Test("A part that carries on the section before it adds no new section")
    func continuedSectionsMerge() {
        let first = SourceLevelsBuilder.WrittenPart(
            summary: "",
            sections: [.init(start: 1, title: "Methods", line: "a"), .init(start: 40, title: "Imaging", line: "b")],
            lines: [:],
            terms: []
        )
        let second = SourceLevelsBuilder.WrittenPart(
            summary: "",
            sections: [.init(start: 61, title: "imaging", line: "c"), .init(start: 70, title: "Results", line: "d")],
            lines: [:],
            terms: []
        )
        let merged = SourceLevelsBuilder.mergedSections([(1, first), (61, second)])
        #expect(merged.map(\.title) == ["Methods", "Imaging", "Results"])
        #expect(merged.map(\.start) == [1, 40, 70])
    }

    // MARK: Where the learner is

    static func pagedLevels() -> SourceLevels {
        func paragraph(_ index: Int) -> SourceLevels.Paragraph { .init(index: index, line: "Line \(index).", anchor: "Anchor \(index)") }
        return SourceLevels(
            sourceID: "src-1",
            contentSHA256: "sha",
            gist: "g",
            why: "w",
            findings: [],
            sections: [
                .init(title: "Introduction", line: "a", paragraphs: [1, 2, 3].map(paragraph)),
                .init(title: "Results", line: "b", paragraphs: [4, 5, 6].map(paragraph)),
                .init(title: "Discussion", line: "c", paragraphs: [7, 8].map(paragraph)),
            ],
            terms: [],
            model: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    @Test("The section under the page on screen: every section with a paragraph on it, else the last before it")
    func sectionUnderPage() {
        let levels = Self.pagedLevels()
        // Page 0: ¶1–2; page 1: ¶3–4 (Introduction ends, Results starts);
        // page 2 is a figure; page 3: ¶5–8.
        let pages = [1: 0, 2: 0, 3: 1, 4: 1, 5: 3, 6: 3, 7: 3, 8: 3]
        let onFirst = SourceLevelsFocus.of(.page(0), levels: levels, pages: pages, positions: [:])
        #expect(onFirst.sections == [0])
        #expect(onFirst.paragraphs == [1, 2])
        #expect(onFirst.primarySection == 0)

        let straddling = SourceLevelsFocus.of(.page(1), levels: levels, pages: pages, positions: [:])
        #expect(straddling.sections == [0, 1])
        #expect(straddling.paragraphs == [3, 4])

        let figure = SourceLevelsFocus.of(.page(2), levels: levels, pages: pages, positions: [:])
        #expect(figure.paragraphs == [4])
        #expect(figure.sections == [1])

        let last = SourceLevelsFocus.of(.page(3), levels: levels, pages: pages, positions: [:])
        #expect(last.sections == [1, 2])
        #expect(last.primarySection == 1)

        #expect(SourceLevelsFocus.of(.page(0), levels: levels, pages: [:], positions: [:]) == .none, "no page map, no focus")
        #expect(SourceLevelsFocus.of(nil, levels: levels, pages: pages, positions: [:]) == .none)
    }

    @Test("Down a web page, the paragraph whose start is the last one above the depth")
    func sectionUnderScrollDepth() {
        let levels = Self.pagedLevels()
        let positions = Dictionary(uniqueKeysWithValues: (1...8).map { ($0, Double($0 - 1) / 8) })
        let focus = SourceLevelsFocus.of(.fraction(0.5), levels: levels, pages: [:], positions: positions)
        #expect(focus.paragraphs == [5])
        #expect(focus.sections == [1])
        #expect(SourceLevelsFocus.of(.fraction(0), levels: levels, pages: [:], positions: positions).paragraphs == [1])
        #expect(SourceLevelsFocus.of(.fraction(1), levels: levels, pages: [:], positions: positions).sections == [2])
    }

    @Test("Each paragraph's page is found by its anchor in the PDF's page text, hyphenation and all; one not found reads on the page before")
    func pagesAreFoundByAnchor() {
        let pageTexts = [
            "Mitochondrial potential\nMitochondria make most of the cell\u{2019}s ATP by pump-\ning protons across their inner membrane, which builds a voltage.",
            "Figure 1",
            "Cells that lose this voltage are cleared by mitophagy, a quality control pathway that depends on PINK1.\nWe measured the membrane potential with TMRM in fibroblasts.",
        ]
        let anchors = [
            (number: 1, anchor: "Mitochondria make most of the cell's ATP by pumping protons across their inner"),
            (number: 2, anchor: "A sentence the cleaned text has that the PDF does not print anywhere at all"),
            (number: 3, anchor: "Cells that lose this voltage are cleared by mitophagy, a quality control pathway"),
            (number: 4, anchor: "We measured the membrane potential with TMRM in fibroblasts from young and old"),
        ]
        let pages = SourceLevelsPageLocator.pages(for: anchors, pageTexts: pageTexts)
        #expect(pages[1] == 0)
        #expect(pages[2] == 0, "not found: the page of the paragraph before")
        #expect(pages[3] == 2)
        #expect(pages[4] == 2, "a run of its opening words is enough")
    }

    // MARK: MCP

    @Test("get_source_levels answers at the depth asked for, with the text's opening words and the stale flag")
    func mcpPayloadDepths() throws {
        let levels = Self.pagedLevels()
        let gist = MCPDataStore.sourceLevelsPayload(sourceID: "src-1", title: "T", levels: levels, currentSHA256: "sha", depth: .gist, wroteNow: false)
        #expect(gist["has_levels"] as? Bool == true)
        #expect(gist["stale"] as? Bool == false)
        #expect(gist["sections"] == nil)

        let sections = MCPDataStore.sourceLevelsPayload(sourceID: "src-1", title: "T", levels: levels, currentSHA256: "other", depth: .sections, wroteNow: false)
        #expect(sections["stale"] as? Bool == true)
        let listed = try #require(sections["sections"] as? [[String: Any]])
        #expect(listed.count == 3)
        #expect(listed[1]["opens_with"] as? String == "Anchor 4")
        #expect(listed[1]["paragraphs"] == nil)

        let all = MCPDataStore.sourceLevelsPayload(sourceID: "src-1", title: "T", levels: levels, currentSHA256: "sha", depth: .all, wroteNow: true)
        let withParagraphs = try #require(all["sections"] as? [[String: Any]])
        #expect((withParagraphs[2]["paragraphs"] as? [[String: Any]])?.count == 2)
        #expect(all["written_now"] as? Bool == true)

        let none = MCPDataStore.sourceLevelsPayload(sourceID: "src-1", title: "T", levels: nil, currentSHA256: "sha", depth: .all, wroteNow: false)
        #expect(none["has_levels"] as? Bool == false)
    }

    @Test("get_source_levels is paid work that draws its popup and holds no store gate")
    func mcpRegistration() {
        #expect(MCPToolRegistry.paidWorkToolNames.contains("get_source_levels"))
        #expect(MCPToolActivityTitle.shownToolNames.contains("get_source_levels"))
        #expect(MCPToolActivityTitle.forTool("get_source_levels", arguments: ["write_if_missing": true])?.subject == .source)
        #expect(MCPToolRegistry.selfGatedToolNames.contains("get_source_levels"))
        let tool = MCPToolRegistry.shared.tools.first { $0.name == "get_source_levels" }
        #expect(tool?.inputSchema["required"] as? [String] == ["source_id"])
        #expect(tool?.inputSchema["anyOf"] == nil)
    }
}

// MARK: - A canned model

/// Answers a part with a section at each heading, a line for each of its
/// paragraphs and one term, finishing part 1 last; answers the merge with a
/// gist, a finding about S2 and two of the terms.
private struct CannedLevelsBackend: SourceLevelsBackend {
    actor Recorder {
        var calls: [String] = []
        func record(_ user: String) { calls.append(user) }
    }

    let recorder = Recorder()

    var modelLabel: String? { "canned" }

    func inputBudget(requestedMaxTokens: Int) -> Int? { nil }

    func write(system: String, user: String, maxTokens: Int, source: AIUsageSource) async throws -> String {
        if user.contains("Write: the whole source from its parts") {
            await recorder.record(user)
            return """
            {"gist": "Old cells hold a lower voltage.", "why": "It explains slow clearance.",
             "findings": [{"text": "The drop is largest late.", "section": 2}],
             "terms": [{"term": "term 3", "definition": "Sharper meaning 3."}, {"term": "Term 1", "definition": ""}]}
            """
        }
        guard let partLine = user.components(separatedBy: "\n").first(where: { $0.hasPrefix("Write: part ") }),
              let part = Int(partLine.dropFirst("Write: part ".count).prefix { $0.isNumber }) else {
            throw SourceLevelsError.unreadableAnswer("unexpected request")
        }
        if part == 1 { try await Task.sleep(for: .milliseconds(80)) }
        await recorder.record(user)
        // The paragraphs and headings this part holds, from its text.
        var sections: [String] = []
        var paragraphs: [String] = []
        var pendingHeading: String?
        for line in user.components(separatedBy: "\n") {
            if line.hasPrefix("# ") {
                pendingHeading = String(line.dropFirst(2))
            } else if line.hasPrefix("¶"), let number = Int(line.dropFirst().prefix { $0.isNumber }) {
                if let heading = pendingHeading {
                    let index = heading.split(separator: " ").last.map(String.init) ?? ""
                    sections.append("{\"start\": \(number), \"title\": \"\(heading)\", \"line\": \"Line of section \(index).\"}")
                    pendingHeading = nil
                }
                paragraphs.append("{\"n\": \(number), \"line\": \"Line \(number).\"}")
            }
        }
        let firstParagraph = paragraphs.first.flatMap { entry in Int(entry.drop { !$0.isNumber }.prefix { $0.isNumber }) } ?? 1
        return """
        {"summary": "Summary of part \(part).", "sections": [\(sections.joined(separator: ","))],
         "paragraphs": [\(paragraphs.joined(separator: ","))],
         "terms": [{"term": "Term \(part)", "definition": "Meaning \(part).", "paragraph": \(firstParagraph)}]}
        """
    }
}
