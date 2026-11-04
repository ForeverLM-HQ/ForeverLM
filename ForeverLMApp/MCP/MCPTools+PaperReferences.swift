#if os(macOS)
import Foundation
import PDFKit

// MARK: - A paper's reference list over MCP (schema 174)
//
// Every paper's reference list is read from its PDF and linked when the paper is added
// (`PaperReferenceLinkService`): each entry with the DOI or address it names, from what it
// prints or from a Crossref or OpenAlex record that agrees with it. These three tools give an
// assistant the same reach. `resolve_paper_references` runs that free read on a paper that was
// added before it existed, or once more after a catalog was down; `get_paper_references` shows
// what is stored and what is still missing; `save_paper_references` stores entries the
// assistant authored itself from its own reading and lookups, so the learner's OpenRouter
// account never pays for a paper's list ("The agent does the work": nothing here calls a model).

extension MCPToolRegistry {
    static var paperReferenceToolDefs: [MCPToolDef] {
        [
            MCPToolDef(
                name: "get_paper_references",
                description: "Read a paper's stored reference list: each entry's number (the citation number in the paper's text; an author-year list is numbered in the order it prints), its label, the entry as the paper prints it, the paper it names (doi, url, and title, authors, journal and year when a catalog gave them), how the link was found (link_origin: printed_doi, printed_url, catalog, agent or none), and library_source_id when the learner's library already holds that paper (read fresh, so it stays right when sources come and go). The list is read from the paper's PDF and linked when the paper is added, with no model; counts tell how much is linked and unlinked_numbers lists the entries that name no paper yet. Pass include_reference_text to also get the reference list's raw text as the PDF prints it (up to 60,000 characters, from the last bibliography heading), which is the only way to read a paper's references through ForeverLM: get_source_content leaves bibliography entries out. Pass only_unlinked to list just the entries without a link. Use resolve_paper_references to read or link a paper that has not been, and save_paper_references to store entries you authored. Read-only.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Paper source ID from list_sources."],
                        "include_reference_text": ["type": "boolean", "description": "Also return the PDF's reference-list text (reference_text), for a paper whose entries were not read or were read wrongly. Defaults to false."],
                        "only_unlinked": ["type": "boolean", "description": "List only the entries that name no paper yet. Defaults to false."],
                    ],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "resolve_paper_references",
                description: "Read a paper's reference list from its PDF and find the link of each entry, free and with no model: an entry's printed DOI or address is its link, and one that prints none is matched against Crossref and OpenAlex and takes a record only when the entry prints that record's title (or its volume and first page beside the author) and the year agrees. This is what runs by itself when a paper is added; call it for a paper added before that existed, or to ask the catalogs again after they were down. A paper already read and answered is returned as it stands; pass force to read its PDF again (entries a catalog already answered keep their answer, and entries you saved with save_paper_references are never replaced). Makes web requests to Crossref and OpenAlex, so a long list takes a minute or more. Returns the counts and what was left unanswered; get_paper_references shows the entries. Needs the paper's PDF on the learner's Mac.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Paper source ID from list_sources."],
                        "force": ["type": "boolean", "description": "Read the PDF's reference list again even when one is stored. Defaults to false."],
                    ],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "save_paper_references",
                description: "Save reference entries you authored for a paper, so its citations open the papers they name: read the paper's reference list (get_paper_references with include_reference_text), find each entry's DOI or web address yourself (the entry's own text, Crossref, OpenAlex, Semantic Scholar or the publisher's page), and save them here. This spends none of the learner's AI budget: you do the lookups and the learner's account pays for nothing. Each reference has number (the citation number in the paper's text, from 1) and, for an entry not stored yet, its text as the paper prints it. Give doi (bare 10.… or a doi.org address) and/or url (an http or https address of the paper's page or PDF) only when you read it in the entry or opened the page yourself, never one recalled from memory: a wrong link is read as a fact. A doi without a url gets its doi.org address. title, authors, journal, year and label are optional. An entry already stored keeps whatever you leave out. With replace the paper's whole stored list is replaced by the references you pass (each then needs text), for a list the app read wrongly. Entries are saved in one step or not at all, and an invalid doi or address refuses the call and names it. Returns the counts as stored.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Paper source ID from list_sources."],
                        "references": [
                            "type": "array",
                            "description": "The entries to save, at most 600 a call.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "number": ["type": "integer", "minimum": 1, "description": "The entry's citation number in the paper's text."],
                                    "text": ["type": "string", "description": "The entry as the paper prints it. Required for an entry not stored yet."],
                                    "label": ["type": "string", "description": "What a citation calls the entry; defaults to the number (\"12\"), or \"Smith 2019\" for an author-year list."],
                                    "doi": ["type": "string", "description": "The paper's DOI, bare or as a doi.org address."],
                                    "url": ["type": "string", "description": "An http or https address of the paper's page or PDF, when it has no DOI."],
                                    "title": ["type": "string", "description": "The cited paper's title."],
                                    "authors": ["type": "string", "description": "Its authors, as one line."],
                                    "journal": ["type": "string", "description": "Where it was published."],
                                    "year": ["type": "string", "description": "Its year."],
                                ],
                                "required": ["number"],
                            ] as [String: Any],
                        ] as [String: Any],
                        "replace": ["type": "boolean", "description": "Replace the paper's whole stored list with these references. Defaults to false."],
                    ],
                    "required": ["source_id", "references"],
                ]
            ),
        ]
    }

    static let paperReferenceToolNames: Set<String> = [
        "get_paper_references", "resolve_paper_references", "save_paper_references",
    ]
}

extension MCPDataStore {

    /// The most references one `save_paper_references` call takes.
    static let maximumSavedPaperReferences = 600
    /// The most reference-list text `get_paper_references` returns.
    static let maximumReferenceTextCharacters = 60_000

    func executePaperReferenceTool(name: String, arguments: [String: Any]) async throws -> String? {
        switch name {
        case "get_paper_references":
            return try getPaperReferences(
                sourceID: arguments["source_id"] as? String ?? "",
                includeReferenceText: arguments["include_reference_text"] as? Bool ?? false,
                onlyUnlinked: arguments["only_unlinked"] as? Bool ?? false
            )
        case "resolve_paper_references":
            return try await resolvePaperReferences(
                sourceID: arguments["source_id"] as? String ?? "",
                force: arguments["force"] as? Bool ?? false
            )
        case "save_paper_references":
            return try savePaperReferences(
                sourceID: arguments["source_id"] as? String ?? "",
                rawReferences: arguments["references"] as? [[String: Any]],
                replace: arguments["replace"] as? Bool ?? false
            )
        default:
            return nil
        }
    }

    private func requirePaper(_ rawSourceID: String) throws -> (store: KnowledgeStore, article: StudioArticle) {
        let sourceID = rawSourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceID.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        let store = try knowledgeStore()
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID). Use list_sources to see valid IDs.")
        }
        guard article.sourceType == .paper else {
            throw MCPError.invalidInput(
                "A reference list belongs to a paper; '\(article.title)' is a \(article.sourceType.rawValue) source."
            )
        }
        return (store, article)
    }

    // MARK: get_paper_references

    private func getPaperReferences(sourceID rawSourceID: String, includeReferenceText: Bool, onlyUnlinked: Bool) throws -> String {
        let (store, article) = try requirePaper(rawSourceID)
        let references = try store.loadPaperReferences(sourceID: article.id)
        let state = try store.paperReferenceReadState(sourceID: article.id)
        let linked = references.filter(\.isLinked)

        var payload: [String: Any] = [
            "source_id": article.id,
            "source_title": article.title,
            "read_state": state.map { $0.state == .read ? "read" : "queued" } ?? "never",
            "entry_count": references.count,
            "linked_count": linked.count,
            "unlinked_numbers": references.filter { !$0.isLinked }.map(\.ordinal),
            "references": references
                .filter { !onlyUnlinked || !$0.isLinked }
                .map { paperReferencePayload($0, libraryID: libraryID(for: $0, in: store)) },
        ]
        if let state {
            if let error = cleanedOptional(state.lastError) { payload["last_error"] = error }
            if let readAt = state.readAt { payload["read_at"] = ISO8601DateFormatter().string(from: readAt) }
            if let author = state.authoredBy { payload["authored_by"] = author }
        }
        if includeReferenceText {
            if let text = Self.referenceListText(of: article) {
                payload["reference_text"] = text
            } else {
                payload["reference_text_message"] = "This paper has no PDF on this Mac to read the reference list from."
            }
        }
        if references.isEmpty {
            payload["message"] = state?.state == .read
                ? "No entries could be read from this paper's PDF (a scanned paper, or a layout the reader does not take). Read its reference list with include_reference_text and save the entries with save_paper_references."
                : "This paper's references have not been read yet. resolve_paper_references reads and links them with no model."
        } else if linked.count < references.count {
            payload["message"] = "\(references.count - linked.count) entr\(references.count - linked.count == 1 ? "y names" : "ies name") no paper yet. If they should, find each one's DOI or address and save them with save_paper_references."
        }
        return try jsonString(payload)
    }

    /// One stored entry, in the shape a follow-up `save_paper_references` call keys on: the
    /// same `number`.
    private func paperReferencePayload(_ reference: PaperReference, libraryID: String?) -> [String: Any] {
        var entry: [String: Any] = [
            "number": reference.ordinal,
            "label": reference.label,
            "text": reference.text,
            "link_origin": reference.origin.rawValue,
            "catalog_checked": reference.catalogCheckedAt != nil,
        ]
        if let doi = cleanedOptional(reference.doi) { entry["doi"] = doi }
        if let url = cleanedOptional(reference.url) { entry["url"] = url }
        if let title = cleanedOptional(reference.title) { entry["title"] = title }
        if let authors = cleanedOptional(reference.authors) { entry["authors"] = authors }
        if let journal = cleanedOptional(reference.journal) { entry["journal"] = journal }
        if let year = cleanedOptional(reference.year) { entry["year"] = year }
        if let libraryID { entry["library_source_id"] = libraryID }
        return entry
    }

    private func libraryID(for reference: PaperReference, in store: KnowledgeStore) -> String? {
        guard let url = reference.url else { return nil }
        return store.activeSourceID(forReferenceURL: url)
    }

    /// The reference-list text of the paper's PDF: from the last bibliography heading, or the
    /// whole text when there is none, held to `maximumReferenceTextCharacters`.
    static func referenceListText(of article: StudioArticle) -> String? {
        guard let document = article.pdfPages?.document() else { return nil }
        let text = PDFTextExtractor.embeddedText(from: document, pages: 0..<document.pageCount)
        guard !text.isEmpty else { return nil }
        let section = SlideCitationService.referenceSection(of: text)
            .replacingOccurrences(of: "\u{000C}", with: "\n")
        return section.count > maximumReferenceTextCharacters
            ? String(section.prefix(maximumReferenceTextCharacters))
            : section
    }

    // MARK: resolve_paper_references

    private func resolvePaperReferences(sourceID rawSourceID: String, force: Bool) async throws -> String {
        // Resolved through the storage actor, never the cached connection: the catalog
        // requests take minutes and the tool is off the store gate for them.
        let sourceID = rawSourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceID.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        guard let article = try await notebookFileStorage.loadSourceWithoutContent(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID). Use list_sources to see valid IDs.")
        }
        guard article.sourceType == .paper else {
            throw MCPError.invalidInput(
                "A reference list belongs to a paper; '\(article.title)' is a \(article.sourceType.rawValue) source."
            )
        }
        let service = PaperReferenceLinkService(storage: notebookFileStorage)
        let outcome = try await service.resolve(sourceID: article.id, force: force)
        NotificationCenter.default.post(name: .paperReferencesDidChange, object: article.id)
        var payload: [String: Any] = [
            "source_id": article.id,
            "source_title": article.title,
            "entry_count": outcome.entryCount,
            "linked_count": outcome.linkedCount,
            "unlinked_count": outcome.entryCount - outcome.linkedCount,
            "read_from_pdf": outcome.readCount,
            "unanswered_count": outcome.unansweredCount,
            "complete": outcome.isComplete,
        ]
        if outcome.hasNoFile {
            payload["message"] = "This paper has no PDF on this Mac, so there is no reference list to read."
        } else if outcome.entryCount == 0 {
            payload["message"] = "No entries could be read from this paper's PDF (a scanned paper, or a layout the reader does not take). Read its reference list with get_paper_references (include_reference_text) and save the entries with save_paper_references."
        } else if outcome.unansweredCount > 0 {
            payload["message"] = "\(outcome.unansweredCount) entr\(outcome.unansweredCount == 1 ? "y was" : "ies were") not answered by a catalog (offline or rate-limited). Call again to ask them again."
        } else if outcome.linkedCount < outcome.entryCount {
            payload["message"] = "\(outcome.entryCount - outcome.linkedCount) entr\(outcome.entryCount - outcome.linkedCount == 1 ? "y names" : "ies name") no paper that a catalog vouches for. get_paper_references (only_unlinked) lists them; save_paper_references stores links you find."
        }
        return try jsonString(payload)
    }

    // MARK: save_paper_references

    /// One validated entry of a save, before it is merged with what is stored.
    private struct AuthoredReference {
        let number: Int
        let text: String?
        let label: String?
        let doi: String?
        let url: String?
        let title: String?
        let authors: String?
        let journal: String?
        let year: String?
    }

    private func savePaperReferences(
        sourceID rawSourceID: String,
        rawReferences: [[String: Any]]?,
        replace: Bool
    ) throws -> String {
        let (store, article) = try requirePaper(rawSourceID)
        guard let rawReferences, !rawReferences.isEmpty else {
            throw MCPError.invalidInput("references is required: pass at least one entry with its number.")
        }
        guard rawReferences.count <= Self.maximumSavedPaperReferences else {
            throw MCPError.invalidInput("At most \(Self.maximumSavedPaperReferences) references can be saved in one call.")
        }

        var authored: [AuthoredReference] = []
        var seen = Set<Int>()
        var problems: [String] = []
        for (index, raw) in rawReferences.enumerated() {
            let position = "references[\(index)]"
            guard let number = (raw["number"] as? NSNumber)?.intValue, number >= 1,
                  (raw["number"] as? NSNumber)?.doubleValue == Double(number) else {
                problems.append("\(position): number must be an integer from 1.")
                continue
            }
            guard seen.insert(number).inserted else {
                problems.append("\(position): number \(number) appears twice.")
                continue
            }
            var doi: String?
            if let rawDOI = cleanedOptional(raw["doi"] as? String) {
                guard let normalized = PaperReferenceIdentity.normalizedDOI(rawDOI) else {
                    problems.append("\(position) (number \(number)): '\(rawDOI)' is not a DOI.")
                    continue
                }
                doi = normalized
            }
            var url: String?
            if let rawURL = cleanedOptional(raw["url"] as? String) {
                guard let parsed = URL(string: rawURL), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                      parsed.host != nil else {
                    problems.append("\(position) (number \(number)): '\(rawURL)' is not an http or https address.")
                    continue
                }
                url = rawURL
            }
            authored.append(AuthoredReference(
                number: number,
                text: cleanedOptional(raw["text"] as? String).map { String($0.prefix(PaperReferenceParser.maximumEntryLength)) },
                label: cleanedOptional(raw["label"] as? String),
                doi: doi,
                url: url,
                title: cleanedOptional(raw["title"] as? String),
                authors: cleanedOptional(raw["authors"] as? String),
                journal: cleanedOptional(raw["journal"] as? String),
                year: cleanedOptional(raw["year"] as? String)
            ))
        }

        let stored = Dictionary(
            uniqueKeysWithValues: try store.loadPaperReferences(sourceID: article.id).map { ($0.ordinal, $0) }
        )
        let now = Date()
        var merged: [PaperReference] = []
        for entry in authored {
            let existing = replace ? nil : stored[entry.number]
            guard let text = entry.text ?? existing?.text else {
                problems.append("number \(entry.number): text is required for an entry that is not stored yet.")
                continue
            }
            var reference = existing ?? PaperReference(
                sourceID: article.id, ordinal: entry.number, label: String(entry.number), text: text
            )
            reference.text = text
            if let label = entry.label { reference.label = label }
            reference.title = entry.title ?? reference.title
            reference.authors = entry.authors ?? reference.authors
            reference.journal = entry.journal ?? reference.journal
            reference.year = entry.year ?? reference.year
            if entry.doi != nil || entry.url != nil {
                reference.doi = entry.doi ?? reference.doi
                reference.url = entry.url ?? entry.doi.map(PaperReferenceIdentity.url(forDOI:)) ?? reference.url
                reference.origin = .agent
                // The assistant looked it up: no catalog is asked again about this entry.
                reference.catalogCheckedAt = now
            }
            reference.updatedAt = now
            merged.append(reference)
        }
        guard problems.isEmpty else {
            throw MCPError.invalidInput("Nothing was saved. " + problems.joined(separator: " "))
        }

        try store.savePaperReferencesAuthoredByAgent(sourceID: article.id, references: merged, replacing: replace)
        NotificationCenter.default.post(name: .paperReferencesDidChange, object: article.id)
        let all = try store.loadPaperReferences(sourceID: article.id)
        return try jsonString([
            "source_id": article.id,
            "source_title": article.title,
            "saved": merged.count,
            "replaced_list": replace,
            "entry_count": all.count,
            "linked_count": all.filter(\.isLinked).count,
            "unlinked_numbers": all.filter { !$0.isLinked }.map(\.ordinal),
        ] as [String: Any])
    }
}
#endif
