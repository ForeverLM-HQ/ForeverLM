import AppKit
import PDFKit
import Testing
@testable import ForeverLM

@Suite("Book Chapter Boundary Validation")
struct BookChapterBoundaryValidationTests {
    @Test("PDF TOC extraction keeps printed chapter pages separate from PDF page index")
    func pdfTOCExtractionKeepsPrintedPagesSeparateFromPDFPageIndex() {
        let entries = StudioViewModel.extractPDFTOCChapterEntries([
            """
            Table of Contents
            Chapter 1 – Quantum Theory & The New Observables ....................................... 1
            Chapter 2 – Quantum Electrodynamics: Lighting Up Life ................................... 4
            Part II: Coherent Quantum Effects in Biology
            Chapter 18 – Morphogenetic Integration & Immunodynamics ........................... 56
            References
            """
        ])

        #expect(entries.map(\.title) == [
            "Chapter 1 – Quantum Theory & The New Observables",
            "Chapter 2 – Quantum Electrodynamics: Lighting Up Life",
            "Chapter 18 – Morphogenetic Integration & Immunodynamics"
        ])
        #expect(entries.map(\.printedPage) == [1, 4, 56])
    }

    @Test("PDF chapter heading detection ignores TOC entries and keeps mid-page headings")
    func pdfChapterHeadingDetectionIgnoresTOCEntriesAndKeepsMidPageHeadings() {
        let detected = StudioViewModel.detectPDFChapterHeadingEntries(pageTexts: [
            """
            Table of Contents
            Chapter 1 – Quantum Theory & The New Observables ....................................... 1
            Chapter 2 – Quantum Electrodynamics: Lighting Up Life ................................... 4
            """,
            """
            Dr. N. S. Babcock Physical Principles of Quantum Biology
            The preface ends on this page after several paragraphs.
            Chapter 1 – Quantum Theory and the New Observables
            Modern physics begins with the discovery of new observables.
            """,
            """
            Dr. N. S. Babcock Physical Principles of Quantum Biology
            Some closing text from the previous chapter appears first.
            Chapter 2 – Quantum Electrodynamics: Lighting Up Life
            Quantum electrodynamics enters biology during electron transfer.
            """,
            """
            Dr. N. S. Babcock Physical Principles of Quantum Biology
            More body text appears before this next chapter boundary.
            Chapter 18 – Morphogenetic Integration & Immunodynamics
            Living tissues coordinate immune and morphogenetic processes.
            """
        ])

        #expect(detected.map(\.pageIndex) == [1, 2, 3])
        #expect(detected.map(\.title) == [
            "Chapter 1 – Quantum Theory and the New Observables",
            "Chapter 2 – Quantum Electrodynamics: Lighting Up Life",
            "Chapter 18 – Morphogenetic Integration & Immunodynamics"
        ])
    }

    @Test("Validated chapter ranges may stop the final chapter before back matter")
    func validatedRangesStopBeforeBackMatter() throws {
        let ranges = try StudioViewModel.validatePDFChapterRanges(
            [
                (title: "1) Foundations", pageIndex: 2, endPageIndexExclusive: 8),
                (title: "2) Applications", pageIndex: 8, endPageIndexExclusive: 14)
            ],
            pageCount: 20
        )

        #expect(ranges.map(\.pageIndex) == [2, 8])
        #expect(ranges.map(\.endPageIndexExclusive) == [8, 14])
    }

    @Test("Validated chapter ranges reject gaps and overlaps")
    func validatedRangesRejectGapsAndOverlaps() {
        for invalidStart in [7, 9] {
            do {
                _ = try StudioViewModel.validatePDFChapterRanges(
                    [
                        (title: "1) Foundations", pageIndex: 2, endPageIndexExclusive: 8),
                        (title: "2) Applications", pageIndex: invalidStart, endPageIndexExclusive: 14)
                    ],
                    pageCount: 20
                )
                Issue.record("Expected a chapter range gap or overlap to fail")
            } catch SourceError.bookChapterBoundaryMismatch(let message) {
                #expect(message.contains("gap or overlap"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("Validated chapter ranges reject an end beyond the PDF")
    func validatedRangesRejectEndBeyondPDF() {
        do {
            _ = try StudioViewModel.validatePDFChapterRanges(
                [(title: "1) Foundations", pageIndex: 2, endPageIndexExclusive: 21)],
                pageCount: 20
            )
            Issue.record("Expected an out-of-bounds chapter range to fail")
        } catch SourceError.bookChapterBoundaryMismatch(let message) {
            #expect(message.contains("outside the PDF"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - AI chapter list shape

    @Test("The 130-entry Molecular Biology of the Cell split of 2026-08-24 is refused")
    func refusesFragmentedContentsListing() {
        let chapters = Self.molecularBiologyOfTheCellContentsListing
        #expect(chapters.count == 130)

        let issue = StudioViewModel.bookChapterSelectionIssue(chapters: chapters, pageCount: 1532)

        #expect(issue?.contains("130 chapters") == true)
        #expect(issue?.contains("median length") == true)
        #expect(issue?.contains("1532-page book") == true)
    }

    @Test("The 24 real chapters of Molecular Biology of the Cell import")
    func acceptsHealthyChapterList() {
        let issue = StudioViewModel.bookChapterSelectionIssue(
            chapters: Self.molecularBiologyOfTheCellChapters,
            pageCount: 1532
        )

        #expect(issue == nil)
    }

    @Test("A section word as a chapter title is refused")
    func refusesSectionHeadingTitles() {
        let issue = StudioViewModel.bookChapterSelectionIssue(
            chapters: [
                (title: "1) Cells, Genomes, and the Diversity of Life", pageIndex: 40),
                (title: "Summary", pageIndex: 84),
                (title: "Problems", pageIndex: 86),
                (title: "2) Cell Chemistry and Bioenergetics", pageIndex: 88),
                (title: "References", pageIndex: 150)
            ],
            pageCount: 400
        )

        #expect(issue?.contains("3 chapters are titled after a section heading") == true)
        #expect(issue?.contains("\u{201C}Summary\u{201D}") == true)
        #expect(issue?.contains("\u{201C}Problems\u{201D}") == true)
        #expect(issue?.contains("\u{201C}References\u{201D}") == true)
    }

    @Test("Section heading detection strips numbering and leaves real chapter names alone")
    func sectionHeadingDetection() {
        #expect(StudioViewModel.isBookSectionHeadingTitle("Summary"))
        #expect(StudioViewModel.isBookSectionHeadingTitle("  PROBLEMS "))
        #expect(StudioViewModel.isBookSectionHeadingTitle("3) References"))
        #expect(StudioViewModel.isBookSectionHeadingTitle("Chapter 12: Summary"))
        #expect(StudioViewModel.isBookSectionHeadingTitle("Further Reading."))
        #expect(!StudioViewModel.isBookSectionHeadingTitle("Introduction"))
        #expect(!StudioViewModel.isBookSectionHeadingTitle("Preface"))
        #expect(!StudioViewModel.isBookSectionHeadingTitle("Epilogue: quantum life"))
        #expect(!StudioViewModel.isBookSectionHeadingTitle("A Summary of the Evidence"))
        #expect(!StudioViewModel.isBookSectionHeadingTitle("1984"))
    }

    @Test("A title that runs on into the table of contents is refused")
    func refusesTableOfContentsRunTitles() {
        let issue = StudioViewModel.bookChapterSelectionIssue(
            chapters: [
                (title: "10) Membrane Structure", pageIndex: 560),
                (
                    title: "11) Small-Molecule Transport and Electrical Properties of Membranes Chapter 12 Intracellular Organization and Protein Sorting Chapter 13 Intracellular Membrane Traffic",
                    pageIndex: 600
                ),
                (title: "16) The Cytoskeleton", pageIndex: 970)
            ],
            pageCount: 1532
        )

        #expect(issue?.contains("the title of chapter 2 runs on into the table of contents") == true)
        #expect(issue?.contains("Small-Molecule Transport") == true)
    }

    @Test("A long book whose chapters are mostly a page or two is refused")
    func refusesMostlyTinyChapters() {
        let issue = StudioViewModel.bookChapterSelectionIssue(
            chapters: [
                (title: "Foreword", pageIndex: 4),
                (title: "A Note on the Text", pageIndex: 5),
                (title: "The Long Middle", pageIndex: 7)
            ],
            pageCount: 300
        )

        #expect(issue?.contains("2 of 3 chapters are under 3 pages") == true)
    }

    @Test("Short books and single chapters keep whatever sections the splitter found")
    func keepsShortBooksAndSingleChapters() {
        // A paper imported as a book: five sections of three or four pages.
        #expect(StudioViewModel.bookChapterSelectionIssue(
            chapters: [
                (title: "Introduction", pageIndex: 0),
                (title: "Methods", pageIndex: 3),
                (title: "Results", pageIndex: 7),
                (title: "Discussion", pageIndex: 11),
                (title: "Conclusion", pageIndex: 15)
            ],
            pageCount: 18
        ) == nil)

        // A pamphlet: twelve sections three pages apart.
        let pamphlet = (0..<12).map { (title: "Section \($0 + 1)", pageIndex: $0 * 3) }
        #expect(StudioViewModel.bookChapterSelectionIssue(chapters: pamphlet, pageCount: 40) == nil)

        // A single chapter, whatever it is called.
        #expect(StudioViewModel.bookChapterSelectionIssue(
            chapters: [(title: "Summary", pageIndex: 0)],
            pageCount: 600
        ) == nil)
    }

    @Test("Many chapter-sized chapters in a long book are kept")
    func keepsManyModerateChapters() {
        // Forty essays of six to nine pages in a collection of about 300 pages.
        var start = 6
        var chapters: [(title: String, pageIndex: Int)] = []
        for index in 0..<40 {
            chapters.append((title: "Essay \(index + 1)", pageIndex: start))
            start += 6 + index % 4
        }

        #expect(StudioViewModel.bookChapterSelectionIssue(chapters: chapters, pageCount: start + 4) == nil)
    }

    /// The 24 chapters Molecular Biology of the Cell (7th ed.) actually has,
    /// with the page lengths of the chapter PDFs the good import produced.
    static var molecularBiologyOfTheCellChapters: [(title: String, pageIndex: Int)] {
        [
            (title: "1) Cells, Genomes, and the Diversity of Life", pageIndex: 40),
            (title: "2) Cell Chemistry and Bioenergetics", pageIndex: 88),
            (title: "3) Proteins", pageIndex: 154),
            (title: "4) DNA, Chromosomes, and Genomes", pageIndex: 222),
            (title: "5) DNA Replication, Repair, and Recombination", pageIndex: 292),
            (title: "6) How Cells Read the Genome: From DNA to Protein", pageIndex: 360),
            (title: "7) Control of Gene Expression", pageIndex: 436),
            (title: "8) Analyzing Cells, Molecules, and Systems", pageIndex: 514),
            (title: "9) Visualizing Cells and Their Molecules", pageIndex: 602),
            (title: "10) Membrane Structure", pageIndex: 642),
            (title: "11) Small-Molecule Transport and Electrical Properties of Membranes", pageIndex: 676),
            (title: "12) Intracellular Organization and Protein Sorting", pageIndex: 722),
            (title: "13) Intracellular Membrane Traffic", pageIndex: 788),
            (title: "14) Energy Conversion and Metabolic Compartmentation: Mitochondria and Chloroplasts", pageIndex: 850),
            (title: "15) Cell Signaling", pageIndex: 912),
            (title: "16) The Cytoskeleton", pageIndex: 988),
            (title: "17) The Cell Cycle", pageIndex: 1066),
            (title: "18) Cell Death", pageIndex: 1128),
            (title: "19) Cell Junctions and the Extracellular Matrix", pageIndex: 1144),
            (title: "20) Cancer", pageIndex: 1202),
            (title: "21) Development of Multicellular Organisms", pageIndex: 1256),
            (title: "22) Stem Cells in Tissue Homeostasis and Regeneration", pageIndex: 1318),
            (title: "23) Pathogens and Infection", pageIndex: 1352),
            (title: "24) The Innate and Adaptive Immune Systems", pageIndex: 1392)
        ]
    }

    /// The 130 titles the splitter returned for the same PDF on 2026-08-24,
    /// read back from the archived chapter rows of the production library. The
    /// archived chapter PDFs are gone, so page starts are reconstructed to the
    /// shape that import showed: the first 119 entries one to four pages apart
    /// across the opening chapters, then eleven lumps of 10 to 370 pages.
    static var molecularBiologyOfTheCellContentsListing: [(title: String, pageIndex: Int)] {
        let fragmentLengths = [2, 1, 4, 3, 2, 1, 3, 4, 2, 1]
        var start = 1
        var chapters: [(title: String, pageIndex: Int)] = []
        for (index, title) in contentsListingFragmentTitles.enumerated() {
            chapters.append((title: title, pageIndex: start))
            start += fragmentLengths[index % fragmentLengths.count]
        }
        let lumpStarts = [440, 560, 700, 730, 760, 1130, 1140, 1250, 1300, 1360, 1470]
        for (title, pageIndex) in zip(contentsListingLumpTitles, lumpStarts) {
            chapters.append((title: title, pageIndex: pageIndex))
        }
        return chapters
    }

    private static let contentsListingFragmentTitles: [String] = [
        "1) Cells, Genomes, and the Diversity of Life",
        "THE UNIVERSAL FEATURES OF LIFE ON EARTH",
        "Polymerization",
        "All Cells Transcribe Portions of Their DNA into RNA Molecules",
        "All Cells Use Proteins as Catalysts",
        "Each Protein Is Encoded by a Specific Gene",
        "All Cells Function as Biochemical Factories",
        "Random Thermal Motion",
        "GENOME DIVERSIFICATION AND THE TREE OF LIFE",
        "Familiar to Us",
        "New Types of Organisms",
        "New Genes Are Generated from Preexisting Genes",
        "Within a Single Genome",
        "Three Domains of Life",
        "Captured by an Ancient Archaeon",
        "Bacterium Engulfed by an Ancient Eukaryotic Cell",
        "Eukaryotes Have Hybrid Genomes",
        "Eukaryotic Genomes Are Big",
        "Development",
        "Many Eukaryotes Live as Solitary Cells",
        "Summary",
        "Mutations Reveal the Functions of Genes",
        "Many Subsequent Discoveries",
        "Can Be Determined",
        "Arabidopsis Has Been Chosen as a Model Plant",
        "Development",
        "Vertebrate Models",
        "The Mouse Is the Predominant Mammalian Model Organism",
        "Humans Are Unique in Reporting on Their Own Peculiarities",
        "Summary",
        "Problems",
        "2) Cell Chemistry and Bioenergetics",
        "Together in Cells",
        "CATALYSIS AND THE USE OF ENERGY BY CELLS Cell Metabolism Is Organized by Enzymes",
        "Macromolecule and Its Binding to Other Molecules Summary",
        "Heat Energy from Cells",
        "Chemical Reactions",
        "Reaction Pathways",
        "Rapidity of Molecular Motions",
        "Whether It Can Occur Spontaneously",
        "Change and a Reaction’s Direction",
        "Each Other",
        "Two Molecules Together",
        "Summary",
        "HOW CELLS OBTAIN ENERGY FROM FOOD Glycolysis Is a Central atP-producing Pathway",
        "Acetyl Groups to CO2",
        "They Need from Food",
        "Metabolism Is Highly Organized and Regulated",
        "Summary",
        "Problems",
        "3) Proteins",
        "Proteins Are Built",
        "Proteins Also Contain Unstructured Regions",
        "Revealing That Much Remains Unknown",
        "Many Structures in Cells Are Capable of Self-Assembly",
        "Amyloid Fibrils",
        "Amyloid Structures Can Also Perform Useful Functions in Cells",
        "Summary",
        "The Surface Conformation of a Protein Determines Its Chemistry",
        "Transition States",
        "Affect Each Other’s Binding",
        "Transitions",
        "Many Changes in Proteins Are Driven by Protein Phosphorylation",
        "Protein Can Function as a Microprocessor",
        "Off by the Gain and Loss of a Phosphate Group",
        "Efficient Use of Genetic Information",
        "Machines",
        "Set of Different Functions",
        "Condensates",
        "Assemblies",
        "That Direct Them to Specific Sites Inside the Cell",
        "Cell Function",
        "Designed",
        "Summary",
        "4) DNA, Chromosomes, and Genomes",
        "THE STRUCTURE AND FUNCTION OF DNA",
        "Summary",
        "How Our Genes Are Arranged",
        "DNA Molecules Are Highly Condensed in Chromosomes",
        "How DNA Is Packaged",
        "Chromatin Fiber",
        "Summary",
        "Very Differently in Chromatin",
        "Different Sites",
        "Act in Concert to Control Chromosome Functions",
        "Chromatin Modifications Along a Chromosome",
        "Neighboring Chromatin Domains",
        "That Arise During Tumor Progression Contribute to Many Cancers Summary",
        "Chromatin Structures",
        "Them Are Expressed",
        "Chromosomal DNA Is Organized into Loops by Large Protein Rings",
        "Mitotic Chromosomes Are Highly Condensed",
        "Summary",
        "HOW GENOMES EVOLVE",
        "DNA Sequences Trace the Relationships of All Organisms",
        "Shows How the Structures of Genomes Diverge",
        "Rates of DNA Addition and DNA Loss in a Lineage",
        "Conserved DNA Sequences of Unknown Function",
        "Help Decipher Critical Steps in Evolution",
        "Changes in Vertebrates",
        "Genetic Novelty During Evolution",
        "DNA Duplications Contribute to the Evolution of Organisms",
        "We Can Trace Human History by Analyzing Genomes",
        "Genomes Reveals Much Variation",
        "Unusually High Mutation Rates",
        "Improving Medicine",
        "Problems",
        "THE MAINTENANCE OF DNA SEQUENCES",
        "Low Mutation Rates Are Necessary for Life as We Know It",
        "Summary",
        "The DNA Replication Fork Is Asymmetrical",
        "Proofreading Mechanisms",
        "Correction",
        "Replication Machine",
        "DNA Replication Is Corrected",
        "Summary",
        "Only One Part of the Cell Cycle",
        "That Protect the Ends of Chromosomes",
        "Summary"
    ]

    private static let contentsListingLumpTitles: [String] = [
        "8) Analyzing Cells, Molecules, and Systems Chapter 9 Visualizing Cells and Their Molecules PART IV INTERNAL ORGANIZATION OF THE CELL",
        "10) Membrane Structure",
        "17) The Cell Cycle",
        "PANel 14–1 Redox Potentials",
        "11) Small-Molecule Transport and Electrical Properties of Membranes Chapter 12 Intracellular Organization and Protein Sorting Chapter 13 Intracellular Membrane Traffic Chapter 14 Energy Conversion and Metabolic Compartmentation: Mitochondria and Chloroplasts Chapter 15 Cell Signaling",
        "Signaling Pathway",
        "16) The Cytoskeleton",
        "PANel 16–4 Microtubules",
        "18) Cell Death",
        "21) Development of Multicellular Organisms Chapter 22 Stem Cells in Tissue Homeostasis and Regeneration Chapter 23 Pathogens and Infection Chapter 24 The Innate and Adaptive Immune Systems",
        "19) Cell Junctions and the Extracellular Matrix Chapter 20 Cancer"
    ]

    private func makePDFDocument(pages: [String]) throws -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 420, height: 640)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw TestPDFError.renderFailed
        }

        for text in pages {
            context.beginPDFPage(nil)
            let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: NSColor.black
            ]
            NSString(string: text).draw(
                in: CGRect(x: 36, y: 120, width: 340, height: 480),
                withAttributes: attributes
            )
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()

        guard let document = PDFDocument(data: data as Data) else {
            throw TestPDFError.renderFailed
        }
        return document
    }

    @Test("A chapter splitter reply is checked against its candidates before it is cached or used")
    func splitterReplyIsValidatedAgainstCandidates() throws {
        let candidates: [Int: AIService.BookChapterCandidate] = [
            1: .init(title: "Preface", fixedPageIndex: 6),
            2: .init(title: "Chapter 1", fixedPageIndex: 12),
            3: .init(title: "Chapter 2", fixedPageIndex: nil),
        ]
        let good = #"{"chapters":[{"id":1,"title":"Preface","pageIndex":6,"endPageIndexExclusive":12},{"id":2,"title":"","pageIndex":12,"endPageIndexExclusive":40},{"id":3,"title":"Chapter 2: The Cell","pageIndex":40,"endPageIndexExclusive":90}]}"#
        let chapters = try AIService.validatedBookChapterBoundaries(good, candidates: candidates, pageCount: 100)
        #expect(chapters.map(\.title) == ["Preface", "Chapter 1", "Chapter 2: The Cell"])
        #expect(chapters.map(\.pageIndex) == [6, 12, 40])
        #expect(chapters.last?.endPageIndexExclusive == 90)

        let refused = [
            // Out of order.
            #"{"chapters":[{"id":2,"title":"Chapter 1","pageIndex":12,"endPageIndexExclusive":40},{"id":1,"title":"Preface","pageIndex":6,"endPageIndexExclusive":12}]}"#,
            // An outline entry's page moved.
            #"{"chapters":[{"id":1,"title":"Preface","pageIndex":7,"endPageIndexExclusive":12}]}"#,
            // A gap between chapters.
            #"{"chapters":[{"id":1,"title":"Preface","pageIndex":6,"endPageIndexExclusive":10},{"id":2,"title":"Chapter 1","pageIndex":12,"endPageIndexExclusive":40}]}"#,
            // A candidate that was never offered.
            #"{"chapters":[{"id":9,"title":"Ghost","pageIndex":50,"endPageIndexExclusive":60}]}"#,
            // Past the last page.
            #"{"chapters":[{"id":3,"title":"Chapter 2","pageIndex":40,"endPageIndexExclusive":101}]}"#,
            "The chapters are the preface and two chapters.",
        ]
        for reply in refused {
            #expect(throws: (any Error).self, "accepted: \(reply)") {
                try AIService.validatedBookChapterBoundaries(reply, candidates: candidates, pageCount: 100)
            }
        }
    }

    private enum TestPDFError: Error {
        case renderFailed
    }
}
