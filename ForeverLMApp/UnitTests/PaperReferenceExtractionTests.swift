import Foundation
import Testing
@testable import ForeverLM

@Suite("Paper reference extraction")
struct PaperReferenceExtractionTests {

    @Test("Paper reference extraction is a configurable paper task")
    func taskContract() {
        #expect(AITask.paperReferenceExtraction.rawValue == "paper_reference_extraction")
        #expect(AITask.paperReferenceExtraction.sourceType == .paper)
        #expect(AITask.advancedTasks.contains(.paperReferenceExtraction))
        #expect(AITask.paperReferenceExtraction.usesBackgroundModelDefault)
        #expect(!AITask.paperReferenceExtraction.requiresVision)
        #expect(AITask.paperReferenceExtraction.defaultPrompt == Prompts.paperReferenceExtraction)
        #expect(
            AITaskSettingsCatalog.descriptor(forRawID: "paper_reference_extraction")?.displayName
                == "Paper Reference Extraction"
        )
        #expect(AIUsageTaskLabel.text(for: "paper_reference_extraction") == "Read Paper References")
    }

    @Test("Every paper offers a reference read; nothing else does")
    func supportedSources() {
        let paper = StudioArticle(url: "https://doi.org/10.1000/x", title: "A paper", sourceType: .paper)
        let video = StudioArticle(url: "https://www.youtube.com/watch?v=abc", title: "A talk", sourceType: .video)
        #expect(StudioViewModel.supportsReferenceExtraction(paper))
        #expect(!StudioViewModel.supportsReferenceExtraction(video))
    }

    // MARK: - Reference section

    /// A body that mentions references in prose, then the list under its own heading.
    private let paper = """
    Introduction
    Earlier references to this mechanism (see references 3 and 4) were indirect.
    Methods
    We measured everything twice.
    References
    1. Smith J, Jones A. A first paper about something. Nature. 2020;580:100-105. \
    doi:10.1038/s41586-020-00001-1
    2. Brown K. A second paper, wrapped across
    two lines because the column was narrow. Cell. 2019;177:1-10.
    3. Lee M, et al. A third paper that keeps the section past the length floor. \
    Science. 2021;372:200-210.
    """

    @Test("Cuts the text at the last bibliography heading")
    func cutsAtHeading() {
        let section = SlideCitationService.referenceSection(of: paper)

        #expect(section.hasPrefix("References\n1. Smith J"))
        #expect(section.contains("3. Lee M"))
        #expect(!section.contains("We measured everything twice."))
    }

    @Test("Passes the whole text on when no heading can be found")
    func wholeTextWithoutHeading() {
        let text = paper.replacingOccurrences(of: "\nReferences\n", with: "\n")
        #expect(SlideCitationService.referenceSection(of: text) == text)
    }

    /// A running header near the end of a paper is a heading with nothing under it, not the
    /// list; the list under the earlier real heading is what should be read.
    @Test("A heading with nothing under it is not the list")
    func ignoresTrailingBareHeading() {
        let text = paper + "\n\u{000C}References\nPage 12"
        let section = SlideCitationService.referenceSection(of: text)

        #expect(section == text)
    }

    @Test("Recognises the heading in its printed variants")
    func headingVariants() {
        for line in [
            "References", "REFERENCES", "References:", "7. References", "7 References",
            "VII. References", "(7) References", "  Bibliography  ", "Literature Cited",
            "References and Notes", "Notes and references", "Works Cited", "Reference List",
        ] {
            #expect(SlideCitationService.isReferenceHeadingLine(line), "\(line)")
        }
    }

    @Test("A sentence about references is not the heading")
    func headingRejectsProse() {
        for line in [
            "We thank the referees for their references.",
            "References to earlier work show the same trend",
            "12. Smith J. References in the wild. Nature. 2020.",
            "See Supplementary References for the full list",
            "",
        ] {
            #expect(!SlideCitationService.isReferenceHeadingLine(line), "\(line)")
        }
    }

    // MARK: - Identity boundary

    /// A DOI printed in the reference list identifies the paper; one the model supplied from
    /// memory does not, however plausible, and the entry waits for the catalog lookup.
    @Test("A bibliography DOI is identity only when it is printed")
    func printedDOIIsIdentity() throws {
        let reply = """
        {"citations": [
          {"title": "A first paper about something", "authors": "Smith; Jones", "year": "2020",
           "journal": "Nature", "doi": "10.1038/s41586-020-00001-1", "url": null},
          {"title": "A second paper, wrapped across two lines because the column was narrow",
           "authors": "Brown", "year": "2019", "journal": "Cell", "doi": "10.1016/j.cell.2019.01.001",
           "url": null}
        ]}
        """
        let citations = try SlideCitationService.decodeReply(reply).citations
        let candidates = SlideCitationService.candidatesFromExtractedCitations(
            citations,
            sourceID: "paper-1",
            sourceText: SlideCitationService.referenceSection(of: paper)
        )

        #expect(candidates.count == 2)
        #expect(candidates[0].doi == "10.1038/s41586-020-00001-1")
        #expect(candidates[0].url == "https://doi.org/10.1038/s41586-020-00001-1")
        #expect(candidates[0].status == .pending)
        #expect(candidates[1].doi == nil)
        #expect(candidates[1].status == .unresolved)
        #expect(candidates.allSatisfy { $0.slideImagePath == nil && $0.slideTimeSeconds == nil })
    }

    @Test("The reference list is chunked with overlap like other long material")
    func chunking() {
        let section = SlideCitationService.referenceSection(of: paper)
        let chunks = SlideCitationService.materialChunks(section, maxCharacters: 120, overlapCharacters: 20)

        #expect(chunks.count > 1)
        #expect(chunks.first?.hasPrefix("References") == true)
        #expect(chunks.last?.contains("372:200-210") == true)
    }

    // MARK: - Catalog matching

    /// The three shapes a reference list prints that a catalog does not: superscript markup
    /// read as `^(+)`, typographic dashes, and a trailing period. None of them is a
    /// different paper.
    @Test("Matches a title across punctuation, dashes and superscript markup")
    func titleMatchFoldsPunctuation() {
        #expect(SlideCitationService.titlesMatch(
            "NAD^(+) repletion improves mitochondrial and stem cell function and enhances life span in mice",
            "NAD+ Repletion Improves Mitochondrial and Stem Cell Function and Enhances Life Span in Mice"
        ))
        #expect(SlideCitationService.titlesMatch(
            "Mitochondrial–nuclear communications.",
            "Mitochondrial-nuclear communications"
        ))
        #expect(SlideCitationService.titlesMatch(
            "Complex IV-deficient Surf1^(–/–) mice initiate mitochondrial stress responses",
            "Complex IV-deficient Surf1−/− mice initiate mitochondrial stress responses"
        ))
    }

    @Test("Still rejects a title whose words differ")
    func titleMatchKeepsWordDifferences() {
        #expect(!SlideCitationService.titlesMatch(
            "Mitochondrial–nuclear communications",
            "Mitochondrial–nuclear communications in aging"
        ))
        #expect(!SlideCitationService.titlesMatch("...", "..."))
    }

    /// A reference cites the issue year; Crossref's `issued` is often the online date.
    @Test("A printed year agrees with a record one year away, not two")
    func yearTolerance() {
        #expect(SlideCitationService.yearsAgree("2016", "2016"))
        #expect(SlideCitationService.yearsAgree("2016", "2015"))
        #expect(SlideCitationService.yearsAgree("2016", "2017"))
        #expect(!SlideCitationService.yearsAgree("2016", "2018"))
        #expect(SlideCitationService.yearsAgree(nil, "2018"))
        #expect(SlideCitationService.yearsAgree("n.d.", "2018"))
        #expect(!SlideCitationService.yearsAgree("2016", nil))
    }

    /// A row an earlier read left unmatched is rewritten, not doubled, when a later read
    /// identifies it.
    @Test("A rescan upgrades an unmatched row in place")
    func upgradesUnresolvedRow() {
        let stale = VideoCitedPaper(
            id: "row-1", sourceID: "paper-1", title: "A second paper", authors: "Brown",
            year: "2019", journal: nil, status: .unresolved,
            createdAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let resolved = VideoCitedPaper(
            sourceID: "paper-1", title: "A second paper", authors: "Brown", year: "2019",
            journal: "Cell", doi: "10.1016/j.cell.2019.01.001",
            url: "https://doi.org/10.1016/j.cell.2019.01.001", status: .pending
        )
        let upgraded = StudioViewModel.upgrading(stale, to: resolved)

        #expect(upgraded.id == "row-1")
        #expect(upgraded.createdAt == stale.createdAt)
        #expect(upgraded.status == .pending)
        #expect(upgraded.doi == resolved.doi)
        #expect(upgraded.journal == "Cell")
        #expect(upgraded.updatedAt > stale.updatedAt || upgraded.updatedAt >= stale.createdAt)
    }

    // MARK: - Title-less entries

    /// Nature's reference style prints no titles: "Sturm, G. et al. Commun. Biol. 6, 22
    /// (2023)". Each such entry is still a candidate — attribution-only, under its stand-in
    /// label — and its volume and first page travel beside it as the locator the catalog
    /// lookup will spend.
    @Test("A title-less entry becomes an attribution-only candidate with a locator")
    func titlelessEntryCarriesLocator() throws {
        let reply = """
        {"citations": [
          {"title": null, "authors": "Sturm, G.", "year": "2023", "journal": "Commun. Biol.",
           "volume": "6", "pages": "22", "doi": null, "url": null},
          {"title": null, "authors": "Argov, Z.; Bank, W. J.; Maris, J.", "year": "1987",
           "journal": "Neurology", "volume": "37", "pages": "257–262", "doi": null, "url": null},
          {"title": "A first paper about something", "authors": "Smith, J.; Jones, A.", "year": "2020",
           "journal": "Nature", "doi": null, "url": null}
        ]}
        """
        let citations = try SlideCitationService.decodeReply(reply).citations
        let (candidates, locators) = SlideCitationService.candidatesAndLocators(
            citations, sourceID: "paper-1", sourceText: paper
        )

        #expect(candidates.count == 3)
        #expect(candidates[0].isAttributionOnly)
        #expect(candidates[0].title == VideoCitedPaper.attributionLabel(
            authors: "Sturm, G.", journal: "Commun. Biol.", year: "2023"
        ))
        #expect(candidates[0].status == .unresolved)
        #expect(locators[candidates[0].id] == SlideCitationService.BibliographicLocator(volume: "6", pages: "22"))
        #expect(locators[candidates[1].id]?.volume == "37")
        #expect(locators[candidates[1].id]?.firstPage == "257")
        #expect(!candidates[2].isAttributionOnly)
        #expect(locators[candidates[2].id] == nil)
    }

    @Test("The first page is read off a range, an article number, or a pp. prefix")
    func firstPageOfRange() {
        #expect(SlideCitationService.BibliographicLocator.firstPage(of: "257–262") == "257")
        #expect(SlideCitationService.BibliographicLocator.firstPage(of: "1040-1054.e7") == "1040")
        #expect(SlideCitationService.BibliographicLocator.firstPage(of: "e136055") == "e136055")
        #expect(SlideCitationService.BibliographicLocator.firstPage(of: "pp. 12-19") == "12")
        #expect(SlideCitationService.BibliographicLocator(volume: nil, pages: nil) == nil)
        #expect(SlideCitationService.BibliographicLocator(volume: " ", pages: "")  == nil)
    }

    /// Reference lists, Crossref and OpenAlex each write an author differently.
    @Test("The first author's surname is read from every name shape")
    func firstAuthorSurnameShapes() {
        #expect(SlideCitationService.firstAuthorSurname("Argov, Z.; Bank, W. J.; Maris, J.") == "Argov")
        #expect(SlideCitationService.firstAuthorSurname("Naviaux, R. K. et al.") == "Naviaux")
        #expect(SlideCitationService.firstAuthorSurname("Sturm") == "Sturm")
        #expect(SlideCitationService.firstAuthorSurname("Gabriel Sturm; Kalpita R. Karan") == "Sturm")
        #expect(SlideCitationService.firstAuthorSurname("Z. Argov") == "Argov")
        #expect(SlideCitationService.firstAuthorSurname("Argov Z, Bank WJ") == "Argov")
        #expect(SlideCitationService.firstAuthorSurname("Denham Harman") == "Harman")
        #expect(SlideCitationService.firstAuthorSurname("J. van der Berg") == "van der Berg")
        #expect(SlideCitationService.firstAuthorSurname("Bobba-Alves, N.") == "Bobba-Alves")
        #expect(SlideCitationService.firstAuthorSurname(nil) == nil)
        #expect(SlideCitationService.firstAuthorSurname("  ") == nil)
    }

    @Test("Surnames match across diacritics, hyphens and dropped particles")
    func surnameMatching() {
        #expect(SlideCitationService.surnamesMatch("Desdín-Micó", "Desdin-Mico"))
        #expect(SlideCitationService.surnamesMatch("Forsström", "Forsstrom"))
        #expect(SlideCitationService.surnamesMatch("Berg", "van der Berg"))
        #expect(!SlideCitationService.surnamesMatch("Li", "Ali"))
        #expect(!SlideCitationService.surnamesMatch("Sturm", "Sharma"))
    }

    /// The abbreviations reference lists actually print, against the names catalogs hold.
    @Test("Abbreviated venues are recognised, and near-namesakes are not")
    func venueAbbreviations() {
        let compatible: [(String, String)] = [
            ("Commun. Biol.", "Communications Biology"),
            ("J. Clin. Invest.", "Journal of Clinical Investigation"),
            ("Proc Natl Acad Sci USA", "Proceedings of the National Academy of Sciences"),
            ("JBC", "Journal of Biological Chemistry"),
            ("Cell Metab.", "Cell Metabolism"),
            ("Mol. Syst. Biol.", "Molecular Systems Biology"),
            ("EMBO Rep.", "EMBO Reports"),
            ("Psychol. Rev.", "Psychological Review"),
            ("Science", "Science"),
            ("Nat. Metab.", "Nature Metabolism"),
            ("Commun Biol", "Commun Biol"),
        ]
        for (printed, record) in compatible {
            #expect(SlideCitationService.journalsCompatible(printed, record), "\(printed) vs \(record)")
        }
        let incompatible: [(String, String)] = [
            ("Nature", "Nature Metabolism"),
            ("BMC Medicine", "BMC Emergency Medicine"),
            ("BMC Medicine", "BMC Systems Biology"),
            ("Science", "Science Advances"),
            ("Cell", "Cell Metabolism"),
            ("Neurology", "Chemistry Letters"),
        ]
        for (printed, record) in incompatible {
            #expect(!SlideCitationService.journalsCompatible(printed, record), "\(printed) vs \(record)")
        }
    }

    private func entry(
        authors: String, year: String, journal: String
    ) -> VideoCitedPaper {
        VideoCitedPaper(
            sourceID: "paper-1",
            title: VideoCitedPaper.attributionLabel(authors: authors, journal: journal, year: year),
            authors: authors, year: year, journal: journal, status: .unresolved
        )
    }

    /// The record OpenAlex returns for "Sturm, G. et al. Commun. Biol. 6, 22 (2023)".
    private let sturm = SlideCitationService.ResolvedPaper(
        doi: "10.1038/s42003-022-04303-x",
        title: "OxPhos defects cause hypermetabolism and reduce lifespan in cells and in patients with mitochondrial diseases",
        journal: "Communications Biology", year: "2023",
        authors: "Gabriel Sturm; Kalpita R. Karan; Anna S. Monzel",
        volume: "6", firstPage: "22"
    )

    @Test("A record is accepted when author, year, volume and first page all agree")
    func locatorAcceptsFullAgreement() throws {
        let read = entry(authors: "Sturm, G.", year: "2023", journal: "Commun. Biol.")
        let locator = try #require(SlideCitationService.BibliographicLocator(volume: "6", pages: "22"))
        #expect(SlideCitationService.locatorAccepted(read: read, locator: locator, record: sturm))

        // Crossref dates the same paper to its online-first month.
        let onlineFirst = SlideCitationService.ResolvedPaper(
            doi: sturm.doi, title: sturm.title, journal: "Communications Biology", year: "2022",
            authors: "Sturm; Karan; Monzel", volume: "6", firstPage: "22"
        )
        #expect(SlideCitationService.locatorAccepted(read: read, locator: locator, record: onlineFirst))
    }

    @Test("A record whose volume or page disagrees is rejected whatever else fits")
    func locatorRejectsContradiction() throws {
        let read = entry(authors: "Sturm, G.", year: "2023", journal: "Commun. Biol.")
        let locator = try #require(SlideCitationService.BibliographicLocator(volume: "6", pages: "22"))
        let wrongVolume = SlideCitationService.ResolvedPaper(
            doi: "10.1038/other", title: sturm.title, journal: sturm.journal, year: "2023",
            authors: sturm.authors, volume: "5", firstPage: "22"
        )
        let wrongPage = SlideCitationService.ResolvedPaper(
            doi: "10.1038/other", title: sturm.title, journal: sturm.journal, year: "2023",
            authors: sturm.authors, volume: "6", firstPage: "221"
        )
        #expect(!SlideCitationService.locatorAccepted(read: read, locator: locator, record: wrongVolume))
        #expect(!SlideCitationService.locatorAccepted(read: read, locator: locator, record: wrongPage))
    }

    @Test("A record is rejected when the cited author is not on it or the year is off")
    func locatorRejectsAuthorAndYear() throws {
        let locator = try #require(SlideCitationService.BibliographicLocator(volume: "6", pages: "22"))
        let otherAuthor = entry(authors: "Sharma, R.", year: "2023", journal: "Commun. Biol.")
        #expect(!SlideCitationService.locatorAccepted(read: otherAuthor, locator: locator, record: sturm))
        let otherYear = entry(authors: "Sturm, G.", year: "2020", journal: "Commun. Biol.")
        #expect(!SlideCitationService.locatorAccepted(read: otherYear, locator: locator, record: sturm))
    }

    /// An article-numbered journal: OpenAlex holds the volume but no first page, so the venue
    /// has to agree too — and a record that confirms neither volume nor page is never enough.
    @Test("One agreeing locator field needs the venue; none is never an identification")
    func locatorNeedsVenueWhenHalfConfirmed() throws {
        let read = entry(authors: "Sharma, R.", year: "2021", journal: "J. Clin. Invest.")
        let locator = try #require(SlideCitationService.BibliographicLocator(volume: "131", pages: "e136055"))
        let noPage = SlideCitationService.ResolvedPaper(
            doi: "10.1172/jci136055", title: "Circulating markers of NADH-reductive stress",
            journal: "Journal of Clinical Investigation", year: "2021",
            authors: "Rohit Sharma; Bryn Reinstadler", volume: "131", firstPage: nil
        )
        #expect(SlideCitationService.locatorAccepted(read: read, locator: locator, record: noPage))

        let otherVenue = SlideCitationService.ResolvedPaper(
            doi: "10.1000/x", title: "Some Sharma paper", journal: "Journal of Cell Biology",
            year: "2021", authors: "Sharma", volume: "131", firstPage: nil
        )
        #expect(!SlideCitationService.locatorAccepted(read: read, locator: locator, record: otherVenue))

        let nothingConfirmed = SlideCitationService.ResolvedPaper(
            doi: "10.1000/y", title: "Some Sharma paper", journal: "Journal of Clinical Investigation",
            year: "2021", authors: "Sharma", volume: nil, firstPage: nil
        )
        #expect(!SlideCitationService.locatorAccepted(read: read, locator: locator, record: nothingConfirmed))

        // Crossref's article number confirms the page the way OpenAlex could not.
        let articleNumbered = SlideCitationService.ResolvedPaper(
            doi: "10.1172/jci136055", title: noPage.title, journal: noPage.journal, year: "2021",
            authors: "Sharma; Reinstadler", volume: "131", firstPage: "E136055"
        )
        #expect(SlideCitationService.locatorAccepted(read: read, locator: locator, record: articleNumbered))
    }

    @Test("Page keys fold article-number prefixes and leading zeros")
    func pageKeys() {
        #expect(SlideCitationService.pageKey("e136055") == SlideCitationService.pageKey("136055"))
        #expect(SlideCitationService.pageKey("E136055") == SlideCitationService.pageKey("e136055"))
        #expect(SlideCitationService.pageKey("022") == SlideCitationService.pageKey("22"))
        #expect(SlideCitationService.pageKey("22") != SlideCitationService.pageKey("221"))
        #expect(SlideCitationService.volumeKey(" 37") == SlideCitationService.volumeKey("37"))
        #expect(SlideCitationService.volumeKey("37") != SlideCitationService.volumeKey("38"))
    }

    /// Crossref files an article-numbered paper under `article-number` and no `page`, and
    /// lists the venue's short forms; both feed the locator test.
    private func json(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// Crossref files an article-numbered paper under `article-number` and no `page`, and
    /// lists the venue's short forms; both feed the locator test.
    @Test("Crossref volume, page or article number and short titles are parsed")
    func parsesCrossrefLocatorFields() throws {
        let paged = try #require(SlideCitationService.parseCrossrefItem(json("""
        {"DOI": "10.1212/wnl.37.2.257",
         "title": ["Bioenergetic heterogeneity of human mitochondrial myopathies"],
         "container-title": ["Neurology"], "short-container-title": ["Neurology"],
         "issued": {"date-parts": [[1987, 2, 1]]},
         "author": [{"family": "Argov", "given": "Z."}],
         "volume": "37", "page": "257-262"}
        """)))
        #expect(paged.volume == "37")
        #expect(paged.firstPage == "257")
        #expect(paged.journalAliases == ["Neurology"])

        let numbered = try #require(SlideCitationService.parseCrossrefItem(json("""
        {"DOI": "10.1038/s42003-022-04303-x",
         "title": ["OxPhos defects cause hypermetabolism"],
         "container-title": ["Communications Biology"], "short-container-title": ["Commun Biol"],
         "issued": {"date-parts": [[2023, 1, 12]]},
         "author": [{"family": "Sturm", "given": "Gabriel"}],
         "volume": "6", "article-number": "22"}
        """)))
        #expect(numbered.firstPage == "22")
        #expect(numbered.journalAliases == ["Commun Biol"])
    }

    @Test("OpenAlex biblio fields are parsed")
    func parsesOpenAlexLocatorFields() throws {
        let work = try #require(SlideCitationService.parseOpenAlexWork(json("""
        {"doi": "https://doi.org/10.1126/science.aax0860",
         "title": "T cells with dysfunctional mitochondria induce multimorbidity and premature senescence",
         "publication_year": 2020,
         "biblio": {"volume": "368", "issue": "6497", "first_page": "1371", "last_page": "1376"},
         "authorships": [{"author": {"display_name": "Gabriela Desdín-Micó"}}],
         "primary_location": {"source": {"display_name": "Science"}}}
        """)))
        #expect(work.doi == "10.1126/science.aax0860")
        #expect(work.volume == "368")
        #expect(work.firstPage == "1371")
        #expect(work.journal == "Science")
        #expect(SlideCitationService.firstAuthorSurname(work.authors) == "Desdín-Micó")
    }

    // MARK: - Web fallback

    /// Crossref dates a paper to its online-first month, so a printed year one off is the same
    /// paper here as in the catalog pass; a printed volume or page the record contradicts is not.
    @Test("The web fallback allows online-first years and rejects a contradicted locator")
    func webMatchYearSlackAndLocator() throws {
        let read = entry(authors: "Sturm, G.", year: "2023", journal: "Commun. Biol.")
        let onlineFirst = SlideCitationService.ResolvedPaper(
            doi: sturm.doi, title: sturm.title, journal: sturm.journal, year: "2022",
            authors: "Sturm; Karan", volume: "6", firstPage: "22"
        )
        #expect(SlideCitationService.webMatchAccepted(read: read, candidate: onlineFirst))

        let locator = try #require(SlideCitationService.BibliographicLocator(volume: "6", pages: "22"))
        #expect(SlideCitationService.webMatchAccepted(read: read, candidate: onlineFirst, locator: locator))
        let otherVolume = try #require(SlideCitationService.BibliographicLocator(volume: "7", pages: "22"))
        #expect(!SlideCitationService.webMatchAccepted(read: read, candidate: onlineFirst, locator: otherVolume))

        // Authors written "Argov, Z." on one side and as a family name on the other still meet.
        let argov = entry(authors: "Argov, Z.; Bank, W. J.", year: "1987", journal: "Neurology")
        let record = SlideCitationService.ResolvedPaper(
            doi: "10.1212/wnl.37.2.257", title: "Bioenergetic heterogeneity", journal: "Neurology",
            year: "1987", authors: "Argov; Bank; Maris"
        )
        #expect(SlideCitationService.webMatchAccepted(read: argov, candidate: record))
    }

    @Test("The web prompt carries the volume and first page when the entry printed them")
    func webPromptIncludesLocator() throws {
        let read = entry(authors: "Sturm, G.", year: "2023", journal: "Commun. Biol.")
        let locator = try #require(SlideCitationService.BibliographicLocator(volume: "6", pages: "22"))
        let prompt = SlideCitationService.webLookupPrompt(for: read, locator: locator)
        #expect(!prompt.contains("Title:"))
        #expect(prompt.contains("Volume: 6"))
        #expect(prompt.contains("First page or article number: 22"))
        #expect(!SlideCitationService.webLookupPrompt(for: read).contains("Volume:"))
    }
}
