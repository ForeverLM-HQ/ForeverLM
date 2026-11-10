import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif

private let referenceLinkLogger = Logger(subsystem: "com.foreverlm", category: "PaperReferenceLinks")

/// A catalog's answer, with "no such record" told apart from "could not ask": the first is
/// settled and recorded, the second leaves the entry to be asked again.
enum ReferenceCatalogAnswer<Value: Sendable>: Sendable {
    case answered(Value)
    case unavailable(String)
}

/// The free catalogs a reference entry is matched against. Injected so a test feeds canned
/// answers and never reaches the network.
struct PaperReferenceCatalogs: Sendable {
    /// The record Crossref holds for a DOI; `.answered(nil)` when it holds none.
    var recordForDOI: @Sendable (String) async -> ReferenceCatalogAnswer<SlideCitationService.ResolvedPaper?>
    /// Crossref's best matches for a whole reference entry.
    var crossrefCandidates: @Sendable (String) async -> ReferenceCatalogAnswer<[SlideCitationService.ResolvedPaper]>
    /// OpenAlex's best matches for the entry's printed title (its search reads titles and
    /// abstracts, so a whole entry, authors and pages and all, finds nothing), asked only when
    /// Crossref held no accepted record.
    var openAlexCandidates: @Sendable (String) async -> ReferenceCatalogAnswer<[SlideCitationService.ResolvedPaper]>

    static let live = PaperReferenceCatalogs(
        recordForDOI: { await ReferenceCatalogClient.record(forDOI: $0) },
        crossrefCandidates: { await ReferenceCatalogClient.crossrefCandidates(forEntry: $0) },
        openAlexCandidates: { await ReferenceCatalogClient.openAlexCandidates(forEntry: $0) }
    )
}

/// The requests behind `PaperReferenceCatalogs.live`: Crossref and OpenAlex, both free and
/// keyless, asked politely (a contact address in the User-Agent, which both give a better rate
/// to) and one at a time through a pacer, since a library's backlog is thousands of entries.
enum ReferenceCatalogClient {
    /// Crossref's published polite pool allows far more; OpenAlex's anonymous search rate-limited
    /// every request when tried on 2026-09-28 (`LiteratureSearch`), so it is asked sparingly and
    /// a 429 from it is an unanswered question, never a "no match".
    private static let crossrefInterval: TimeInterval = 0.12
    private static let openAlexInterval: TimeInterval = 0.35
    private static let workFields = "DOI,title,container-title,short-container-title,issued,author,volume,page,article-number"

    private actor Pacer {
        private var next = Date.distantPast
        func wait(interval: TimeInterval) async {
            let now = Date()
            let start = max(now, next)
            next = start.addingTimeInterval(interval)
            let delay = start.timeIntervalSince(now)
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        }
    }
    private static let crossrefPacer = Pacer()
    private static let openAlexPacer = Pacer()

    static func record(forDOI doi: String) async -> ReferenceCatalogAnswer<SlideCitationService.ResolvedPaper?> {
        guard let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.crossref.org/works/\(encoded)") else {
            return .answered(nil)
        }
        await crossrefPacer.wait(interval: crossrefInterval)
        switch await fetch(url) {
        case .failure(let reason):
            return .unavailable(reason)
        case .success(let status, let data):
            if status == 404 { return .answered(nil) }
            guard (200...299).contains(status) else { return .unavailable("Crossref answered HTTP \(status)") }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any] else {
                return .unavailable("Crossref answered with something that is not a record")
            }
            return .answered(SlideCitationService.parseCrossrefItem(message))
        }
    }

    static func crossrefCandidates(forEntry text: String) async -> ReferenceCatalogAnswer<[SlideCitationService.ResolvedPaper]> {
        guard var components = URLComponents(string: "https://api.crossref.org/works") else { return .answered([]) }
        components.queryItems = [
            URLQueryItem(name: "query.bibliographic", value: text),
            URLQueryItem(name: "rows", value: "5"),
            URLQueryItem(name: "select", value: workFields),
        ]
        guard let url = components.url else { return .answered([]) }
        await crossrefPacer.wait(interval: crossrefInterval)
        switch await fetch(url) {
        case .failure(let reason):
            return .unavailable(reason)
        case .success(let status, let data):
            guard (200...299).contains(status) else { return .unavailable("Crossref answered HTTP \(status)") }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let items = message["items"] as? [[String: Any]] else {
                return .unavailable("Crossref answered with something that is not a search result")
            }
            return .answered(items.compactMap(SlideCitationService.parseCrossrefItem))
        }
    }

    static func openAlexCandidates(forEntry text: String) async -> ReferenceCatalogAnswer<[SlideCitationService.ResolvedPaper]> {
        guard var components = URLComponents(string: "https://api.openalex.org/works") else { return .answered([]) }
        components.queryItems = [
            URLQueryItem(name: "search", value: text),
            URLQueryItem(name: "per-page", value: "5"),
            URLQueryItem(name: "mailto", value: "support@foreverlm.com"),
        ]
        guard let url = components.url else { return .answered([]) }
        await openAlexPacer.wait(interval: openAlexInterval)
        switch await fetch(url) {
        case .failure(let reason):
            return .unavailable(reason)
        case .success(let status, let data):
            guard (200...299).contains(status) else { return .unavailable("OpenAlex answered HTTP \(status)") }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                return .unavailable("OpenAlex answered with something that is not a search result")
            }
            return .answered(results.compactMap(parseOpenAlexReferenceWork))
        }
    }

    /// An OpenAlex work as a record a reference entry can name: one with a DOI as
    /// `SlideCitationService.parseOpenAlexWork` reads it, else one PubMed indexes (an article
    /// from before DOIs, "Fed Proc" 1970), with its PubMed id and no DOI. Its venue is left out
    /// when OpenAlex names PubMed itself, a repository, as where the work is.
    static func parseOpenAlexReferenceWork(_ work: [String: Any]) -> SlideCitationService.ResolvedPaper? {
        if let record = SlideCitationService.parseOpenAlexWork(work) { return record }
        guard let title = work["title"] as? String, !title.isEmpty,
              let pmidAddress = (work["ids"] as? [String: Any])?["pmid"] as? String,
              let pmid = pmidAddress.split(separator: "/").last.map(String.init),
              !pmid.isEmpty, pmid.allSatisfy(\.isNumber) else { return nil }
        let source = (work["primary_location"] as? [String: Any])?["source"] as? [String: Any]
        let journal = (source?["type"] as? String) == "repository" ? nil : source?["display_name"] as? String
        let authors = (work["authorships"] as? [[String: Any]])?
            .compactMap { ($0["author"] as? [String: Any])?["display_name"] as? String }
            .joined(separator: "; ")
        let biblio = work["biblio"] as? [String: Any]
        return SlideCitationService.ResolvedPaper(
            doi: "",
            title: title,
            journal: journal,
            year: (work["publication_year"] as? Int).map(String.init),
            authors: PaperReferenceSummary.nonBlank(authors),
            volume: PaperReferenceSummary.nonBlank(biblio?["volume"] as? String),
            firstPage: PaperReferenceSummary.nonBlank(biblio?["first_page"] as? String),
            pubMedID: pmid
        )
    }

    private enum Fetched {
        case success(status: Int, data: Data)
        case failure(String)
    }

    private static func fetch(_ url: URL) async -> Fetched {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("ForeverLM (mailto:support@foreverlm.com)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return .success(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

/// Reads a paper's reference list, finds the link of each entry, and keeps both.
///
/// Free and deterministic apart from the catalogs: the entries come from the PDF's own text
/// (`PaperReferenceParser`), an entry's printed DOI or address is its link, and one that prints
/// none is looked up in Crossref and OpenAlex and takes a record only when the entry prints it
/// (`PaperReferenceCatalogMatch`). No model is asked, so this runs unattended at ingest without
/// spending anything of the learner's, and it never decides what an entry is by guessing.
///
/// Durable and resumable: the list is stored before any catalog is asked, each answer is stored
/// as it comes, and a catalog that does not answer leaves its entries to be asked again at the
/// next drain, up to `maximumPaperReferenceReadAttempts`. A failure never blocks reading the
/// paper: nothing here touches the source itself.
actor PaperReferenceLinkService {

    struct Outcome: Equatable, Sendable {
        /// Entries the stored list holds after the read.
        let entryCount: Int
        /// Entries that name a paper.
        let linkedCount: Int
        /// Entries a catalog did not answer for (offline, rate-limited); asked again next time.
        let unansweredCount: Int
        /// Entries read from the PDF this time, 0 when the stored list was kept as it was.
        let readCount: Int
        /// The paper has no PDF here to read.
        let hasNoFile: Bool

        var isComplete: Bool { unansweredCount == 0 }
    }

    struct DrainResult: Equatable, Sendable {
        let papersRead: Int
        let remaining: Int
    }

    typealias TextReader = @Sendable (StudioArticle) async -> String?

    /// Entries asked at once. The pacers hold the rate; this holds the load.
    static let concurrentLookups = 3

    private let storage: StorageService
    private let catalogs: PaperReferenceCatalogs
    private let readText: TextReader
    private var isDraining = false
    private static let running = RunningSources()

    init(
        storage: StorageService,
        catalogs: PaperReferenceCatalogs = .live,
        readText: @escaping TextReader = PaperReferenceLinkService.pdfText
    ) {
        self.storage = storage
        self.catalogs = catalogs
        self.readText = readText
    }

    /// One paper at a time anywhere in the process: the app's drain and an assistant's
    /// `resolve_paper_references` may name the same paper.
    private actor RunningSources {
        private var held = Set<String>()
        func begin(_ id: String) -> Bool { held.insert(id).inserted }
        func end(_ id: String) { held.remove(id) }
    }

    // MARK: One paper

    /// Reads the paper's reference list when it has none stored (or `force`), then asks the
    /// catalogs about every entry that has no answer yet. Idempotent: a paper already read and
    /// answered is returned as it stands.
    func resolve(sourceID: String, force: Bool = false) async throws -> Outcome {
        guard await Self.running.begin(sourceID) else {
            let stored = try await storage.loadPaperReferences(sourceID: sourceID)
            return Outcome(
                entryCount: stored.count, linkedCount: stored.filter(\.isLinked).count,
                unansweredCount: 0, readCount: 0, hasNoFile: false
            )
        }
        defer { Task { await Self.running.end(sourceID) } }

        guard let article = try await storage.loadSourceWithoutContent(sourceID), article.sourceType == .paper else {
            try await storage.dropPaperReferences(sourceID: sourceID)
            return Outcome(entryCount: 0, linkedCount: 0, unansweredCount: 0, readCount: 0, hasNoFile: false)
        }
        let state = try await storage.paperReferenceReadState(sourceID: sourceID)
        let pdfPath = article.localFilePath.map { StorageService.relativeSourcePath($0) }

        var readCount = 0
        let readByOlderParser = state.map {
            $0.parserVersion < PaperReferenceParser.version && ($0.authoredBy ?? "app") == "app"
        } ?? false
        if force || state == nil || state?.entryCount == 0 || readByOlderParser {
            guard let text = await readText(article) else {
                try await storage.finishPaperReferenceRead(
                    sourceID: sourceID, pdfPath: pdfPath, failure: nil, authoredBy: "app"
                )
                return Outcome(entryCount: 0, linkedCount: 0, unansweredCount: 0, readCount: 0, hasNoFile: true)
            }
            let entries = await Task.detached(priority: .utility) {
                PaperReferenceParser.entries(inPaperText: text)
            }.value
            readCount = entries.count
            let now = Date()
            try await storage.replacePaperReferenceList(
                sourceID: sourceID,
                entries: entries.map { Self.initialReference(for: $0, sourceID: sourceID, now: now) }
            )
        }

        let unanswered = try await askCatalogs(sourceID: sourceID)
        try await storage.finishPaperReferenceRead(
            sourceID: sourceID,
            pdfPath: pdfPath,
            failure: unanswered == 0 ? nil : "\(unanswered) reference(s) were not answered by a catalog",
            authoredBy: "app"
        )
        let stored = try await storage.loadPaperReferences(sourceID: sourceID)
        return Outcome(
            entryCount: stored.count,
            linkedCount: stored.filter(\.isLinked).count,
            unansweredCount: unanswered,
            readCount: readCount,
            hasNoFile: false
        )
    }

    /// Asks the catalogs about each entry still without an answer, a few at a time, storing
    /// each result as it arrives. Returns how many were not answered.
    private func askCatalogs(sourceID: String) async throws -> Int {
        let pending = try await storage.loadPaperReferences(sourceID: sourceID).filter(Self.needsCatalog)
        guard !pending.isEmpty else { return 0 }
        var unanswered = 0
        let catalogs = self.catalogs
        var index = 0
        while index < pending.count, !Task.isCancelled {
            let batch = Array(pending[index..<min(index + Self.concurrentLookups, pending.count)])
            index += batch.count
            let results = await withTaskGroup(of: (PaperReference, Bool).self) { group in
                for reference in batch {
                    group.addTask { await Self.resolved(reference, catalogs: catalogs) }
                }
                var gathered: [(PaperReference, Bool)] = []
                for await result in group { gathered.append(result) }
                return gathered
            }
            for (reference, answered) in results {
                if answered {
                    try await storage.savePaperReference(reference)
                } else {
                    unanswered += 1
                }
            }
        }
        return unanswered + max(0, pending.count - index)
    }

    // MARK: Pure steps

    /// An entry as the PDF prints it, with the identity it prints itself: no catalog asked.
    static func initialReference(for entry: PaperReferenceParser.Entry, sourceID: String, now: Date) -> PaperReference {
        var reference = PaperReference(sourceID: sourceID, ordinal: entry.ordinal, label: entry.label, text: entry.text, updatedAt: now)
        if let printed = PaperReferenceIdentity.printedLink(in: entry.text) {
            reference.url = printed.url
            reference.doi = printed.doi
            reference.origin = printed.origin
        }
        return reference
    }

    /// Whether a catalog is still owed an answer about the entry: it has none, or it has a DOI
    /// and no record of what the DOI names.
    static func needsCatalog(_ reference: PaperReference) -> Bool {
        reference.catalogCheckedAt == nil && reference.origin != .agent
    }

    /// The entry after the catalogs were asked, and whether they answered. An entry that prints a
    /// DOI keeps it and takes the record's title, authors, venue and year; one that prints
    /// nothing is matched against Crossref, then OpenAlex; one that prints another address (an
    /// arXiv id, a web page) has nothing to look up.
    static func resolved(
        _ reference: PaperReference,
        catalogs: PaperReferenceCatalogs
    ) async -> (PaperReference, Bool) {
        var reference = reference
        let now = Date()
        if let doi = reference.doi {
            switch await catalogs.recordForDOI(doi) {
            case .unavailable:
                return (reference, false)
            case .answered(let record):
                if let record { fillMetadata(of: &reference, from: record) }
                reference.catalogCheckedAt = now
                reference.updatedAt = now
                return (reference, true)
            }
        }
        if reference.url != nil {
            reference.catalogCheckedAt = now
            reference.updatedAt = now
            return (reference, true)
        }
        let search = PaperReferenceIdentity.searchText(of: reference.text)
        switch await catalogs.crossrefCandidates(search) {
        case .unavailable:
            return (reference, false)
        case .answered(let pool):
            var match = PaperReferenceCatalogMatch.accepted(entry: reference.text, among: pool)
            if match == nil, case .answered(let more) = await catalogs.openAlexCandidates(Self.openAlexSearchText(of: reference.text)) {
                match = PaperReferenceCatalogMatch.accepted(entry: reference.text, among: more)
            }
            if let match { apply(match, to: &reference) }
            reference.catalogCheckedAt = now
            reference.updatedAt = now
            return (reference, true)
        }
    }

    /// What OpenAlex is searched for: the title the entry prints, else the entry.
    static func openAlexSearchText(of entry: String) -> String {
        PaperReferenceSummary.printedTitle(in: entry) ?? PaperReferenceIdentity.searchText(of: entry)
    }

    /// A catalog record as the entry's link and description: its DOI, else its PubMed page.
    static func apply(_ record: SlideCitationService.ResolvedPaper, to reference: inout PaperReference) {
        if record.doi.isEmpty, let pmid = record.pubMedID {
            reference.doi = nil
            reference.url = PaperReferenceIdentity.url(forPubMedID: pmid)
        } else {
            let doi = record.doi.lowercased()
            reference.doi = doi
            reference.url = PaperReferenceIdentity.url(forDOI: doi)
        }
        reference.origin = .catalog
        fillMetadata(of: &reference, from: record)
    }

    static func fillMetadata(of reference: inout PaperReference, from record: SlideCitationService.ResolvedPaper) {
        reference.title = reference.title ?? record.title
        reference.authors = reference.authors ?? record.authors
        reference.journal = reference.journal ?? record.journal
        reference.year = reference.year ?? record.year
    }

    // MARK: Reading the file

    /// The paper's PDF text, every page (the list is at the end, which a page cap drops), off
    /// the main actor. Nil when the paper has no PDF on this Mac.
    static let pdfText: TextReader = { article in
        #if canImport(PDFKit)
        return await Task.detached(priority: .utility) { () -> String? in
            guard let document = article.pdfPages?.document() else { return nil }
            let text = PDFTextExtractor.embeddedText(from: document, pages: 0..<document.pageCount)
            return text.isEmpty ? nil : text
        }.value
        #else
        return nil
        #endif
    }

    // MARK: Queue

    /// Reads and links the papers owed it, newest first, until none is left, a catalog stops
    /// answering, the Mac is in Low Power Mode, or the task is cancelled. Bounded per paper and
    /// resumable: a quit loses at most the paper in hand.
    func drain() async -> DrainResult {
        guard !isDraining else { return DrainResult(papersRead: 0, remaining: await remaining()) }
        isDraining = true
        defer { isDraining = false }

        // A paper the parser of an older version read is read again by this one.
        do {
            try await storage.requeueOlderPaperReferenceReads()
        } catch {
            referenceLinkLogger.error("Could not queue empty reference reads again: \(error.localizedDescription, privacy: .public)")
        }
        var papersRead = 0
        while !Task.isCancelled {
            if ProcessInfo.processInfo.isLowPowerModeEnabled { break }
            let next: [PaperReferenceReadCandidate]
            do {
                next = try await storage.paperReferenceReadCandidates(limit: 1)
            } catch {
                referenceLinkLogger.error("Could not read the reference queue: \(error.localizedDescription, privacy: .public)")
                break
            }
            guard let candidate = next.first else { break }
            do {
                let outcome = try await resolve(sourceID: candidate.sourceID)
                papersRead += 1
                // Every question went unanswered: offline or rate-limited. Stop until the next
                // trigger rather than spend every paper's attempts at network speed.
                if outcome.unansweredCount > 0, outcome.unansweredCount == outcome.entryCount { break }
            } catch {
                referenceLinkLogger.error(
                    "Reading the references of \(candidate.sourceID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                do {
                    try await storage.finishPaperReferenceRead(
                        sourceID: candidate.sourceID, pdfPath: nil, failure: error.localizedDescription, authoredBy: "app"
                    )
                } catch {
                    referenceLinkLogger.error("Could not record the failed reference read: \(error.localizedDescription, privacy: .public)")
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        let left = await remaining()
        if papersRead > 0 {
            referenceLinkLogger.info("Read the references of \(papersRead) paper(s); \(left) remaining")
        }
        return DrainResult(papersRead: papersRead, remaining: left)
    }

    private func remaining() async -> Int {
        (try? await storage.paperReferenceReadQueueCount()) ?? 0
    }
}
