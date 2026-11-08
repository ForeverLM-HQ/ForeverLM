import Testing
import Foundation
import CoreText
import PDFKit
@testable import ForeverLM

/// The 2026-09-28 mis-import. Asked for Luoma et al., "Parkinsonism,
/// premature menopause, and mitochondrial DNA polymerase γ mutations" (Lancet
/// 2004), `import_paper_from_url` truncated its DOI at the parenthesis to
/// `10.1016/s0140-6736`, OpenAlex answered that DOI with an LSE repository
/// copy of Ginsburg et al., "The global burden of women's cancers" (Lancet
/// 2017), and the Paper Metadata model rewrote the source to match the file.
enum LancetMisImportFixture {
    static let luomaDOI = "10.1016/s0140-6736(04)16983-3"
    static let luomaTitle = "Parkinsonism, premature menopause, and mitochondrial DNA polymerase γ mutations: clinical and molecular genetic study"
    static let ginsburgDOI = "10.1016/S0140-6736(16)31392-7"
    static let ginsburgTitle = "The global burden of women’s cancers: a grand challenge in global health"
    static let wrongPDFURL = "https://researchonline.lse.ac.uk/id/eprint/102659/1/Womens_Cancers_Paper_Accepted_05.08.16.pdf"

    /// The opening of the PDF that was saved, as PDFKit reads it: LSE
    /// Research Online's cover sheet — which prints the truncated DOI — and
    /// the accepted manuscript's own title page, whose title words differ a
    /// little from the published one.
    static let coverSheetLines = [
        "Ginsburg, Ophira, Bray, Freddie, Coleman, Michel P, Vanderpuye, Verna, Eniu,",
        "Alexandru, Kotha, S Rani, Sarker, Malabika & Conteh, Lesong (2017) The global burden of",
        "women’s cancers: a grand challenge in global health. The Lancet, 389(10071),",
        "847-860. https://doi.org/10.1016/S0140-6736",
        "https://researchonline.lse.ac.uk/id/eprint/102659/",
        "Version: Accepted Version",
        "This document is the author’s accepted version of the journal article. There may be",
        "differences between this version and the published version.",
    ]
    static let titlePageLines = [
        "Lancet Series on Women’s Cancers Paper 1 REV 1 April 3, 2016",
        "The global burden of women’s cancers: an unmet grand challenge in global health.",
        "Ophira Ginsburg MD, Freddie Bray PhD, Michel P Coleman FFPH, Verna Vanderpuye MD",
        "1. Women’s College Research Institute, Faculty of Medicine, University of Toronto, Canada",
        "2. World Health Organization, Geneva, Switzerland",
        "3. Cancer Surveillance Section, International Agency for Research on Cancer, Lyon, France",
    ]
    static var openingText: String { (coverSheetLines + titlePageLines).joined(separator: "\n") }

    /// Enough of a paper's body that the file reads as text.
    static let bodyWords = """
        Background Mutations in the gene encoding the catalytic subunit of mitochondrial DNA \
        polymerase cause progressive external ophthalmoplegia with multiple deletions. Methods \
        We studied seven families and sequenced the gene in every affected member we could reach. \
        Findings Parkinsonism segregated with the mutations and responded to dopaminergic drugs.
        """

    /// The first page of the paper that was asked for: its title and DOI as
    /// the publisher prints them, over the start of its body.
    static var luomaPageLines: [String] {
        ["THE LANCET • Vol 364 • September 4, 2004", "DOI:10.1016/S0140-6736(04)16983-3"]
            + luomaTitle.components(separatedBy: ": ")
            + bodyWords.components(separatedBy: ". ")
    }

    /// One page per list of lines, drawn with CoreText so PDFKit reads the
    /// words back; `subject` becomes the document's Subject attribute, where
    /// Elsevier prints a paper's DOI.
    static func writePDF(to url: URL, pages: [[String]], subject: String? = nil) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        var info: [String: Any] = [:]
        if let subject { info[kCGPDFContextSubject as String] = subject }
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 9, nil)
        for lines in pages {
            context.beginPDFPage(nil)
            for (index, text) in lines.enumerated() {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
                context.textPosition = CGPoint(x: 36, y: 740 - CGFloat(index) * 14)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// A fresh directory for one test's files.
    static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paper_identity_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@Suite("Paper PDF identity")
struct PaperPDFIdentityTests {
    typealias Fixture = LancetMisImportFixture

    private func verdict(doi: String?, titles: [String], text: String) -> PaperPDFIdentity.Verdict {
        PaperPDFIdentity.verdict(
            for: PaperPDFIdentity.Request(doi: doi, titles: titles),
            evidence: PaperPDFIdentity.Evidence(openingText: text)
        )
    }

    // MARK: DOI parsing

    @Test("A printed DOI keeps the parentheses it opened and drops the ones it did not")
    func printedDOIsKeepTheirOwnParentheses() {
        #expect(PaperService.printedDOIs(in: "doi:10.1016/S0140-6736(04)16983-3") == ["10.1016/S0140-6736(04)16983-3"])
        #expect(PaperService.printedDOIs(in: "(https://doi.org/10.1016/S0140-6736(04)16983-3).") == ["10.1016/S0140-6736(04)16983-3"])
        #expect(PaperService.printedDOIs(in: "(see 10.1000/xyz).") == ["10.1000/xyz"])
        #expect(PaperService.printedDOIs(in: "[doi:10.1000/abc]") == ["10.1000/abc"])
        #expect(PaperService.printedDOIs(in: "doi:10.1002/(SICI)1097-0177(200001)217:1<2::AID-DVDY2>3.0.CO;2-8") == ["10.1002/(SICI)1097-0177(200001)217:1"])
        #expect(PaperService.printedDOIs(in: "doi: 10.1186/s13059-020-02210-0; pmid: 1") == ["10.1186/s13059-020-02210-0"])
        #expect(
            PaperService.printedDOIs(in: "Published 10.1038/s41586-020-2012-7, preprint 10.1101/2020.01.22.914952.")
                == ["10.1038/s41586-020-2012-7", "10.1101/2020.01.22.914952"]
        )
        #expect(PaperService.printedDOIs(in: "Vol 10.1234/") == [])
    }

    @Test("The Lancet's parenthesised DOI survives the open-access lookup and the page metadata")
    func parenthesisedDOISurvivesTheImportParsers() {
        // The regression itself: the stored DOI was cut to `10.1016/s0140-6736`
        // before OpenAlex was asked.
        #expect(PaperService.openAccessLookupDOI(
            url: "https://www.thelancet.com/journals/lancet/article/PIIS0140-6736(04)16983-3/fulltext",
            storedDOI: Fixture.luomaDOI
        ) == Fixture.luomaDOI)
        #expect(PaperService.openAccessLookupDOI(
            url: "https://doi.org/10.1016/s0140-6736(04)16983-3",
            storedDOI: nil
        ) == Fixture.luomaDOI)

        let html = """
        <html><head>
        <meta name="citation_title" content="Parkinsonism, premature menopause, and mitochondrial DNA polymerase γ mutations">
        <meta name="citation_doi" content="10.1016/S0140-6736(04)16983-3">
        </head><body></body></html>
        """
        #expect(PaperService.extractPaperPageMetadata(from: html)?.doi == "10.1016/S0140-6736(04)16983-3")
    }

    @Test("Europe PMC is asked for a DOI as one phrase")
    func europePMCQuotesTheDOI() {
        // Unquoted, Lucene reads the `(` as a group and finds nothing.
        #expect(PaperService.europePMCDOIQuery(Fixture.luomaDOI) == "DOI:\"10.1016/s0140-6736(04)16983-3\"")
        #expect(PaperService.europePMCDOIQuery("10.1038/s41592-018-0229-2") == "DOI:\"10.1038/s41592-018-0229-2\"")
    }

    // MARK: Verdicts

    @Test("Another Lancet paper's accepted manuscript is turned away")
    func wrongLancetPaperIsAMismatch() {
        let result = verdict(doi: Fixture.luomaDOI, titles: [Fixture.luomaTitle], text: Fixture.openingText)
        guard case .mismatch(let reason) = result else {
            Issue.record("expected a mismatch, got \(result)")
            return
        }
        #expect(reason.contains(Fixture.luomaTitle))
        #expect(reason.contains("10.1016/S0140-6736"))
    }

    @Test("The same file is confirmed for the paper it is, under its reworded manuscript title")
    func wrongFileIsRightForItsOwnPaper() {
        #expect(verdict(doi: Fixture.ginsburgDOI, titles: [Fixture.ginsburgTitle], text: Fixture.openingText) == .confirmed)
    }

    @Test("A requested title outweighs the truncated DOI the cover sheet prints")
    func titleOutweighsATruncatedDOI() {
        let result = verdict(doi: "10.1016/s0140-6736", titles: [Fixture.luomaTitle], text: Fixture.openingText)
        guard case .mismatch = result else {
            Issue.record("expected a mismatch, got \(result)")
            return
        }
    }

    @Test("With no title to go on, a DOI the requested one merely starts with is a different DOI")
    func truncatedPrintedDOIIsNotTheRequestedOne() {
        let result = verdict(doi: Fixture.luomaDOI, titles: [], text: Fixture.openingText)
        #expect(result == .mismatch("it prints the DOI 10.1016/S0140-6736, not \(Fixture.luomaDOI)"))
    }

    @Test("A publisher PDF that prints the requested DOI needs no title")
    func printedRequestedDOIConfirms() {
        let text = "THE LANCET • Vol 364 • September 4, 2004 • www.thelancet.com\nDOI:10.1016/S0140-6736(04)16983-3\n" + Fixture.bodyWords
        #expect(verdict(doi: Fixture.luomaDOI, titles: [], text: text) == .confirmed)
        #expect(verdict(doi: "https://doi.org/10.1016/S0140-6736(04)16983-3", titles: [], text: text) == .confirmed)
    }

    @Test("A DOI the page broke across lines is still printed")
    func lineBrokenDOIConfirms() {
        let text = "https://doi.org/10.1016/S0140-\n6736(04)16983-3\n" + Fixture.bodyWords
        #expect(verdict(doi: Fixture.luomaDOI, titles: [], text: text) == .confirmed)
    }

    @Test("A longer DOI that starts with the requested one is not it")
    func longerDOIIsNotTheRequestedOne() {
        let text = "doi:10.1038/nature12345\n" + Fixture.bodyWords
        #expect(verdict(doi: "10.1038/nature1234", titles: [], text: text) == .mismatch("it prints the DOI 10.1038/nature12345, not 10.1038/nature1234"))
    }

    @Test("A title the typesetter hyphenated across lines still reads as the title")
    func hyphenatedTitleConfirms() {
        let text = """
            Parkinsonism, premature menopause, and mito-
            chondrial DNA polymerase γ muta-
            tions: clinical and molecular genetic study
            Luoma P, Melberg A, Rinne JO, Kaukonen JA, Nupponen NN
            """ + "\n" + Fixture.bodyWords
        #expect(verdict(doi: Fixture.luomaDOI, titles: [Fixture.luomaTitle], text: text) == .confirmed)
    }

    @Test("A title's words scattered through a paper that prints its own DOI are not its title")
    func scatteredTitleWordsDoNotConfirm() {
        // Every content word of the Luoma title, each a sentence apart, never
        // standing together as a title does.
        let filler = "we measured every sample twice over several weeks in the laboratory under the same conditions to be sure"
        let scattered = ["Parkinsonism", "premature", "menopause", "mitochondrial", "DNA", "polymerase",
                         "mutations", "clinical", "molecular", "genetic", "study"]
            .map { "\($0) \(filler)." }
            .joined(separator: "\n")
        let result = verdict(doi: Fixture.luomaDOI, titles: [Fixture.luomaTitle], text: "doi:10.1016/j.mito.2019.07.003\n" + scattered)
        guard case .mismatch = result else {
            Issue.record("expected a mismatch, got \(result)")
            return
        }
        // A file that prints no DOI at all has only its headline to go on,
        // and a magazine piece's print headline can differ from its
        // registered title, so there the words may lie anywhere.
        #expect(verdict(doi: Fixture.luomaDOI, titles: [Fixture.luomaTitle], text: scattered) == .confirmed)
    }

    @Test("A short title printed whole is recognised, though the piece prints another paper's DOI")
    func shortTitlePrintedWholeConfirms() {
        // A Nature Reviews Research Highlight prints the DOI of the paper it
        // highlights and never its own: the one file of 701 in the library a
        // DOI-only rule turned away (2026-09-28).
        let text = """
            Research Highlights
            METABOLISM
            Alternative cycle for citrate
            The citric acid cycle sits at the centre of carbon metabolism. A second, cyclic route for citrate \
            runs between mitochondria and cytosol, the authors report, and cell state decides which one a cell uses.
            ORIGINAL ARTICLE Arnold, P. K. et al. A non-canonical tricarboxylic acid cycle underlies cellular \
            identity. Nature https://doi.org/10.1038/s41586-022-04475-w (2022)
            """
        let highlightDOI = "10.1038/s41580-022-00475-w"
        #expect(verdict(doi: highlightDOI, titles: ["Alternative cycle for citrate"], text: text) == .confirmed)
        // Without the title, the other paper's DOI is all there is to go on.
        #expect(verdict(doi: highlightDOI, titles: [], text: text)
            == .mismatch("it prints the DOI 10.1038/s41586-022-04475-w, not \(highlightDOI)"))
    }

    @Test("A bioRxiv address's version suffix is not a different DOI")
    func versionSuffixIsTheSameDOI() {
        let text = "bioRxiv preprint doi: https://doi.org/10.1101/2024.01.02.573921; this version posted January 3, 2024.\n" + Fixture.bodyWords
        #expect(verdict(doi: "10.1101/2024.01.02.573921v2", titles: [], text: text) == .confirmed)
    }

    @Test("A scan without a text layer cannot refute anything")
    func unreadableFileIsUnverifiable() {
        #expect(verdict(doi: Fixture.luomaDOI, titles: [Fixture.luomaTitle], text: "") == .unverifiable)
        #expect(!PaperPDFIdentity.hasReadableText(PaperPDFIdentity.Evidence(openingText: "Luoma 2004")))
        #expect(PaperPDFIdentity.hasReadableText(PaperPDFIdentity.Evidence(openingText: Fixture.openingText)))
    }

    @Test("Chrome a landing page wore and an empty request judge nothing")
    func chromeAndEmptyRequestsAreUnverifiable() {
        #expect(verdict(doi: nil, titles: ["Just a moment..."], text: Fixture.openingText) == .unverifiable)
        #expect(verdict(doi: nil, titles: ["Client Request Error"], text: Fixture.openingText) == .unverifiable)
        #expect(verdict(doi: nil, titles: [], text: Fixture.openingText) == .unverifiable)
        #expect(!PaperPDFIdentity.Request(doi: "  ", titles: ["", "  "]).asksForAnything)
    }
}

@Suite("Paper PDF identity in the import pipeline")
struct PaperPDFIdentityImportTests {
    typealias Fixture = LancetMisImportFixture

    private func makeStore() throws -> (MCPDataStore, URL) {
        let directory = try Fixture.makeDirectory()
        let store = MCPDataStore(dbPath: directory.appendingPathComponent("knowledge.db").path)
        _ = try store.knowledgeStore()
        return (store, directory)
    }

    @Test("The DOI scanners that read a downloaded PDF keep a DOI's parentheses")
    func pdfDOIScannersKeepParentheses() {
        #expect(MCPDataStore.extractDOIFromText("DOI: 10.1016/S0140-6736(16)31392-7\nReceived") == "10.1016/S0140-6736(16)31392-7")
        #expect(StudioViewModel.extractDOIFromText("doi:10.1016/S0140-6736(04)16983-3.") == "10.1016/S0140-6736(04)16983-3")
        // The wrong file's cover sheet prints the truncated DOI, and that is
        // what it prints.
        #expect(MCPDataStore.extractDOIFromText(Fixture.openingText) == "10.1016/S0140-6736")
    }

    @Test("The wrong PDF's opening pages are read from the file and turn it away")
    func fileVerdictTurnsAwayTheWrongLancetPDF() async throws {
        let directory = try Fixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("candidate.pdf")
        try Fixture.writePDF(to: file, pages: [Fixture.coverSheetLines, Fixture.titlePageLines])

        var request = PaperPDFIdentity.Request(doi: Fixture.luomaDOI, titles: [Fixture.luomaTitle])
        // The registered title would come from Crossref; the verdict is the
        // same without it, so the test stays off the network.
        request.askedForRegisteredTitle = true
        let verdict = await PaperPDFIdentity.verdict(forPDFAt: file, request: &request)
        guard case .mismatch(let reason) = verdict else {
            Issue.record("expected a mismatch, got \(verdict)")
            return
        }
        #expect(reason.contains(Fixture.luomaTitle))
    }

    @Test("A PDF whose Subject attribute prints the requested DOI is confirmed")
    func fileVerdictConfirmsDOIInTheSubjectAttribute() async throws {
        let directory = try Fixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("candidate.pdf")
        try Fixture.writePDF(
            to: file,
            pages: [Fixture.bodyWords.components(separatedBy: ". ")],
            subject: "The Lancet, 364 (2004) 875-882. doi:10.1016/S0140-6736(04)16983-3"
        )

        var request = PaperPDFIdentity.Request(doi: Fixture.luomaDOI, titles: [])
        let verdict = await PaperPDFIdentity.verdict(forPDFAt: file, request: &request)
        #expect(verdict == .confirmed)
        #expect(!request.askedForRegisteredTitle, "a confirmed file sends nobody to Crossref")
    }

    @Test("A file turned away as another paper is paywall evidence that names it")
    func mismatchIsPaywallEvidence() throws {
        let mismatch = PaperPDFIdentityMismatchError(
            pdfURL: Fixture.wrongPDFURL,
            reason: "its opening pages do not carry the title “\(Fixture.luomaTitle)”"
        )
        let evidence = try #require(MCPDataStore.paperPaywallEvidence(for: mismatch))
        #expect(evidence.contains("researchonline.lse.ac.uk is a different paper"))

        let combined = MCPDataStore.paperPaywallEvidence("no open-access PDF found", rejecting: [mismatch])
        #expect(combined.hasPrefix("no open-access PDF found; the PDF found at researchonline.lse.ac.uk is a different paper"))
        #expect(MCPDataStore.paperPaywallEvidence("publisher denied access (HTTP 403)", rejecting: []) == "publisher denied access (HTTP 403)")
    }

    @Test("A turned-away PDF leaves the requested paper's bibliography on a paywalled row")
    func turnedAwayPDFKeepsTheRequestedBibliography() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = "https://doi.org/10.1016/s0140-6736(04)16983-3"
        let crossref = PaperService.CrossrefMetadata(
            authorsDisplay: "Petri Luoma et al.",
            journal: "The Lancet",
            year: "2004",
            title: Fixture.luomaTitle,
            doi: Fixture.luomaDOI
        )
        let mismatch = PaperPDFIdentityMismatchError(pdfURL: Fixture.wrongPDFURL, reason: "it prints the DOI 10.1016/S0140-6736")
        let evidence = MCPDataStore.paperPaywallEvidence(
            try #require(MCPDataStore.paperPaywallEvidence(for: PaperPDFUnavailableError(sourceURL: sourceURL))),
            rejecting: [mismatch]
        )
        let result = try #require(try store.savePaywalledPaperImport(
            sourceURL: sourceURL,
            normalizedURL: URLNormalizer.normalize(sourceURL),
            titleOverride: nil,
            pageMetadata: PaperService.PaperPageMetadata(
                title: "Redirecting", authorsDisplay: nil, journal: nil, year: nil, doi: nil, pdfURL: nil
            ),
            scholarlyMetadata: crossref,
            doi: Fixture.luomaDOI,
            evidence: evidence,
            connectorLabel: nil
        ))
        #expect(result.contains("is a different paper"))

        let id = try #require(try store.existingPaperByDOI(Fixture.luomaDOI)?.id)
        let saved = try #require(try store.knowledgeStore().loadSourceForSync(id))
        #expect(saved.title == Fixture.luomaTitle)
        #expect(saved.doi == Fixture.luomaDOI)
        #expect(saved.publishedYear == "2004")
        #expect(saved.isPaywalled)
        #expect(saved.resolvedPDFPath == nil)
    }
}

/// The DOIs the gate asked Crossref about, standing in for the network.
private actor RegisteredTitleLookups {
    private(set) var dois: [String] = []
    func record(_ doi: String) { dois.append(doi) }
}

// MARK: - Studio pipeline

/// The Studio's own resolution (`downloadPaperPDF`, and the open-access copies
/// `adoptOpenAccessAlternativeIfAvailable` swaps onto the row) holds every file
/// to the paper through `StudioViewModel.PaperPDFIdentityGate`, the way the MCP
/// import does, before `convertPaperToLocalPDF` and the Paper Metadata model.
@Suite("Paper PDF identity in the Studio pipeline")
@MainActor
struct PaperPDFIdentityStudioTests {
    typealias Fixture = LancetMisImportFixture
    typealias Gate = StudioViewModel.PaperPDFIdentityGate

    private func luomaRow(title: String = Fixture.luomaTitle) -> StudioArticle {
        var article = StudioArticle(
            url: "https://www.thelancet.com/journals/lancet/article/PIIS0140-6736(04)16983-3/fulltext",
            title: title,
            sourceType: .paper
        )
        article.domain = "thelancet.com"
        article.doi = Fixture.luomaDOI
        return article
    }

    private func wrongLancetPDF(in directory: URL, named name: String = "candidate.pdf") throws -> URL {
        let file = directory.appendingPathComponent(name)
        try Fixture.writePDF(to: file, pages: [Fixture.coverSheetLines, Fixture.titlePageLines])
        return file
    }

    @Test("A row's PDFs are held to its DOI, and to its title once that is a real one")
    func requestIsTheRowsDOIAndRealTitle() {
        let request = StudioViewModel.paperPDFIdentityRequest(for: luomaRow())
        #expect(request.doi == Fixture.luomaDOI)
        #expect(request.titles == [Fixture.luomaTitle])

        // A row still wearing its domain has no title to hold a file to.
        #expect(StudioViewModel.paperPDFIdentityRequest(for: luomaRow(title: "thelancet.com")).titles.isEmpty)

        // With no stored DOI, the one its address carries, parentheses and all.
        let bare = StudioArticle(url: "https://doi.org/10.1016/s0140-6736(04)16983-3", title: "doi.org", sourceType: .paper)
        #expect(StudioViewModel.paperPDFIdentityRequest(for: bare).doi == Fixture.luomaDOI)
    }

    @Test("The wrong Lancet PDF is turned away, removed and logged under the paper's source id")
    func gateTurnsAwayTheWrongLancetPDF() async throws {
        let directory = try Fixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try wrongLancetPDF(in: directory)
        let row = luomaRow()
        let lookups = RegisteredTitleLookups()
        var logged: [(sourceID: String, doi: String?, pdfURL: String)] = []
        let gate = Gate(
            article: row,
            registeredTitle: { doi in await lookups.record(doi); return nil },
            recordMismatch: { gate, rejection in logged.append((gate.sourceID, gate.request.doi, rejection.pdfURL)) }
        )

        await #expect(throws: PaperPDFIdentityMismatchError.self) {
            try await gate.admit(pdfAt: file.path, from: Fixture.wrongPDFURL)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path), "the wrong file never reaches the metadata model")
        #expect(gate.rejections.map(\.origin) == ["researchonline.lse.ac.uk"])
        #expect(gate.rejections.first?.reason.contains(Fixture.luomaTitle) == true)
        #expect(logged.count == 1)
        #expect(logged.first?.sourceID == row.id)
        #expect(logged.first?.doi == Fixture.luomaDOI)
        #expect(logged.first?.pdfURL == Fixture.wrongPDFURL)
        #expect(await lookups.dois == [Fixture.luomaDOI])
    }

    @Test("A file already in the Papers folder is turned away but left where it is")
    func gateKeepsAFileItDidNotDownload() async throws {
        let directory = try Fixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Two rows whose DOIs were cut to the same prefix share this name, so
        // the file may be the other row's PDF.
        let file = try wrongLancetPDF(in: directory, named: "10.1016_s0140-6736.pdf")
        let gate = Gate(article: luomaRow(), registeredTitle: { _ in nil }, recordMismatch: { _, _ in })

        await #expect(throws: PaperPDFIdentityMismatchError.self) {
            try await gate.admit(pdfAt: file.path, from: file.absoluteString, keepsRejectedFile: true)
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(gate.rejections.first?.evidence.hasPrefix("the PDF found at 10.1016_s0140-6736.pdf is a different paper") == true)
    }

    @Test("The same file is admitted for the paper it is, with nobody sent to Crossref")
    func gateAdmitsThePaperItIsFor() async throws {
        let directory = try Fixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try wrongLancetPDF(in: directory)
        var ginsburg = StudioArticle(url: "https://doi.org/10.1016/S0140-6736(16)31392-7", title: Fixture.ginsburgTitle, sourceType: .paper)
        ginsburg.doi = Fixture.ginsburgDOI
        let lookups = RegisteredTitleLookups()
        let gate = Gate(
            article: ginsburg,
            registeredTitle: { doi in await lookups.record(doi); return nil },
            recordMismatch: { _, _ in Issue.record("a confirmed file is not logged") }
        )

        try await gate.admit(pdfAt: file.path, from: Fixture.wrongPDFURL)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(gate.rejections.isEmpty)
        #expect(await lookups.dois.isEmpty)
    }

    @Test("One gate asks for the registered title once across every candidate, and it confirms the right file")
    func registeredTitleIsAskedOnceAcrossCandidates() async throws {
        let directory = try Fixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A row still wearing its domain: only the DOI says which paper it is.
        let lookups = RegisteredTitleLookups()
        let gate = Gate(
            article: luomaRow(title: "thelancet.com"),
            registeredTitle: { doi in await lookups.record(doi); return Fixture.luomaTitle },
            recordMismatch: { _, _ in }
        )

        for name in ["openalex.pdf", "unpaywall.pdf"] {
            let file = try wrongLancetPDF(in: directory, named: name)
            await #expect(throws: PaperPDFIdentityMismatchError.self) {
                try await gate.admit(pdfAt: file.path, from: "https://example.org/\(name)")
            }
        }
        let right = directory.appendingPathComponent("pmc.pdf")
        try Fixture.writePDF(to: right, pages: [Fixture.luomaPageLines])
        try await gate.admit(pdfAt: right.path, from: "https://pmc.ncbi.nlm.nih.gov/articles/PMC0000000/pdf")

        #expect(await lookups.dois == [Fixture.luomaDOI])
        #expect(gate.request.titles == [Fixture.luomaTitle])
        #expect(gate.rejections.count == 2)
        #expect(FileManager.default.fileExists(atPath: right.path))
    }

    @Test("A row whose open-access copies were all turned away names each file")
    func openAccessFailureNamesTheFilesTurnedAway() {
        #expect(StudioViewModel.openAccessFailureMessage(turnedAway: [])
            == "Found open-access copies, but none returned a readable PDF. Attach the PDF manually.")

        let rejection = PaperPDFIdentityMismatchError(
            pdfURL: Fixture.wrongPDFURL,
            reason: "its opening pages do not carry the title “\(Fixture.luomaTitle)”"
        )
        let message = StudioViewModel.openAccessFailureMessage(turnedAway: [rejection])
        #expect(message.contains("The PDF found at researchonline.lse.ac.uk is a different paper: its opening pages do not carry the title"))
        #expect(message.hasSuffix("Attach the PDF manually."))

        #expect(StudioViewModel.turnedAwayPDFsSummary([]) == nil)
        #expect(StudioViewModel.turnedAwayPDFsSummary([rejection])
            == "turned away the PDF found at researchonline.lse.ac.uk, a different paper")
        #expect(StudioViewModel.turnedAwayPDFsSummary([rejection, rejection]) == "turned away 2 PDFs that were other papers")
    }

    @Test("A download that must not touch the file there goes to the next free name beside it")
    func unusedPaperPathNumbersBesideTheTakenFile() async throws {
        let directory = try Fixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let taken = directory.appendingPathComponent("10.1016_s0140-6736.pdf")
        try Data("%PDF".utf8).write(to: taken)

        let second = await StudioViewModel.unusedPaperPath(besides: taken.path)
        #expect((second as NSString).lastPathComponent == "10.1016_s0140-6736 2.pdf")
        try Data("%PDF".utf8).write(to: URL(fileURLWithPath: second))
        #expect((await StudioViewModel.unusedPaperPath(besides: taken.path) as NSString).lastPathComponent == "10.1016_s0140-6736 3.pdf")
    }
}

// MARK: - The AI browser agent's file

/// Step 3 of `resolveMissingPaperPDF`, the AI browser agent, downloads a file
/// from a link a model picked, which is exactly the kind of candidate that can
/// be another paper. It is held to the resolution's gate like the steps before
/// it, before the model's title check and before anything is installed.
@Suite("Paper PDF identity for the AI browser agent's file")
@MainActor
struct PaperPDFIdentityBrowserAgentTests {
    typealias Fixture = LancetMisImportFixture
    typealias Gate = StudioViewModel.PaperPDFIdentityGate
    typealias Download = SourceDiscovery.PaperAIBrowserDownloadService.DownloadedPDF

    /// The row a paywall recheck hands the browser: the Luoma paper, marked paywalled.
    private func paywalledLuomaRow() -> StudioArticle {
        var article = StudioArticle(
            url: "https://www.thelancet.com/journals/lancet/article/PIIS0140-6736(04)16983-3/fulltext",
            title: Fixture.luomaTitle,
            sourceType: .paper
        )
        article.domain = "thelancet.com"
        article.doi = Fixture.luomaDOI
        article.isPaywalled = true
        return article
    }

    private func viewModel(showing row: StudioArticle) -> StudioViewModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaperPDFIdentityBrowser_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vm = StudioViewModel(storageService: StorageService(storeRoot: root), observeCloudKitChanges: false)
        vm.articles = [row]
        return vm
    }

    /// Where WebKit put the agent's download: a temporary file named by a UUID.
    private func agentDownload(in directory: URL, pages: [[String]]) throws -> URL {
        let file = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        try Fixture.writePDF(to: file, pages: pages)
        return file
    }

    @Test("The agent's download of another paper fails the attempt, names its host, and leaves the row paywalled")
    func agentsWrongPaperIsTurnedAway() async throws {
        let directory = try Fixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let row = paywalledLuomaRow()
        let vm = viewModel(showing: row)
        let attemptID = UUID()
        vm.activePaperBrowserAttemptIDs[row.id] = attemptID
        var logged: [String] = []
        let gate = Gate(
            article: row,
            registeredTitle: { _ in nil },
            recordMismatch: { gate, _ in logged.append(gate.sourceID) }
        )
        let file = try agentDownload(in: directory, pages: [Fixture.coverSheetLines, Fixture.titlePageLines])

        let rejection = await #expect(throws: PaperPDFIdentityMismatchError.self) {
            try await vm.attachPaperBrowserDownload(
                Download(file: file, sourceURL: URL(string: Fixture.wrongPDFURL)),
                to: row.id,
                attemptID: attemptID,
                identity: gate
            )
        }
        #expect(rejection?.pdfURL == Fixture.wrongPDFURL)
        #expect(!FileManager.default.fileExists(atPath: file.path), "the temporary download is removed")
        let saved = try #require(vm.articles.first)
        #expect(saved.localFilePath == nil)
        #expect(saved.hasPaywallMarker)
        #expect(saved.title == Fixture.luomaTitle)
        #expect(saved.doi == Fixture.luomaDOI)
        #expect(vm.attachingPDFIds.isEmpty)
        #expect(logged == [row.id])
        // What the recheck's and the needing-attention pass's summaries read.
        #expect(StudioViewModel.turnedAwayPDFsSummary(gate.rejections)
            == "turned away the PDF found at researchonline.lse.ac.uk, a different paper")
    }

    @Test("A download WebKit named no address for is turned away in the agent's name, not the temporary file's")
    func rejectionWithoutAnAddressNamesTheAgent() async throws {
        let directory = try Fixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let row = paywalledLuomaRow()
        let vm = viewModel(showing: row)
        let attemptID = UUID()
        vm.activePaperBrowserAttemptIDs[row.id] = attemptID
        let gate = Gate(article: row, registeredTitle: { _ in nil }, recordMismatch: { _, _ in })
        let file = try agentDownload(in: directory, pages: [Fixture.coverSheetLines, Fixture.titlePageLines])

        await #expect(throws: PaperPDFIdentityMismatchError.self) {
            try await vm.attachPaperBrowserDownload(
                Download(file: file, sourceURL: nil),
                to: row.id,
                attemptID: attemptID,
                identity: gate
            )
        }
        #expect(gate.rejections.map(\.origin) == [StudioViewModel.paperBrowserAgentPDFOrigin])
        #expect(StudioViewModel.turnedAwayPDFsSummary(gate.rejections)
            == "turned away the PDF found at a link the AI browser chose, a different paper")
    }

    @Test("The paper's supplementary file is refused though it prints the paper's title and DOI")
    func supplementaryDownloadIsNotThePaper() async throws {
        let directory = try Fixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let row = paywalledLuomaRow()
        let vm = viewModel(showing: row)
        let attemptID = UUID()
        vm.activePaperBrowserAttemptIDs[row.id] = attemptID
        let gate = Gate(article: row, registeredTitle: { _ in nil }, recordMismatch: { _, _ in Issue.record("the gate never sees it") })
        let file = try agentDownload(in: directory, pages: [Fixture.luomaPageLines])
        let appendix = "https://www.thelancet.com/cms/10.1016/S0140-6736(04)16983-3/attachment/supplementary_appendix.pdf"

        await #expect(throws: SourceError.paperIngestionFailed("That file is the paper's supplementary material, not the paper.")) {
            try await vm.attachPaperBrowserDownload(
                Download(file: file, sourceURL: URL(string: appendix)),
                to: row.id,
                attemptID: attemptID,
                identity: gate
            )
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(gate.rejections.isEmpty)
        #expect(vm.articles.first?.localFilePath == nil)
    }

    @Test("A file the gate confirms is attached without the model's title check")
    func confirmedFileSkipsTheTitleCheck() async throws {
        let directory = try Fixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try agentDownload(in: directory, pages: [Fixture.luomaPageLines])
        let gate = Gate(article: paywalledLuomaRow(), registeredTitle: { _ in nil }, recordMismatch: { _, _ in })
        var titleChecks = 0

        let admitted = try await StudioViewModel.admitsPDFAttachment(
            at: file.path,
            from: "https://pmc.ncbi.nlm.nih.gov/articles/PMC0000000/pdf",
            identity: gate,
            titleCheck: { titleChecks += 1; return false }
        )
        #expect(admitted)
        #expect(titleChecks == 0)
        #expect(gate.rejections.isEmpty)
    }

    @Test("Another paper's file never reaches the title check, and is left for its owner to remove")
    func mismatchNeverReachesTheTitleCheck() async throws {
        let directory = try Fixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try agentDownload(in: directory, pages: [Fixture.coverSheetLines, Fixture.titlePageLines])
        let gate = Gate(article: paywalledLuomaRow(), registeredTitle: { _ in nil }, recordMismatch: { _, _ in })
        var titleChecks = 0

        await #expect(throws: PaperPDFIdentityMismatchError.self) {
            try await StudioViewModel.admitsPDFAttachment(
                at: file.path,
                from: Fixture.wrongPDFURL,
                identity: gate,
                titleCheck: { titleChecks += 1; return true }
            )
        }
        #expect(titleChecks == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("A file the gate cannot read, or one with no gate, is left to the title check")
    func unverifiableFileGoesToTheTitleCheck() async throws {
        let directory = try Fixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Too few words to judge by, and no DOI: a scan without a text layer.
        let scan = try agentDownload(in: directory, pages: [["Scanned page 1"]])
        let gate = Gate(article: paywalledLuomaRow(), registeredTitle: { _ in nil }, recordMismatch: { _, _ in })
        var titleChecks = 0

        let admittedScan = try await StudioViewModel.admitsPDFAttachment(
            at: scan.path,
            from: "https://example.org/scan.pdf",
            identity: gate,
            titleCheck: { titleChecks += 1; return false }
        )
        #expect(!admittedScan, "the title check's answer stands")
        #expect(titleChecks == 1)
        #expect(gate.rejections.isEmpty)

        // The learner's own Try with AI Browser holds no gate.
        let right = try agentDownload(in: directory, pages: [Fixture.luomaPageLines])
        let admittedWithoutGate = try await StudioViewModel.admitsPDFAttachment(
            at: right.path,
            from: "https://pmc.ncbi.nlm.nih.gov/articles/PMC0000000/pdf",
            identity: nil,
            titleCheck: { titleChecks += 1; return true }
        )
        #expect(admittedWithoutGate)
        #expect(titleChecks == 2)
    }

    @Test("A download a page's script assembled is named by the page that made it")
    func blobAddressNamesItsPage() {
        let rejection = PaperPDFIdentityMismatchError(
            pdfURL: "blob:https://www.thelancet.com/7c1e0b52-4d2a-4f0e-9d7e-2b8f3f7c9a10",
            reason: "its opening pages do not carry the title “\(Fixture.luomaTitle)”"
        )
        #expect(rejection.origin == "thelancet.com")
    }
}

// MARK: - Retry Download keeps the paper until a copy is accepted

/// Retry Download tries the paper's open-access copies. It used to clear the
/// paper's text, walkthroughs and narration before each try, so a retry that
/// found no usable copy left the paper with nothing. Now nothing is cleared
/// until a copy's PDF is accepted, and then in the transaction that saves it.
@Suite("Open-access retry keeps the paper until a copy is accepted")
@MainActor
struct OpenAccessRetryKeepsPaperTests {
    private static let text = "Mitochondria couple respiration to ATP synthesis through a proton gradient across the inner membrane."

    private static func walkthrough(for sourceID: String) -> PaperWalkthrough {
        PaperWalkthrough(
            sourceID: sourceID,
            sourceSHA256: PaperContentPreparationService.sha256(text),
            title: "Coupling",
            steps: [
                PaperWalkthroughStep(
                    id: "step-0", kind: .explain, title: "Coupling", body: "Respiration and ATP synthesis are coupled.",
                    anchor: PaperWalkthroughAnchor(passage: "couple respiration to ATP synthesis")
                ),
            ],
            author: .assistant
        )
    }

    /// A paper whose download failed, holding stored text and a walkthrough.
    private static func seedPaper(_ store: KnowledgeStore, id: String = "paper-1") throws -> StudioArticle {
        var paper = StudioArticle(
            url: "https://journals.example.org/article/\(id)",
            title: "Coupling in the inner membrane",
            sourceType: .paper,
            id: id
        )
        paper.domain = "journals.example.org"
        paper.state = .error
        paper.errorMessage = "PDF download failed"
        try store.saveSource(paper)
        try store.execForTesting("INSERT OR REPLACE INTO source_content (source_id, content) VALUES ('\(id)', '\(text)')")
        try store.savePaperWalkthrough(walkthrough(for: id))
        return paper
    }

    @Test("A retry whose every copy fails leaves the paper's text, walkthrough and address as they were")
    func everyCandidateFailing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenAccessRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage, observeCloudKitChanges: false)
        let store = try await storage.notebookFilesKnowledgeStore()
        let paper = try Self.seedPaper(store)
        vm.articles.append(paper)
        let gate = StudioViewModel.PaperPDFIdentityGate(article: paper, registeredTitle: { _ in nil }, recordMismatch: { _, _ in })

        var tried: [String] = []
        let handled = await vm.adoptOpenAccessAlternative(
            for: paper.id,
            among: [
                PaperService.OpenAccessAlternativeResult(replacementURL: "https://repository.example.org/a.pdf", sourceName: "Repository A"),
                PaperService.OpenAccessAlternativeResult(replacementURL: "https://repository.example.org/b.pdf", sourceName: "Repository B"),
            ],
            userInitiated: true,
            markFailure: true,
            identity: gate
        ) { _ in
            tried.append(vm.articles.first { $0.id == paper.id }?.url ?? "")
            // While a copy is tried, nothing stored has gone.
            #expect(try! store.hasPaperWalkthroughRow(paper.id))
            #expect(try! store.loadSourceContent(paper.id) == Self.text)
            return StudioViewModel.PaperDownloadResult(success: false, lastError: SourceError.pdfReadFailed)
        }

        #expect(handled)
        #expect(tried == ["https://repository.example.org/a.pdf", "https://repository.example.org/b.pdf"])
        #expect(try store.hasPaperWalkthroughRow(paper.id), "the walkthrough survives a retry that attached nothing")
        #expect(try store.loadSourceContent(paper.id) == Self.text, "the text survives too")
        let stored = try #require(try store.loadSourceForSync(paper.id))
        #expect(stored.url == paper.url)
        #expect(stored.state == .error)
        #expect(stored.errorMessage == StudioViewModel.openAccessFailureMessage(turnedAway: []))
        let shown = try #require(vm.articles.first { $0.id == paper.id })
        #expect(shown.url == paper.url)
        #expect(shown.errorMessage == stored.errorMessage)
    }

    @Test("The save that attaches a copy clears the old text and walkthrough with it, and a refused save clears nothing")
    func replacingSaveIsOneTransaction() throws {
        let store = try KnowledgeStore(inMemory: true)
        let paper = try Self.seedPaper(store)

        // A save the store refuses (ready with no text) rolls the clearing back.
        var refused = paper
        refused.state = .ready
        refused.errorMessage = nil
        refused.content = "   "
        #expect(throws: (any Error).self) { try store.saveSourceReplacingDerivedData(refused) }
        #expect(try store.hasPaperWalkthroughRow(paper.id))
        #expect(try store.loadSourceContent(paper.id) == Self.text)
        #expect(try store.loadSourceForSync(paper.id)?.state == .error)

        // The accepted copy's save takes the old text and its walkthrough.
        var attached = paper
        attached.url = "https://repository.example.org/a.pdf"
        attached.localFilePath = "Papers/paper-1.pdf"
        attached.domain = "Local PDF"
        attached.prepareForPaperMetadataExtraction()
        try store.saveSourceReplacingDerivedData(attached)
        #expect(try !store.hasPaperWalkthroughRow(paper.id))
        #expect(try store.loadSourceContent(paper.id) == nil)
        let stored = try #require(try store.loadSourceForSync(paper.id))
        #expect(stored.url == "https://repository.example.org/a.pdf")
        #expect(stored.state == .queued)
    }
}
