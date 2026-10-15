import Foundation
import Testing
@testable import ForeverLM

/// A passage selected in the reader may be TeX; the composer's chip shows it
/// folded into readable text, while prose without TeX passes through unchanged.
@Suite("Readable math preview")
struct ReadableMathPreviewTests {
    @Test("A displayed fraction with a subscripted, superscripted mathrm reads as one line")
    func protonMotiveForce() {
        let passage = "$$\\frac{\\Delta G_{\\mathrm{H^+}}}{F} = \\Delta\\psi - \\frac{2.3RT}{F}\\Delta\\mathrm{pH}$$"
        #expect(passage.foldingTeXForPreview() == "ΔG_H⁺/F = Δψ - 2.3RT/FΔpH")
    }

    @Test("Inline delimiters vanish and the prose around them survives")
    func inlineMathInProse() {
        #expect("The force \\(\\Delta p\\) is about 200 mV.".foldingTeXForPreview() == "The force Δp is about 200 mV.")
        #expect("\\[ E = mc^2 \\]".foldingTeXForPreview() == "E = mc²")
    }

    @Test("A passage quoted from a reply — an isotope with a doubly braced mathrm — reads as the reply showed it")
    func quotedIsotopePassage() {
        // What "More details" on a selection over KaTeX output hands back: the
        // equation's source, delimiters and all, in the prose around it.
        let passage = "\\(^{23}\\mathrm{{Na}}\\) triple-quantum-filtered NMR."
        #expect(passage.foldingTeXForPreview() == "²³Na triple-quantum-filtered NMR.")
    }

    @Test("Scripts become Unicode when every character has a form, and keep their marker otherwise")
    func scripts() {
        #expect("$x_{i}^{2} + \\alpha_1$".foldingTeXForPreview() == "xᵢ² + α₁")
        #expect("\\ln K_{eq} = -\\frac{\\Delta G^\\circ}{RT}".foldingTeXForPreview() == "ln K_eq = -ΔG°/RT")
    }

    @Test("A fraction's part is parenthesised only when it would bleed into the slash")
    func fractions() {
        #expect("$\\frac{a+b}{2}$".foldingTeXForPreview() == "(a+b)/2")
        #expect("$\\tfrac{1}{2}O_2$".foldingTeXForPreview() == "1/2O₂")
    }

    @Test("Relations and arrows are spaced; environments, sizing and wrappers drop away")
    func operatorsAndWrappers() {
        #expect("NADH + H^+ \\rightarrow NAD^+ + H_2O".foldingTeXForPreview() == "NADH + H⁺ → NAD⁺ + H₂O")
        #expect("\\begin{equation} J = -D \\nabla c \\end{equation}".foldingTeXForPreview() == "J = -D ∇c")
        #expect("\\left( \\frac{\\partial G}{\\partial n_i} \\right)_{T,P}".foldingTeXForPreview() == "( ∂G/∂nᵢ )_T,P")
        #expect("$\\sqrt{n} \\approx \\text{about } 3$".foldingTeXForPreview() == "√n ≈ about 3")
    }

    @Test("Prose without TeX is returned as it was, dollar signs and all")
    func proseUntouched() {
        let prose = "Plain prose about $5 and 10% growth, with a backslash\\ path."
        #expect(prose.foldingTeXForPreview() == prose)
        #expect(ReadableMath.containsTeX(prose) == false)
    }
}

/// A scholarly catalog hands a title over with its inline markup, and every
/// surface draws a title as text, so the library keeps it as the text it draws.
@Suite("Inline title markup")
struct InlineTitleMarkupTests {
    @Test("The titles a chat's Sources list showed as tags read as their formulas")
    func catalogTitles() {
        #expect("Respiratory chain linked H<sub>2</sub>O<sub>2</sub> production in pigeon heart mitochondria".foldingInlineMarkup()
            == "Respiratory chain linked H₂O₂ production in pigeon heart mitochondria")
        #expect("Mitochondrial ATP‐sensitive K<sup>+</sup> channel opening decreases reactive oxygen species generation".foldingInlineMarkup()
            == "Mitochondrial ATP‐sensitive K⁺ channel opening decreases reactive oxygen species generation")
        #expect("Differential expression of voltage‐activated Na<sup>+</sup> currents".foldingInlineMarkup()
            == "Differential expression of voltage‐activated Na⁺ currents")
        #expect("Cytochrome <i>c</i> in the apoptotic and antioxidant cascades".foldingInlineMarkup()
            == "Cytochrome c in the apoptotic and antioxidant cascades")
    }

    @Test("A script is Unicode when every character has a form, and reads inline otherwise")
    func scripts() {
        #expect("Ca<sup>2+</sup> uptake".foldingInlineMarkup() == "Ca²⁺ uptake")
        #expect("V<sub>max</sub> and K<sub>m</sub>".foldingInlineMarkup() == "Vₘₐₓ and Kₘ")
        #expect("<sup>31</sup>P-NMR of [Ca<sup>2+</sup>]<sub>i</sub>".foldingInlineMarkup() == "³¹P-NMR of [Ca²⁺]ᵢ")
        #expect("Cl<sup>–</sup> channels".foldingInlineMarkup() == "Cl⁻ channels")
        #expect("Mitochondrial K<sub>ATP</sub> channels".foldingInlineMarkup() == "Mitochondrial KATP channels")
        #expect("Surf1<sup>−/−</sup> mice".foldingInlineMarkup() == "Surf1−/− mice")
        #expect("O<sub>2</sub><sup>•−</sup> production".foldingInlineMarkup() == "O₂•− production")
        // Scopus's subscript, a namespaced JATS tag, and HTML's case.
        #expect("CO<inf>2</inf> fixation".foldingInlineMarkup() == "CO₂ fixation")
        #expect("NAD<jats:sup>+</jats:sup> repletion".foldingInlineMarkup() == "NAD⁺ repletion")
        #expect("H<SUB>2</SUB>S signalling".foldingInlineMarkup() == "H₂S signalling")
    }

    @Test("Styling keeps its words, attributes and all, and a footnote marker goes")
    func styling() {
        #expect("The <i>Drosophila <b>Hox</b></i> genes".foldingInlineMarkup() == "The Drosophila Hox genes")
        #expect("<scp>DHDDS</scp>‐related juvenile parkinsonism".foldingInlineMarkup() == "DHDDS‐related juvenile parkinsonism")
        #expect("A <span class=\"x\" data-y='a>b'>styled</span> word".foldingInlineMarkup() == "A styled word")
        #expect("Mitophagy in ageing<xref ref-type=\"fn\" rid=\"fn1\">*</xref>".foldingInlineMarkup() == "Mitophagy in ageing")
    }

    @Test("Only a known tag closed by its own end tag is markup; every other `<` is text")
    func textThatIsNotMarkup() {
        for text in [
            "Robin <> Zara - Weekly",
            "p < 0.05 in <10 nm particles",
            "The <dialog> element",
            "When to use <em> vs <i>",
            "a <b>bold claim",
            "stray </sub> close",
            "<subtitle>kept</subtitle>",
        ] {
            #expect(text.foldingInlineMarkup() == text)
        }
        // Crossed tags: the pair that closes is markup, the one it cut is text.
        #expect("crossed <i>a <b>b</i> c</b>".foldingInlineMarkup() == "crossed a <b>b c</b>")
    }

    @Test("MathML reads as the formula it draws, the whitespace between its elements ignored")
    func mathML() {
        let peroxide = "Formation of <mml:math xmlns:mml=\"http://www.w3.org/1998/Math/MathML\"><mml:msub><mml:mi>H</mml:mi><mml:mn>2</mml:mn></mml:msub><mml:msub><mml:mi mathvariant=\"normal\">O</mml:mi><mml:mn>2</mml:mn></mml:msub></mml:math> in mitochondria"
        #expect(peroxide.foldingInlineMarkup() == "Formation of H₂O₂ in mitochondria")
        let laidOut = """
            The <mml:math>
              <mml:mrow>
                <mml:msup>
                  <mml:mi>Ca</mml:mi>
                  <mml:mrow><mml:mn>2</mml:mn><mml:mo>+</mml:mo></mml:mrow>
                </mml:msup>
              </mml:mrow>
            </mml:math> wave
            """
        #expect(laidOut.foldingInlineMarkup() == "The Ca²⁺ wave")
        #expect("<mml:math><mml:mfrac><mml:mrow><mml:mi>a</mml:mi><mml:mo>+</mml:mo><mml:mi>b</mml:mi></mml:mrow><mml:mn>2</mml:mn></mml:mfrac></mml:math>".foldingInlineMarkup() == "(a+b)/2")
        #expect("<mml:math><mml:mmultiscripts><mml:mi>C</mml:mi><mml:mprescripts/><mml:none/><mml:mn>14</mml:mn></mml:mmultiscripts></mml:math> dating".foldingInlineMarkup() == "¹⁴C dating")
        #expect("<mml:math><mml:msubsup><mml:mi>x</mml:mi><mml:mi>i</mml:mi><mml:mn>2</mml:mn></mml:msubsup></mml:math>".foldingInlineMarkup() == "xᵢ²")
        #expect("<mml:math><mml:msqrt><mml:mi>s</mml:mi></mml:msqrt></mml:math> scaling".foldingInlineMarkup() == "√s scaling")
        // An annotation repeats the formula as TeX; drawing it too would say it twice.
        #expect("<mml:math><mml:semantics><mml:msub><mml:mi>T</mml:mi><mml:mi>c</mml:mi></mml:msub><mml:annotation encoding=\"application/x-tex\">T_c</mml:annotation></mml:semantics></mml:math> superconductors".foldingInlineMarkup() == "Tc superconductors")
    }

    @Test("A JATS formula reads its MathML first, and TeX alone through the TeX fold")
    func jatsFormulas() {
        #expect("<inline-formula><alternatives><tex-math>$H_2$</tex-math><mml:math><mml:msub><mml:mi>H</mml:mi><mml:mn>2</mml:mn></mml:msub></mml:math></alternatives></inline-formula> evolution".foldingInlineMarkup() == "H₂ evolution")
        #expect("<inline-formula><tex-math id=\"M1\">\\documentclass[12pt]{minimal}\\usepackage{amsmath}\\begin{document}$$\\alpha$$\\end{document}</tex-math></inline-formula>-ketoglutarate".foldingInlineMarkup() == "α-ketoglutarate")
    }

    @Test("A source's title is decoded, then folded, however the source is made")
    func sourceTitles() throws {
        // Escaped markup is markup once decoded; an escaped `<` in prose stays text.
        #expect("H&lt;sub&gt;2&lt;/sub&gt;O &amp; ions".decodingTitleMarkup() == "H₂O & ions")
        #expect("p &lt; 0.05".decodingTitleMarkup() == "p < 0.05")

        var paper = StudioArticle(
            url: "https://doi.org/10.1016/0014-5793(71)80459-3",
            title: "Respiratory chain linked H<sub>2</sub>O<sub>2</sub> production",
            sourceType: .paper
        )
        #expect(paper.title == "Respiratory chain linked H₂O₂ production")
        paper.title = "Mitochondrial ATP‐sensitive K<sup>+</sup> channel"
        #expect(paper.title == "Mitochondrial ATP‐sensitive K⁺ channel")

        // The path every stored row and every CloudKit payload takes.
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(paper)) as? [String: Any])
        object["title"] = "Voltage‐activated Na<sup>+</sup> currents"
        let decoded = try JSONDecoder().decode(StudioArticle.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.title == "Voltage‐activated Na⁺ currents")

        #expect(VideoCitedPaper(sourceID: "lecture", title: "Cytochrome <i>c</i> release").title == "Cytochrome c release")
        #expect(PaperService.CrossrefMetadata(authorsDisplay: nil, journal: nil, year: nil, title: "K<sup>+</sup> channels").title == "K⁺ channels")
        #expect(SlideCitationService.ResolvedPaper(doi: "10.1/x", title: "H<sub>2</sub>S", journal: nil, year: nil).title == "H₂S")
    }

    @Test("Typography is not identity: markup, Unicode scripts and plain digits name one title")
    func titleIdentity() {
        let printed = "Respiratory chain linked H2O2 production in pigeon heart mitochondria"
        let catalog = "Respiratory chain linked H<sub>2</sub>O<sub>2</sub> production in pigeon heart mitochondria"
        let library = "Respiratory chain linked H₂O₂ production in pigeon heart mitochondria"
        #expect(SlideCitationService.titlesMatch(printed, catalog))
        #expect(SlideCitationService.titlesMatch(printed, library))
        #expect(StudioViewModel.normalizedPaperTitle(catalog) == StudioViewModel.normalizedPaperTitle(library))
        #expect(StudioViewModel.normalizedPaperTitle(printed) == StudioViewModel.normalizedPaperTitle(library))
        #expect(VideoCitedPaper.normalizeTitle(printed) == VideoCitedPaper.normalizeTitle(library))
        #expect(PDFReferenceEntries.entry(
            "2. Loschen G, Flohé L, Chance B. Respiratory chain linked H2O2 production in pigeon heart mitochondria. FEBS Lett. 1971;18:261–264.",
            printsTitle: library
        ))
        // Different words are still a different title.
        #expect(!SlideCitationService.titlesMatch("Respiratory chain linked H2O2 production", library))
    }

    @Test("A card's math spans fold in place and its prose and line breaks stay as written")
    func cardMathSpans() {
        let back = "Reverse rates follow the forward rates: \\(k_{-1} = k_1 e^{FE/RT}\\), so the fit yields \\(E_m\\) and \\(\\Delta\\psi_m\\).\n\nSecond line, $5 and $10."
        #expect(back.foldingMathSpans() == "Reverse rates follow the forward rates: k₋₁ = k₁ e^(FE/RT), so the fit yields Eₘ and Δψₘ.\n\nSecond line, $5 and $10.")
        #expect("Plain text, 50% of it.".foldingMathSpans() == "Plain text, 50% of it.")
        #expect("A \\(Δ never closes".foldingMathSpans() == "A \\(Δ never closes")
        #expect("$$\\frac{a}{b}$$ then \\[x^2\\]".foldingMathSpans() == "a/b then x²")
    }
}
