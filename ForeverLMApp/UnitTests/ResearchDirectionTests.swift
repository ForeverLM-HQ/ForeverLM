import Foundation
import Testing
@testable import ForeverLM

/// Directions (docs/directions-design.md): what the store keeps and refuses
/// from a search, how an answer is recorded, what goes with a deleted home,
/// and what a store from before schema 147 gains.
@Suite("Research direction persistence")
struct ResearchDirectionPersistenceTests {

    private func makeGoal(_ store: KnowledgeStore, title: String = "Find methods to target rare mitochondrial diseases", parentNotebookID: String? = nil) throws -> LearningGoalRecord {
        try store.createCompanionGoal(
            title: title, topic: title,
            startAt: Date(), endAt: Date().addingTimeInterval(14 * 86_400),
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [],
            parentNotebookID: parentNotebookID
        )
    }

    private func makeNotebook(_ store: KnowledgeStore, title: String = "Mitochondria") throws -> LearningGoalRecord {
        try store.createCompanionGoal(
            title: title, topic: title,
            startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
    }

    private func hypoxiaDraft(title: String = "Hypoxia or HIF activation for complex I deficiency") -> ResearchDirectionDraft {
        ResearchDirectionDraft(
            title: title,
            rationale: "Chronic hypoxia rescued Ndufs4 knockout mice, and small molecules that raise haemoglobin's oxygen affinity now reproduce it without a hypoxic chamber.",
            angle: .enabling,
            evidence: [
                DirectionEvidence(
                    citation: "Jain et al., Science 2016",
                    title: "Hypoxia as a therapy for mitochondrial disease",
                    doi: "https://doi.org/10.1126/SCIENCE.AAD9642",
                    finding: "Breathing 11% oxygen prevented the Leigh-like disease of Ndufs4 knockout mice."
                ),
                DirectionEvidence(
                    citation: "Small-molecule hypoxia therapy, Cell 2025",
                    url: "https://www.cell.com/cell/fulltext/S0092-8674(25)00185-2",
                    doi: "10.1016/j.cell.2025.02.019",
                    finding: "An oral haemoglobin oxygen-affinity modulator reproduced the rescue."
                ),
            ],
            objection: "Human dosing is unknown and hypoxia worsens some complex I lesions.",
            nextStep: "Check which PMD genotypes were rescued and which were harmed across the published models."
        )
    }

    @Test("A search's proposals are saved with the store's ids and cleaned evidence")
    func proposeSavesAndQueues() throws {
        let store = try KnowledgeStore(inMemory: true)
        let goal = try makeGoal(store)
        let result = try store.proposeResearchDirections(homeID: goal.id, drafts: [hypoxiaDraft()], chatSessionID: "chat-1")
        #expect(result.duplicates.isEmpty)
        let saved = try #require(result.saved.first)
        #expect(saved.homeKind == .goal)
        #expect(saved.homeID == goal.id)
        #expect(saved.status == .proposed)
        #expect(saved.chatSessionID == "chat-1")
        #expect(saved.evidence.count == 2)
        #expect(saved.evidence[0].doi == "10.1126/science.aad9642", "a DOI is stored bare and lowercased")
        #expect(saved.evidence[1].url == "https://www.cell.com/cell/fulltext/S0092-8674(25)00185-2")

        let loaded = try #require(try store.loadResearchDirection(saved.id))
        #expect(loaded == saved, "what was saved reads back whole")
        #expect(try store.loadResearchDirections(homeID: goal.id).map(\.id) == [saved.id])
    }

    @Test("A proposal without evidence that can be opened, or toward no home, refuses the whole call")
    func proposeRefusesAndWritesNothing() throws {
        let store = try KnowledgeStore(inMemory: true)
        let goal = try makeGoal(store)
        var uncited = hypoxiaDraft(title: "Uncited")
        uncited.evidence = []
        #expect(throws: KnowledgeStoreError.self) {
            try store.proposeResearchDirections(homeID: goal.id, drafts: [hypoxiaDraft(), uncited])
        }
        var unopenable = hypoxiaDraft(title: "Unopenable")
        unopenable.evidence = [DirectionEvidence(citation: "Someone, 2020", url: "not a web address", finding: "Something")]
        #expect(throws: KnowledgeStoreError.self) {
            try store.proposeResearchDirections(homeID: goal.id, drafts: [unopenable])
        }
        var reasonless = hypoxiaDraft(title: "Reasonless")
        reasonless.rationale = "  "
        #expect(throws: KnowledgeStoreError.self) {
            try store.proposeResearchDirections(homeID: goal.id, drafts: [reasonless])
        }
        #expect(throws: KnowledgeStoreError.self) {
            try store.proposeResearchDirections(homeID: "no-such-home", drafts: [hypoxiaDraft()])
        }
        #expect(try store.loadResearchDirections().isEmpty, "nothing is half-saved")
    }

    @Test("A proposal the home already has, reworded only in case or punctuation, is skipped and named")
    func duplicatesAreSkipped() throws {
        let store = try KnowledgeStore(inMemory: true)
        let goal = try makeGoal(store)
        let first = try store.proposeResearchDirections(homeID: goal.id, drafts: [hypoxiaDraft()])
        let answered = try #require(first.saved.first)
        _ = try store.updateResearchDirection(answered.id, change: ResearchDirectionChange(status: .setAside, verdictReason: "Already knew about it"))

        let second = try store.proposeResearchDirections(
            homeID: goal.id,
            drafts: [
                hypoxiaDraft(title: "hypoxia, or HIF activation, for complex-I deficiency!"),
                hypoxiaDraft(title: "Base editing of heteroplasmic mtDNA point mutations"),
            ]
        )
        #expect(second.duplicates == ["hypoxia, or HIF activation, for complex-I deficiency!"], "a set-aside direction is not proposed again")
        #expect(second.saved.map(\.title) == ["Base editing of heteroplasmic mtDNA point mutations"])

        let otherGoal = try makeGoal(store, title: "Another goal")
        let elsewhere = try store.proposeResearchDirections(homeID: otherGoal.id, drafts: [hypoxiaDraft()])
        #expect(elsewhere.saved.count == 1, "another home may hold the same direction")
    }

    @Test("An answer is recorded with its reason and time; going back to a proposal clears both")
    func answersAreRecorded() throws {
        let store = try KnowledgeStore(inMemory: true)
        let goal = try makeGoal(store)
        let direction = try #require(try store.proposeResearchDirections(homeID: goal.id, drafts: [hypoxiaDraft()]).saved.first)

        #expect(throws: KnowledgeStoreError.self, "a reason goes with an answer") {
            try store.updateResearchDirection(direction.id, change: ResearchDirectionChange(verdictReason: "Because"))
        }

        let pursued = try store.updateResearchDirection(direction.id, change: ResearchDirectionChange(status: .pursued, verdictReason: "  Fits the phenotyping angle  "))
        #expect(pursued.status == .pursued)
        #expect(pursued.verdictReason == "Fits the phenotyping angle")
        #expect(pursued.decidedAt != nil)

        let reworded = try store.updateResearchDirection(direction.id, change: ResearchDirectionChange(verdictReason: "It is the cheapest to test"))
        #expect(reworded.status == .pursued)
        #expect(reworded.verdictReason == "It is the cheapest to test", "a reason alone rewrites the answer's reason")

        let reopened = try store.updateResearchDirection(direction.id, change: ResearchDirectionChange(status: .proposed))
        #expect(reopened.status == .proposed)
        #expect(reopened.verdictReason == nil)
        #expect(reopened.decidedAt == nil)
    }

    @Test("Evidence a deeper look found is appended once, by DOI")
    func evidenceIsAppendedOnce() throws {
        let store = try KnowledgeStore(inMemory: true)
        let goal = try makeGoal(store)
        let direction = try #require(try store.proposeResearchDirections(homeID: goal.id, drafts: [hypoxiaDraft()]).saved.first)
        let updated = try store.updateResearchDirection(direction.id, change: ResearchDirectionChange(evidenceToAdd: [
            DirectionEvidence(citation: "Jain again", doi: "10.1126/science.aad9642", finding: "The same paper"),
            DirectionEvidence(citation: "Ast et al., Cell 2019", doi: "10.1016/j.cell.2019.07.009", finding: "Hypoxia rescues frataxin loss."),
        ]))
        #expect(updated.evidence.map(\.doi) == ["10.1126/science.aad9642", "10.1016/j.cell.2025.02.019", "10.1016/j.cell.2019.07.009"])
        #expect(updated.evidence[0].citation == "Jain et al., Science 2016", "the first occurrence is kept")
    }

    @Test("Deleting a Goal, a Notebook or an Idea deletes what was proposed toward it")
    func homesTakeTheirDirectionsWithThem() throws {
        let store = try KnowledgeStore(inMemory: true)
        let goal = try makeGoal(store)
        let idea = try store.createIdea(title: "Could spare mitochondrial mass protect against disease?")
        let notebook = try makeNotebook(store)
        let kept = try makeGoal(store, title: "A goal that stays")
        _ = try #require(try store.proposeResearchDirections(homeID: goal.id, drafts: [hypoxiaDraft()]).saved.first)
        let onIdea = try #require(try store.proposeResearchDirections(homeID: idea.id, drafts: [hypoxiaDraft()]).saved.first)
        let onNotebook = try #require(try store.proposeResearchDirections(homeID: notebook.id, drafts: [hypoxiaDraft()]).saved.first)
        let onKept = try #require(try store.proposeResearchDirections(homeID: kept.id, drafts: [hypoxiaDraft()]).saved.first)
        #expect(onNotebook.homeKind == .notebook)
        #expect(onIdea.homeKind == .idea)

        try store.deleteLearningGoal(goal.id)
        try store.deleteIdea(idea.id)
        try store.deleteLearningGoal(notebook.id)

        #expect(try store.loadResearchDirections().map(\.id) == [onKept.id])
    }

    @Test("A record from a newer build reads an unknown angle and status leniently; an unknown home fails")
    func lenientDecode() throws {
        let known = ResearchDirection(homeKind: .idea, homeID: "i", title: "T", rationale: "R")
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(known)) as? [String: Any])
        object["angle"] = "serendipity"
        object["status"] = "parked"
        let lenient = try JSONDecoder().decode(ResearchDirection.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(lenient.angle == .other)
        #expect(lenient.status == .proposed)
        object["homeKind"] = "team"
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ResearchDirection.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test("Evidence names the library source with its DOI, whether given bare or as a doi.org address")
    func evidenceFindsTheLibrarySource() throws {
        let store = try KnowledgeStore(inMemory: true)
        var paper = StudioArticle(
            url: "https://www.science.org/doi/10.1126/science.aad9642",
            title: "Hypoxia as a therapy for mitochondrial disease",
            sourceType: .paper, discoveryOrigin: .manual, id: "jain-2016"
        )
        paper.doi = "10.1126/science.aad9642"
        // Not ready: a ready paper needs the metadata attestation its
        // ingestion makes, which is not what this test is about. The DOI is
        // what the lookup reads.
        try store.saveSource(paper)
        #expect(try store.librarySourceID(for: DirectionEvidence(citation: "Jain", doi: "10.1126/SCIENCE.AAD9642", finding: "x")) == "jain-2016")
        #expect(try store.librarySourceID(for: DirectionEvidence(citation: "Jain", url: "https://doi.org/10.1126/science.aad9642", finding: "x")) == "jain-2016")
        #expect(try store.librarySourceID(for: DirectionEvidence(citation: "Other", doi: "10.1000/other", finding: "x")) == nil)
    }

}

@Suite("Research direction model")
struct ResearchDirectionModelTests {

    @Test("The duplicate key ignores case, accents, punctuation and spacing")
    func duplicateKey() {
        #expect(ResearchDirection.duplicateKey("Hypoxia, or HIF activation — for Complex I") == ResearchDirection.duplicateKey("hypoxia or hif activation for complex i"))
        #expect(ResearchDirection.duplicateKey("Pearson syndrome") != ResearchDirection.duplicateKey("Barth syndrome"))
        #expect(ResearchDirection.duplicateKey("Café au lait") == ResearchDirection.duplicateKey("cafe au lait"))
    }

    @Test("A DOI is read bare from a resolver address or a doi: label, and refused when it is not one")
    func doiNormalization() {
        #expect(DirectionEvidence.normalizedDOI("https://doi.org/10.1126/Science.AAD9642") == "10.1126/science.aad9642")
        #expect(DirectionEvidence.normalizedDOI("doi:10.1016/j.cell.2025.02.019") == "10.1016/j.cell.2025.02.019")
        #expect(DirectionEvidence.normalizedDOI("https://example.com/paper") == nil)
        #expect(DirectionEvidence.normalizedDOI("") == nil)
        #expect(DirectionEvidence(citation: "c", doi: "10.1/x", finding: "f").openURL?.absoluteString == "https://doi.org/10.1/x")
    }

    @Test("Pursued reads first, then proposals, then what was set aside")
    func listOrder() {
        let now = Date()
        let aside = ResearchDirection(homeKind: .goal, homeID: "g", title: "A", rationale: "r", status: .setAside, createdAt: now)
        let proposedOld = ResearchDirection(homeKind: .goal, homeID: "g", title: "B", rationale: "r", createdAt: now.addingTimeInterval(-10))
        let proposedNew = ResearchDirection(homeKind: .goal, homeID: "g", title: "C", rationale: "r", createdAt: now)
        let pursued = ResearchDirection(homeKind: .goal, homeID: "g", title: "D", rationale: "r", status: .pursued, createdAt: now.addingTimeInterval(-100))
        #expect([aside, proposedOld, proposedNew, pursued].sorted(by: ResearchDirection.listOrder).map(\.title) == ["D", "C", "B", "A"])
    }

    @Test("The chip says how many directions there are and how many are new")
    func chipText() {
        #expect(DirectionListing.chipText(open: 3, waiting: 2, all: 4) == "3 directions · 2 new")
        #expect(DirectionListing.chipText(open: 1, waiting: 0, all: 1) == "1 direction")
        #expect(DirectionListing.chipText(open: 0, waiting: 0, all: 2) == "2 set aside")
    }

    @Test("A direction search's steps name the home, every angle, and the tool that saves")
    func searchSteps() {
        let steps = Prompts.directionSearchSteps(homeKind: .goal, homeID: "goal-1", homeTitle: "Find methods", focus: "methods to target")
        #expect(steps.contains("home_id goal-1"))
        #expect(steps.contains("The learner asked for: methods to target"))
        for angle in DirectionAngle.allCases where angle != .other {
            #expect(steps.contains("- \(angle.rawValue):"), "\(angle.rawValue) is described")
        }
        #expect(steps.contains("propose_directions"))
        #expect(steps.contains("update_direction"))
        #expect(Prompts.directionSearchRequest(homeKind: .idea, homeID: "idea-1").contains("find_directions with that home_id"))
    }

    @Test("A Find directions request is sent at once, carries the home, and is not a Reader passage")
    func launchRequest() {
        let launch = DirectionSearchLaunch(homeKind: .goal, homeID: "goal-1", homeTitle: "Rare mitochondrial diseases", notebookID: nil)
        let request = ReaderSelectionExplanationRequest(directionSearch: launch, sourceIDs: ["s1"])
        #expect(request.sendsAtOnce)
        #expect(!request.isReaderSelection)
        #expect(request.selectedText == "Find directions for “Rare mitochondrial diseases”")
        #expect(request.contextualContent() == Prompts.directionSearchRequest(homeKind: .goal, homeID: "goal-1"))
    }
}

@Suite("Literature search")
struct LiteratureSearchTests {

    /// An `esearch` answer as PubMed gave it on 2026-09-28.
    static let recordedSearch = """
    {"header":{"type":"esearch","version":"0.3"},"esearchresult":{"count":"46","retmax":"2","retstart":"0","idlist":["39841808","26917594"],"translationset":[],"querytranslation":"x"}}
    """

    /// Two `efetch` records trimmed from PubMed's answer that day, with what
    /// a reader must not take for the record's own: a reference list whose
    /// entries carry DOIs, a translated abstract, inline markup in a title,
    /// a labelled abstract, a collective author and a MedlineDate.
    static let recordedArticles = """
    <?xml version="1.0" ?>
    <!DOCTYPE PubmedArticleSet PUBLIC "-//NLM//DTD PubMedArticle, 1st January 2025//EN" "https://dtd.nlm.nih.gov/ncbi/pubmed/out/pubmed_250101.dtd">
    <PubmedArticleSet>
    <PubmedArticle><MedlineCitation Status="MEDLINE" Owner="NLM"><PMID Version="1">26917594</PMID>
    <Article PubModel="Print-Electronic"><Journal><JournalIssue CitedMedium="Internet"><Volume>352</Volume><PubDate><Year>2016</Year><Month>Apr</Month></PubDate></JournalIssue><Title>Science (New York, N.Y.)</Title></Journal>
    <ArticleTitle>Hypoxia as a therapy for <i>mitochondrial</i> disease.</ArticleTitle>
    <Abstract><AbstractText Label="BACKGROUND">Defects in the mitochondrial respiratory chain underlie a spectrum of human conditions.</AbstractText><AbstractText Label="RESULTS">Chronic hypoxia <sup>rescued</sup> Ndufs4 knockout mice.</AbstractText></Abstract>
    <AuthorList CompleteYN="Y"><Author ValidYN="Y"><LastName>Jain</LastName><ForeName>Isha H</ForeName><Initials>IH</Initials></Author><Author ValidYN="Y"><LastName>Zazzeron</LastName><Initials>L</Initials></Author><Author ValidYN="Y"><LastName>Goli</LastName><Initials>R</Initials></Author><Author ValidYN="Y"><LastName>Mootha</LastName><Initials>VK</Initials></Author></AuthorList>
    <PublicationTypeList><PublicationType UI="D016428">Journal Article</PublicationType></PublicationTypeList></Article>
    <OtherAbstract Type="Publisher" Language="fre"><AbstractText>Une traduction qui n'est pas le résumé.</AbstractText></OtherAbstract></MedlineCitation>
    <PubmedData><ArticleIdList><ArticleId IdType="pubmed">26917594</ArticleId><ArticleId IdType="pmc">PMC4860742</ArticleId><ArticleId IdType="doi">10.1126/science.aad9642</ArticleId></ArticleIdList>
    <ReferenceList><Reference><Citation>Someone else's paper.</Citation><ArticleIdList><ArticleId IdType="doi">10.1000/not-this-one</ArticleId><ArticleId IdType="pubmed">11111111</ArticleId></ArticleIdList></Reference></ReferenceList></PubmedData></PubmedArticle>
    <PubmedArticle><MedlineCitation Status="MEDLINE" Owner="NLM"><PMID Version="1">39841808</PMID>
    <Article PubModel="Print"><Journal><JournalIssue CitedMedium="Internet"><PubDate><MedlineDate>2025 Jan-Feb</MedlineDate></PubDate></JournalIssue><Title>Science translational medicine</Title></Journal>
    <ArticleTitle>Hypoxia as a medicine.</ArticleTitle>
    <AuthorList CompleteYN="Y"><Author ValidYN="Y"><CollectiveName>Mitochondrial Medicine Consortium</CollectiveName></Author></AuthorList>
    <PublicationTypeList><PublicationType UI="D016428">Journal Article</PublicationType><PublicationType UI="D016454">Review</PublicationType></PublicationTypeList></Article></MedlineCitation>
    <PubmedData><ArticleIdList><ArticleId IdType="pubmed">39841808</ArticleId><ArticleId IdType="doi">10.1126/scitranslmed.adr4049</ArticleId></ArticleIdList></PubmedData></PubmedArticle>
    </PubmedArticleSet>
    """

    @Test("A recorded PubMed record reads into a work with its own ids, labelled abstract and authors")
    func parsesRecordedArticles() throws {
        let works = try LiteratureSearch.parseArticles(Data(Self.recordedArticles.utf8))
        #expect(works.count == 2)
        let jain = works[0]
        #expect(jain.pmid == "26917594")
        #expect(jain.title == "Hypoxia as a therapy for mitochondrial disease.", "inline markup joins the title")
        #expect(jain.doi == "10.1126/science.aad9642", "the record's DOI, not a reference's")
        #expect(jain.pmcid == "PMC4860742")
        #expect(jain.isFreeFullText)
        #expect(jain.journal == "Science (New York, N.Y.)")
        #expect(jain.year == 2016)
        #expect(jain.authors == "Jain IH, Zazzeron L, Goli R, et al.")
        #expect(jain.abstract == "Background: Defects in the mitochondrial respiratory chain underlie a spectrum of human conditions. Results: Chronic hypoxia rescued Ndufs4 knockout mice.", "the translation is not the abstract")
        #expect(!jain.isReview)
        #expect(jain.url == "https://doi.org/10.1126/science.aad9642")
        let review = works[1]
        #expect(review.year == 2025, "a MedlineDate gives its year")
        #expect(review.authors == "Mitochondrial Medicine Consortium")
        #expect(review.isReview)
        #expect(review.abstract == nil)
        #expect(!review.isFreeFullText)
    }

    @Test("A recorded esearch answer gives the count and the ranked ids")
    func parsesRecordedSearch() throws {
        let found = try LiteratureSearch.parseSearch(Data(Self.recordedSearch.utf8))
        #expect(found.count == 46)
        #expect(found.ids == ["39841808", "26917594"])
        #expect(throws: LiteratureSearch.SearchError.self) {
            try LiteratureSearch.parseSearch(Data(#"{"esearchresult":{"ERROR":"Invalid query"}}"#.utf8))
        }
    }

    @Test("The request encodes every character a server could misread, narrows by year and preprints, and caps the page")
    func buildsRequests() throws {
        let request = try LiteratureSearch.searchRequest(query: "\"mitochondrial disease\"[tiab] AND NAD+[tiab]", fromYear: 2020, preprintsOnly: true, sort: .newest, limit: 99)
        let url = try #require(request.url?.absoluteString)
        #expect(url.hasPrefix("https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?"))
        #expect(url.contains("NAD%2B%5Btiab%5D"), "a + is sent as %2B, not read as a space")
        let components = try #require(URLComponents(string: url))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["term"] == "(\"mitochondrial disease\"[tiab] AND NAD+[tiab]) AND preprint[pt]")
        #expect(items["sort"] == "pub_date")
        #expect(items["retmax"] == "25")
        #expect(items["mindate"] == "2020")
        #expect(items["datetype"] == "pdat")
        #expect(items["tool"] == "ForeverLM")
        #expect(LiteratureSearch.fetchRequest(pmids: ["1", "2"]).url?.absoluteString.contains("id=1%2C2") == true)
        #expect(throws: LiteratureSearch.SearchError.self) {
            try LiteratureSearch.searchRequest(query: "   ")
        }
    }

    @Test("A search PubMed never answers says so, not a raw network error")
    func unansweredSearchSaysSo() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimingOutURLProtocol.self]
        let session = URLSession(configuration: configuration)
        do {
            _ = try await LiteratureSearch.search(query: "hypoxia", session: session)
            Issue.record("a search nobody answered returned results")
        } catch let error as LiteratureSearch.SearchError {
            #expect(error == .unreachable("no answer within 30 seconds"))
            #expect(error.localizedDescription.contains("Nothing was searched"))
        }
    }

    @Test("An answer that is not a search result is an error, not an empty list")
    func unreadableIsAnError() {
        #expect(throws: LiteratureSearch.SearchError.self) {
            try LiteratureSearch.parseSearch(Data("<html>busy</html>".utf8))
        }
        #expect(throws: LiteratureSearch.SearchError.self) {
            try LiteratureSearch.parseArticles(Data("not xml <".utf8))
        }
    }
}

/// Answers every request as a timeout, the way a PubMed search that runs past
/// `LiteratureSearch.timeout` ends.
private final class TimingOutURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }
    override func stopLoading() {}
}
