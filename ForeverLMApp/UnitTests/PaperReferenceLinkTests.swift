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
        """
        let entries = PaperReferenceParser.entries(inPaperText: text)
        #expect(entries.map(\.label) == ["Albamonte 2008", "Allen 2013", "Allio 2017", "Arbeithuber 2020", "Bergstrom 1998"])
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
        let store = try KnowledgeStore(storeDirectory: root, syncGeneration: .one, freeSpace: Schema154Fixture.roomy)
        return (store, root)
    }

    private func addPaper(_ store: KnowledgeStore, _ id: String, path: String? = "Papers/x.pdf", status: String = "active") throws {
        try store.execForTesting("""
            INSERT INTO sources (id, date_added, state, source_type, status) VALUES ('\(id)', 0, 'ready', 'paper', '\(status)');
            INSERT INTO papers (source_id, url, local_file_path) VALUES ('\(id)', 'https://doi.org/10.1/\(id)', \(path.map { "'\($0)'" } ?? "NULL"));
        """)
    }

    @Test("Schema 174 adds both tables empty from 173, queues the papers that have a file by id, and syncs nothing")
    func migrationFrom173() throws {
        let (store, root) = try store("paper-references-173")
        defer { try? FileManager.default.removeItem(at: root) }
        try addPaper(store, "with-file")
        try addPaper(store, "no-file", path: nil)
        try store.clearAllPendingSyncChanges()
        // A store as schema 173 left it: everything but the two tables.
        try store.execForTesting("""
            DROP TABLE paper_references;
            DROP TABLE paper_reference_reads;
            PRAGMA user_version = 173;
        """)

        Schema154Fixture.newLaunch(root)
        let migrated = try KnowledgeStore(storeDirectory: root, syncGeneration: .one, freeSpace: Schema154Fixture.roomy)

        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(KnowledgeStore.schemaVersion == 174)
        #expect(try migrated.holdsPaperReferenceTables())
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM paper_references") == 0)
        #expect(try migrated.paperReferenceReadCandidates(limit: 10).map(\.sourceID) == ["with-file"])
        #expect(try migrated.pendingSyncChanges().isEmpty)
        // The papers are still all there.
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM papers") == 2)
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
        let store = try KnowledgeStore(storeDirectory: root, syncGeneration: .one, freeSpace: Schema154Fixture.roomy)
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
