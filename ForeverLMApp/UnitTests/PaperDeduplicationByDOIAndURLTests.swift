import Foundation
import Testing
@testable import ForeverLM

private func makePaper(
    url: String = "https://example.com/paper",
    title: String = "Test Paper",
    author: String? = nil,
    journal: String? = nil,
    publishedYear: String? = nil,
    localFilePath: String? = nil,
    doi: String? = nil,
    publishedDOI: String? = nil
) -> StudioArticle {
    var article = StudioArticle(
        url: url,
        title: title,
        sourceType: .paper,
        localFilePath: localFilePath,
        author: author,
        journal: journal,
        publishedYear: publishedYear
    )
    article.state = .ready
    article.doi = doi
    article.publishedDOI = publishedDOI
    article.normalizedURL = URLNormalizer.normalize(url)
    return article
}

/// A paper that has not been marked ready, for tests that persist one: the store
/// refuses a ready source with no durable readable text.
private func makeQueuedPaper(
    url: String,
    title: String,
    journal: String? = nil,
    publishedYear: String? = nil,
    doi: String? = nil,
    publishedDOI: String? = nil
) -> StudioArticle {
    var article = makePaper(
        url: url,
        title: title,
        journal: journal,
        publishedYear: publishedYear,
        doi: doi,
        publishedDOI: publishedDOI
    )
    article.state = .queued
    return article
}

@Suite("normalizeDOI")
struct NormalizeDOITests {
    @Test("Lowercases DOI")
    func lowercases() {
        let result = StudioViewModel.normalizeDOI("10.1234/ABC")
        #expect(result == "10.1234/abc")
    }

    @Test("Strips version suffix")
    func stripsVersionSuffix() {
        let result = StudioViewModel.normalizeDOI("10.1101/2024.11.04.615786v12")
        #expect(result == "10.1101/2024.11.04.615786")
    }

    @Test("A v after a letter is part of the DOI, so two Oxford papers of 2015 never compare equal")
    func keepsLetterBeforeV() {
        #expect(StudioViewModel.normalizeDOI("10.1093/NAR/GKV1344") == "10.1093/nar/gkv1344")
        #expect(StudioViewModel.normalizeDOI("10.1093/nar/gkv1344") != StudioViewModel.normalizeDOI("10.1093/nar/gkv1157"))
        #expect(StudioViewModel.normalizeDOI("10.1093/bioinformatics/btv351") == "10.1093/bioinformatics/btv351")
        #expect(StudioViewModel.normalizeDOI("10.1037/rev0000453") == "10.1037/rev0000453")
    }

    @Test("A preprint server's version is dropped with the separator before it")
    func stripsPreprintServerVersions() {
        #expect(StudioViewModel.normalizeDOI("10.64898/2026.04.11.717967v1") == "10.64898/2026.04.11.717967")
        #expect(StudioViewModel.normalizeDOI("10.21203/rs.3.rs-4356493/v1") == "10.21203/rs.3.rs-4356493")
        #expect(StudioViewModel.normalizeDOI("10.20944/preprints202608.1166.v1") == "10.20944/preprints202608.1166")
        #expect(StudioViewModel.normalizeDOI(" 10.1101/2025.05.06.652103V2 ") == "10.1101/2025.05.06.652103")
        // A version that would be the whole suffix is kept.
        #expect(StudioViewModel.normalizeDOI("10.5555/v12") == "10.5555/v12")
    }
}

@Suite("normalizedPaperFilename")
struct NormalizedPaperFilenameTests {
    @Test("Strips version from filename")
    func stripsVersion() {
        let result = StudioViewModel.normalizedPaperFilename("615786v3.pdf")
        #expect(result == "615786.pdf")
    }

    @Test("No version suffix leaves filename unchanged")
    func noVersion() {
        let result = StudioViewModel.normalizedPaperFilename("paper.pdf")
        #expect(result == "paper.pdf")
    }

    @Test("A v after a letter is part of the name: two Oxford papers of 2015 get two files")
    func keepsLetterBeforeV() {
        let pfam = StudioViewModel.paperFilenameFromDOI("10.1093/nar/gkv1344")
        let ensembl = StudioViewModel.paperFilenameFromDOI("10.1093/nar/gkv1157")
        #expect(pfam == "10.1093_nar_gkv1344.pdf")
        #expect(StudioViewModel.normalizedPaperFilename(pfam) == pfam)
        #expect(StudioViewModel.normalizedPaperFilename(pfam) != StudioViewModel.normalizedPaperFilename(ensembl))
        #expect(StudioViewModel.normalizedPaperFilename("www_researchsquare_com_article_rs-10622019_v1.pdf") == "www_researchsquare_com_article_rs-10622019_.pdf")
    }
}

@Suite("direct PDF URL detection")
struct DirectPDFURLDetectionTests {
    @Test("Treats PDF URLs with query strings as direct PDFs")
    func pdfURLWithQueryString() {
        let url = "https://example.edu/downloads/paper.pdf?download=1#page=2"

        #expect(PaperService.paperPDFURL(from: url) == url)
        #expect(StudioViewModel.detectSourceType(url: url) == .paper)
    }
}

@Suite("mergePaperMetadata")
@MainActor
struct MergePaperMetadataTests {
    @Test("Fills missing paper metadata fields")
    func fillsMissingMetadata() {
        var recipient = makePaper(
            title: "Mitochondria as signaling organelles",
            author: StudioArticle.unknownPaperAuthor,
            journal: StudioArticle.unknownPaperJournal,
            publishedYear: StudioArticle.unknownPaperYear
        )
        let donor = makePaper(
            title: "Mitochondria as signaling organelles",
            author: "Chandel",
            journal: "BMC Biology",
            publishedYear: "2014",
            doi: "10.1186/1741-7007-12-34"
        )

        let changed = StudioViewModel.mergePaperMetadata(from: donor, into: &recipient)

        #expect(changed)
        #expect(recipient.author == "Chandel")
        #expect(recipient.journal == "BMC Biology")
        #expect(recipient.publishedYear == "2014")
        #expect(recipient.doi == "10.1186/1741-7007-12-34")
    }

    @Test("Does not overwrite existing paper metadata")
    func doesNotOverwriteExistingMetadata() {
        var recipient = makePaper(
            title: "Attention Is All You Need",
            author: "Vaswani et al.",
            journal: "NeurIPS",
            publishedYear: "2017",
            doi: "10.5555/old"
        )
        let donor = makePaper(
            title: "Attention Is All You Need",
            author: "Someone Else",
            journal: "Other",
            publishedYear: "2024",
            doi: "10.5555/new"
        )

        let changed = StudioViewModel.mergePaperMetadata(from: donor, into: &recipient)

        #expect(!changed)
        #expect(recipient.author == "Vaswani et al.")
        #expect(recipient.journal == "NeurIPS")
        #expect(recipient.publishedYear == "2017")
        #expect(recipient.doi == "10.5555/old")
    }

    @Test("Carries a published DOI over to a record that has none")
    func carriesPublishedDOI() {
        var recipient = makePaper(
            url: "https://www.nature.com/articles/s41586-025-09429-6",
            title: "PeptiVerse",
            author: "Zhang et al.",
            journal: "Nature",
            publishedYear: "2025"
        )
        let donor = makePaper(
            url: "https://www.biorxiv.org/content/10.1101/2025.01.02.631000v1",
            title: "PeptiVerse",
            author: "Zhang et al.",
            journal: "bioRxiv",
            publishedYear: "2025",
            publishedDOI: "10.1038/s41586-025-09429-6"
        )

        let changed = StudioViewModel.mergePaperMetadata(from: donor, into: &recipient)

        #expect(changed)
        #expect(recipient.publishedDOI == "10.1038/s41586-025-09429-6")
    }
}

@Suite("preprint recognition")
struct PreprintRecognitionTests {
    @Test("Recognizes preprint servers by URL")
    func recognizesByURL() {
        #expect(PaperService.isPreprintPaper(
            url: "https://www.biorxiv.org/content/10.1101/2025.01.02.631000v1",
            journal: nil
        ))
        #expect(PaperService.isPreprintPaper(url: "https://arxiv.org/abs/1706.03762", journal: nil))
    }

    @Test("Recognizes a preprint saved as a PDF by its recorded venue")
    func recognizesByVenue() {
        #expect(PaperService.isPreprintPaper(url: "/Papers/local-copy.pdf", journal: "medRxiv"))
    }

    @Test("A peer-reviewed record is not a preprint")
    func journalIsNotPreprint() {
        #expect(!PaperService.isPreprintPaper(
            url: "https://www.nature.com/articles/s41586-025-09429-6",
            journal: "Nature"
        ))
    }
}

@Suite("preprint and published version identity")
@MainActor
struct PreprintPublishedIdentityTests {
    @Test("A resolved published DOI links the preprint to the journal record without making them one paper")
    func publishedDOILinksButDoesNotMerge() {
        let preprint = makePaper(
            url: "https://www.biorxiv.org/content/10.1101/2025.01.02.631000v1",
            title: "PeptiVerse: a unified platform for therapeutic peptide property prediction",
            journal: "bioRxiv",
            doi: "10.1101/2025.01.02.631000",
            publishedDOI: "10.1038/S41586-025-09429-6"
        )
        let published = makePaper(
            url: "https://www.nature.com/articles/s41586-025-09429-6",
            title: "Something the journal reworded entirely",
            journal: "Nature",
            doi: "10.1038/s41586-025-09429-6"
        )

        let preprintKeys = Set(StudioViewModel.paperDedupDisplayKeys(for: preprint))
        let publishedKeys = Set(StudioViewModel.paperDedupDisplayKeys(for: published))

        #expect(!preprintKeys.contains("doi:10.1038/s41586-025-09429-6"))
        #expect(preprintKeys.isDisjoint(with: publishedKeys))
        #expect(StudioViewModel.publishedVersion(of: preprint, in: [preprint, published])?.id == published.id)
        #expect(StudioViewModel.earlierVersions(of: published, in: [preprint, published]).map(\.id) == [preprint.id])
    }

    @Test("A preprint is not grouped with its published version, even under the same title")
    func versionsAreNotDuplicates() {
        let preprint = makePaper(
            url: "https://www.biorxiv.org/content/10.1101/2025.01.02.631000v1",
            title: "PeptiVerse: a unified platform",
            journal: "bioRxiv",
            doi: "10.1101/2025.01.02.631000",
            publishedDOI: "10.1038/s41586-025-09429-6"
        )
        let published = makePaper(
            url: "https://www.nature.com/articles/s41586-025-09429-6",
            title: "PeptiVerse: a unified platform",
            journal: "Nature",
            doi: "10.1038/s41586-025-09429-6"
        )
        let unrelated = makePaper(
            url: "https://arxiv.org/abs/1706.03762",
            title: "Attention Is All You Need",
            doi: "10.48550/arxiv.1706.03762"
        )

        #expect(StudioViewModel.firstPaperIdentityDuplicateGroup(in: [preprint, published, unrelated]) == nil)
    }

    @Test("Two preprints, or two journal records, of one title are still one record")
    func sameKindStillGroups() {
        let first = makePaper(url: "https://www.biorxiv.org/content/10.1101/2025.01.02.631000v1", title: "PeptiVerse", journal: "bioRxiv")
        let second = makePaper(url: "/Papers/copy.pdf", title: "PeptiVerse", journal: "arXiv")
        let journalA = makePaper(url: "https://www.nature.com/articles/a", title: "PeptiVerse", journal: "Nature", doi: "10.1038/a")
        let journalB = makePaper(url: "https://example.org/pv", title: "PeptiVerse", journal: "Nature")

        #expect(StudioViewModel.firstPaperIdentityDuplicateGroup(in: [first, second])?.count == 2)
        #expect(StudioViewModel.firstPaperIdentityDuplicateGroup(in: [journalA, journalB])?.count == 2)
    }

    @Test("Where a paper stands among its versions")
    func versionKinds() {
        #expect(StudioViewModel.paperVersionKind(of: makePaper(url: "https://arxiv.org/abs/1706.03762")) == .preprint)
        #expect(StudioViewModel.paperVersionKind(of: makePaper(url: "/Papers/copy.pdf", journal: "medRxiv")) == .preprint)
        #expect(StudioViewModel.paperVersionKind(of: makePaper(url: "/Papers/copy.pdf", journal: "Nature", doi: "10.1101/2025.01.02.631000")) == .preprint)
        #expect(StudioViewModel.paperVersionKind(of: makePaper(
            url: "/Papers/copy.pdf", journal: "Nature", doi: "10.1101/2025.01.02.631000", publishedDOI: "10.1038/x"
        )) == .preprint)
        #expect(StudioViewModel.paperVersionKind(of: makePaper(url: "https://www.nature.com/articles/s41586-025-09429-6", journal: "Nature")) == .journal)
        #expect(StudioViewModel.paperVersionKind(of: makePaper(url: "https://example.org/x", doi: "10.1038/x")) == .journal)
        #expect(StudioViewModel.paperVersionKind(of: makePaper(url: "https://example.org/x", journal: "Cell")) == .journal)
        #expect(StudioViewModel.paperVersionKind(of: makePaper(url: "https://example.org/x")) == .unknown)
    }

    @Test("A journal version with its PDF stands in for the preprint in the lists; without one it does not")
    func supersededPreprints() {
        let preprint = makePaper(
            url: "https://www.biorxiv.org/content/10.1101/2025.01.02.631000v1",
            title: "PeptiVerse", journal: "bioRxiv",
            doi: "10.1101/2025.01.02.631000", publishedDOI: "10.1038/s41586-025-09429-6"
        )
        let published = makePaper(
            url: "https://www.nature.com/articles/s41586-025-09429-6",
            title: "A rewritten title", journal: "Nature", doi: "10.1038/s41586-025-09429-6"
        )

        #expect(StudioViewModel.supersededPreprintIDs(in: [preprint, published], hasUsablePDF: { $0.id == published.id }) == [preprint.id])
        #expect(StudioViewModel.supersededPreprintIDs(in: [preprint, published], hasUsablePDF: { $0.id == preprint.id }).isEmpty)
        #expect(StudioViewModel.supersededPreprintIDs(in: [preprint], hasUsablePDF: { _ in true }).isEmpty)
    }

    @Test("A journal's British spelling of the preprint's title still links the versions")
    func britishSpellingLinksVersions() {
        // The Evo 2 preprint and its Nature version: the preprint never learned its published DOI,
        // and Nature spells "modelling".
        let preprint = makePaper(
            url: "Papers/10.1101_2025.02.18.638918.pdf",
            title: "Genome modeling and design across all domains of life with Evo 2",
            author: "Garyk Brixi; Matthew G. Durrant; Jerome Ku; Michael Poli",
            journal: "bioRxiv", doi: "10.1101/2025.02.18.638918"
        )
        let published = makePaper(
            url: "https://www.nature.com/articles/s41586-026-10176-5",
            title: "Genome modelling and design across all domains of life with Evo 2",
            author: "Garyk Brixi; Matthew G. Durrant; Jerome Ku; Mohsen Naghipourfar",
            journal: "Nature", doi: "10.1038/s41586-026-10176-5"
        )

        #expect(StudioViewModel.publishedVersion(of: preprint, in: [preprint, published])?.id == published.id)
        #expect(StudioViewModel.supersededPreprintIDs(in: [preprint, published], hasUsablePDF: { _ in true }) == [preprint.id])
        #expect(StudioViewModel.firstPaperIdentityDuplicateGroup(in: [preprint, published]) == nil)
    }

    @Test("A lightly reworded title links the versions only under the same first author")
    func rewordedTitleNeedsTheFirstAuthor() {
        let preprint = makePaper(
            url: "https://www.biorxiv.org/content/10.1101/2025.01.02.631000v1",
            title: "PeptiVerse: a unified platform for therapeutic peptide property prediction",
            author: "Ada Lovelace; Charles Babbage",
            journal: "bioRxiv", doi: "10.1101/2025.01.02.631000"
        )
        let published = makePaper(
            url: "https://www.nature.com/articles/s41586-025-09429-6",
            title: "PeptiVerse is a unified platform for therapeutic peptide property prediction",
            author: "Lovelace, Ada; Babbage, Charles",
            journal: "Nature", doi: "10.1038/s41586-025-09429-6"
        )
        var otherAuthor = published
        otherAuthor.author = "Grace Hopper"

        #expect(StudioViewModel.publishedVersion(of: preprint, in: [preprint, published])?.id == published.id)
        #expect(StudioViewModel.supersededPreprintIDs(in: [preprint, published], hasUsablePDF: { _ in true }) == [preprint.id])
        #expect(StudioViewModel.publishedVersion(of: preprint, in: [preprint, otherAuthor]) == nil)
        #expect(StudioViewModel.supersededPreprintIDs(in: [preprint, otherAuthor], hasUsablePDF: { _ in true }).isEmpty)
    }

    @Test("A different paper by the same first author is not a version")
    func sameAuthorDifferentPaper() {
        let preprint = makePaper(
            url: "https://www.biorxiv.org/content/10.1101/2025.01.02.631000v1",
            title: "Genome modeling and design across all domains of life with Evo 2",
            author: "Garyk Brixi", journal: "bioRxiv", doi: "10.1101/2025.01.02.631000"
        )
        let other = makePaper(
            url: "https://www.nature.com/articles/s41586-099",
            title: "Protein language models design functional enzymes across domains of life",
            author: "Garyk Brixi", journal: "Nature", doi: "10.1038/s41586-099"
        )

        #expect(StudioViewModel.publishedVersion(of: preprint, in: [preprint, other]) == nil)
        #expect(StudioViewModel.supersededPreprintIDs(in: [preprint, other], hasUsablePDF: { _ in true }).isEmpty)
    }

    @Test("Spelling and punctuation fold out of a version's title key")
    func versionTitleKeyFolds() {
        #expect(StudioViewModel.paperVersionTitleKey("Modelling tumour behaviour: a catalogue.")
            == StudioViewModel.paperVersionTitleKey("Modeling tumor behavior — a catalog"))
        #expect(StudioViewModel.paperVersionTitleKey("Single-cell analysis of haemoglobin in foetal centres")
            == StudioViewModel.paperVersionTitleKey("Single cell analysis of hemoglobin in fetal centers"))
        #expect(StudioViewModel.paperVersionTitleKey("Optimisation of organised data")
            == StudioViewModel.paperVersionTitleKey("Optimization of organized data"))
        #expect(StudioViewModel.paperVersionTitleKey("Cell") != StudioViewModel.paperVersionTitleKey("Cells"))
    }

    @Test("A first author's surname, whatever the list's format")
    func firstAuthorKey() {
        #expect(StudioViewModel.paperFirstAuthorKey("Garyk Brixi; Matthew G. Durrant") == "brixi")
        #expect(StudioViewModel.paperFirstAuthorKey("Brixi, Garyk; Durrant, Matthew") == "brixi")
        #expect(StudioViewModel.paperFirstAuthorKey("Brixi GA, Durrant MG, Ku J") == "brixi")
        #expect(StudioViewModel.paperFirstAuthorKey("Christopher Ré") == "re")
        #expect(StudioViewModel.paperFirstAuthorKey("  ") == nil)
        #expect(StudioViewModel.paperFirstAuthorKey(nil) == nil)
    }

    @Test("A journal version in another library is not this preprint's")
    func versionsStayInTheirLibrary() {
        var preprint = makePaper(
            url: "https://www.biorxiv.org/content/10.1101/2025.01.02.631000v1",
            title: "PeptiVerse", journal: "bioRxiv", doi: "10.1101/2025.01.02.631000",
            publishedDOI: "10.1038/s41586-025-09429-6"
        )
        var published = makePaper(
            url: "https://www.nature.com/articles/s41586-025-09429-6",
            title: "PeptiVerse", journal: "Nature", doi: "10.1038/s41586-025-09429-6"
        )
        published.teamID = "team-1"
        preprint.teamID = nil

        #expect(StudioViewModel.publishedVersion(of: preprint, in: [preprint, published]) == nil)
        #expect(StudioViewModel.supersededPreprintIDs(in: [preprint, published], hasUsablePDF: { _ in true }).isEmpty)
    }

    @Test("Titles differing only in capitalization are one record")
    func titleCaseDifferenceIsOneRecord() {
        let lowercased = makePaper(
            url: "https://www.biorxiv.org/content/10.1101/2025.01.02.631000v1",
            title: "PeptiVerse: A unified platform for therapeutic peptide property prediction"
        )
        let titleCased = makePaper(
            url: "https://example.org/peptiverse",
            title: "PeptiVerse: A Unified Platform for Therapeutic Peptide Property Prediction"
        )

        let group = StudioViewModel.firstPaperIdentityDuplicateGroup(in: [lowercased, titleCased])

        #expect(group?.count == 2)
    }

    @Test("Distinct papers are left alone")
    func distinctPapersDoNotGroup() {
        let first = makePaper(url: "https://example.org/a", title: "Paper A", doi: "10.1/a")
        let second = makePaper(url: "https://example.org/b", title: "Paper B", doi: "10.1/b")

        #expect(StudioViewModel.firstPaperIdentityDuplicateGroup(in: [first, second]) == nil)
    }

    @Test("Two papers with different DOIs are two papers, however exactly their titles match")
    func differentDOIsNeverGroupOnTitle() {
        // A Methods Primer and its one-page PrimeView: one title, two DOIs.
        let primer = makePaper(
            url: "https://www.nature.com/articles/s43586-021-00084-5",
            title: "DNA-encoded chemical libraries", journal: "Nature Reviews Methods Primers"
        )
        let primeView = makePaper(
            url: "https://www.nature.com/articles/s43586-021-00090-7",
            title: "DNA-encoded chemical libraries", journal: "Nature Reviews Methods Primers"
        )

        #expect(!StudioViewModel.paperDedupKeysMatch(primer, primeView))
        #expect(!StudioViewModel.paperDedupKeysMatch(primeView, primer))
        #expect(StudioViewModel.firstPaperIdentityDuplicateGroup(in: [primer, primeView]) == nil)
        #expect(StudioViewModel.firstPaperIdentityMergePlan(in: [primer, primeView]) == nil)
        // The PrimeView with a PDF does not hide the Primer that has none.
        let keysWithPDF = Set(StudioViewModel.paperDedupDisplayKeys(for: primeView))
        #expect(keysWithPDF.isDisjoint(with: StudioViewModel.paperDedupLookupKeys(for: primer)))
    }

    @Test("A copy without a DOI still meets its titled twin, but never joins two DOIs together")
    func doiLessCopyJoinsOneDOI() {
        let primer = makePaper(
            url: "https://www.nature.com/articles/s43586-021-00084-5",
            title: "DNA-encoded chemical libraries", journal: "Nature Reviews Methods Primers"
        )
        let primeView = makePaper(
            url: "https://www.nature.com/articles/s43586-021-00090-7",
            title: "DNA-encoded chemical libraries", journal: "Nature Reviews Methods Primers"
        )
        let copy = makePaper(
            url: "/Papers/del-copy.pdf",
            title: "DNA-encoded chemical libraries", journal: "Nature Reviews Methods Primers"
        )

        #expect(StudioViewModel.paperDedupKeysMatch(copy, primer))
        #expect(StudioViewModel.paperDedupKeysMatch(primer, copy))
        let keysWithPDF = Set(StudioViewModel.paperDedupDisplayKeys(for: primer))
        #expect(!keysWithPDF.isDisjoint(with: StudioViewModel.paperDedupLookupKeys(for: copy)))

        let group = StudioViewModel.firstPaperIdentityDuplicateGroup(in: [copy, primer, primeView])
        #expect(group?.count == 2)
        #expect(group.map { Set($0.map(\.id)) } == Set([copy.id, primer.id]))
    }

    @Test("A published DOI equal to the paper's own DOI is not a self-match")
    func selfMatchIsNotADuplicate() {
        let paper = makePaper(
            url: "https://www.nature.com/articles/s41586-025-09429-6",
            title: "PeptiVerse",
            doi: "10.1038/s41586-025-09429-6",
            publishedDOI: "10.1038/s41586-025-09429-6"
        )
        let other = makePaper(url: "https://example.org/other", title: "Other paper", doi: "10.1/other")

        #expect(StudioViewModel.firstPaperIdentityDuplicateGroup(in: [paper, other]) == nil)
    }
}

@Suite("published DOI persistence")
struct PublishedDOIPersistenceTests {
    @Test("A locally resolved published DOI survives a reload")
    func publishedDOIRoundTrips() throws {
        let store = try KnowledgeStore(inMemory: true)
        var paper = makeQueuedPaper(
            url: "https://www.biorxiv.org/content/10.1101/2025.01.02.631000v1",
            title: "PeptiVerse",
            journal: "Nature",
            publishedYear: "2025",
            doi: "10.1101/2025.01.02.631000",
            publishedDOI: "10.1038/S41586-025-09429-6"
        )
        try store.saveSource(paper)

        let reloaded = try store.loadSources().first { $0.id == paper.id }
        #expect(reloaded?.publishedDOI == "10.1038/s41586-025-09429-6")

        // A later save that knows nothing about the published version must not
        // erase it — the resolve pass runs once, the row is saved many times.
        paper.publishedDOI = nil
        paper.publishedYear = "2026"
        try store.saveSource(paper)

        let afterBlindSave = try store.loadSources().first { $0.id == paper.id }
        #expect(afterBlindSave?.publishedDOI == "10.1038/s41586-025-09429-6")
        #expect(afterBlindSave?.publishedYear == "2026")
    }
}
