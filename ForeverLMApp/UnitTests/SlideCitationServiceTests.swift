import AppKit
import Foundation
import Testing
@testable import ForeverLM

@Suite("Meeting paper discovery")
struct MeetingPaperDiscoveryTests {
    @Test("Meeting paper discovery is a configurable meeting task")
    func taskContract() {
        #expect(AITask.meetingPaperDiscovery.sourceType == .meeting)
        #expect(AITask.advancedTasks.contains(.meetingPaperDiscovery))
        #expect(AITask.meetingPaperDiscovery.defaultPrompt == Prompts.meetingPaperDiscovery)
        #expect(MCPToolRegistry.shared.tools.map(\.name).contains("scan_meeting_for_mentioned_papers"))
        #expect(MCPToolRegistry.annotations(for: "scan_meeting_for_mentioned_papers")["openWorldHint"] as? Bool == true)
        #expect(Prompts.mcpServerInstructions.contains("scan_meeting_for_mentioned_papers"))
    }

    @Test("Meeting material chunks cover long transcripts with overlap")
    func chunksCoverCompleteTranscript() {
        let content = "abcdefghijklmnopqrstuvwxyz"
        let chunks = SlideCitationService.materialChunks(
            content,
            maxCharacters: 10,
            overlapCharacters: 3
        )

        #expect(chunks == ["abcdefghij", "hijklmnopq", "opqrstuvwx", "vwxyz"])
        #expect(chunks.dropFirst().allSatisfy { chunk in
            chunks.contains { previous in
                previous != chunk && previous.suffix(3) == chunk.prefix(3)
            }
        })
    }

    @Test("Empty meeting material produces no model chunks")
    func emptyMaterial() {
        #expect(SlideCitationService.materialChunks("  \n ").isEmpty)
    }
}

/// Shared fixtures. File-scoped so the resolution and attribution suites build the same
/// shapes rather than each keeping its own copy.
private func candidate(
    _ title: String,
    doi: String = "10.0000/x",
    journal: String? = nil,
    year: String? = nil,
    authors: String? = nil
) -> SlideCitationService.ResolvedPaper {
    SlideCitationService.ResolvedPaper(
        doi: doi, title: title, journal: journal, year: year, authors: authors
    )
}

private func read(
    _ title: String,
    journal: String? = nil,
    year: String? = nil,
    authors: String? = nil
) -> VideoCitedPaper {
    VideoCitedPaper(sourceID: "src_1", title: title, authors: authors, year: year, journal: journal)
}

@Suite("Slide Citation Extraction")
struct SlideCitationServiceTests {

    // MARK: - Slide selection

    private func slide(
        _ index: Int,
        recognizedText: String,
        seconds: Double? = nil
    ) -> YouTubeSlideFrameContext {
        YouTubeSlideFrameContext(
            index: index,
            timeSeconds: seconds,
            windows: seconds.map { [SlideTimeWindow(start: $0, end: nil)] } ?? [],
            imagePath: "Videos/src_1/Slides/slide_\(index).jpg",
            recognizedText: recognizedText
        )
    }

    /// The regression that made a citation-dense talk report zero papers.
    ///
    /// Frames captured too small to OCR produced no recognised text, the old filter read that
    /// as "nothing cited here", and every slide was dropped before the model saw it. An
    /// unreadable frame is not evidence of an uncited slide — only the model can say.
    @Test("Sends slides to the model even when nothing was recognized locally")
    func scansSlidesWithNoRecognizedText() {
        let slides = [
            slide(1, recognizedText: ""),
            slide(2, recognizedText: ""),
            slide(3, recognizedText: ""),
        ]

        #expect(SlideCitationService.slidesToScan(slides).count == 3)
    }

    /// A talk's own title slide is not filtered out either — deciding that is the model's job,
    /// and it answers with an empty array.
    @Test("Sends every slide regardless of what the text looks like")
    func scansEverySlide() {
        let slides = [
            slide(1, recognizedText: "Contact-dependent mitochondrial transfer:"),
            slide(2, recognizedText: "Thank you!"),
            slide(3, recognizedText: "A Network of Macrophages Supports Mitochondrial Homeostasis in the Heart"),
        ]

        #expect(SlideCitationService.slidesToScan(slides).count == 3)
    }

    @Test("Caps a very long deck rather than scanning without bound")
    func capsVeryLongDeck() {
        let slides = (1...200).map { slide($0, recognizedText: "") }

        let selected = SlideCitationService.slidesToScan(slides)

        #expect(selected.count < slides.count)
        #expect(selected.count >= 40)
        #expect(selected.first?.index == 1)
    }

    @Test("The all-papers lecture workflow scans the complete captured deck")
    func exhaustiveLectureScanUsesEverySlide() {
        let slides = (1...200).map { slide($0, recognizedText: "") }

        let selected = SlideCitationService.slidesToScan(slides, exhaustive: true)

        #expect(selected.count == slides.count)
        #expect(selected.last?.index == 200)
    }

    @Test("The MCP scan exposes the complete-deck option")
    func mcpScanExposesAllSlides() throws {
        let tool = try #require(
            MCPToolRegistry.shared.tools.first { $0.name == "scan_video_for_cited_papers" }
        )
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        let allSlides = try #require(properties["all_slides"] as? [String: Any])

        #expect(allSlides["type"] as? String == "boolean")
    }

    @Test("The normal citation read returns the slide verdict in the same call")
    func extractionPromptCombinesVerdictAndCitations() {
        #expect(Prompts.slideCitationExtraction.contains("isPresentationSlide"))
        #expect(Prompts.slideCitationExtraction.contains("citations"))
    }

    @Test("A bounded successful pass is not reported as a complete-deck scan")
    func boundedPassIsIncomplete() {
        let result = SlideCitationService.ScanResult(
            candidates: [],
            slidesScanned: 40,
            slidesFailed: 0,
            slidesAvailable: 78,
            nonSlideFramePaths: [],
            scannedFramePaths: []
        )

        #expect(result.slidesSkipped == 38)
        #expect(!result.isComplete)
    }

    @Test("A failure-free all-slide pass is complete")
    func exhaustivePassIsComplete() {
        let result = SlideCitationService.ScanResult(
            candidates: [],
            slidesScanned: 78,
            slidesFailed: 0,
            slidesAvailable: 78,
            nonSlideFramePaths: [],
            scannedFramePaths: []
        )

        #expect(result.slidesSkipped == 0)
        #expect(result.isComplete)
    }

    // MARK: - Attribution-only citations

    /// The common case this originally missed: a figure credited in tiny type in the corner
    /// — "Hayashida et al. BMC Medicine, 2023" — with the paper's title nowhere on the slide.
    @Test("Keeps a citation that gives only an attribution")
    func buildsLabelForAttributionOnlyCitation() {
        let paper = VideoCitedPaper(
            sourceID: "src_1",
            title: VideoCitedPaper.attributionLabel(
                authors: "Hayashida", journal: "BMC Medicine", year: "2023"
            ),
            authors: "Hayashida",
            year: "2023",
            journal: "BMC Medicine"
        )

        #expect(paper.title == "Hayashida et al., BMC Medicine, 2023")
        #expect(paper.isAttributionOnly)
    }

    @Test("Treats a citation with a printed title as a normal one")
    func printedTitleIsNotAttributionOnly() {
        let paper = VideoCitedPaper(
            sourceID: "src_1",
            title: "Exogenous mitochondrial transplantation improves survival",
            authors: "Hayashida",
            year: "2023",
            journal: "BMC Medicine"
        )

        #expect(!paper.isAttributionOnly)
    }

    // MARK: - Row subtitles

    /// A resolved paper carries every author the record lists. Printed in full they wrapped to
    /// more lines than the title above them and swamped it, so the subtitle collapses them the
    /// way the rest of the app writes a paper's byline.
    @Test("Collapses a long author list to the first author")
    func subtitleShortensAuthors() {
        let paper = VideoCitedPaper(
            sourceID: "src_1",
            title: "Mitochondrial transfer from bone-marrow-derived stromal cells to pulmonary alveoli",
            authors: "Islam; Das; Emin; Wei; Sun; Westphalen; Rowlands; Quadri; Bhattacharya; Bhattacharya",
            year: "2012",
            journal: "Nature Medicine"
        )

        #expect(paper.displaySubtitle == "Islam et al. · Nature Medicine · 2012")
    }

    @Test("Names both authors of a two-author paper")
    func subtitleKeepsBothAuthorsOfAPair() {
        let paper = VideoCitedPaper(
            sourceID: "src_1", title: "A paper", authors: "Islam; Das", year: "2012", journal: "Nature"
        )

        #expect(paper.displaySubtitle == "Islam & Das · Nature · 2012")
    }

    /// The attribution stands in as the title, so a subtitle would repeat it almost word for
    /// word directly underneath itself.
    @Test("Gives an attribution-only citation no subtitle")
    func subtitleOmittedWhenTitleIsTheAttribution() {
        let paper = VideoCitedPaper(
            sourceID: "src_1",
            title: VideoCitedPaper.attributionLabel(
                authors: "Hayashida", journal: "BMC Medicine", year: "2023"
            ),
            authors: "Hayashida",
            year: "2023",
            journal: "BMC Medicine"
        )

        #expect(paper.displaySubtitle == nil)
    }

    @Test("Keeps the venue line when a paper records no authors")
    func subtitleSurvivesMissingAuthors() {
        let paper = VideoCitedPaper(
            sourceID: "src_1", title: "A paper", year: "2012", journal: "Nature"
        )

        #expect(paper.displaySubtitle == "Nature · 2012")
    }

    /// Journal names are short, so the title measure — which divides by the shorter side —
    /// scored two unrelated BMC journals as a match on one shared word.
    @Test("Holds similarly named journals apart")
    func distinguishesSimilarJournals() {
        #expect(SlideCitationService.journalsMatch("BMC Medicine", "BMC Medicine"))
        #expect(!SlideCitationService.journalsMatch("BMC Medicine", "BMC Systems Biology"))
        #expect(!SlideCitationService.journalsMatch("BMC Medicine", "BMC Emergency Medicine"))
        #expect(!SlideCitationService.journalsMatch("Nature", "Chemistry Letters"))
    }

    // MARK: - Venue attribution

    /// The slide that prompted this: "Szeto et al., Br J Pharmacol, 2014" in the corner of
    /// a cardiolipin figure. The pool is what Crossref really holds for Szeto around 2014 —
    /// two Clinical Pharmacology & Therapeutics papers the venue-ranked search puts first,
    /// the cited paper, and a companion British Journal of Pharmacology paper Szeto is last
    /// author on.
    @Test("Resolves a slide attribution to the first author's one paper in that venue")
    func resolvesVenueAttribution() {
        let slide = read("Szeto et al., Br J Pharmacol, 2014",
                         journal: "Br J Pharmacol", year: "2014", authors: "Szeto")
        let pool = [
            SlideCitationService.ResolvedPaper(
                doi: "10.1038/clpt.2014.174", title: "Serendipity and the Discovery of Novel Compounds",
                journal: "Clinical Pharmacology &amp; Therapeutics", year: "2014", authors: "Szeto; Birk",
                journalAliases: ["Clin Pharmacol Ther"]
            ),
            SlideCitationService.ResolvedPaper(
                doi: "10.1111/bph.12468", title: "Targeting mitochondrial cardiolipin",
                journal: "British Journal of Pharmacology", year: "2014", authors: "Birk; Chao; Szeto",
                journalAliases: ["British J Pharmacology"]
            ),
            SlideCitationService.ResolvedPaper(
                doi: "10.1111/bph.12461",
                title: "First-in-class cardiolipin-protective compound as a therapeutic agent to restore mitochondrial bioenergetics",
                journal: "British Journal of Pharmacology", year: "2014", authors: "Szeto",
                journalAliases: ["British J Pharmacology"]
            ),
        ]

        #expect(SlideCitationService.attributionMatch(read: slide, pool: pool)?.doi == "10.1111/bph.12461")
    }

    @Test("Resolves a venue whose Crossref title keeps its HTML ampersand")
    func resolvesVenueWithEncodedAmpersand() {
        let slide = read("Wai et al., Trends in Endocrinology and Metabolism, 2016",
                         journal: "Trends in Endocrinology and Metabolism", year: "2016", authors: "Wai; Langer")
        let record = SlideCitationService.ResolvedPaper(
            doi: "10.1016/j.tem.2015.12.001", title: "Mitochondrial Dynamics and Metabolic Regulation",
            journal: "Trends in Endocrinology &amp; Metabolism", year: "2016", authors: "Wai; Langer"
        )

        #expect(SlideCitationService.attributionMatch(read: slide, pool: [record])?.doi == record.doi)
    }

    /// Three Cai first-author papers in Frontiers in Cellular Neuroscience in 2016. The first
    /// author, venue and year cannot choose; the co-author the slide printed can, even read
    /// off small print as "Tamminen" for Tammineni.
    @Test("A printed co-author settles several same-venue papers, and without one nothing resolves")
    func coauthorSettlesSameVenueAmbiguity() {
        let pool = [
            candidate("Alterations in Mitochondrial Quality Control in Alzheimer's Disease",
                      doi: "10.3389/fncel.2016.00024", journal: "Frontiers in Cellular Neuroscience",
                      year: "2016", authors: "Cai; Tammineni"),
            candidate("JNK Inhibition Inhibits Lateral Line Neuromast Hair Cell Development",
                      doi: "10.3389/fncel.2016.00019", journal: "Frontiers in Cellular Neuroscience",
                      year: "2016", authors: "Cai; Lin; Sun"),
            candidate("Neurogenesis-Promoting Natural Product alpha-Asarone",
                      doi: "10.3389/fncel.2016.00280", journal: "Frontiers in Cellular Neuroscience",
                      year: "2016", authors: "Cai; Li; Mao"),
        ]
        let bare = read("Cai et al., Front. Cell. Neurosci., 2016",
                        journal: "Front. Cell. Neurosci.", year: "2016", authors: "Cai")
        let withCoauthor = read("Cai et al., Front. Cell. Neurosci., 2016",
                                journal: "Front. Cell. Neurosci.", year: "2016", authors: "Cai; Tamminen")

        #expect(SlideCitationService.attributionMatch(read: bare, pool: pool) == nil)
        #expect(SlideCitationService.attributionMatch(read: withCoauthor, pool: pool)?.doi == "10.3389/fncel.2016.00024")
    }

    @Test("Two agreeing papers in the year window resolve only to the one in the printed year")
    func printedYearSettlesWindowAmbiguity() {
        let slide = read("Wolf et al., EMBO J, 2019", journal: "EMBO J", year: "2019", authors: "Wolf")
        let pool = [
            candidate("Individual cristae within the same mitochondrion display different membrane potentials",
                      doi: "10.15252/embj.2018101056", journal: "The EMBO Journal", year: "2019", authors: "Wolf; Segawa"),
            candidate("Mitochondrial genome inheritance and replacement",
                      doi: "10.15252/embj.2018000001", journal: "The EMBO Journal", year: "2018", authors: "Wolf; Hayama"),
            candidate("Erratum: Individual cristae within the same mitochondrion",
                      doi: "10.15252/embj.2019999999", journal: "The EMBO Journal", year: "2019", authors: "Wolf; Segawa"),
        ]

        #expect(SlideCitationService.attributionMatch(read: slide, pool: pool)?.doi == "10.15252/embj.2018101056")
    }

    /// Same author and year, wrong journal — the case a Crossref author search really returns.
    @Test("Rejects an attribution whose venue disagrees")
    func rejectsAttributionWithWrongJournal() {
        let slide = read("Hayashida et al., BMC Medicine, 2023",
                         journal: "BMC Medicine", year: "2023", authors: "Hayashida")
        let pool = [
            candidate("Thiol-reactive Pyrene Dimer", doi: "10.1246/cl.220521",
                      journal: "Chemistry Letters", year: "2023", authors: "Hayashida; Other"),
            candidate("Predictive value of quick surgical airway assessment", doi: "10.1186/s12873-018-0203-4",
                      journal: "BMC Emergency Medicine", year: "2023", authors: "Hayashida; Matsumoto"),
        ]

        #expect(SlideCitationService.attributionMatch(read: slide, pool: pool) == nil)
    }

    /// The failure this rule exists for, taken from a real talk. The slide read "Free Radical
    /// Theory of Aging · 1954 Denham Harman" and printed no venue, so Crossref's author +
    /// year-window search returned the nearest thing anyone named Harman published: the
    /// programme of the 1955 American Dairy Science Association meeting. It was then offered
    /// as a confident suggestion on a talk about mitochondrial medicine.
    @Test("Rejects a same-surname, same-year paper when the slide printed no venue")
    func rejectsAttributionWithYearButNoVenue() {
        let slide = read("Denham Harman, 1954", year: "1954", authors: "Denham Harman")
        let pool = [
            candidate(
                "Proceedings of the Fiftieth Annual Meeting of the American Dairy Science Association",
                doi: "10.3168/jds.s0022-0302(55)95058-x",
                journal: "Journal of Dairy Science",
                year: "1955",
                authors: "Harman"
            ),
        ]

        #expect(SlideCitationService.attributionMatch(read: slide, pool: pool) == nil)
    }

    /// An author name alone identifies nothing — plenty of papers share a surname.
    @Test("Rejects an attribution with no corroboration")
    func rejectsUncorroboratedAttribution() {
        let slide = read("Hayashida et al.", authors: "Hayashida")

        #expect(SlideCitationService.attributionMatch(read: slide, pool: [
            candidate("Some unrelated paper", authors: "Hayashida"),
        ]) == nil)
    }

    /// The same slide read twice over — "Denham Harman" and "Harman" are different strings
    /// before resolution, so both survived the pre-resolution dedup and were stored.
    @Test("Collapses candidates that resolved to the same paper")
    func collapsesResolvedDuplicates() {
        let resolved = SlideCitationService.collapsingDuplicates([
            read("Aging: a theory based on free radical and radiation chemistry",
                 year: "1956", authors: "Denham Harman"),
            read("Aging: A Theory Based on Free Radical and Radiation Chemistry",
                 year: "1956", authors: "Harman"),
        ])

        #expect(resolved.count == 1)
    }

    @Test("Rejects a record the cited author is not first on")
    func rejectsAttributionWithoutFirstAuthor() {
        let slide = read("Hayashida et al., BMC Medicine, 2023",
                         journal: "BMC Medicine", year: "2023", authors: "Hayashida")

        #expect(SlideCitationService.attributionMatch(read: slide, pool: [
            candidate("A BMC Medicine paper by someone else", doi: "10.0000/y",
                      journal: "BMC Medicine", year: "2023", authors: "Tanaka; Suzuki"),
            candidate("A BMC Medicine paper Hayashida co-wrote", doi: "10.0000/z",
                      journal: "BMC Medicine", year: "2023", authors: "Tanaka; Hayashida"),
        ]) == nil)
    }

    @Test("Rejects a record whose volume or page contradicts what the slide printed")
    func rejectsAttributionAgainstPrintedLocator() {
        let slide = read("Szeto et al., Br J Pharmacol, 2014",
                         journal: "Br J Pharmacol", year: "2014", authors: "Szeto")
        let record = SlideCitationService.ResolvedPaper(
            doi: "10.1111/bph.12461", title: "First-in-class cardiolipin-protective compound",
            journal: "British Journal of Pharmacology", year: "2014", authors: "Szeto",
            volume: "171", firstPage: "2029"
        )

        #expect(SlideCitationService.attributionMatch(
            read: slide,
            locator: SlideCitationService.BibliographicLocator(volume: "171", pages: "2029-50"),
            pool: [record]
        )?.doi == record.doi)
        #expect(SlideCitationService.attributionMatch(
            read: slide,
            locator: SlideCitationService.BibliographicLocator(volume: "170", pages: "2029-50"),
            pool: [record]
        ) == nil)
    }

    // MARK: - Vision capability

    /// Real refusal wording from providers when a text-only model is handed an image.
    /// Capability is discovered from the refusal rather than guessed from the model ID,
    /// because that list changes weekly and wrongly hiding a capable model is worse.
    @Test("Recognizes a provider refusing an image")
    func detectsMissingVisionSupport() {
        let refusals = [
            "No endpoints found that support image input.",
            "This model does not support image input.",
            "Invalid content type. image_url is only supported by certain models.",
            "The model cannot process images.",
            "Multimodal input is unsupported for this model.",
        ]

        for message in refusals {
            #expect(
                SlideCitationService.isMissingVisionSupport(AIError.apiError(message)),
                "Should have been read as a vision refusal: \(message)"
            )
        }
    }

    /// The costly false positive: aborting a whole scan on an unrelated failure, when those
    /// should count as one bad slide and let the rest continue.
    @Test("Leaves unrelated failures alone")
    func ignoresUnrelatedFailures() {
        let unrelated = [
            "Rate limit exceeded. Please retry after 30s.",
            "Invalid API key.",
            "Upstream provider is overloaded.",
            "Context length exceeded for this request.",
            "The request timed out.",
        ]

        for message in unrelated {
            #expect(
                !SlideCitationService.isMissingVisionSupport(AIError.apiError(message)),
                "Should not have been read as a vision refusal: \(message)"
            )
        }
    }

    @Test("Names the setting to change")
    func explainsHowToFixVisionSupport() throws {
        let error = SlideCitationService.SlideCitationError.modelCannotReadImages(
            task: .slideCitationExtraction,
            model: "some-text-only-model",
            providerMessage: "No endpoints found that support image input."
        )

        let description = try #require(error.errorDescription)

        #expect(description.contains("some-text-only-model"))
        #expect(description.contains("Slide Citation Extraction"))
        #expect(description.contains("No endpoints found that support image input."))
    }

    /// Classification and extraction are pinned separately in Settings, so the refusal
    /// must name the task whose model refused, not always the extraction row.
    @Test("Names the classification setting when that model refused")
    func explainsClassificationVisionSupport() throws {
        let error = SlideCitationService.SlideCitationError.modelCannotReadImages(
            task: .slideFrameClassification,
            model: "some-text-only-model",
            providerMessage: "No endpoints found that support image input."
        )

        #expect(try #require(error.errorDescription).contains("Slide Deduplication"))
    }

    // MARK: - Title matching

    @Test("Accepts a lookup that matches the slide title")
    func acceptsMatchingTitle() {
        #expect(SlideCitationService.titlesMatch(
            "Miro proteins and their role in mitochondrial transfer in cancer and beyond",
            "Miro proteins and their role in mitochondrial transfer in cancer and beyond"
        ))
    }

    @Test("Rejects a title truncated by OCR")
    func rejectsTruncatedTitle() {
        #expect(!SlideCitationService.titlesMatch(
            "Miro proteins and their role in mitochondrial",
            "Miro proteins and their role in mitochondrial transfer in cancer and beyond"
        ))
    }

    /// The guard that stops a confident lookup from importing an unrelated paper.
    @Test("Rejects an unrelated lookup result")
    func rejectsUnrelatedTitle() {
        #expect(!SlideCitationService.titlesMatch(
            "Miro proteins and their role in mitochondrial transfer",
            "Attention is all you need"
        ))
    }

    @Test("Rejects a missing lookup title")
    func rejectsMissingTitle() {
        #expect(!SlideCitationService.titlesMatch("Some paper title", nil))
    }

    // MARK: - Response decoding

    @Test("Decodes a citation array")
    func decodesCitations() throws {
        let reply = """
        [{"title": "Miro proteins and their role in mitochondrial transfer",
          "authors": "Zuzana Nahacka; Jaromir Novak", "year": "2022",
          "journal": "Nature", "doi": "10.1038/s41586-022-00001-1"}]
        """

        let citations = try SlideCitationService.decodeCitations(reply)

        #expect(citations.count == 1)
        let first = try #require(citations.first)
        #expect(first.title == "Miro proteins and their role in mitochondrial transfer")
        #expect(first.year == "2022")
        #expect(first.doi == "10.1038/s41586-022-00001-1")
    }

    @Test("Accepts a paper URL only when it is literal course-material text")
    func requiresLiteralMaterialURLForIdentity() throws {
        let literalURL = "https://arxiv.org/abs/1706.03762"
        let reply = """
        {"citations": [{
          "title": "Attention Is All You Need",
          "authors": "Vaswani",
          "year": "2017",
          "journal": "NeurIPS",
          "doi": null,
          "url": "\(literalURL)"
        }]}
        """
        let citations = try SlideCitationService.decodeReply(reply).citations

        let accepted = SlideCitationService.candidatesFromExtractedCitations(
            citations,
            sourceID: "notes-1",
            sourceText: "Required reading: Attention Is All You Need — \(literalURL)"
        )
        let rejected = SlideCitationService.candidatesFromExtractedCitations(
            citations,
            sourceID: "notes-1",
            sourceText: "Required reading: Attention Is All You Need."
        )

        #expect(accepted.first?.url == literalURL)
        #expect(accepted.first?.status == .pending)
        #expect(rejected.first?.url == nil)
        #expect(rejected.first?.status == .unresolved)
    }

    @Test("Accepts a DOI only when it is literal course-material text")
    func requiresLiteralMaterialDOIForIdentity() throws {
        let doi = "10.5555/3295222.3295349"
        let reply = """
        {"citations": [{
          "title": "Attention Is All You Need",
          "authors": "Vaswani",
          "year": "2017",
          "journal": "NeurIPS",
          "doi": "\(doi)",
          "url": null
        }]}
        """
        let citations = try SlideCitationService.decodeReply(reply).citations

        let accepted = SlideCitationService.candidatesFromExtractedCitations(
            citations,
            sourceID: "syllabus-1",
            sourceText: "DOI: \(doi)"
        )
        let rejected = SlideCitationService.candidatesFromExtractedCitations(
            citations,
            sourceID: "syllabus-1",
            sourceText: "No DOI is printed here."
        )

        #expect(accepted.first?.doi == doi)
        #expect(accepted.first?.url == "https://doi.org/\(doi)")
        #expect(accepted.first?.status == .pending)
        #expect(rejected.first?.doi == nil)
        #expect(rejected.first?.status == .unresolved)
    }

    @Test("Decodes an array wrapped in a code fence")
    func decodesFencedCitations() throws {
        let reply = """
        ```json
        [{"title": "A paper", "authors": null, "year": null, "journal": null, "doi": null}]
        ```
        """

        let citations = try SlideCitationService.decodeCitations(reply)

        #expect(citations.count == 1)
    }

    /// A slide that genuinely cites nothing is a real answer, not a failure.
    @Test("Treats an empty array as no citations")
    func decodesEmptyArray() throws {
        #expect(try SlideCitationService.decodeCitations("[]").isEmpty)
    }

    /// Anything that isn't an array is surfaced rather than read as "no papers here".
    @Test("Rejects a reply that is not an array")
    func rejectsProseReply() {
        #expect(throws: SlideCitationService.SlideCitationError.self) {
            try SlideCitationService.decodeCitations("I could not read this slide.")
        }
    }

    // MARK: - Frame classification

    /// The current prompt returns an object carrying the slide/non-slide judgement.
    @Test("Reads a slide object with its citations")
    func decodesSlideObject() throws {
        let reply = """
        {"isPresentationSlide": true,
         "citations": [{"title": "A paper", "authors": "Smith", "year": "2022", "journal": "Nature", "doi": null}]}
        """

        let read = try SlideCitationService.decodeReply(reply)

        #expect(read.presentationVerdict == true)
        #expect(read.isPresentationSlide)
        #expect(read.citations.count == 1)
        #expect(read.citations.first?.title == "A paper")
    }

    /// A camera shot of the room is flagged and carries no citations to store.
    @Test("Reads a non-slide frame as not a slide")
    func decodesNonSlideObject() throws {
        let read = try SlideCitationService.decodeReply(
            #"{"isPresentationSlide": false, "citations": []}"#
        )

        #expect(!read.isPresentationSlide)
        #expect(read.citations.isEmpty)
    }

    @Test("Reads a slide object wrapped in a code fence")
    func decodesFencedSlideObject() throws {
        let reply = """
        ```json
        {"isPresentationSlide": false, "citations": []}
        ```
        """

        #expect(try !SlideCitationService.decodeReply(reply).isPresentationSlide)
    }

    /// A bare array is the older reply shape, and what a user's custom prompt override still
    /// returns. It stays visible while signalling that the fallback classifier is needed.
    @Test("Treats a legacy array reply as a slide")
    func decodesLegacyArrayAsSlide() throws {
        let read = try SlideCitationService.decodeReply(
            #"[{"title": "A paper", "authors": null, "year": null, "journal": null, "doi": null}]"#
        )

        #expect(read.presentationVerdict == nil)
        #expect(read.isPresentationSlide)
        #expect(read.citations.count == 1)
    }

    /// A field-less object also stays visible while signalling the classifier fallback.
    @Test("Defaults a classification-less object to a slide")
    func defaultsMissingClassificationToSlide() throws {
        let read = try SlideCitationService.decodeReply(#"{"citations": []}"#)

        #expect(read.presentationVerdict == nil)
        #expect(read.isPresentationSlide)
        #expect(read.citations.isEmpty)
    }

    // MARK: - Classification pass

    /// The dedicated classification pass reads its one-field reply the same way: a frame
    /// is hidden only on an explicit false.
    @Test("Decodes the classification pass's verdict")
    func decodesClassificationVerdict() {
        #expect(SlideCitationService.decodeClassification(#"{"isPresentationSlide": true}"#))
        #expect(!SlideCitationService.decodeClassification(#"{"isPresentationSlide": false}"#))
    }

    @Test("Decodes a fenced classification reply")
    func decodesFencedClassification() {
        let reply = """
        ```json
        {"isPresentationSlide": false}
        ```
        """

        #expect(!SlideCitationService.decodeClassification(reply))
    }

    /// A garbled or empty reply keeps the frame — hiding a real slide costs more than
    /// showing a room shot twice.
    @Test("Keeps the frame when the classification reply cannot be read")
    func unreadableClassificationKeepsFrame() {
        #expect(SlideCitationService.decodeClassification(""))
        #expect(SlideCitationService.decodeClassification("It looks like a slide to me."))
        #expect(SlideCitationService.decodeClassification(#"{"isPresentationSlide": "maybe"}"#))
        #expect(SlideCitationService.decodeClassification(#"{"somethingElse": false}"#))
    }

    // MARK: - Deduplication

    @Test("Collapses the same paper by DOI across slides")
    func dedupesByDOI() {
        let first = VideoCitedPaper(
            sourceID: "src_1",
            title: "Miro proteins in mitochondrial transfer",
            doi: "10.1038/ABC-123"
        )
        let second = VideoCitedPaper(
            sourceID: "src_1",
            title: "Miro Proteins In Mitochondrial Transfer (repeated slide)",
            doi: "10.1038/abc-123"
        )

        #expect(first.dedupKey == second.dedupKey)
    }

    @Test("Falls back to a normalized title when no DOI is known")
    func dedupesByTitle() {
        let first = VideoCitedPaper(sourceID: "src_1", title: "Immune evasion through mitochondrial transfer")
        let second = VideoCitedPaper(sourceID: "src_1", title: "Immune  evasion, through mitochondrial transfer!")

        #expect(first.dedupKey == second.dedupKey)
    }
}

/// These cases come from resolving a real talk's slides. Each one is a way the lookup was
/// observed to go wrong before the resolver picked the best record across sources instead of
/// trusting the first one to answer.
@Suite("Cited Paper Resolution")
struct SlideCitationResolutionTests {

    @Test("Exact title identity is required")
    func requiresExactTitleIdentity() {
        #expect(SlideCitationService.titlesMatch(
            "Immune evasion through mitochondrial transfer",
            "Immune evasion through mitochondrial transfer"
        ))
        #expect(!SlideCitationService.titlesMatch(
            "Immune evasion through mitochondrial transfer",
            "Mitochondrial transfer-driven immune evasion"
        ))
    }
}

@Suite("Cited Paper Web Fallback")
struct SlideCitationWebFallbackTests {

    /// The regression this whole fallback exists for. A figure credited "Arnold & Finley, JBC,
    /// 2023" is attribution-only, and the catalog path rejects it because "JBC" shares no words
    /// with "Journal of Biological Chemistry". Once a web search finds the DOI and Crossref
    /// confirms it, the record is accepted on author and year — the journal strings never have
    /// to agree.
    @Test("Accepts an abbreviated-journal attribution once author and year agree")
    func acceptsAbbreviatedJournalAttribution() {
        let label = VideoCitedPaper.attributionLabel(authors: "Arnold", journal: "JBC", year: "2023")
        let slide = read(label, journal: "JBC", year: "2023", authors: "Arnold")
        #expect(slide.isAttributionOnly)

        let record = candidate(
            "Regulation and function of the mammalian tricarboxylic acid cycle",
            journal: "Journal of Biological Chemistry",
            year: "2023",
            authors: "Arnold; Finley"
        )
        #expect(SlideCitationService.webMatchAccepted(read: slide, candidate: record))
    }

    /// A year on the slide is hard evidence: a record two years off is a different paper even
    /// when the author matches.
    @Test("Rejects a confirmed record whose year contradicts the slide")
    func rejectsYearContradiction() {
        let label = VideoCitedPaper.attributionLabel(authors: "Arnold", journal: "JBC", year: "2023")
        let slide = read(label, journal: "JBC", year: "2023", authors: "Arnold")
        let record = candidate(
            "Some other Arnold paper", journal: "Journal of Biological Chemistry",
            year: "2019", authors: "Arnold; Finley"
        )
        #expect(!SlideCitationService.webMatchAccepted(read: slide, candidate: record))
    }

    /// The guard against a plausible but wrong DOI: a web search can return a real paper that is
    /// simply not the one cited. With no title to compare, the cited surname must be on it.
    @Test("Rejects a real record that is not by the cited author")
    func rejectsWrongAuthor() {
        let label = VideoCitedPaper.attributionLabel(authors: "Arnold", journal: "JBC", year: "2023")
        let slide = read(label, journal: "JBC", year: "2023", authors: "Arnold")
        let record = candidate(
            "A different 2023 JBC paper", journal: "Journal of Biological Chemistry",
            year: "2023", authors: "Zhang; Li"
        )
        #expect(!SlideCitationService.webMatchAccepted(read: slide, candidate: record))
    }

    /// A citation that printed its title carries no author here; the titles overlapping is what
    /// confirms the DOI is the right paper.
    @Test("Accepts a titled citation on title overlap alone")
    func acceptsTitledOnOverlap() {
        let slide = read("Immune evasion through mitochondrial transfer in the tumour microenvironment")
        #expect(!slide.isAttributionOnly)
        let record = candidate(
            "Immune evasion through mitochondrial transfer in the tumour microenvironment",
            authors: "Ikeda; Kawase"
        )
        #expect(SlideCitationService.webMatchAccepted(read: slide, candidate: record))
    }

    @Test("Rejects a titled citation when nothing agrees")
    func rejectsTitledMismatch() {
        let slide = read("Miro proteins and their role in mitochondrial transfer in cancer and beyond")
        let record = candidate("Dynamic Titania Nanotube Surface Achieves UV-Triggered Charge Reversal")
        #expect(!SlideCitationService.webMatchAccepted(read: slide, candidate: record))
    }

    // MARK: - Reply decoding

    /// Only the DOI is read from the model. A year comes back as often as a number as a string,
    /// and decoding the whole object would let that type throw and lose the one field that counts.
    @Test("Reads the DOI even when a sibling field is a JSON number")
    func decodesDOIWithNumericSibling() {
        let reply = #"{"doi": "10.1016/j.jbc.2022.102838", "title": "Regulation of the TCA cycle", "year": 2023}"#
        #expect(SlideCitationService.decodeWebLookup(reply) == "10.1016/j.jbc.2022.102838")
    }

    @Test("Reads the DOI out of a code fence")
    func decodesDOIInFence() {
        let reply = "```json\n{\"doi\": \"10.1000/x\"}\n```"
        #expect(SlideCitationService.decodeWebLookup(reply) == "10.1000/x")
    }

    @Test("Reads a null DOI as no match")
    func decodesNullDOI() {
        #expect(SlideCitationService.decodeWebLookup(#"{"doi": null}"#) == nil)
    }

    @Test("Reads a non-JSON reply as no match")
    func decodesNonJSON() {
        #expect(SlideCitationService.decodeWebLookup("I couldn't find that paper.") == nil)
    }

    // MARK: - Prompt

    /// An attribution-only candidate has a synthetic title, so it must not be fed back as if the
    /// slide printed one — the model would try to match a title that was never there.
    @Test("Omits the synthetic title for an attribution-only candidate")
    func promptOmitsSyntheticTitle() {
        let label = VideoCitedPaper.attributionLabel(authors: "Arnold", journal: "JBC", year: "2023")
        let slide = read(label, journal: "JBC", year: "2023", authors: "Arnold")
        let prompt = SlideCitationService.webLookupPrompt(for: slide)
        #expect(!prompt.contains("Title:"))
        #expect(prompt.contains("Authors: Arnold"))
        #expect(prompt.contains("Journal: JBC"))
        #expect(prompt.contains("Year: 2023"))
    }

    @Test("Includes a printed title for a titled candidate")
    func promptIncludesTitle() {
        let slide = read("Regulation and function of the mammalian tricarboxylic acid cycle", authors: "Arnold")
        let prompt = SlideCitationService.webLookupPrompt(for: slide)
        #expect(prompt.contains("Title: Regulation and function of the mammalian tricarboxylic acid cycle"))
    }

    // MARK: - Crossref record parsing

    /// The confirming fetch parses one work out of `/works/{doi}`'s `message`, the same shape a
    /// `/works` search item takes, built here the way JSONSerialization hands it over.
    @Test("Parses a Crossref work into a resolved paper")
    func parsesCrossrefWork() throws {
        let json = """
        {
          "DOI": "10.1016/j.jbc.2022.102838",
          "title": ["Regulation and function of the mammalian tricarboxylic acid cycle"],
          "container-title": ["Journal of Biological Chemistry"],
          "issued": {"date-parts": [[2023, 1]]},
          "author": [{"family": "Arnold"}, {"family": "Finley"}]
        }
        """
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let item = try #require(object as? [String: Any])
        let paper = try #require(SlideCitationService.parseCrossrefItem(item))
        #expect(paper.doi == "10.1016/j.jbc.2022.102838")
        #expect(paper.title == "Regulation and function of the mammalian tricarboxylic acid cycle")
        #expect(paper.journal == "Journal of Biological Chemistry")
        #expect(paper.year == "2023")
        #expect(paper.authors == "Arnold; Finley")
    }

    @Test("Skips a Crossref record with no title")
    func skipsTitlelessWork() throws {
        let object = try JSONSerialization.jsonObject(with: Data(#"{"DOI": "10.1/x"}"#.utf8))
        let item = try #require(object as? [String: Any])
        #expect(SlideCitationService.parseCrossrefItem(item) == nil)
    }
}

@Suite("Cited Papers by Slide")
struct VideoCitedPaperWindowTests {

    private func imagePath(_ index: Int) -> String {
        "Videos/src_1/Slides/slide_\(index).jpg"
    }

    private func slide(
        _ index: Int,
        windows: [SlideTimeWindow]
    ) -> YouTubeSlideFrameContext {
        YouTubeSlideFrameContext(
            index: index,
            timeSeconds: windows.first?.start,
            windows: windows,
            imagePath: imagePath(index),
            recognizedText: ""
        )
    }

    private func window(_ start: Double, _ end: Double?) -> SlideTimeWindow {
        SlideTimeWindow(start: start, end: end)
    }

    private func paper(
        onSlide index: Int? = nil,
        at seconds: Double? = nil,
        title: String = "A paper",
        status: VideoCitedPaper.Status = .pending
    ) -> VideoCitedPaper {
        VideoCitedPaper(
            sourceID: "src_1",
            title: title,
            slideTimeSeconds: seconds,
            slideImagePath: index.map(imagePath),
            status: status
        )
    }

    private func bySlide(
        _ papers: [VideoCitedPaper],
        slides: [YouTubeSlideFrameContext]
    ) -> [Int: [VideoCitedPaper]] {
        VideoCitedPaperWindow.bySlide(papers: papers, slides: slides)
    }

    @Test("Groups each paper under the slide it was read from")
    func groupsPapersUnderTheirSlide() {
        let slides = [
            slide(1, windows: [window(100, 160)]),
            slide(2, windows: [window(160, 300)]),
        ]
        let papers = [
            paper(onSlide: 1, at: 100, title: "First"),
            paper(onSlide: 2, at: 160, title: "Second"),
            paper(onSlide: 1, at: 100, title: "Also first"),
        ]

        let grouped = bySlide(papers, slides: slides)
        #expect(grouped[1]?.map(\.title) == ["First", "Also first"])
        #expect(grouped[2]?.map(\.title) == ["Second"])
    }

    /// The margin is not the video: nothing is playing while the transcript is being read,
    /// so a slide answers for itself at any position — including none.
    @Test("Groups regardless of playback position")
    func groupsWithoutAPlaybackPosition() {
        let slides = [slide(1, windows: [window(100, 160)])]

        #expect(bySlide([paper(onSlide: 1, at: 100)], slides: slides)[1]?.count == 1)
    }

    /// Wider than the chip on purpose: an unresolved row is the slide saying it cited
    /// something, and the margin has the room to say the lookup came back empty. Only a
    /// paper the learner waved off stays gone.
    @Test("Keeps unresolved rows and drops dismissed ones")
    func keepsUnresolvedDropsDismissed() {
        let slides = [slide(1, windows: [window(100, 160)])]
        let papers = [
            paper(onSlide: 1, at: 100, title: "Pending", status: .pending),
            paper(onSlide: 1, at: 100, title: "Imported", status: .imported),
            paper(onSlide: 1, at: 100, title: "Unresolved", status: .unresolved),
            paper(onSlide: 1, at: 100, title: "Dismissed", status: .dismissed),
        ]

        #expect(bySlide(papers, slides: slides)[1]?.map(\.title) == ["Pending", "Imported", "Unresolved"])
    }

    /// Same identity rule as the playback window: the stored frame path decides, not the
    /// timestamp, so a paper does not surface under a slide it was never read off.
    @Test("Groups by the stored frame path, not the stored timestamp")
    func groupsByFramePath() {
        let slides = [
            slide(1, windows: [window(100, 160)]),
            slide(2, windows: [window(500, 560)]),
        ]
        // Stored time says slide 1's stretch, but the frame it was read off is slide 2.
        let grouped = bySlide([paper(onSlide: 2, at: 110)], slides: slides)

        #expect(grouped[1] == nil)
        #expect(grouped[2]?.count == 1)
    }

    /// A row saved before frame paths were kept still has a timestamp, which is enough to
    /// place it in the margin.
    @Test("Falls back to the timestamp for a paper with no frame path")
    func groupsLegacyPaperByTimestamp() {
        let slides = [
            slide(1, windows: [window(100, 160)]),
            slide(2, windows: [window(500, 560)]),
        ]

        #expect(bySlide([paper(at: 500)], slides: slides)[2]?.count == 1)
    }

    @Test("Leaves a paper matching no slide out of the margin")
    func skipsPapersWithNoSlide() {
        let slides = [slide(1, windows: [window(100, 160)])]

        #expect(bySlide([paper(at: 900)], slides: slides).isEmpty)
    }
}

/// Anchors `Bundle(for:)` on the test bundle so fixtures resolve.
private final class FixtureAnchor {}

@Suite("Slide Citation Vision")
struct SlideCitationVisionTests {

    private func fixtureImage() throws -> Data {
        let bundle = Bundle(for: FixtureAnchor.self)
        let url = try #require(
            bundle.url(forResource: "slide_cited_paper", withExtension: "jpg"),
            "slide_cited_paper.jpg missing from UnitTests/Fixtures"
        )
        return try Data(contentsOf: url)
    }

    @Test("Fixture slide is bundled and large enough to read")
    func fixtureIsUsable() throws {
        let data = try fixtureImage()
        let image = try #require(NSImage(data: data))

        // The failure this guards: frames captured at 160x90 carry no legible text, and no
        // model can read what is not there.
        #expect(image.size.width >= 640)
        #expect(image.size.height >= 360)
    }

    /// The end-to-end check: a real slide image, the real prompt, the configured vision
    /// model, and the paper printed on it comes back.
    ///
    /// Opt-in because it spends real model calls. Run with:
    ///   FOREVERLM_LIVE_AI_TESTS=1 xcodebuild test ...
    @Test("Reads the cited paper off a real slide image", .enabled(if: ProcessInfo.processInfo.environment["FOREVERLM_LIVE_AI_TESTS"] == "1"))
    func readsCitedPaperFromSlideImage() async throws {
        let config = try #require(
            KeychainService.resolveConfig(for: .slideCitationExtraction),
            "No model configured for slide citation extraction"
        )
        let reply = try await AIService().call(
            config: config,
            system: AITask.slideCitationExtraction.effectivePrompt ?? Prompts.slideCitationExtraction,
            user: "Read the slide image and list the papers it cites.",
            maxTokens: 900,
            temperature: 0,
            imageJPEGData: try fixtureImage()
        )

        let citations = try SlideCitationService.decodeCitations(reply)
        // title is optional now — a slide can credit a paper without printing its title.
        let titles = citations.compactMap { $0.title }.map(VideoCitedPaper.normalizeTitle)
        let expected = VideoCitedPaper.normalizeTitle(
            "A Network of Macrophages Supports Mitochondrial Homeostasis in the Heart"
        )

        #expect(
            titles.contains { SlideCitationService.titlesMatch($0, expected) },
            "Expected the macrophages paper. Model returned: \(titles)"
        )
    }
}

/// Marking the frames the vision pass flagged as photographs of the room, so a deck page and a
/// camera shot of it stop showing as two slides — without deleting the frame, so a misjudgement
/// is reversible and a bad scan can never lose a real slide.
@Suite("Non-slide frame marking")
struct NonSlideFrameMarkingTests {
    private static let path1 = "Videos/src_1/Slides/slide_001_10s.jpg"
    private static let path2 = "Videos/src_1/Slides/slide_002_60s.jpg"
    private static let path3 = "Videos/src_1/Slides/slide_003_80s.jpg"

    /// A three-slide deck where the middle frame is a camera shot of the room.
    private static let deck = """
    Transcript body goes here.

    ## Extracted video slide frames

    Representative slide screenshots extracted from YouTube video frames.

    ### Slide frame 1 [0:10–1:00]
    Image: \(path1)

    ### Slide frame 2 [1:00–1:20]
    Image: \(path2)

    ### Slide frame 3 [1:20–2:00]
    Image: \(path3)
    """

    @Test("Marks the flagged frame and keeps every block, hiding it only from display")
    func marksFlaggedFrame() throws {
        let rewritten = try #require(
            YouTubeSlideContentParser.markingNonSlideFrames(
                [Self.path2], clearingAmong: [Self.path1, Self.path2, Self.path3], in: Self.deck
            )
        )

        let parsed = YouTubeSlideContentParser.parse(rewritten)
        // Every block survives — the frame is marked, not deleted, so its cited-paper keying
        // and a chance to reclassify it both remain.
        #expect(parsed.slides.map(\.index) == [1, 2, 3])
        #expect(rewritten.contains(Self.path2))
        // Only the flagged frame carries the mark, and only it is hidden from the reader.
        #expect(parsed.slides.first { $0.index == 2 }?.isNonSlide == true)
        #expect(parsed.slides.first { $0.index == 1 }?.isNonSlide == false)
        #expect(parsed.displaySlides.map(\.index) == [1, 3])
        #expect(rewritten.contains("Transcript body goes here."))
    }

    @Test("Is idempotent: marking an already-marked frame changes nothing")
    func markingIsIdempotent() throws {
        let once = try #require(
            YouTubeSlideContentParser.markingNonSlideFrames(
                [Self.path2], clearingAmong: [Self.path2], in: Self.deck
            )
        )
        // A second identical scan finds nothing to change.
        #expect(
            YouTubeSlideContentParser.markingNonSlideFrames(
                [Self.path2], clearingAmong: [Self.path2], in: once
            ) == nil
        )
    }

    @Test("Clears a stale mark when a rescan judges the frame a real slide")
    func clearsStaleMark() throws {
        let marked = try #require(
            YouTubeSlideContentParser.markingNonSlideFrames(
                [Self.path2], clearingAmong: [Self.path2], in: Self.deck
            )
        )
        // A later scan looks at frame 2 again and judges it a slide: it is scanned but not
        // flagged, so its mark is cleared and it returns to the display.
        let cleared = try #require(
            YouTubeSlideContentParser.markingNonSlideFrames(
                [], clearingAmong: [Self.path2], in: marked
            )
        )
        #expect(YouTubeSlideContentParser.parse(cleared).displaySlides.map(\.index) == [1, 2, 3])
    }

    @Test("Leaves a mark alone when the rescan never reached that frame")
    func keepsMarkOutsideScannedSet() throws {
        let marked = try #require(
            YouTubeSlideContentParser.markingNonSlideFrames(
                [Self.path2], clearingAmong: [Self.path2], in: Self.deck
            )
        )
        // A single-slide rescan of frame 1 must not un-hide frame 2, which it never looked at.
        #expect(
            YouTubeSlideContentParser.markingNonSlideFrames(
                [], clearingAmong: [Self.path1], in: marked
            ) == nil
        )
        #expect(YouTubeSlideContentParser.parse(marked).displaySlides.map(\.index) == [1, 3])
    }

    @Test("Returns nil when nothing to mark and nothing to clear")
    func returnsNilForEmptyWork() {
        #expect(
            YouTubeSlideContentParser.markingNonSlideFrames([], clearingAmong: [], in: Self.deck) == nil
        )
    }

    /// Content without a slide section is not a video with slides; leave it be.
    @Test("Returns nil when there is no slide section")
    func noSectionReturnsNil() {
        #expect(
            YouTubeSlideContentParser.markingNonSlideFrames(
                ["anything"], clearingAmong: ["anything"], in: "Just a transcript, no slides."
            ) == nil
        )
    }
}

/// The write-time guard that refuses to act on a scan that flagged a majority of frames — the
/// classifier misfiring, not a deck that is mostly camera shots.
@Suite("Misclassified-scan guard")
struct MisclassifiedScanGuardTests {
    private static func result(nonSlide: [String], scanned: [String]) -> SlideCitationService.ScanResult {
        SlideCitationService.ScanResult(
            candidates: [], slidesScanned: scanned.count, slidesFailed: 0,
            nonSlideFramePaths: nonSlide, scannedFramePaths: scanned
        )
    }

    private static let deck = """
    Body.

    ## Extracted video slide frames

    ### Slide frame 1 [0:10]
    Image: a.jpg

    ### Slide frame 2 [0:20]
    Image: b.jpg

    ### Slide frame 3 [0:30]
    Image: c.jpg
    """

    @Test("A minority of flagged frames is trusted and marked")
    func minorityIsApplied() throws {
        let r = Self.result(nonSlide: ["b.jpg"], scanned: ["a.jpg", "b.jpg", "c.jpg"])
        #expect(!SlideCitationService.isMisclassifiedScan(r))
        let rewritten = try #require(SlideCitationService.contentMarkingNonSlideFrames(for: r, in: Self.deck))
        #expect(YouTubeSlideContentParser.parse(rewritten).displaySlides.map(\.index) == [1, 3])
    }

    @Test("A majority of flagged frames is treated as a misfire and ignored")
    func majorityIsIgnored() {
        let r = Self.result(nonSlide: ["a.jpg", "b.jpg"], scanned: ["a.jpg", "b.jpg", "c.jpg"])
        #expect(SlideCitationService.isMisclassifiedScan(r))
        // Nothing is written, so the deck keeps whatever an earlier sane scan left it.
        #expect(SlideCitationService.contentMarkingNonSlideFrames(for: r, in: Self.deck) == nil)
    }

    @Test("Exactly half flagged is still trusted")
    func halfIsApplied() throws {
        let r = Self.result(nonSlide: ["a.jpg", "b.jpg"], scanned: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        #expect(!SlideCitationService.isMisclassifiedScan(r))
        #expect(SlideCitationService.contentMarkingNonSlideFrames(for: r, in: Self.deck) != nil)
    }
}
