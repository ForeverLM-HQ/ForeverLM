import Foundation

/// A search of the scholarly record for a chat that is looking for research
/// directions (docs/directions-design.md), with no model call and no cost.
///
/// PubMed through NCBI's E-utilities: `esearch` finds the records, `efetch`
/// returns each one whole — title, authors, journal, year, abstract, DOI, its
/// PubMed Central copy, and whether it is a review or a preprint. Both are
/// free and keyless, and answered in about half a second when measured.
/// Two other services were tried and dropped:
/// OpenAlex answered every anonymous search with 429 ("Anonymous search is
/// temporarily rate-limited"), and Europe PMC took 12 to 40 seconds a query,
/// so the first live direction search had all three of its calls run past a
/// 60-second limit. A failure is thrown, never softened into an empty list:
/// "found nothing" and "could not search" must read differently.
enum LiteratureSearch {

    enum Sort: String, CaseIterable, Sendable {
        case relevance
        case newest

        /// esearch's `sort` value.
        var pubMedValue: String {
            switch self {
            case .relevance: return "relevance"
            case .newest: return "pub_date"
            }
        }
    }

    struct Work: Equatable, Sendable {
        var title: String
        var authors: String?
        var journal: String?
        var year: Int?
        var doi: String?
        var pmid: String
        var pmcid: String?
        var isPreprint: Bool
        var isReview: Bool
        var abstract: String?

        /// The address a reader opens: the DOI's resolver when there is a
        /// DOI, otherwise the record's PubMed page.
        var url: String {
            if let doi { return "https://doi.org/\(doi)" }
            return "https://pubmed.ncbi.nlm.nih.gov/\(pmid)/"
        }

        /// A copy in PubMed Central is free to read in full.
        var isFreeFullText: Bool { pmcid != nil }
    }

    struct Result: Equatable, Sendable {
        var query: String
        var hitCount: Int
        var works: [Work]
    }

    enum SearchError: LocalizedError, Equatable {
        case emptyQuery
        case badStatus(Int, String)
        case unreadableResponse
        /// No answer at all: a timeout, no connection.
        case unreachable(String)

        var errorDescription: String? {
            switch self {
            case .emptyQuery:
                return "Pass a query to search the literature."
            case .badStatus(let status, let body):
                return "PubMed answered HTTP \(status)\(body.isEmpty ? "" : ": \(body)"). Nothing was searched; try again shortly or search the web instead."
            case .unreadableResponse:
                return "PubMed answered with something that is not a search result. Nothing was searched."
            case .unreachable(let reason):
                return "PubMed did not answer (\(reason)). Nothing was searched; try again shortly or search the web instead."
            }
        }
    }

    static let maximumResults = 25
    static let abstractLimit = 1_500
    static let timeout: TimeInterval = 30
    private static let eutils = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"

    // MARK: Requests

    /// The `esearch` request for one search. `fromYear`/`toYear` narrow by
    /// publication year; `preprintsOnly` keeps preprints.
    static func searchRequest(
        query rawQuery: String,
        fromYear: Int? = nil,
        toYear: Int? = nil,
        preprintsOnly: Bool = false,
        sort: Sort = .relevance,
        limit: Int = 10
    ) throws -> URLRequest {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SearchError.emptyQuery }
        let term = preprintsOnly ? "(\(trimmed)) AND preprint[pt]" : trimmed
        var items: [(String, String)] = [
            ("db", "pubmed"),
            ("retmode", "json"),
            ("retmax", String(min(max(limit, 1), maximumResults))),
            ("sort", sort.pubMedValue),
            ("term", term),
        ]
        if fromYear != nil || toYear != nil {
            let thisYear = Calendar(identifier: .gregorian).component(.year, from: Date())
            items.append(("datetype", "pdat"))
            items.append(("mindate", String(fromYear ?? 1800)))
            items.append(("maxdate", String(toYear ?? thisYear + 1)))
        }
        return request("\(eutils)/esearch.fcgi", items)
    }

    /// The `efetch` request for the records a search named.
    static func fetchRequest(pmids: [String]) -> URLRequest {
        request("\(eutils)/efetch.fcgi", [
            ("db", "pubmed"),
            ("retmode", "xml"),
            ("id", pmids.joined(separator: ",")),
        ])
    }

    /// Every value is percent-encoded by hand: URLComponents leaves `+` as it
    /// is, which a server reads as a space, so "NAD+" was searched as "NAD".
    private static func request(_ base: String, _ items: [(String, String)]) -> URLRequest {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = items + [("tool", "ForeverLM"), ("email", "support@foreverlm.com")]
        let query = pairs
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }
            .joined(separator: "&")
        var request = URLRequest(url: URL(string: "\(base)?\(query)")!)
        request.timeoutInterval = timeout
        return request
    }

    // MARK: Search

    static func search(
        query: String,
        fromYear: Int? = nil,
        toYear: Int? = nil,
        preprintsOnly: Bool = false,
        sort: Sort = .relevance,
        limit: Int = 10,
        session: URLSession = .shared
    ) async throws -> Result {
        let found = try parseSearch(try await send(
            try searchRequest(query: query, fromYear: fromYear, toYear: toYear, preprintsOnly: preprintsOnly, sort: sort, limit: limit),
            session: session
        ))
        guard !found.ids.isEmpty else { return Result(query: query, hitCount: found.count, works: []) }
        let works = try parseArticles(try await send(fetchRequest(pmids: found.ids), session: session))
        // efetch returns records in its own order; the search's ranking is kept.
        let byID = Dictionary(works.map { ($0.pmid, $0) }, uniquingKeysWith: { first, _ in first })
        return Result(query: query, hitCount: found.count, works: found.ids.compactMap { byID[$0] })
    }

    private static func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        await pacer.wait()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw SearchError.unreachable(error.code == .timedOut
                ? "no answer within \(Int(timeout)) seconds"
                : error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let body = String(data: data.prefix(300), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SearchError.badStatus(status, body)
        }
        return data
    }

    /// NCBI allows three requests a second without a key. A chat that runs
    /// three searches at once sends six, so each request starts at least
    /// 0.35 s after the one before.
    private actor Pacer {
        private var next = Date.distantPast
        func wait() async {
            let now = Date()
            let start = max(now, next)
            next = start.addingTimeInterval(0.35)
            let delay = start.timeIntervalSince(now)
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        }
    }
    private static let pacer = Pacer()

    // MARK: Parsing

    /// Reads an `esearch` JSON answer: how many records match, and the ids of
    /// the page asked for, in the order the search ranked them.
    static func parseSearch(_ data: Data) throws -> (count: Int, ids: [String]) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["esearchresult"] as? [String: Any] else {
            throw SearchError.unreadableResponse
        }
        if let message = result["ERROR"] as? String {
            throw SearchError.badStatus(200, message)
        }
        let count = Int(result["count"] as? String ?? "") ?? 0
        let ids = (result["idlist"] as? [String]) ?? []
        return (count, ids)
    }

    /// Reads an `efetch` XML answer into works. Pure, so it can be tested
    /// against a recorded answer.
    static func parseArticles(_ data: Data) throws -> [Work] {
        let reader = PubMedArticleReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { throw SearchError.unreadableResponse }
        return reader.works
    }

    /// Runs of space fold; the XML reader hands inline markup (`<i>`,
    /// `<sup>`) over as separate runs of text.
    static func cleanedText(_ raw: String) -> String {
        raw.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// An `XMLParser` delegate over a PubMed `efetch` answer. It reads a record's
/// own fields only: the reference list at the end of a record names every
/// cited paper's ids under the same element names, and a translated abstract
/// (`OtherAbstract`) is not the record's abstract.
private final class PubMedArticleReader: NSObject, XMLParserDelegate {
    private(set) var works: [LiteratureSearch.Work] = []
    private var stack: [String] = []

    private enum Field {
        case title, abstract, journal, year, medlineDate, lastName, initials, collectiveName, articleID, publicationType
    }
    private var field: Field?

    private var title = ""
    private var abstractParts: [String] = []
    private var abstractPart = ""
    private var abstractLabel: String?
    private var journal = ""
    private var yearText = ""
    private var medlineDate = ""
    private var authors: [String] = []
    private var lastName = ""
    private var initials = ""
    private var collectiveName = ""
    private var ids: [String: String] = [:]
    private var idType: String?
    private var idValue = ""
    private var publicationTypes: [String] = []
    private var publicationType = ""

    private func path(endsWith suffix: [String]) -> Bool {
        stack.count >= suffix.count && Array(stack.suffix(suffix.count)) == suffix
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        stack.append(name)
        // Inside a field already (inline markup in a title or abstract): the
        // text still belongs to that field.
        guard field == nil else { return }
        if name == "PubmedArticle" {
            title = ""; abstractParts = []; journal = ""; yearText = ""; medlineDate = ""
            authors = []; ids = [:]; publicationTypes = []
            return
        }
        guard stack.contains("PubmedArticle"), !stack.contains("ReferenceList") else { return }
        switch name {
        case "ArticleTitle" where path(endsWith: ["Article", "ArticleTitle"]):
            field = .title
        case "AbstractText" where path(endsWith: ["Article", "Abstract", "AbstractText"]):
            field = .abstract
            abstractPart = ""
            abstractLabel = attributes["Label"]
        case "Title" where path(endsWith: ["Article", "Journal", "Title"]):
            field = .journal
        case "Year" where path(endsWith: ["Journal", "JournalIssue", "PubDate", "Year"]):
            field = .year
        case "MedlineDate" where path(endsWith: ["Journal", "JournalIssue", "PubDate", "MedlineDate"]):
            field = .medlineDate
        case "Author" where path(endsWith: ["Article", "AuthorList", "Author"]):
            lastName = ""; initials = ""; collectiveName = ""
        case "LastName" where path(endsWith: ["AuthorList", "Author", "LastName"]):
            field = .lastName
        case "Initials" where path(endsWith: ["AuthorList", "Author", "Initials"]):
            field = .initials
        case "CollectiveName" where path(endsWith: ["AuthorList", "Author", "CollectiveName"]):
            field = .collectiveName
        case "ArticleId" where path(endsWith: ["PubmedArticle", "PubmedData", "ArticleIdList", "ArticleId"]):
            field = .articleID
            idType = attributes["IdType"]
            idValue = ""
        case "PublicationType" where path(endsWith: ["Article", "PublicationTypeList", "PublicationType"]):
            field = .publicationType
            publicationType = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch field {
        case .title: title += string
        case .abstract: abstractPart += string
        case .journal: journal += string
        case .year: yearText += string
        case .medlineDate: medlineDate += string
        case .lastName: lastName += string
        case .initials: initials += string
        case .collectiveName: collectiveName += string
        case .articleID: idValue += string
        case .publicationType: publicationType += string
        case nil: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { stack.removeLast() }
        // Only the element that opened the field closes it.
        if let open = field, name == Self.element(for: open), closesField(open) {
            switch open {
            case .abstract:
                let text = LiteratureSearch.cleanedText(abstractPart)
                if !text.isEmpty {
                    abstractParts.append(abstractLabel.map { "\($0.capitalized): \(text)" } ?? text)
                }
            case .articleID:
                let value = idValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if let idType, !value.isEmpty, ids[idType] == nil { ids[idType] = value }
            case .publicationType:
                let value = LiteratureSearch.cleanedText(publicationType)
                if !value.isEmpty { publicationTypes.append(value) }
            default:
                break
            }
            field = nil
            return
        }
        guard field == nil else { return }
        if name == "Author", path(endsWith: ["Article", "AuthorList", "Author"]), !stack.contains("ReferenceList") {
            let last = LiteratureSearch.cleanedText(lastName)
            let collective = LiteratureSearch.cleanedText(collectiveName)
            if !last.isEmpty {
                authors.append([last, LiteratureSearch.cleanedText(initials)].filter { !$0.isEmpty }.joined(separator: " "))
            } else if !collective.isEmpty {
                authors.append(collective)
            }
        } else if name == "PubmedArticle" {
            finishArticle()
        }
    }

    /// A field's own element is the one on top of the stack when it closes;
    /// an inline tag of the same name deeper inside does not end it.
    private func closesField(_ open: Field) -> Bool {
        let fieldDepth = stack.lastIndex(of: Self.element(for: open)) ?? -1
        return fieldDepth == stack.count - 1
    }

    private static func element(for field: Field) -> String {
        switch field {
        case .title: return "ArticleTitle"
        case .abstract: return "AbstractText"
        case .journal: return "Title"
        case .year: return "Year"
        case .medlineDate: return "MedlineDate"
        case .lastName: return "LastName"
        case .initials: return "Initials"
        case .collectiveName: return "CollectiveName"
        case .articleID: return "ArticleId"
        case .publicationType: return "PublicationType"
        }
    }

    private func finishArticle() {
        let cleanTitle = LiteratureSearch.cleanedText(title)
        guard let pmid = ids["pubmed"], !cleanTitle.isEmpty else { return }
        let publicationYear = Int(yearText.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? Int(medlineDate.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4))
        let authorLine: String? = authors.isEmpty
            ? nil
            : authors.count > 3 ? authors.prefix(3).joined(separator: ", ") + ", et al." : authors.joined(separator: ", ")
        var abstract = abstractParts.joined(separator: " ")
        if abstract.count > LiteratureSearch.abstractLimit {
            abstract = String(abstract.prefix(LiteratureSearch.abstractLimit)) + "…"
        }
        let types = Set(publicationTypes.map { $0.lowercased() })
        let journalName = LiteratureSearch.cleanedText(journal)
        works.append(LiteratureSearch.Work(
            title: cleanTitle,
            authors: authorLine,
            journal: journalName.isEmpty ? nil : journalName,
            year: publicationYear,
            doi: DirectionEvidence.normalizedDOI(ids["doi"]),
            pmid: pmid,
            pmcid: ids["pmc"],
            isPreprint: types.contains("preprint"),
            isReview: types.contains("review") || types.contains("systematic review"),
            abstract: abstract.isEmpty ? nil : abstract
        ))
    }
}
