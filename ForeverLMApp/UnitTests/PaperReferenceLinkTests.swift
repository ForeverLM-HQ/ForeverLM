import Foundation
import Testing
@testable import ForeverLM

@Suite("Paper reference lists: reading")
struct PaperReferenceParserTests {

    /// A NEJM-style numbered list: hyphenated lines, a running foot in the middle of an entry.
    private func numberedPaper() -> String {
        let page1 = """
        Introduction
        Some body text.
        References
        1. Pickett SJ, Grady JP, Ng YS, et al. Pheno-
        typic heterogeneity in m.3243A>G mito-
        chondrial disease: the role of nuclear fac-
        tors. Ann Clin Transl Neurol 2018; 5:
        333-45.
        2. Jenuth JP, Peterson AC, Shoubridge
        EA. Tissue-specific selection for different
        mtDNA genotypes in heteroplasmic mice.
        Nat Genet 1997; 16: 93-5.
        3. Manwaring N, Jones MM, Wang JJ,
        et al. Population prevalence of the MELAS
        A3243G mutation. Mitochondrion 2007; 7:
        230-3.
        1562
        n engl j med 383;16 nejm.org October 15, 2020
        """
        let page2 = """
        Brief Report
        4. Elliott HR, Samuels DC, Eden JA, Rel-
        ton CL, Chinnery PF. Pathogenic mito-
        chondrial DNA mutations are common in
        the general population. Am J Hum Genet
        2008; 83: 254-60. doi:10.1016/j.ajhg.2008.07.001
        Copyright © 2020 Massachusetts Medical Society.
        """
        return [filler("A"), filler("B"), page1, page2].joined(separator: "\u{000C}")
    }

    /// A page of prose with the journal's running head and foot, so the head and foot recur.
    private func filler(_ tag: String) -> String {
        """
        Brief Report
        Body text of page \(tag) goes here and says nothing about references.
        n engl j med 383;16 nejm.org October 15, 2020
        """
    }

    @Test("A numbered list is read entry by entry, hyphens closed, running lines left out")
    func numbered() {
        let entries = PaperReferenceParser.entries(inPaperText: numberedPaper())
        #expect(entries.map(\.ordinal) == [1, 2, 3, 4])
        #expect(entries[0].text.hasPrefix("Pickett SJ, Grady JP, Ng YS, et al. Phenotypic heterogeneity in m.3243A>G mitochondrial disease"))
        #expect(entries[0].text.hasSuffix("2018; 5: 333-45."))
        #expect(entries[2].text.hasSuffix("2007; 7: 230-3."))
        #expect(!entries[2].text.contains("1562"))
        #expect(!entries[2].text.contains("nejm.org"))
        #expect(!entries[3].text.contains("Copyright"))
        #expect(PaperReferenceIdentity.doi(in: entries[3].text) == "10.1016/j.ajhg.2008.07.001")
    }

    @Test("Numbers set in a column of their own (Nature) take the entries after them in order")
    func numberRun() {
        let text = """
        Online content
        Methods are available at https://doi.org/10.1038/s41586-000-0000-0.
        1. 2. 3. 4. Anderson, S. et al. Sequence and organization of the human mitochondrial genome.
        Nature 290, 338–346 (1981).
        Wanrooij, P. H., Uhler, J. P. & Gustafsson, C. M. G-quadruplex structures in RNA stimulate
        mitochondrial transcription termination. Proc. Natl Acad. Sci. USA 107, 16072–16077 (2010).
        van Goethem, G., Dermaut, B. & van Broeckhoven, C. Mutation of POLG is associated with
        progressive external ophthalmoplegia. Nat. Genet. 28, 211–212 (2001).
        Article
        Nishino, I., Spinazzola, A. & Hirano, M. Thymidine phosphorylase gene mutations in MNGIE.
        Science 283, 689–692 (1999).
        Acknowledgements We thank everyone.
        """
        let entries = PaperReferenceParser.entries(inPaperText: text)
        #expect(entries.map(\.ordinal) == [1, 2, 3, 4])
        #expect(entries[0].text.hasPrefix("Anderson, S. et al."))
        #expect(entries[2].text.hasPrefix("van Goethem, G."))
        #expect(entries[3].text.hasSuffix("Science 283, 689–692 (1999)."))
    }

    @Test("A run whose entries do not count out to its numbers is not guessed at")
    func numberRunMismatch() {
        let text = """
        References
        1. 2. 3. 4. 5. Anderson, S. et al. Sequence and organization of the human genome.
        Nature 290, 338–346 (1981).
        Wanrooij, P. H., Uhler, J. P. & Gustafsson, C. M. G-quadruplex structures in RNA.
        Proc. Natl Acad. Sci. USA 107, 16072–16077 (2010).
        """
        #expect(PaperReferenceParser.entries(inPaperText: text).isEmpty)
    }

    @Test("Section headings numbered 1, 2, 3 and affiliations are not a reference list")
    func notAList() {
        let text = """
        1. Introduction
        Text text text text text text text text text text text text.
        2. Methods
        Text text text text text text text text text text text text.
        3. Results
        Text text text text text text text text text text text text.
        4. Discussion
        Text text text text text text text text text text text text.
        """
        #expect(PaperReferenceParser.entries(inPaperText: text).isEmpty)
    }

    @Test("An unnumbered author-year list is labelled by surname and year")
    func authorYear() {
        let text = """
        References
        Alasoo, K., Rodrigues, J., and Gaffney, D.J. (2017). Genetic effects on chromatin accessibility. Nat. Genet. 49, 1-10.
        Barton, N.H. (1990). Pleiotropic models of quantitative variation. Genetics 124, 773–782.
        Battle, A., Khan, Z., and Gilad, Y. (2015). Impact of regulatory variation from RNA to protein. Science 347, 664–667.
        Botstein, D., and Risch, N. (2003). Discovering genotypes underlying human phenotypes. Nat. Genet. 33, 228–237.
        Yu, S.P., Yeh, C.H., and Choi, D.W. (1999a). Role of the outward delayed rectifier K+ current. J. Neurochem. 73, 933–941.
        Yu, S.P., Yeh, C.H., and Choi, D.W. (1999b). NMDA receptor-mediated K+ efflux. Science 284, 336–339.
        """
        let entries = PaperReferenceParser.entries(inPaperText: text)
        #expect(entries.map(\.label) == [
            "Alasoo 2017", "Barton 1990", "Battle 2015", "Botstein 2003", "Yu 1999a", "Yu 1999b",
        ])
        #expect(entries.map(\.ordinal) == [1, 2, 3, 4, 5, 6])
    }

    @Test("Initials without a comma open an author-year entry too")
    func authorYearWithoutComma() {
        let text = """
        References
        Albamonte MS, Willis MA, Vitullo AD. 2008. The developing human ovary. Human Reproduction 23:1895–1901.
        Allen JF, de Paula WB. 2013. Mitochondrial genome function and maternal inheritance. Biochem Soc Trans 41:1298–1304.
        Allio R, Donega S, Galtier N. 2017. Large variation in the ratio of mitochondrial to nuclear mutation rate. Mol Biol Evol 34:2762.
        Arbeithuber B, Hester J, Makova KD. 2020. Age-related accumulation of de novo mutations. PLOS Biology 18:e3000745.
        Bergstrom CT, Pritchard J. 1998. Germline bottlenecks and the maintenance of mitochondrial DNA. Genetics 149:2135.
        Schmidt-Nielsen K. 1970. Energy metabolism, body size, and the problems of scaling. FedProc. 29:1524–1532.
        """
        let entries = PaperReferenceParser.entries(inPaperText: text)
        #expect(entries.map(\.label) == [
            "Albamonte 2008", "Allen 2013", "Allio 2017", "Arbeithuber 2020", "Bergstrom 1998", "Schmidt-Nielsen 1970",
        ])
        // A lone author's comma-less name ends at the initials, not at the title's first comma.
        #expect(PaperReferenceParser.authorYearLabel(of: "Harman D. 1956. Aging: a theory based on free radical and radiation chemistry. J Gerontol. 11(3):298–300.") == "Harman 1956")
    }

    @Test("A PubMed Central entry ends at its catalog tags, and an inline Acknowledgments heading ends the last entry")
    func entryEnds() {
        #expect(PaperReferenceParser.cleaned("Godin AG. Super-resolution microscopy. Biophys J. 2014; 107:1777. [PubMed: 25418158] Box 1 Modes of Mitochondrial Communication")
                == "Godin AG. Super-resolution microscopy. Biophys J. 2014; 107:1777. [PubMed: 25418158]")
        #expect(PaperReferenceParser.cleaned("Smith J. A title that is long enough here. Science 2020. Acknowledgments: We thank Zara Holt.")
                == "Smith J. A title that is long enough here. Science 2020.")
        #expect(PaperReferenceParser.cleaned("Shoubridge EA. Tissue selection. Nat Genet 1997; 16: 189- 201.").hasSuffix("189-201."))
    }
}

@Suite("Paper reference lists: identity, markers and the index")
struct PaperReferenceIdentityTests {

    @Test("A DOI is read out of an entry and normalised; other addresses follow in order")
    func printedIdentity() {
        #expect(PaperReferenceIdentity.doi(in: "Lee K. Title. Cell 2019. doi: 10.1016/J.Cell.2019.01.001.") == "10.1016/j.cell.2019.01.001")
        #expect(PaperReferenceIdentity.printedLink(in: "Lee K. Title. Cell 2019. DOI: https://doi.org/10.1016/j.cell.2019.01.001, PMID: 123456")?.origin == .printedDOI)
        let arxiv = PaperReferenceIdentity.printedLink(in: "Lee K. Title. arXiv:2101.01234v2 (2021).")
        #expect(arxiv?.url == "https://arxiv.org/abs/2101.01234")
        #expect(arxiv?.doi == nil)
        #expect(PaperReferenceIdentity.printedLink(in: "Godin AG. Title. Biophys J. 2014. [PubMed: 25418158]")?.url == "https://pubmed.ncbi.nlm.nih.gov/25418158/")
        #expect(PaperReferenceIdentity.printedLink(in: "Lab. Data at https://example.org/data/set1.")?.url == "https://example.org/data/set1")
        #expect(PaperReferenceIdentity.printedLink(in: "Pickett SJ. Title. J Med 2018; 5: 333-45.") == nil)
    }

    @Test("A DOI handed over in any form normalises to the bare lower-case DOI, and a non-DOI is refused")
    func normalizedDOI() {
        #expect(PaperReferenceIdentity.normalizedDOI("https://doi.org/10.1038/S41586-020-2649-2") == "10.1038/s41586-020-2649-2")
        #expect(PaperReferenceIdentity.normalizedDOI("doi:10.1016%2Fj.cell.2019.01.001") == "10.1016/j.cell.2019.01.001")
        #expect(PaperReferenceIdentity.normalizedDOI(" 10.1000/xyz123. ") == "10.1000/xyz123")
        #expect(PaperReferenceIdentity.normalizedDOI("pubmed 12345") == nil)
        #expect(PaperReferenceIdentity.normalizedDOI("") == nil)
    }

    @Test("Years are read outside addresses")
    func years() {
        #expect(PaperReferenceIdentity.years(in: "Lee K. Title 1999. Cell 2019; 176: 1325. doi:10.1016/j.cell.2019.2020.5") == [1999, 2019])
    }

    @Test("Citation numbers: lists, ranges, brackets and superscript digits; letters name no number")
    func markerNumbers() {
        #expect(PaperCitationMarker.numbers(in: "5") == [5])
        #expect(PaperCitationMarker.numbers(in: "5–7") == [5, 6, 7])
        #expect(PaperCitationMarker.numbers(in: "[3, 5-6, 9]") == [3, 5, 6, 9])
        #expect(PaperCitationMarker.numbers(in: "\u{00B9}\u{00B2}") == [12])
        #expect(PaperCitationMarker.numbers(in: "\u{2075}\u{207B}\u{2077}") == [5, 6, 7])
        #expect(PaperCitationMarker.numbers(in: "\u{00B2}\u{02D2}\u{2074}") == [2, 4])
        #expect(PaperCitationMarker.numbers(in: "7-5").isEmpty)
        #expect(PaperCitationMarker.numbers(in: "1-900").isEmpty)
        #expect(PaperCitationMarker.numbers(in: "Smith 2019").isEmpty)
    }

    @Test("Author-year markers read every citation in them")
    func markerAuthorYear() {
        let citations = PaperCitationMarker.authorYear(in: "(Smith et al., 2019; Lee and Park 2020a; Cho 2018, 2019)")
        #expect(citations.map(\.surname) == ["Smith", "Lee", "Cho", "Cho"])
        #expect(citations.map(\.year) == ["2019", "2020", "2018", "2019"])
        #expect(citations[1].suffix == "a")
        #expect(citations[0].matches(label: "Smith 2019"))
        #expect(citations[1].matches(label: "Lee 2020a"))
        #expect(!citations[1].matches(label: "Lee 2020b"))
        #expect(!citations[0].matches(label: "Smith 2018"))
    }

    private func index() -> PaperReferenceIndex {
        let texts = [
            "Pickett SJ, Grady JP. Phenotypic heterogeneity in mitochondrial disease. Ann Clin Transl Neurol 2018; 5: 333-45.",
            "Jenuth JP, Peterson AC. Tissue-specific selection for different mtDNA genotypes in mice. Nat Genet 1997; 16: 93-5.",
            "Manwaring N, Jones MM. Population prevalence of the MELAS A3243G mutation. Mitochondrion 2007; 7: 230-3.",
        ]
        var references = texts.enumerated().map { offset, text in
            PaperReference(sourceID: "paper", ordinal: offset + 1, label: String(offset + 1), text: text)
        }
        references[1].url = "https://doi.org/10.1038/ng0597-93"
        references[1].doi = "10.1038/ng0597-93"
        references[1].origin = .catalog
        references[2].url = "ftp://example.org/x"
        return PaperReferenceIndex(sourceID: "paper", references: references)
    }

    @Test("A number, a range and a marker resolve to entries; a link is only an http(s) address")
    func resolvesMarkers() {
        let index = index()
        #expect(index.link(forNumber: 2)?.absoluteString == "https://doi.org/10.1038/ng0597-93")
        #expect(index.link(forNumber: 1) == nil)
        #expect(index.link(forNumber: 3) == nil, "an address that is not http or https is not a link")
        #expect(index.link(forNumber: 9) == nil)
        #expect(index.references(forMarker: "1–3").map(\.ordinal) == [1, 2, 3])
        #expect(index.references(forMarker: "2,2,3").map(\.ordinal) == [2, 3])
        #expect(index.references(forMarker: "8, 2").map(\.ordinal) == [2], "a number past the list names nothing")
    }

    @Test("An author-year marker resolves through the labels")
    func resolvesAuthorYear() {
        let references = [
            PaperReference(sourceID: "p", ordinal: 1, label: "Alasoo 2017", text: "Alasoo, K. (2017). Title."),
            PaperReference(sourceID: "p", ordinal: 2, label: "Yu 1999a", text: "Yu, S.P. (1999a). One."),
            PaperReference(sourceID: "p", ordinal: 3, label: "Yu 1999b", text: "Yu, S.P. (1999b). Two."),
        ]
        let index = PaperReferenceIndex(sourceID: "p", references: references)
        #expect(index.references(forMarker: "(Alasoo et al., 2017)").map(\.ordinal) == [1])
        #expect(index.references(forMarker: "Yu et al., 1999b").map(\.ordinal) == [3])
        #expect(index.references(forMarker: "Yu 1999").map(\.ordinal) == [2, 3])
    }

    @Test("The entry the PDF's own link landed on is found by its DOI or its first words")
    func matchesEntryText() {
        let index = index()
        let landed = "2. Jenuth JP, Peterson AC. Tissue-specific selection for different mtDNA genotypes in mice. Nat Genet 1997; 16: 93-5."
        #expect(index.reference(matchingEntryText: landed)?.ordinal == 2)
        #expect(index.link(forEntryText: "Jenuth JP, Peterson AC. Tissue specific selection for different mtDNA genotypes")?.absoluteString
                == "https://doi.org/10.1038/ng0597-93")
        #expect(index.reference(matchingEntryText: "Affiliation line") == nil)
    }
}

@Suite("Paper reference lists: linking")
struct PaperReferenceLinkingTests {

    private func record(
        doi: String = "10.1002/ana.51",
        title: String = "Phenotypic heterogeneity in m.3243A>G mitochondrial disease: the role of nuclear factors",
        year: String? = "2018", authors: String? = "Pickett; Grady; Ng",
        volume: String? = "5", firstPage: String? = "333"
    ) -> SlideCitationService.ResolvedPaper {
        SlideCitationService.ResolvedPaper(
            doi: doi, title: title, journal: "Annals of Clinical and Translational Neurology",
            year: year, authors: authors, volume: volume, firstPage: firstPage
        )
    }

    private let entry = "Pickett SJ, Grady JP, Ng YS, et al. Phenotypic heterogeneity in m.3243A>G mitochondrial disease: the role of nuclear factors. Ann Clin Transl Neurol 2018; 5: 333-45."

    @Test("A record is accepted when the entry prints its title, the year agrees and its first author is printed")
    func acceptsPrintedTitle() {
        #expect(PaperReferenceCatalogMatch.accepted(entry: entry, among: [record()])?.doi == "10.1002/ana.51")
        // An issue year against an online-first one.
        #expect(PaperReferenceCatalogMatch.accepted(entry: entry, among: [record(year: "2017")]) != nil)
    }

    @Test("A record is refused when the title is not printed, the year is two off, or the author is not")
    func refuses() {
        #expect(PaperReferenceCatalogMatch.accepted(entry: entry, among: [record(title: "A different paper about something else entirely", volume: nil, firstPage: nil)]) == nil)
        #expect(PaperReferenceCatalogMatch.accepted(entry: entry, among: [record(year: "2014")]) == nil)
        #expect(PaperReferenceCatalogMatch.accepted(entry: entry, among: [record(authors: "Zhang; Wei")]) == nil)
        #expect(PaperReferenceCatalogMatch.accepted(entry: entry, among: [record(year: nil)]) == nil)
    }

    @Test("Two different DOIs that both fit settle nothing; the same DOI twice is one")
    func uniqueness() {
        #expect(PaperReferenceCatalogMatch.accepted(entry: entry, among: [record(), record(doi: "10.1002/ana.99")]) == nil)
        #expect(PaperReferenceCatalogMatch.accepted(entry: entry, among: [record(), record(doi: "10.1002/ANA.51")]) != nil)
    }

    @Test("Volume and first page beside the author and year name a paper whose title the entry breaks")
    func locatorPath() {
        let broken = "Pickett SJ, Grady JP. Phenotypic heterogeneity in mito disease. Ann Clin Transl Neurol 2018; 5: 333-45."
        #expect(PaperReferenceCatalogMatch.accepted(entry: broken, among: [record()]) != nil)
        #expect(PaperReferenceCatalogMatch.accepted(entry: broken, among: [record(volume: "6")]) == nil)
        #expect(PaperReferenceCatalogMatch.accepted(entry: broken, among: [record(firstPage: "33")]) == nil)
    }

    @Test("Canned Crossref JSON parses into a record the entry is matched against")
    func crossrefJSON() throws {
        let json = """
        {"DOI":"10.1002/ana.51","title":["Phenotypic heterogeneity in m.3243A>G mitochondrial disease: the role of nuclear factors"],
         "container-title":["Ann Clin Transl Neurol"],"issued":{"date-parts":[[2018,5]]},
         "author":[{"family":"Pickett"},{"family":"Grady"}],"volume":"5","page":"333-345"}
        """
        let item = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let parsed = try #require(SlideCitationService.parseCrossrefItem(item))
        #expect(PaperReferenceCatalogMatch.accepted(entry: entry, among: [parsed])?.doi == "10.1002/ana.51")
    }

    // MARK: Resolving one entry against canned catalogs

    private func catalogs(
        record: ReferenceCatalogAnswer<SlideCitationService.ResolvedPaper?> = .answered(nil),
        crossref: ReferenceCatalogAnswer<[SlideCitationService.ResolvedPaper]> = .answered([]),
        openAlex: ReferenceCatalogAnswer<[SlideCitationService.ResolvedPaper]> = .answered([])
    ) -> PaperReferenceCatalogs {
        PaperReferenceCatalogs(
            recordForDOI: { _ in record },
            crossrefCandidates: { _ in crossref },
            openAlexCandidates: { _ in openAlex }
        )
    }

    @Test("An entry that prints a DOI keeps it as its link and takes the record's description")
    func printedDOIEntry() async {
        let initial = PaperLinkHarness.initial("Lee K. Title of a paper that is printed here. Cell 2019; 5: 1. doi:10.1016/j.cell.2019.01.001")
        #expect(initial.origin == .printedDOI)
        #expect(initial.url == "https://doi.org/10.1016/j.cell.2019.01.001")
        let (done, answered) = await PaperReferenceLinkService.resolved(
            initial,
            catalogs: catalogs(record: .answered(record(doi: "10.1016/j.cell.2019.01.001", title: "Title of a paper that is printed here")))
        )
        #expect(answered)
        #expect(done.title == "Title of a paper that is printed here")
        #expect(done.doi == "10.1016/j.cell.2019.01.001")
        #expect(done.origin == .printedDOI)
        #expect(done.catalogCheckedAt != nil)
    }

    @Test("An entry with no printed identity takes the Crossref record it prints, else OpenAlex's")
    func catalogEntry() async {
        let initial = PaperLinkHarness.initial(entry)
        #expect(initial.url == nil)
        let (viaCrossref, _) = await PaperReferenceLinkService.resolved(initial, catalogs: catalogs(crossref: .answered([record()])))
        #expect(viaCrossref.origin == .catalog)
        #expect(viaCrossref.url == "https://doi.org/10.1002/ana.51")
        let (viaOpenAlex, _) = await PaperReferenceLinkService.resolved(
            initial, catalogs: catalogs(crossref: .answered([]), openAlex: .answered([record(doi: "10.1002/ana.77")]))
        )
        #expect(viaOpenAlex.doi == "10.1002/ana.77")
    }

    @Test("A catalog that did not answer leaves the entry unchecked; one that answered no match dates it")
    func unavailable() async {
        let initial = PaperLinkHarness.initial(entry)
        let (unasked, answeredA) = await PaperReferenceLinkService.resolved(initial, catalogs: catalogs(crossref: .unavailable("offline")))
        #expect(!answeredA)
        #expect(unasked.catalogCheckedAt == nil)
        let (none, answeredB) = await PaperReferenceLinkService.resolved(
            initial, catalogs: catalogs(crossref: .answered([]), openAlex: .unavailable("429"))
        )
        #expect(answeredB, "Crossref answered; OpenAlex is a second chance, not a reason to ask again")
        #expect(none.url == nil)
        #expect(none.catalogCheckedAt != nil)
        #expect(!PaperReferenceLinkService.needsCatalog(none))
        #expect(PaperReferenceLinkService.needsCatalog(unasked))
    }

    @Test("OpenAlex is searched by the printed title, and a record PubMed alone indexes links to PubMed")
    func pubMedOnlyRecord() async throws {
        let entry = "Schmidt-Nielsen K. 1970. Energy metabolism, body size, and the problems of scaling. FedProc. 29:1524–1532."
        #expect(PaperReferenceLinkService.openAlexSearchText(of: entry) == "Energy metabolism, body size, and the problems of scaling")
        // OpenAlex's record for it, as the API returns it (2026-11-08): no DOI, PubMed as the
        // "source", a title that leaves out "the", and the volume and first page.
        let json = """
        {"id":"https://openalex.org/W2406999319","doi":null,"title":"Energy metabolism, body size, and problems of scaling.",
         "publication_year":1970,"ids":{"openalex":"https://openalex.org/W2406999319","pmid":"https://pubmed.ncbi.nlm.nih.gov/5459901"},
         "primary_location":{"source":{"display_name":"PubMed","type":"repository"}},
         "authorships":[{"author":{"display_name":"Knut Schmidt‐Nielsen"}}],
         "biblio":{"volume":"29","issue":"4","first_page":"1524","last_page":"32"}}
        """
        let work = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(SlideCitationService.parseOpenAlexWork(work) == nil, "a slide's citation still needs a DOI")
        let parsed = try #require(ReferenceCatalogClient.parseOpenAlexReferenceWork(work))
        #expect(parsed.doi.isEmpty)
        #expect(parsed.pubMedID == "5459901")
        #expect(parsed.journal == nil, "PubMed is where OpenAlex found it, not its journal")

        let searched = SearchedFor()
        let catalogs = PaperReferenceCatalogs(
            recordForDOI: { _ in .answered(nil) },
            crossrefCandidates: { _ in .answered([]) },
            openAlexCandidates: { text in await searched.note(text); return .answered([parsed]) }
        )
        let (done, answered) = await PaperReferenceLinkService.resolved(PaperLinkHarness.initial(entry), catalogs: catalogs)
        #expect(answered)
        #expect(await searched.texts == ["Energy metabolism, body size, and the problems of scaling"])
        #expect(done.origin == .catalog)
        #expect(done.doi == nil)
        #expect(done.url == "https://pubmed.ncbi.nlm.nih.gov/5459901/")
        #expect(done.year == "1970")

        // Two PubMed ids that both fit settle nothing, like two DOIs.
        let other = SlideCitationService.ResolvedPaper(
            doi: "", title: parsed.title, journal: nil, year: "1970", authors: "Knut Schmidt-Nielsen",
            volume: "29", firstPage: "1524", pubMedID: "1"
        )
        #expect(PaperReferenceCatalogMatch.accepted(entry: entry, among: [parsed, other]) == nil)
        #expect(PaperReferenceCatalogMatch.accepted(entry: entry, among: [parsed, parsed])?.pubMedID == "5459901")
    }

    @Test("Candidates are made for linked entries, and the rest are handed to the model as text")
    func candidates() {
        var linked = PaperReference(sourceID: "paper", ordinal: 1, label: "1", text: "Lee K. A paper. Cell 2019.")
        linked.doi = "10.1016/j.cell.2019.01.001"
        linked.url = "https://doi.org/10.1016/j.cell.2019.01.001"
        linked.title = "A paper"
        let unlinked = PaperReference(sourceID: "paper", ordinal: 2, label: "2", text: "Cho Y. Another. Nature 2020.")
        let read = StudioViewModel.citedPaperCandidates(from: [linked, unlinked], sourceID: "paper")
        #expect(read.candidates.map(\.title) == ["A paper"])
        #expect(read.candidates.first?.status == .pending)
        #expect(read.candidates.first?.url == "https://doi.org/10.1016/j.cell.2019.01.001")
        #expect(read.unlinkedText == "Cho Y. Another. Nature 2020.")
        #expect(read.entryCount == 2)
    }
}

private actor SearchedFor {
    private(set) var texts: [String] = []
    func note(_ text: String) { texts.append(text) }
}

private enum PaperLinkHarness {
    static func initial(_ text: String) -> PaperReference {
        PaperReferenceLinkService.initialReference(
            for: PaperReferenceParser.Entry(ordinal: 1, label: "1", text: text), sourceID: "paper", now: Date()
        )
    }
}

@Suite("Paper reference lists: storage")
struct PaperReferenceStorageTests {

    private func store(_ name: String) throws -> (KnowledgeStore, URL) {
        let root = try Schema154Fixture.temporaryRoot(name)
        let store = try KnowledgeStore(storeDirectory: root)
        return (store, root)
    }

    private func addPaper(_ store: KnowledgeStore, _ id: String, path: String? = "Papers/x.pdf", status: String = "active") throws {
        try store.execForTesting("""
            INSERT INTO sources (id, date_added, state, source_type, status) VALUES ('\(id)', 0, 'ready', 'paper', '\(status)');
            INSERT INTO papers (source_id, url, local_file_path) VALUES ('\(id)', 'https://doi.org/10.1/\(id)', \(path.map { "'\($0)'" } ?? "NULL"));
        """)
    }

    @Test("A paper's queue row is made once, left alone once read from the same file, and queued again by a new file")
    func queueLifecycle() throws {
        let (store, root) = try store("paper-references-queue")
        defer { try? FileManager.default.removeItem(at: root) }
        try addPaper(store, "p")
        try store.enqueuePaperReferenceRead(sourceID: "p", pdfPath: "Papers/x.pdf")
        #expect(try store.paperReferenceReadCandidates(limit: 5).count == 1)

        try store.savePaperReference(PaperReference(sourceID: "p", ordinal: 1, label: "1", text: "Entry one text"))
        try store.finishPaperReferenceRead(sourceID: "p", pdfPath: "Papers/x.pdf", failure: nil, authoredBy: "app")
        #expect(try store.paperReferenceReadCandidates(limit: 5).isEmpty)
        #expect(try store.paperReferenceReadState(sourceID: "p")?.entryCount == 1)

        // The save a reader makes again changes nothing.
        try store.enqueuePaperReferenceRead(sourceID: "p", pdfPath: "Papers/x.pdf")
        #expect(try store.paperReferenceReadState(sourceID: "p")?.state == .read)
        // A new file is read again, from scratch.
        try store.enqueuePaperReferenceRead(sourceID: "p", pdfPath: "Papers/y.pdf")
        #expect(try store.paperReferenceReadState(sourceID: "p")?.state == .queued)
        #expect(try store.paperReferenceReadState(sourceID: "p")?.entryCount == 0)
    }

    @Test("A failed read counts an attempt and stops being offered after the fifth; an archived paper is not offered")
    func attempts() throws {
        let (store, root) = try store("paper-references-attempts")
        defer { try? FileManager.default.removeItem(at: root) }
        try addPaper(store, "p")
        try addPaper(store, "gone", status: "archived")
        try store.enqueuePaperReferenceRead(sourceID: "p", pdfPath: "Papers/x.pdf")
        try store.enqueuePaperReferenceRead(sourceID: "gone", pdfPath: "Papers/x.pdf")
        #expect(try store.paperReferenceReadCandidates(limit: 5).map(\.sourceID) == ["p"])
        for attempt in 1...KnowledgeStore.maximumPaperReferenceReadAttempts {
            try store.finishPaperReferenceRead(sourceID: "p", pdfPath: nil, failure: "offline", authoredBy: "app")
            let state = try #require(try store.paperReferenceReadState(sourceID: "p"))
            #expect(state.lastError == "offline")
            #expect(state.state == (attempt < KnowledgeStore.maximumPaperReferenceReadAttempts ? .queued : .read))
        }
        #expect(try store.paperReferenceReadCandidates(limit: 5).isEmpty)
    }

    @Test("A new read keeps what the stored list learned, drops entries it no longer finds, and never replaces an assistant's entry")
    func replaceMerges() throws {
        let (store, root) = try store("paper-references-replace")
        defer { try? FileManager.default.removeItem(at: root) }
        try addPaper(store, "p")
        var first = PaperReference(sourceID: "p", ordinal: 1, label: "1", text: "Pickett SJ. Phenotypic heterogeneity in disease. Ann 2018.")
        first.doi = "10.1002/ana.51"; first.url = "https://doi.org/10.1002/ana.51"; first.origin = .catalog
        first.catalogCheckedAt = Date()
        var second = PaperReference(sourceID: "p", ordinal: 2, label: "2", text: "Old second entry that the new read will not find.")
        let third = PaperReference(sourceID: "p", ordinal: 3, label: "3", text: "Third entry text, as the first read had it.")
        var agent = PaperReference(sourceID: "p", ordinal: 4, label: "4", text: "Authored by an assistant, with its own words.")
        agent.url = "https://example.org/four"; agent.origin = .agent
        second.origin = .none
        try store.replacePaperReferenceList(sourceID: "p", entries: [first, second, third, agent])

        let reread = [
            PaperReference(sourceID: "p", ordinal: 1, label: "1", text: "Pickett SJ. Phenotypic heterogeneity in disease. Ann 2018."),
            PaperReference(sourceID: "p", ordinal: 3, label: "3", text: "Another third entry, now read quite differently."),
            PaperReference(sourceID: "p", ordinal: 4, label: "4", text: "A rewritten fourth that must not replace the assistant's."),
        ]
        try store.replacePaperReferenceList(sourceID: "p", entries: reread)
        let stored = try store.loadPaperReferences(sourceID: "p")
        #expect(stored.map(\.ordinal) == [1, 3, 4])
        #expect(stored[0].url == "https://doi.org/10.1002/ana.51", "same number, same words: the catalog's answer is kept")
        #expect(stored[1].text.hasPrefix("Another third"))
        #expect(stored[2].text.hasPrefix("Authored by an assistant"))
    }

    @Test("A new read relabels an entry it finds again, and asks the catalogs again about one left without a link")
    func replaceRelabelsAndReasks() throws {
        let (store, root) = try store("paper-references-relabel")
        defer { try? FileManager.default.removeItem(at: root) }
        try addPaper(store, "p")
        let text = "Schmidt-Nielsen K. 1970. Energy metabolism, body size, and the problems of scaling. FedProc. 29:1524–1532."
        var unlinked = PaperReference(sourceID: "p", ordinal: 1, label: "metabolism 1970", text: text)
        unlinked.catalogCheckedAt = Date()
        var linked = PaperReference(sourceID: "p", ordinal: 2, label: "Pickett 2018", text: "Pickett SJ. Phenotypic heterogeneity in disease. Ann 2018.")
        linked.doi = "10.1002/ana.51"; linked.url = "https://doi.org/10.1002/ana.51"; linked.origin = .catalog
        linked.catalogCheckedAt = Date()
        try store.replacePaperReferenceList(sourceID: "p", entries: [unlinked, linked])

        try store.replacePaperReferenceList(sourceID: "p", entries: [
            PaperReference(sourceID: "p", ordinal: 1, label: "Schmidt-Nielsen 1970", text: text),
            PaperReference(sourceID: "p", ordinal: 2, label: "Pickett 2018", text: linked.text),
        ])
        let stored = try store.loadPaperReferences(sourceID: "p")
        #expect(stored[0].label == "Schmidt-Nielsen 1970")
        #expect(stored[0].catalogCheckedAt == nil)
        #expect(PaperReferenceLinkService.needsCatalog(stored[0]))
        #expect(stored[1].url == "https://doi.org/10.1002/ana.51")
        #expect(stored[1].catalogCheckedAt != nil, "a link found is not asked for again")
    }

    @Test("An assistant's save merges into the stored entry, replaces the list on request, and marks the read finished by the agent")
    func agentSave() throws {
        let (store, root) = try store("paper-references-agent")
        defer { try? FileManager.default.removeItem(at: root) }
        try addPaper(store, "p")
        try store.enqueuePaperReferenceRead(sourceID: "p", pdfPath: "Papers/x.pdf")
        var entry = PaperReference(sourceID: "p", ordinal: 7, label: "7", text: "Seventh entry as printed in the paper.")
        entry.doi = "10.1000/seven"; entry.url = "https://doi.org/10.1000/seven"; entry.origin = .agent
        try store.savePaperReferencesAuthoredByAgent(sourceID: "p", references: [entry], replacing: false)
        let state = try #require(try store.paperReferenceReadState(sourceID: "p"))
        #expect(state.state == .read)
        #expect(state.authoredBy == "agent")
        #expect(state.entryCount == 1)
        #expect(state.linkedCount == 1)
        #expect(try store.paperReferenceReadCandidates(limit: 5).isEmpty)

        var other = PaperReference(sourceID: "p", ordinal: 1, label: "1", text: "First entry, after a replace.")
        other.updatedAt = Date()
        try store.savePaperReferencesAuthoredByAgent(sourceID: "p", references: [other], replacing: true)
        #expect(try store.loadPaperReferences(sourceID: "p").map(\.ordinal) == [1])
    }

    @Test("Deleting the source removes its list")
    func cascade() throws {
        let (store, root) = try store("paper-references-cascade")
        defer { try? FileManager.default.removeItem(at: root) }
        try addPaper(store, "p")
        try store.savePaperReference(PaperReference(sourceID: "p", ordinal: 1, label: "1", text: "Entry one text"))
        try store.enqueuePaperReferenceRead(sourceID: "p", pdfPath: "Papers/x.pdf")
        try store.dropPaperReferences(sourceID: "p")
        #expect(try store.loadPaperReferences(sourceID: "p").isEmpty)
        #expect(try store.paperReferenceReadState(sourceID: "p") == nil)
    }
}

@Suite("Paper reference lists: sync")
struct PaperReferenceSyncTests {

    private func store(_ name: String) throws -> (KnowledgeStore, URL) {
        let root = try Schema154Fixture.temporaryRoot(name)
        let store = try KnowledgeStore(storeDirectory: root)
        return (store, root)
    }

    private func addPaper(_ store: KnowledgeStore, _ id: String) throws {
        try store.execForTesting("""
            INSERT INTO sources (id, date_added, state, source_type, status) VALUES ('\(id)', 0, 'ready', 'paper', 'active');
            INSERT INTO papers (source_id, url, local_file_path) VALUES ('\(id)', 'https://doi.org/10.1/\(id)', 'Papers/x.pdf');
        """)
    }

    private func entry(
        _ sourceID: String, _ ordinal: Int, _ text: String, doi: String? = nil, origin: PaperReference.LinkOrigin = .none
    ) -> PaperReference {
        var reference = PaperReference(sourceID: sourceID, ordinal: ordinal, label: "\(ordinal)", text: text)
        if let doi {
            reference.doi = doi
            reference.url = "https://doi.org/\(doi)"
            reference.origin = origin
        }
        return reference
    }

    private func decoded(_ data: Data) throws -> [SyncedPaperReference] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([SyncedPaperReference].self, from: data)
    }

    private func published(_ store: KnowledgeStore, _ sourceID: String) throws -> [SyncedPaperReference] {
        try decoded(try #require(try SourceSatelliteRoles.referencesBody(sourceID: sourceID, connection: store)))
    }

    @Test("A paper's list is published as one body, in list order, with each link and how it was found, the same bytes each time")
    func body() throws {
        let (store, root) = try store("paper-references-sync-body")
        defer { try? FileManager.default.removeItem(at: root) }
        try addPaper(store, "p")
        try store.savePaperReferencesAuthoredByAgent(sourceID: "p", references: [
            entry("p", 2, "Doe A. Second paper. J Bar 2002; 2: 3-4.", doi: "10.1000/two", origin: .agent),
            entry("p", 1, "Smith J. First paper. J Foo 2001; 1: 1-2."),
        ], replacing: false)

        let data = try #require(try SourceSatelliteRoles.referencesBody(sourceID: "p", connection: store))
        let entries = try decoded(data)
        #expect(entries.map(\.ordinal) == [1, 2])
        #expect(entries[0].url == nil)
        #expect(entries[1].doi == "10.1000/two")
        #expect(entries[1].origin == "agent")
        #expect(try SourceSatelliteRoles.referencesBody(sourceID: "p", connection: store) == data)
        #expect(try SourceSatelliteRoles.referencesBody(sourceID: "no-list", connection: store) == nil)
        // It is one of the satellites the source is published with.
        let satellites = try SourceSatelliteRoles.localSatellites(sourceID: "p", connection: store, resolve: { URL(fileURLWithPath: $0) })
        #expect(satellites.contains { $0.map == .derived && $0.role == "references" && $0.body == data })
    }

    @Test("A Mac that has read no list keeps the published one whole and counts the paper as read")
    func adoptsWholeList() throws {
        let (store, root) = try store("paper-references-sync-adopt")
        defer { try? FileManager.default.removeItem(at: root) }
        try addPaper(store, "p")
        try addPaper(store, "q")
        try store.savePaperReferencesAuthoredByAgent(sourceID: "q", references: [
            entry("q", 1, "Smith J. First paper. J Foo 2001; 1: 1-2."),
            entry("q", 2, "Doe A. Second paper. J Bar 2002; 2: 3-4.", doi: "10.1000/two", origin: .agent),
        ], replacing: false)
        let incoming = try published(store, "q")

        try store.enqueuePaperReferenceRead(sourceID: "p", pdfPath: "Papers/x.pdf")
        try InboundSourceFiles.mergeReferences(incoming, sourceID: "p", connection: store)

        let held = try store.loadPaperReferences(sourceID: "p")
        #expect(held.map(\.ordinal) == [1, 2])
        #expect(held[1].url == "https://doi.org/10.1000/two")
        #expect(held[1].origin == .agent)
        let state = try #require(try store.paperReferenceReadState(sourceID: "p"))
        #expect(state.state == .read)
        #expect(state.entryCount == 2)
        #expect(state.linkedCount == 1)
        #expect(state.authoredBy == "agent")
        #expect(try store.paperReferenceReadCandidates(limit: 5).isEmpty, "the catalogs are not asked again for it")
    }

    @Test("A Mac with its own list takes a link only for an entry with the same words and no link, whatever the numbers")
    func mergesByWords() throws {
        let (store, root) = try store("paper-references-sync-merge")
        defer { try? FileManager.default.removeItem(at: root) }
        try addPaper(store, "p")
        try store.replacePaperReferenceList(sourceID: "p", entries: [
            entry("p", 1, "Smith J. First paper. J Foo 2001; 1: 1-2."),
            entry("p", 2, "Doe A. Second paper. J Bar 2002; 2: 3-4.", doi: "10.1000/mine", origin: .catalog),
            entry("p", 3, "Roe B. Third paper. J Baz 2003; 3: 5-6."),
        ])
        // The other Mac numbered the same list differently, and found links by hand.
        let incoming = [
            SyncedPaperReference(
                ordinal: 5, label: "5", text: "Smith J. First paper. J Foo 2001; 1: 1-2.", title: "First paper", year: "2001",
                doi: "10.1000/one", url: "https://doi.org/10.1000/one", origin: "agent"
            ),
            SyncedPaperReference(
                ordinal: 1, label: "1", text: "Doe A. Second paper. J Bar 2002; 2: 3-4.", doi: "10.1000/theirs",
                url: "https://doi.org/10.1000/theirs", origin: "agent"
            ),
            SyncedPaperReference(
                ordinal: 9, label: "9", text: "Nobody N. An entry this Mac does not hold. J Qux 1999; 9: 9-9.", doi: "10.1000/none",
                url: "https://doi.org/10.1000/none", origin: "agent"
            ),
        ]
        try InboundSourceFiles.mergeReferences(incoming, sourceID: "p", connection: store)

        let held = try store.loadPaperReferences(sourceID: "p")
        #expect(held.map(\.ordinal) == [1, 2, 3], "no entry is added or renumbered")
        #expect(held[0].url == "https://doi.org/10.1000/one")
        #expect(held[0].origin == .agent)
        #expect(held[0].title == "First paper")
        #expect(held[1].url == "https://doi.org/10.1000/mine", "a link this Mac holds is not replaced")
        #expect(held[1].origin == .catalog)
        #expect(held[2].url == nil)
    }

    @Test("A published list is worth fetching only when this Mac has none, or has an entry without a link and other bytes")
    func worthTaking() throws {
        let (store, root) = try store("paper-references-sync-worth")
        defer { try? FileManager.default.removeItem(at: root) }
        try addPaper(store, "p")
        try addPaper(store, "q")
        try store.savePaperReferencesAuthoredByAgent(sourceID: "q", references: [
            entry("q", 1, "Smith J. First paper. J Foo 2001; 1: 1-2.", doi: "10.1000/one", origin: .agent),
        ], replacing: false)
        let body = try #require(try SourceSatelliteRoles.referencesBody(sourceID: "q", connection: store))
        let satellite = SourceLocalSatellite(
            map: .derived, role: "references", mime: "application/json", encoding: .gzip, body: body, localPath: nil, input: nil
        )
        let pointer = try SourceSatelliteLayout.layout(satellite, owner: "q").file

        #expect(try InboundSourceFiles.referencesWorthTaking(pointer, sourceID: "p", connection: store), "no list here")
        try store.replacePaperReferenceList(sourceID: "p", entries: [
            entry("p", 1, "Smith J. First paper. J Foo 2001; 1: 1-2."),
        ])
        #expect(try InboundSourceFiles.referencesWorthTaking(pointer, sourceID: "p", connection: store), "an entry without a link")
        try store.savePaperReference(entry("p", 1, "Smith J. First paper. J Foo 2001; 1: 1-2.", doi: "10.1000/one", origin: .catalog))
        #expect(!(try InboundSourceFiles.referencesWorthTaking(pointer, sourceID: "p", connection: store)), "every entry linked")
    }
}

@Suite("Paper reference lists: one entry a reference (parser 2)")
struct PaperReferenceSplittingTests {

    @Test("Authors set initials first (ML papers) open entries, and are labelled by the first surname")
    func initialsFirst() {
        let text = """
        References
        J. Abramson, J. Adler, J. Dunger, R. Evans, T. Green, A. Pritzel, O. Ronneberger, L. Willmore, A. J. Ballard,
        J. Bambrick, et al. Accurate structure prediction of biomolecular interactions with AlphaFold 3. Nature,
        2024.
        C. D. Allis and T. Jenuwein. The molecular hallmarks of epigenetic control. Nature Reviews Genetics, 17(8):
        487–500, 2016.
        Ž. Avsec, V. Agarwal, D. Visentin, J. R. Ledsam, A. Grabska-Barwinska, K. R. Taylor, Y. Assael, J. Jumper,
        P. Kohli, and D. R. Kelley. Effective gene expression prediction from sequence by integrating long-range
        interactions. Nature Methods, 18(10):1196–1203, 2021.
        G. Benegas, S. S. Batra, and Y. S. Song. DNA language models are powerful predictors of genome-wide variant
        effects. Proceedings of the National Academy of Sciences, 120(44):e2311219120, 2023.
        S. Biderman, H. Schoelkopf, Q. G. Anthony, H. Bradley, K. O'Brien, E. Hallahan, M. A. Khan, S. Purohit, U. S.
        Prashanth, E. Raff, et al. Pythia: A suite for analyzing large language models across training and scaling.
        In International Conference on Machine Learning, pages 2397–2430. PMLR, 2023.
        """
        let entries = PaperReferenceParser.entries(inPaperText: text)
        #expect(entries.map(\.label) == ["Abramson 2024", "Allis 2016", "Avsec 2021", "Benegas 2023", "Biderman 2023"])
    }

    @Test("A line that ends on an author's initials continues the author list; it does not end the entry")
    func brokenAfterInitials() {
        let text = """
        References
        Ashrafi, G., and T.L. Schwarz. 2013. The pathways of mitophagy for quality
        control and clearance of mitochondria. Cell Death Differ. 20:31–42.
        Chan, N.C., A.M. Salazar, A.H. Pham, M.J. Sweredoski, N.J. Kolawa, R.L.
        Graham, S. Hess, and D.C. Chan. 2011. Broad activation of the ubiquitin-
        proteasome system by Parkin is critical for mitophagy. Hum. Mol. Genet.
        20:1726–1737.
        Deas, E., H. Plun-Favreau, S. Gandhi, H. Desmond, S. Kjaer, S.H. Loh, A.E.
        Renton, R.J. Harvey, A.J. Whitworth, L.M. Martins, et al. 2011. PINK1
        cleavage at position A103 by the mitochondrial protease PARL. Hum.
        Mol. Genet. 20:867–879.
        Geisler, S., K.M. Holmström, D. Skujat, F.C. Fiesel, O.C. Rothfuss, P.J. Kahle,
        and W. Springer. 2010. PINK1/Parkin-mediated mitophagy is dependent
        on VDAC1 and p62/SQSTM1. Nat. Cell Biol. 12:119–131.
        Kane, L.A., M. Lazarou, A.I. Fogel, Y. Li, K. Yamano, S.A. Sarraf, S. Banerjee,
        and R.J. Youle. 2014. PINK1 phosphorylates ubiquitin to activate Parkin E3
        ubiquitin ligase activity. J. Cell Biol. 205:143–153.
        """
        let entries = PaperReferenceParser.entries(inPaperText: text)
        #expect(entries.map(\.label) == ["Ashrafi 2013", "Chan 2011", "Deas 2011", "Geisler 2010", "Kane 2014"])
        #expect(entries[1].text.contains("R.L. Graham, S. Hess"))
        #expect(!PaperReferenceParser.looksFinished(["Graham, S. Hess, and D.C. Chan. 2011. A title, R.L."]))
        #expect(PaperReferenceParser.looksFinished(["Hamilton, J. B. (1965) J. Gerontol. 24, 39541 I."]))
        #expect(PaperReferenceParser.looksFinished(["Smith J. A study. Proc. Natl. Acad. Sci. U.S.A."]))
    }

    @Test("A year set against a journal's full stop counts as the entry's year")
    func yearAfterFullStop() {
        #expect(PaperReferenceIdentity.years(in: "I.M.Orme,J.Immunol.1987,138,4414.") == [1987])
        #expect(PaperReferenceIdentity.years(in: "Section 1.2019 of the code").isEmpty)
        let text = """
        References
        [1] I.M.Orme,J.Immunol.1987,138,4414.
        [2] A.N.Akbar,S.M.Henson,A.Lanna,TrendsImmunol.2016,37,866.
        [3] A. Donnini, F. Re, M. Bollettini, R. Moresi, S. Tesei, G. Bernardini,
        M.Provinciali,Biogerontology2005,6,193.
        [4] J.Nikolich-Žugich,J.Immunol.2014,193,2622.
        [5] R. E. Yanes, H. Zhang, Y. Shen, C. M. Weyand, J. J. Goronzy, Clin.
        Immunol.2019,207,58.
        """
        #expect(PaperReferenceParser.entries(inPaperText: text).map(\.ordinal) == [1, 2, 3, 4, 5])
    }

    @Test("A note set under an entry (Nature News & Views) is no entry of its own")
    func notesUnderEntries() {
        let text = """
        References
        1. 2. 3. 4. Luongo, T. S. et al. SLC25A51 is a
        mammalian mitochondrial NAD+
        transporter. Nature
        588, 174–179 (2020).
        Girardi, E. et al. Epistasis-driven
        identification of SLC25A51. Nat.
        Commun. 11, 6145 (2020).
        Kory, N. et al. MCART1/SLC25A51 is
        required for mitochondrial NAD transport.
        Sci. Adv. 6, eabe5310 (2020).
        The papers in references 1, 2 and 3 report
        the identification of SLC25A51 as a
        mitochondrial NAD+ carrier.
        Mukherjee, S. et al. Nicotinamide adenine
        dinucleotide biosynthesis promotes liver
        regeneration. Hepatology 65, 616–630
        (2017).
        This manuscript describes NAD+
        precursor supplementation as a strategy.
        """
        let entries = PaperReferenceParser.entries(inPaperText: text)
        #expect(entries.map(\.ordinal) == [1, 2, 3, 4])
        #expect(entries[3].text.hasPrefix("Mukherjee, S. et al."))
    }

    @Test("Words beside a run of numbers that finish the entry before it are that entry's, not the next")
    func runCarriesOver() {
        let text = """
        References
        1. 2. 3. Kalache, A., and Gatti, A. (2003). Active ageing: a policy framework. Adv. Gerontol. 11, 7–18.
        Partridge, L., Deelen, J., and Slagboom, P.E. (2018). Facing up to the global challenges of ageing. Nature 561, 45–56.
        Dolan, M.-J., Rakosi-Schmidt, R., Garcia, E., Lin, Y., Nadaf, N.M., Dixon, J., Guo, S.,
        4. 5. Morshed, N., Depp, C., Doman, J., et al. (2025). Spatiotemporal analysis of remyelination
        reveals a concerted interferon-responsive glial state. bioRxiv, 2025.04.22.649486.
        Jin, W.-N., Shi, K., He, W., Sun, J.-H., and Liu, Q. (2021). Depletion of microglia exacerbates
        injury after intracerebral hemorrhage. Neurobiol. Dis. 152, 105299.
        Salter, M.W., and Stevens, B. (2017). Microglia emerge as central players in brain disease. Nat. Med. 23, 1018–1027.
        """
        let entries = PaperReferenceParser.entries(inPaperText: text)
        #expect(entries.map(\.ordinal) == [1, 2, 3, 4, 5])
        #expect(entries[2].text.contains("Guo, S., Morshed, N."))
        #expect(entries[2].text.hasSuffix("bioRxiv, 2025.04.22.649486."))
        #expect(entries[3].text.hasPrefix("Jin, W.-N."))
    }

    @Test("Authors printed with first names open an entry after one that closed on its year")
    func fullNames() {
        let text = """
        References
        Aleksandra Szczepankiewicz, Anna Breborowicz, Paulina Sobkowiak, and Anna Popiel. Polymorphisms of two
        histamine-metabolizing enzymes genes and childhood allergic asthma. Clinical and Molecular Allergy, 8(1):14, 2010.
        Karel HM van Wely, Jelto Swaving, Roland Freudl, and Arnold JM Driessen. Translocation of proteins across the
        cell envelope of gram-positive bacteria. FEMS microbiology reviews, 25(4):437–454, 2001.
        Mihaly Varadi, Stephen Anyango, Mandar Deshpande, Sreenath Nair, Cindy Natassia, Galabina Yordanova,
        David Yuan, Oana Stroe, Gemma Wood. AlphaFold protein structure database. Nucleic acids research, 50(D1):D439–D444, 2022.
        Qiu Zhengqi, Guo Zezhi, Jiang Lei, Qiu He, Pan Jinyao, and Ao Ying. Prognostic role of phyh for overall
        survival in clear cell renal cell carcinoma. European Journal of Medical Research, 26(1):9, 2021.
        Justas Dauparas, Ivan Anishchenko, Nathaniel Bennett, Hua Bai, Robert J Ragotte, et al. Robust deep
        learning–based protein sequence design using proteinmpnn. Science, 378(6615):49–56, 2022.
        """
        let entries = PaperReferenceParser.entries(inPaperText: text)
        #expect(entries.map(\.label) == ["Szczepankiewicz 2010", "van Wely 2001", "Varadi 2022", "Zhengqi 2021", "Dauparas 2022"])
    }

    @Test("A list goes on past another column's closing sections, and the entry left open keeps only its own words")
    func resumesPastColumnHeadings() {
        let text = """
        REFERENCES
        1. Vyas S, Zaganjor E, Haigis MC. Mitochondria and cancer. Cell (2016)
        166:555–66. doi: 10.1016/j.cell.2016.07.002
        2. Federico A, Cardaioli E, Da Pozzo P, Formichi P, Gallus GN,
        Radi E. Mitochondria, oxidative stress and neurodegeneration.
        molecule derived from beta-lapachone, increased energy production
        and improved mitochondrial dysfunction and oxidative stress
        in MELAS fibroblasts. Compared with idebenone, KL1333 was
        a more potent substrate for NQO1 and had a stronger effect
        on ATP levels in MELAS fibroblasts. These results suggest that
        KL1333 may be more effective than idebenone for treatment of
        mitochondrial diseases, and that its dual activation of PGC-1a
        through deacetylation and phosphorylation is worth study.
        AUTHOR CONTRIBUTIONS
        Zara Holt and Ines Varga designed the experiments and wrote the paper.
        3. Suomalainen A, Battersby BJ. Mitochondrial diseases: the
        contribution of organelle stress responses to pathology.
        Nat Rev Mol Cell Biol. (2018) 19:77–92. doi: 10.1038/nrm.2017.66
        4. Lin J, Zhao CB, Lu JH, Wang HJ. Novel mutations in MT-ND1 associated with MELAS.
        Mitochondrial DNA (2014) 25:56–62. doi: 10.3109/19401736.2013.779259
        """
        let entries = PaperReferenceParser.entries(inPaperText: text)
        #expect(entries.map(\.ordinal) == [1, 2, 3, 4])
        #expect(entries[1].text.hasSuffix("Mitochondria, oxidative stress and neurodegeneration."))
    }

    @Test("A citation card's words stop where the next author-year entry starts")
    func cardStopsAtNextEntry() {
        func line(_ text: String) -> PDFReferenceEntries.Line {
            PDFReferenceEntries.Line(text: text, bounds: .zero, continuesWord: false)
        }
        let lines = [
            line("Hsu, P., and Qu, C.K. (2013). Metabolic plasticity and"),
            line("hematopoietic stem cell biology. Curr. Opin. Hematol. 20, 289–"),
            line("294."),
            line("Ito, K., and Suda, T. (2014). Metabolic requirements for"),
            line("the maintenance of self-renewing stem cells. Nat. Rev. Mol. Cell Biol. 15, 243–256."),
        ]
        #expect(PDFReferenceEntries.linesBeforeAuthorEntry(lines).map(\.text) == lines.prefix(3).map(\.text))
        // A numbered entry is left to the numbers.
        let numbered = [line("12. Smith J. A title. Cell 2019; 1: 2."), line("Lee K, Doe A. Another. Cell 2020; 3: 4.")]
        #expect(PDFReferenceEntries.linesBeforeAuthorEntry(numbered).count == 2)
    }
}

@Suite("Paper reference lists: a citation card's short form")
struct PaperReferenceSummaryTests {

    @Test("First author, year and title are read off the words in each journal's style")
    func printed() {
        let cases: [(String, String, String)] = [
            ("Hsu, P., and Qu, C.K. (2013). Metabolic plasticity and hematopoietic stem cell biology. Curr. Opin. Hematol. 20, 289–294.",
             "Hsu et al., 2013", "Metabolic plasticity and hematopoietic stem cell biology"),
            ("Vyas S, Zaganjor E, Haigis MC. Mitochondria and cancer. Cell (2016) 166:555–66.",
             "Vyas et al., 2016", "Mitochondria and cancer"),
            ("J. Abramson, J. Adler, J. Dunger, et al. Accurate structure prediction of biomolecular interactions with AlphaFold 3. Nature, 2024.",
             "Abramson et al., 2024", "Accurate structure prediction of biomolecular interactions with AlphaFold 3"),
            ("Bai, L., Wang, T., Zhao, G., Kovach, A. & Li, H. The atomic structure of a eukaryotic oligosaccharyltransferase complex. Nature 555, 328–333 (2018).",
             "Bai et al., 2018", "The atomic structure of a eukaryotic oligosaccharyltransferase complex"),
            ("Ashrafi, G., and T.L. Schwarz. 2013. The pathways of mitophagy for quality control and clearance of mitochondria. Cell Death Differ. 20:31–42.",
             "Ashrafi et al., 2013", "The pathways of mitophagy for quality control and clearance of mitochondria"),
            ("Brenner, S. (1999). Theoretical biology in the third millennium. Phil. Trans. R. Soc. B 354, 1963–1965.",
             "Brenner, 1999", "Theoretical biology in the third millennium"),
            ("12. Wenz T. PGC-1α activation as a therapeutic approach in mitochondrial disease. IUBMB Life (2009) 61:1051–62.",
             "Wenz, 2009", "PGC-1α activation as a therapeutic approach in mitochondrial disease"),
            // A lone author with no comma, whose title holds the entry's first comma.
            ("Schmidt-Nielsen K. 1970. Energy metabolism, body size, and the problems of scaling. FedProc. 29:1524–1532.",
             "Schmidt-Nielsen, 1970", "Energy metabolism, body size, and the problems of scaling"),
        ]
        for (text, byline, title) in cases {
            let summary = PaperReferenceSummary(entryText: text, stored: nil)
            #expect(summary.byline == byline, "\(text)")
            #expect(summary.title == title, "\(text)")
        }
    }

    @Test("A stored entry's catalog record wins over the words")
    func stored() {
        let reference = PaperReference(
            sourceID: "s", ordinal: 1, label: "1",
            text: "Jayatunga MKP, Ayers M, Bruens L. How successful... Drug Discov Today 2024.",
            title: "How successful are AI-discovered drugs in clinical trials?",
            authors: "KP Jayatunga; Ayers; Bruens", year: "2024"
        )
        let summary = PaperReferenceSummary(entryText: reference.text, stored: reference)
        #expect(summary.byline == "Jayatunga et al., 2024")
        #expect(summary.title == "How successful are AI-discovered drugs in clinical trials?")
    }
}

@Suite("Paper reference lists: papers owed a read")
struct PaperReferenceRequeueTests {

    private func store(_ name: String) throws -> (KnowledgeStore, URL) {
        let root = try Schema154Fixture.temporaryRoot(name)
        let store = try KnowledgeStore(storeDirectory: root)
        return (store, root)
    }

    private func addPaper(_ store: KnowledgeStore, _ id: String, path: String?) throws {
        try store.execForTesting("""
            INSERT INTO sources (id, date_added, state, source_type, status) VALUES ('\(id)', 0, 'ready', 'paper', 'active');
            INSERT INTO papers (source_id, url, local_file_path) VALUES ('\(id)', 'https://doi.org/10.1/\(id)', \(path.map { "'\($0)'" } ?? "NULL"));
        """)
    }

    @Test("A paper an older parser read is queued once for this one, with or without a list; an assistant's is left alone")
    func requeuesOlderReads() throws {
        let (store, root) = try store("paper-references-requeue")
        defer { try? FileManager.default.removeItem(at: root) }
        for id in ["empty-old", "empty-new", "listed", "agent"] { try addPaper(store, id, path: "Papers/\(id).pdf") }
        try store.savePaperReference(PaperReference(sourceID: "listed", ordinal: 1, label: "1", text: "Smith J. A title. Cell 2019."))
        try store.execForTesting("""
            INSERT INTO paper_reference_reads (source_id, state, enqueued_at, parser_version, entry_count, authored_by) VALUES
                ('empty-old', 'read', 0, 1, 0, 'app'),
                ('empty-new', 'read', 0, \(PaperReferenceParser.version), 0, 'app'),
                ('listed', 'read', 0, 2, 1, 'app'),
                ('agent', 'read', 0, 1, 0, 'agent');
        """)
        #expect(try store.requeueOlderPaperReferenceReads() == 2)
        #expect(Set(try store.paperReferenceReadCandidates(limit: 10).map(\.sourceID)) == ["empty-old", "listed"])
        // The read each gets stamps this version, so neither is queued again.
        for id in ["empty-old", "listed"] {
            try store.finishPaperReferenceRead(sourceID: id, pdfPath: nil, failure: nil, authoredBy: "app")
        }
        #expect(try store.requeueOlderPaperReferenceReads() == 0)
    }

    @Test("A paper whose PDF arrives from another Mac is queued for its reference list")
    func syncedPDFIsQueued() throws {
        let (store, root) = try store("paper-references-synced-pdf")
        defer { try? FileManager.default.removeItem(at: root) }
        try addPaper(store, "p", path: nil)
        let bytes = Data("%PDF-paper".utf8)
        let ref = FileRef(owner: "p", role: "pdf", hash: SyncIdentity.sha256Hex(bytes), size: Int64(bytes.count),
                          mime: "application/pdf", encoding: "identity", storedParts: [bytes])
        try InboundSourceFiles.save([InboundSourceFiles.pdfRole: ref.value], sourceID: "p", connection: store)

        #expect(try InboundSourceFiles.receivedPDF(bytes, installedPath: "Papers/synced-p.pdf", sourceID: "p", connection: store))
        let state = try #require(try store.paperReferenceReadState(sourceID: "p"))
        #expect(state.state == .queued)
        #expect(state.pdfPath == "Papers/synced-p.pdf")
        #expect(try store.paperReferenceReadCandidates(limit: 5).map(\.sourceID) == ["p"])
    }
}

@Suite("Paper reference lists: Authors (year) Title lists and their citations (parser 4)")
struct PaperReferenceAuthorYearStyleTests {
    /// A list as EMBO and Springer set it: the year in brackets after the authors, books
    /// that end on a publisher, a lone author, and a line of authors read with no spaces.
    private let list = """
    References
    Alder SN, Brook M, Marsh RA (2026) Rate indicators and the search for
    slower clocks. Front Sci https://doi.org/10.1234/fsci.2026.1821393
    Birch B, Fenn O, Rowan N, Sorrel P, Marsh RA (2026)
    Telling normal from slow mice by plasma features.
    Geroscience 48:7175–7190
    Carrow L (1871) Through the hedge. Mallow
    & Co., London
    Elm A, Bonner BN, Olsen P, Heddle A
    (2000a) Age and breed pattern of diagnoses in insured dogs
    during 1996. VetRec 146:551–557
    Gorse SJ (1981) The mismeasure of moss. W. W.
    Norden
    Harle CB, Futch AB, Greer CW (1990)
    Telomeres shorten during ageing of fibroblasts. Nature 345:458–460
    HarrowDE,StrongR,ReifP,RosenN,
    Korst R, Fern E, Flurk K et al (2023)
    Two compounds extend lifespan in male mice. Geroscience
    46:795–816
    Marsh RA (2016) Not your father’s, or mother’s,
    rodent: moving beyond one strain. Neuron 91:1185–1186
    """

    @Test("Every entry is its own: after a book, after a year that ends its line, a lone author, glued authors")
    func splitsEveryEntry() {
        let entries = PaperReferenceParser.entries(inPaperText: list)
        #expect(entries.map(\.label) == [
            "Alder 2026", "Birch 2026", "Carrow 1871", "Elm 2000a", "Gorse 1981", "Harle 1990", "Harrow 2023", "Marsh 2016",
        ])
        // The title stays with its authors where the line ended on the year.
        #expect(entries[1].text.hasSuffix("Telling normal from slow mice by plasma features. Geroscience 48:7175–7190"))
        #expect(entries[2].text == "Carrow L (1871) Through the hedge. Mallow & Co., London")
        #expect(entries[6].text.hasPrefix("Harrow DE, Strong R, Reif P, Rosen N, Korst R"))
    }

    @Test("The editors of a chapter's book open no entry of their own")
    func editorsStayInTheirEntry() {
        let lines = [
            "Wester, K.R. (2000). Control of Energy Expenditure. In Endotext, K.R.",
            "Feld, B. Anders, M.R. Black, A. Boyd, G. Chrest, E. Corp, W.W. de",
            "Herd, K. Dhar, K. Dunn, J. Hof, et al., eds.",
            "Fry, E., Detten, L., and Kirsch, C. (2009). The awakening response",
            "(CAR): facts and future directions. Int J Psychophysiol 72, 67-73.",
        ]
        #expect(PaperReferenceParser.splitIntoEntries(lines).count == 2)
    }

    @Test("A lone author before a bracketed year is the entry's first author, whatever commas the title has")
    func loneAuthorHead() {
        #expect(PaperReferenceSummary.firstAuthorHead(in: "Marsh RA (2016) Not your father’s, or mother’s, rodent") == "Marsh RA")
        #expect(ReferenceEntryShape.opensWithAuthor("Gorse SJ (1981) The mismeasure of moss. W. W."))
        #expect(!ReferenceEntryShape.opensWithAuthor("Richard A Marsh"))
        #expect(ReferenceEntryShape.unglued("HarrowDE,StrongR,ReifP,RosenN,") == "Harrow DE, Strong R, Reif P, Rosen N,")
        #expect(ReferenceEntryShape.unglued("https://doi.org/10.1234/x,y") == "https://doi.org/10.1234/x,y")
    }

    @Test("A paper and its preprint both fit; the one whose volume the entry prints is the one cited")
    func publishedOverPreprint() {
        let entry = "Bell DW, Casp A, Cork DL et al (2022) PaceMark, a methylation biomarker of the pace of aging. eLife 11:e73420"
        let published = SlideCitationService.ResolvedPaper(
            doi: "10.7554/elife.73420", title: "PaceMark, a methylation biomarker of the pace of aging",
            journal: "eLife", year: "2022", authors: "Bell; Casp", volume: "11"
        )
        let preprint = SlideCitationService.ResolvedPaper(
            doi: "10.1101/2021.08.30.21262858", title: "PaceMark, a methylation biomarker of the pace of aging",
            journal: nil, year: "2021", authors: "Bell; Casp"
        )
        #expect(PaperReferenceCatalogMatch.accepted(entry: entry, among: [preprint, published])?.doi == "10.7554/elife.73420")
        // Two issued records that both print their volume still settle nothing.
        let other = SlideCitationService.ResolvedPaper(
            doi: "10.7554/elife.99999", title: "PaceMark, a methylation biomarker of the pace of aging",
            journal: "eLife", year: "2022", authors: "Bell; Casp", volume: "11"
        )
        #expect(PaperReferenceCatalogMatch.accepted(entry: entry, among: [published, other]) == nil)
    }

    @Test("The citation a linked year belongs to is read from the words before it, however the PDF broke them")
    func citationUnderALink() {
        func cited(_ linked: String, _ context: String) -> PaperCitationMarker.AuthorYear? {
            PDFReferenceEntries.authorYearCitation(linked: linked, endingContext: context)
        }
        #expect(cited("2022", "patterns have begun to\nemerge (Bell et al, 2022") == .init(surname: "Bell", year: "2022", suffix: nil))
        #expect(cited("2023", "(Lopez-\nOrtin et al, 2013, 2023")?.surname == "Lopez-Ortin")
        #expect(cited("2023", "i.e., fisetin (Harri-\nson et al, 2023")?.surname == "Harrison")
        #expect(cited("2026", "plasma (Alder et al, 2026;Birchetal,\n2026")?.surname == "Birch")
        #expect(cited("b", "insured dogs (Elm et al, 2000a, b") == .init(surname: "Elm", year: "2000", suffix: "b"))
        #expect(cited("1871", "as the Red Queen said (Carrow, 1871")?.year == "1871")
        #expect(cited("3", "see Figure 3") == nil)
    }

    @Test("A citation names an entry by its year and surname, one letter of a long surname forgiven")
    func citationNamesEntry() {
        let sitig = PaperCitationMarker.AuthorYear(surname: "Sitig", year: "2016", suffix: nil)
        #expect(PDFReferenceEntries.authorYearCitation(sitig, names: "Sittig 2016"))
        #expect(!PDFReferenceEntries.authorYearCitation(sitig, names: "Sittig 2017"))
        #expect(!PDFReferenceEntries.authorYearCitation(sitig, names: "Baker 2016"))
        #expect(PDFReferenceEntries.authorYearCitation(sitig, names: "Baker 2016", bySurname: false))
        let lee = PaperCitationMarker.AuthorYear(surname: "Lee", year: "2016", suffix: nil)
        #expect(!PDFReferenceEntries.authorYearCitation(lee, names: "Lei 2016"))
        let second = PaperCitationMarker.AuthorYear(surname: "Elm", year: "2000", suffix: "b")
        #expect(PDFReferenceEntries.authorYearCitation(second, names: "Elm 2000b"))
        #expect(!PDFReferenceEntries.authorYearCitation(second, names: "Elm 2000a"))
    }
}
