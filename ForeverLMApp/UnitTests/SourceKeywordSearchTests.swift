import Testing
@testable import ForeverLM

@Suite("Source Keyword Search")
struct SourceKeywordSearchTests {

    @Test("A shorter stem finds the longer spelling, and not the reverse")
    func substringIsTheWholeRule() {
        let body = "Chemical uncouplers such as FCCP lower the membrane potential."
        #expect(SourceKeywordSearch.counts(of: ["uncoupler"], in: body).first?.count == 1)
        #expect(SourceKeywordSearch.counts(of: ["uncouplers"], in: body).isEmpty == false)
        // The learner asking for the longer spelling means it: a body that only
        // says the singular is not a match for the plural.
        let singular = "A chemical uncoupler lowers the membrane potential."
        #expect(SourceKeywordSearch.counts(of: ["uncouplers"], in: singular).isEmpty)
    }

    @Test("Case is ignored and every occurrence is counted")
    func countsEveryOccurrence() {
        let body = "Uncouplers matter. An uncoupler is not an inhibitor. UNCOUPLER dosing is the risk."
        let counts = SourceKeywordSearch.counts(of: ["uncoupler"], in: body)
        #expect(counts.count == 1)
        #expect(counts.first?.count == 3)
    }

    @Test("A keyword the text does not contain is not reported at all")
    func absentKeywordsAreDropped() {
        let counts = SourceKeywordSearch.counts(of: ["BAM15", "rotenone"], in: "BAM15 is a mitochondrial uncoupler.")
        #expect(counts.map(\.keyword) == ["BAM15"])
    }

    @Test("The count ceiling bounds a keyword that saturates a long text")
    func countCeilingBoundsTheScan() {
        let body = String(repeating: "leak ", count: 400)
        let counts = SourceKeywordSearch.counts(of: ["leak"], in: body, countCeiling: 25)
        #expect(counts.first?.count == 25)
    }

    @Test("Snippets show the keyword in place, cut from the original text")
    func snippetsQuoteTheOriginal() {
        let body = "Padding. " + String(repeating: "context ", count: 40)
            + "The paper treats UNCOUPLERS as a drug class. "
            + String(repeating: "tail ", count: 40)
        let snippets = SourceKeywordSearch.snippets(for: ["uncouplers"], in: body, limit: 1)
        #expect(snippets.count == 1)
        // Original casing survives, because the match is located in the
        // original string rather than in a lowercased copy.
        #expect(snippets[0].contains("UNCOUPLERS"))
        #expect(snippets[0].hasPrefix("…"))
        #expect(snippets[0].hasSuffix("…"))
    }

    @Test("A match at the very start or end is not elided")
    func snippetEdgesAreHonest() {
        let snippets = SourceKeywordSearch.snippets(for: ["DNP"], in: "DNP is the classic case.", limit: 2)
        #expect(snippets == ["DNP is the classic case."])
    }

    @Test("Two keywords in one passage produce one snippet, not two")
    func nearbyMatchesCollapse() {
        let body = "FCCP and DNP appear in the same sentence about proton leak."
        let snippets = SourceKeywordSearch.snippets(for: ["FCCP", "DNP"], in: body, limit: 4)
        #expect(snippets.count == 1)
    }

    @Test("Distant matches produce separate snippets, in the order they occur")
    func distantMatchesStaySeparate() {
        let filler = String(repeating: "filler ", count: 60)
        let body = "FCCP opens the section. " + filler + "DNP closes it."
        let snippets = SourceKeywordSearch.snippets(for: ["DNP", "FCCP"], in: body, limit: 4, radius: 20)
        #expect(snippets.count == 2)
        #expect(snippets[0].contains("FCCP"))
        #expect(snippets[1].contains("DNP"))
    }

    @Test("Keywords are trimmed and de-duplicated case-insensitively")
    func normalizationKeepsOneOfEach() {
        let terms = SourceKeywordSearch.normalized(["  uncoupler ", "UNCOUPLER", "", "   ", "UCP1"])
        #expect(terms == ["uncoupler", "UCP1"])
    }

    @Test("A single-character keyword is kept, because a symbol is a real search")
    func shortKeywordsSurvive() {
        #expect(SourceKeywordSearch.normalized(["p"]) == ["p"])
        #expect(SourceKeywordSearch.counts(of: ["p53"], in: "p53 signalling").first?.count == 1)
    }

    @Test("A keyword that is not ASCII is found in every case the text writes it")
    func unicodeCaseIsIgnored() {
        // Bioenergetics Chapter 4 wrote Δψ 58 times, and the single keyword
        // "Δψ" found nothing (2026-09-26).
        let body = "The protonmotive force Δp has two parts, Δψ and ΔpH. Across the membrane ΔΨ reaches 150 mV; δψ is rare."
        #expect(SourceKeywordSearch.counts(of: ["Δψ"], in: body).first?.count == 3)
        #expect(SourceKeywordSearch.counts(of: ["δψ"], in: body).first?.count == 3)
        #expect(SourceKeywordSearch.counts(of: ["ΔpH"], in: body).first?.count == 1)
        #expect(SourceKeywordSearch.counts(of: ["Δp"], in: body).first?.count == 2)
        #expect(SourceKeywordSearch.counts(of: ["µM"], in: "10 μM and 5 µM").first?.count == 2)
        #expect(SourceKeywordSearch.counts(of: ["é"], in: "Café, Cafe\u{301} and cafe").first?.count == 2)
    }

    @Test("A ligature or ß in the text is the letters it folds to")
    func textSideFoldsCount() {
        // PDFs extract "ff" as U+FB00; 91 sources in one library spelled it no
        // other way, so "Differential" has to find "Diﬀerential".
        #expect(SourceKeywordSearch.counts(of: ["Differential Operators"], in: "Diﬀerential Operators, previously").first?.count == 1)
        #expect(SourceKeywordSearch.counts(of: ["effect"], in: "a treatment eﬀect and an effect").first?.count == 2)
        #expect(SourceKeywordSearch.counts(of: ["sufficiency"], in: "Exponential Families and Suﬃciency").first?.count == 1)
        #expect(SourceKeywordSearch.counts(of: ["strasse"], in: "Die Straße").first?.count == 1)
    }

    @Test("A keyword whose fold is longer matches only those letters, not the first one and anything")
    func foldedKeywordsDoNotOvermatch() {
        // Unfolded, Foundation matched "ß" against "s" and any next character
        // and "ﬁ" against "f" and any next character: ×500 in every paper.
        #expect(SourceKeywordSearch.counts(of: ["ß"], in: "modulator of mitochondrial sis sa").isEmpty)
        #expect(SourceKeywordSearch.counts(of: ["Straße"], in: "Die Straße, the STRASSE, a Strasxe.").first?.count == 2)
        #expect(SourceKeywordSearch.counts(of: ["ﬁ"], in: "modulator of fish and ﬁsh").first?.count == 2)
        #expect(SourceKeywordSearch.counts(of: ["ﬀ"], in: "an office of affine fluff").first?.count == 3)
    }

    @Test("Keywords that match the same text are one keyword")
    func normalizationFoldsLikeTheSearch() {
        let terms = SourceKeywordSearch.normalized(["µM", "μM", "Straße", "STRASSE", "Δψ", "δψ", "Café", "Cafe\u{301}"])
        #expect(terms == ["µM", "Straße", "Δψ", "Café"])
    }

    @Test("The screen keeps every text the count finds the keyword in")
    func screenIsNeverStricterThanTheCount() {
        let cases: [(String, String)] = [
            ("Δψ", "the ΔΨ collapses"), ("δψ", "Δψ"), ("ΔpH", "a ΔPH gradient"), ("µM", "10 μM"),
            ("effect", "treatment eﬀect"), ("Differential Operators", "Diﬀerential Operators"),
            ("sufficiency", "Suﬃciency"), ("office", "o\u{FB03}ce"), ("strasse", "Straße"), ("Straße", "STRASSE"),
            ("ss", "\u{1E9E}"), ("st", "\u{FB06}"), ("Km", "300 \u{212A}m"), ("ROS", "ro\u{17F}"),
            ("é", "Cafe\u{301}"), ("Miesenböck", "Miesenbo\u{308}ck"), ("αι", "\u{1FB3}"), ("αι", "\u{3B1}\u{345}"),
            ("ʼn", "\u{149}"), ("aʾ", "\u{1E9A}"), ("i\u{307}", "\u{130}"), ("a;b", "a\u{37E}b"), ("x`y", "x\u{1FEF}y"),
            ("Ω", "10 k\u{2126}"), ("uncoupler", "UNCOUPLERS"),
        ]
        for (keyword, text) in cases {
            #expect(!SourceKeywordSearch.counts(of: [keyword], in: text).isEmpty, "count finds \(keyword)")
            #expect(Self.screenKeeps(keyword, text), "screen keeps \(keyword) in \(text)")
        }

        // And across generated texts built from the characters that fold in
        // surprising ways: whenever the count finds the keyword, the screen
        // kept the text.
        var random = SeededRandom(seed: 20_260_926)
        let pieces = ["a", "e", "f", "i", "k", "l", "n", "s", "t", "A", "F", "K", "S", " ", ";", "`", "\n", "\r\n",
                      "ß", "ẞ", "ſ", "\u{212A}", "ﬀ", "ﬁ", "ﬂ", "ﬃ", "ﬄ", "ﬅ", "ﬆ", "ŉ", "ʼ", "ẚ", "ʾ", "\u{37E}", "\u{1FEF}",
                      "δ", "Δ", "ψ", "Ψ", "σ", "Σ", "ς", "µ", "μ", "Μ", "é", "É", "e\u{301}", "\u{301}", "ö", "ᾳ", "\u{345}",
                      "α", "ι", "İ", "\u{307}", "\u{2126}", "ω", "\u{AD}", "\u{200D}", "\u{FE0F}", "’", "\u{0}"]
        func text(_ length: Int) -> String { (0..<length).map { _ in pieces[random.next(below: pieces.count)] }.joined() }
        var found = 0
        for _ in 0..<3_000 {
            let body = text(1 + random.next(below: 20))
            let characters = Array(body)
            let start = random.next(below: characters.count)
            var keyword = String(characters[start..<min(characters.count, start + 1 + random.next(below: 4))])
            if random.next(below: 2) == 0 { keyword = keyword.uppercased() }
            keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyword.isEmpty, !SourceKeywordSearch.counts(of: [keyword], in: body).isEmpty else { continue }
            found += 1
            #expect(Self.screenKeeps(keyword, body), "screen keeps \(keyword.debugDescription) in \(body.debugDescription)")
        }
        #expect(found > 1_000)
    }

    @Test("The screen rules out a text that cannot hold the keyword")
    func screenRulesTextsOut() {
        #expect(!Self.screenKeeps("uncoupler", "Rotenone inhibits complex I."))
        #expect(!Self.screenKeeps("Δψ", "The membrane potential collapses."))
        #expect(!Self.screenKeeps("Δψ", "Δp alone"))
        // A ligature is read as its letters, and these letters are not "effect".
        #expect(!Self.screenKeeps("effect", "a diﬀerent result"))
        #expect(!Self.screenKeeps("µM", "5 mM"))
        #expect(!Self.screenKeeps("é", "plain text"))
    }

    @Test("The byte search finds a run anywhere and in any ASCII case")
    func byteSearchCoversEveryPosition() {
        func contains(_ run: String, _ text: String) -> Bool {
            var text = text
            return text.withUTF8 { SourceKeywordSearch.containsIgnoringASCIICase(Array(run.utf8), in: UnsafeRawBufferPointer($0)) }
        }
        #expect(contains("fccp", "FCCP opens"))
        #expect(contains("fccp", "opens with fCcP"))
        #expect(contains("zq", "zq"))
        #expect(contains("p53", "the P53 pathway"))
        #expect(contains("a-b", "x A-B y"))
        #expect(!contains("fccp", "FCC"))
        #expect(!contains("fccp", "F CCP"))
        #expect(!contains("ab", ""))
        // Bytes past an embedded NUL are text too.
        #expect(contains("tail", "head\u{0}tail"))
    }

    @Test("The hazard table is every character whose fold spells ASCII")
    func hazardTableMatchesUnicode() {
        var derived: [UInt32: String] = [:]
        for value in UInt32(0x80)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            switch scalar.properties.generalCategory {
            case .unassigned, .privateUse, .surrogate: continue
            default: break
            }
            let folded = SourceKeywordSearch.canonicalFold(String(Character(scalar)))
            if folded.contains(where: { $0.unicodeScalars.allSatisfy(\.isASCII) }) {
                derived[value] = folded
            }
        }
        #expect(derived == SourceKeywordSearch.hazards)
    }

    private static func screenKeeps(_ keyword: String, _ text: String) -> Bool {
        var screen = SourceKeywordSearch.Screen([SourceKeywordSearch.Keyword(keyword)])
        return screen.mayContain(text)[0]
    }

    /// A fixed sequence, so a failure names the same case on every run.
    private struct SeededRandom {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next(below bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    @Test("Mentions across keywords total up, and the matched list names them")
    func matchSummarizesItsEvidence() {
        let match = SourceKeywordMatch(
            sourceID: "src_1",
            title: "Mitochondria-Targeted Drugs",
            sourceType: "paper",
            author: nil,
            groupName: nil,
            keywordCounts: [
                SourceKeywordSearch.KeywordCount(keyword: "uncoupler", count: 4),
                SourceKeywordSearch.KeywordCount(keyword: "FCCP", count: 2),
            ],
            snippets: []
        )
        #expect(match.totalMentions == 6)
        #expect(match.matchedKeywords == ["uncoupler", "FCCP"])
    }
}
