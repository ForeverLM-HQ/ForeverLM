// MCPDataStoreTests: add_source, delete_source, update_source, paywalled imports, Notebook discovery and semantic search.

import Testing
import AppKit
import Foundation
import PDFKit
import SQLite3
@testable import ForeverLM

#if os(macOS)

extension MCPDataStoreTests {
    // MARK: - add_source

    @Test("addSource rejects paper bypasses that cannot run the mandatory LLM gate")
    func addSourceRejectsPaperBypass() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        #expect(throws: MCPError.self) {
            _ = try store.addSource(
                url: "https://example.com/paper.pdf",
                title: "Test Paper",
                sourceType: "paper",
                content: "This is the full text of the paper.",
                parentGroup: nil,
                author: "John Doe"
            )
        }
        let list = try store.listSources()
        #expect(!list.contains("Test Paper"))
    }

    @Test("addSource creates a course source with parent_group")
    func addSourceToCourse() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        // add_source takes a local path only inside the library, Desktop, Documents,
        // Downloads or a temporary folder, so the file names the test's own folder.
        let result = try store.addSource(
            url: tmpPath + "/lecture.pdf",
            title: "Lecture 1 - Intro",
            sourceType: "course",
            content: "Lecture notes content.",
            parentGroup: "ML 101",
            author: nil
        )

        #expect(result.contains("course: ML 101"))
    }

    @Test("addSource refuses a course source with no course to belong to")
    func addSourceRejectsCourselessCourseSource() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        // The Courses tab lists courses, so course material outside one would be
        // a library row nothing can show. Ask for the course instead of adding it.
        #expect(throws: MCPError.self) {
            _ = try store.addSource(
                url: tmpPath + "/handout.pdf",
                title: "Handout",
                sourceType: "course",
                content: "Handout content.",
                parentGroup: nil,
                author: nil
            )
        }
        #expect(throws: MCPError.self) {
            _ = try store.addSource(
                url: tmpPath + "/handout.pdf",
                title: "Handout",
                sourceType: "course",
                content: "Handout content.",
                parentGroup: "   ",
                author: nil
            )
        }
        #expect(!(try store.listSources()).contains("Handout"))
    }

    @Test("addSource without content sets state to queued")
    func addSourceWithoutContent() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        _ = try store.addSource(
            url: "https://example.com/article",
            title: "Queued Article",
            sourceType: "article",
            content: nil,
            parentGroup: nil,
            author: nil
        )

        // Just verify it was added
        let list = try store.listSources()
        #expect(list.contains("Queued Article"))
    }

    @Test("listSources groups book chapters under book headings")
    func listSourcesGroupsBookChapters() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "chapter-2",
            title: "2) Entropy and Time",
            content: "Chapter two content",
            sourceType: "book"
        )
        try insertSource(
            dbPath: dbPath,
            id: "chapter-1",
            title: "1) Energy Flow",
            content: "Chapter one content",
            sourceType: "book"
        )
        try insertSource(
            dbPath: dbPath,
            id: "paper-1",
            title: "Related Paper",
            content: "Paper content",
            sourceType: "paper"
        )
        try execSQL(dbPath: dbPath, """
            INSERT INTO books (id, title) VALUES ('book-power', 'Power, Sex, Suicide');
            INSERT INTO group_members (source_id, group_id, sort_index)
            VALUES ('chapter-2', 'book-power', 2), ('chapter-1', 'book-power', 1);
        """)

        let list = try store.listSources()

        #expect(list.contains("Books (1):"))
        #expect(list.contains("- [book] Power, Sex, Suicide (book_id: book-power, chapters: 2"))
        #expect(list.contains("  - [chapter] 1) Energy Flow (id: chapter-1"))
        #expect(list.contains("  - [chapter] 2) Entropy and Time (id: chapter-2"))
        #expect(list.contains("Other sources (1):"))
        #expect(list.contains("- [paper] Related Paper"))

        let firstChapterIndex = list.range(of: "1) Energy Flow")?.lowerBound
        let secondChapterIndex = list.range(of: "2) Entropy and Time")?.lowerBound
        #expect(firstChapterIndex != nil)
        #expect(secondChapterIndex != nil)
        #expect(firstChapterIndex! < secondChapterIndex!)
    }

    // MARK: - delete_source

    @Test("deleteSource removes source and content")
    func deleteSource() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        let result = try store.addSource(
            url: "https://example.com/to-delete",
            title: "Delete Me",
            sourceType: "article",
            content: "Some content",
            parentGroup: nil,
            author: nil
        )
        // Extract ID from result
        let id = result.components(separatedBy: "id: ").last?.components(separatedBy: ",").first ?? ""
        #expect(!id.isEmpty)

        let deleteResult = try store.deleteSource(id)
        #expect(deleteResult.contains("Deleted source 'Delete Me'"))

        let list = try store.listSources()
        #expect(!list.contains("Delete Me"))
    }

    @Test("deleteSource of an unknown ID is an error, so the call reports isError")
    func deleteSourceNotFound() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        #expect(throws: MCPError.self) { try store.deleteSource("nonexistent-id") }
        // Before, the not-found text came back as a success and posted a data reload.
        let outcome = await MCPToolRegistry(store: store).callToolDetailed(
            name: "delete_source",
            arguments: ["source_id": "nonexistent-id"]
        )
        #expect(outcome.isError)
        #expect(outcome.text == "Error: Source not found: nonexistent-id")
    }

    // MARK: - update_source

    @Test("updateSource changes title and author")
    func updateSourceMetadata() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        let paper = StudioArticle(
            url: "https://example.com/update-me",
            title: "Old Title",
            sourceType: .paper,
            author: "Old Author"
        )
        try store.knowledgeStore().saveSource(paper)
        let id = paper.id

        let result = try store.updateSource(
            sourceID: id,
            title: "New Title",
            author: "New Author",
            parentGroup: nil,
            content: nil
        )
        #expect(result.contains("Updated source"))

        let list = try store.listSources()
        #expect(list.contains("New Title"))
        #expect(list.contains("New Author"))
    }

    @Test("updateSource with content sets state to ready")
    func updateSourceWithContent() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        let addResult = try store.addSource(
            url: "https://example.com/needs-content",
            title: "Needs Content",
            sourceType: "manual",
            content: nil,
            parentGroup: nil,
            author: nil
        )
        let id = addResult.components(separatedBy: "id: ").last?.components(separatedBy: ",").first ?? ""

        _ = try store.updateSource(
            sourceID: id,
            title: nil,
            author: nil,
            parentGroup: nil,
            content: "Now has content with several words in it."
        )

        let detail = try store.getSourceContent(id)
        #expect(detail.contains("Now has content"))
    }

    @Test("getSourceContent resolves the unique source prefixes returned in citations")
    func getSourceContentResolvesUniquePrefix() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        let addResult = try store.addSource(
            url: "https://example.com/prefix-readable",
            title: "Readable by title",
            sourceType: "manual",
            content: "Canonical paper content.",
            parentGroup: nil,
            author: nil
        )
        let id = addResult.components(separatedBy: "id: ").last?.components(separatedBy: ",").first ?? ""
        #expect(id.count >= 8)

        let detail = try store.getSourceContent(String(id.prefix(8)))

        #expect(detail.contains("Readable by title"))
        #expect(detail.contains("Canonical paper content"))
    }

    @Test("MCP saves a pre-generated review guide against an exact source revision")
    func savesPreGeneratedSourceReviewGuide() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let content = "Canonical source text about a causal mechanism and its main limitation."
        try insertSource(
            dbPath: dbPath,
            id: "review-guide-source",
            title: "Review Guide Source",
            content: content
        )

        let expectedSHA256 = PaperContentPreparationService.sha256(content)
        let detail = try store.getSourceContent("review-guide-source")
        #expect(detail.contains("content_sha256: \(expectedSHA256)"))

        let result = try store.saveSourceReviewGuide(
            sourceID: "review-guide-source",
            expectedContentSHA256: expectedSHA256,
            guide: """
            KEY IDEAS
            1. The causal mechanism.

            REVIEW QUESTIONS AND ANSWER GUIDES
            - Question: How does the mechanism work?
            - Strong answer: The source links the cause to the effect.
            - Probe: What limitation constrains that claim?

            CONNECTION QUESTION
            How does the limitation change the causal interpretation?
            """
        )

        #expect(result.contains("Saved Source Review Guide"))
        let saved = try #require(try store.knowledgeStore().loadSourceReviewGuide("review-guide-source"))
        #expect(saved.sourceSHA256 == expectedSHA256)
        #expect(saved.generatorVersion == SourceReviewGuide.currentVersion)
        #expect(saved.guide.contains("Strong answer"))
    }

    @Test("MCP rejects a pre-generated review guide after source content changes")
    func rejectsStalePreGeneratedSourceReviewGuide() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(
            dbPath: dbPath,
            id: "stale-review-guide-source",
            title: "Changing Source",
            content: "Original canonical text."
        )

        let staleSHA256 = PaperContentPreparationService.sha256("Original canonical text.")
        try execSQL(
            dbPath: dbPath,
            "UPDATE source_content SET content = 'Updated canonical text.' WHERE source_id = 'stale-review-guide-source'"
        )

        #expect(throws: MCPError.self) {
            _ = try store.saveSourceReviewGuide(
                sourceID: "stale-review-guide-source",
                expectedContentSHA256: staleSHA256,
                guide: "KEY IDEAS\n1. Stale guide"
            )
        }
        #expect(try store.knowledgeStore().loadSourceReviewGuide("stale-review-guide-source") == nil)
    }

    @Test("updateSource of an unknown ID is an error")
    func updateSourceNotFound() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        #expect(throws: MCPError.self) {
            try store.updateSource(
                sourceID: "nonexistent",
                title: "X",
                author: nil,
                parentGroup: nil,
                content: nil
            )
        }
    }

    @Test("updateSource with no fields returns no-op message")
    func updateSourceNoFields() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        let addResult = try store.addSource(
            url: "https://example.com/no-change",
            title: "No Change",
            sourceType: "article",
            content: nil,
            parentGroup: nil,
            author: nil
        )
        let id = addResult.components(separatedBy: "id: ").last?.components(separatedBy: ",").first ?? ""

        let result = try store.updateSource(
            sourceID: id,
            title: nil,
            author: nil,
            parentGroup: nil,
            content: nil
        )
        #expect(result.contains("No fields to update"))
    }

    @Test("source action tools update paywall, hidden, and context state")
    func sourceActionToolsUpdateSourceState() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        let paper = StudioArticle(
            url: "https://example.com/action-paper",
            title: "Action Paper",
            sourceType: .paper
        )
        try store.knowledgeStore().saveSource(paper)
        let id = paper.id

        let actions = try store.listSourceActions(id)
        #expect(actions.contains("set_source_paywall_status"))
        #expect(!actions.contains("set_source_context_membership"))

        _ = try store.setSourcePaywallStatus(sourceID: id, isPaywalled: true)
        #expect(try scalarInt(dbPath: dbPath, "SELECT is_paywalled FROM papers WHERE source_id = '\(id)'") == 1)
        let paywallActions = try store.listSourceActions(id)
        #expect(paywallActions.contains("recheck_paywalled_papers"))
        #expect(MCPToolRegistry.shared.tools.contains { $0.name == "recheck_paywalled_papers" })
        #expect(MCPToolRegistry.annotations(for: "recheck_paywalled_papers")["openWorldHint"] as? Bool == true)

        _ = try store.setSourceHidden(sourceID: id, hidden: true)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM hidden_sources WHERE source_id = '\(id)'") == 1)

        #expect(!MCPToolRegistry.shared.tools.contains { $0.name == "set_source_context_membership" })
    }

    @Test("paywall recheck is a no-op when the catalog has no eligible papers")
    func paywallRecheckNoEligiblePapers() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        let ordinaryPaper = StudioArticle(
            url: "https://example.com/ordinary-paper",
            title: "Ordinary Paper",
            sourceType: .paper
        )
        try store.knowledgeStore().saveSource(ordinaryPaper)

        let result = try await store.recheckPaywalledPapers(sourceIDs: nil, limit: nil)

        #expect(result == "No paywalled papers need rechecking.")
        let saved = try #require(try store.knowledgeStore().loadSourceForSync(ordinaryPaper.id))
        #expect(!saved.hasPaywallMarker)
    }

    /// 2026-11-27: "how many paywalled Nature articles are there now, would a
    /// monthly subscription be worth it" had no tool to ask; filter_sources
    /// knows nothing of the mark. The list counts by journal, matches a link
    /// whose journal was never read, and keeps a source with no year apart.
    @Test("list_paywalled_sources counts by journal, matches the link, and lists a yearless source apart")
    func listPaywalledSourcesByJournalAndYear() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        func paper(_ url: String, _ title: String, journal: String?, year: String?, doi: String?, paywalled: Bool = true) throws -> String {
            let source = StudioArticle(url: url, title: title, sourceType: .paper)
            try store.knowledgeStore().saveSource(source)
            let sets = [journal.map { "journal = '\($0)'" }, year.map { "published_year = '\($0)'" }, doi.map { "doi = '\($0)'" }]
                .compactMap { $0 }
            if !sets.isEmpty {
                try execSQL(dbPath: dbPath, "UPDATE papers SET \(sets.joined(separator: ", ")) WHERE source_id = '\(source.id)'")
            }
            if paywalled { _ = try store.setSourcePaywallStatus(sourceID: source.id, isPaywalled: true) }
            return source.id
        }
        _ = try paper("https://doi.org/10.1038/nature04779", "Drosophila pink1", journal: "Nature", year: "2006", doi: "10.1038/nature04779")
        let recent = try paper("https://doi.org/10.1038/s41586-019-1405-y", "Intestinal infection", journal: "Nature", year: "2019", doi: "10.1038/s41586-019-1405-y")
        _ = try paper("https://doi.org/10.1038/ng.95", "DNA deletions", journal: "nature genetics", year: "2008", doi: nil)
        let unread = try paper("https://www.nature.com/articles/s43587-026-01105-2", "The case for space", journal: nil, year: nil, doi: nil)
        let cell = try paper("https://www.cell.com/cell/fulltext/x", "A Cell paper", journal: "Cell", year: "2020", doi: nil)
        let open = try paper("https://www.nature.com/articles/s41467-020-1", "An open paper", journal: "Nature Communications", year: "2020", doi: nil, paywalled: false)

        let all = try store.listPaywalledSources(journal: nil, publishedFromYear: nil, includeArchived: false)
        #expect(all.hasPrefix("5 paywalled sources. Archived sources are left out."))
        #expect(all.contains(cell) && !all.contains(open))

        let nature = try store.listPaywalledSources(journal: "nature", publishedFromYear: nil, includeArchived: false)
        #expect(nature.hasPrefix("4 paywalled sources where the journal or link contains 'nature'."))
        #expect(nature.contains("By journal: Nature 2, journal not recorded (nature.com) 1, nature genetics 1."))
        #expect(nature.contains(unread) && !nature.contains(cell))
        #expect(nature.contains("doi 10.1038/s41586-019-1405-y"))

        let lines = try store.listPaywalledSources(journal: "Nature", publishedFromYear: 2017, includeArchived: false)
            .components(separatedBy: "\n")
        #expect(lines.count == 6)
        #expect(lines[0] == "1 paywalled source where the journal or link contains 'Nature', published 2017 or later. Archived sources are left out.")
        #expect(lines[1] == "2 more published before 2017 are left out.")
        #expect(lines[2] == "By journal: Nature 1.")
        #expect(lines[3].contains(recent) && lines[3].contains("2019"))
        #expect(lines[4] == "Year not recorded (1), so not known to be 2017 or later:")
        #expect(lines[5].contains(unread) && lines[5].contains("https://www.nature.com/articles/s43587-026-01105-2"))

        try execSQL(dbPath: dbPath, "UPDATE sources SET status = 'archived' WHERE id = '\(cell)'")
        let active = try store.listPaywalledSources(journal: "Cell", publishedFromYear: nil, includeArchived: false)
        #expect(active == "No source marked paywalled where the journal or link contains 'Cell'. Archived sources are left out.")
        let archived = try store.listPaywalledSources(journal: "Cell", publishedFromYear: nil, includeArchived: true)
        #expect(archived.hasPrefix("1 paywalled source where the journal or link contains 'Cell'."))
        #expect(archived.contains("archived)"))

        #expect(MCPToolRegistry.isReadOnlyTool("list_paywalled_sources"))
        #expect(MCPToolRegistry.screenRecordNarrowedToolNames.contains("list_paywalled_sources"))
    }

    @Test("paper download failures are classified as paywall evidence or transient")
    func paperPaywallEvidenceClassification() {
        // Paywall-shaped failures: the bulk download pass auto-marks these paywalled.
        #expect(MCPDataStore.paperPaywallEvidence(for: SourceError.accessDenied) != nil)
        #expect(MCPDataStore.paperPaywallEvidence(for: SourceError.httpError(401)) != nil)
        #expect(MCPDataStore.paperPaywallEvidence(for: SourceError.httpError(402)) != nil)
        #expect(MCPDataStore.paperPaywallEvidence(for: SourceError.fetchFailed) != nil)
        let unavailable = PaperPDFUnavailableError(sourceURL: "https://doi.org/10.1000/xyz")
        #expect(MCPDataStore.paperPaywallEvidence(for: unavailable)?.contains("10.1000/xyz") == true)

        // Transient or unrelated failures: left in the needs-attention pool.
        #expect(MCPDataStore.paperPaywallEvidence(for: SourceError.httpError(404)) == nil)
        #expect(MCPDataStore.paperPaywallEvidence(for: SourceError.httpError(500)) == nil)
        #expect(MCPDataStore.paperPaywallEvidence(for: SourceError.pdfReadFailed) == nil)
        #expect(MCPDataStore.paperPaywallEvidence(for: URLError(.timedOut)) == nil)
        #expect(MCPDataStore.paperPaywallEvidence(for: MCPError.invalidInput("Downloaded file is not a readable PDF")) == nil)
    }

    @Test("A paywalled URL import keeps the paper as a paywalled row with its bibliography")
    func paywalledURLImportSavesPaywalledPaper() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        let sourceURL = "https://doi.org/10.1126/science.1077780"
        let page = PaperService.PaperPageMetadata(
            title: "Rates of behavior and aging specified by mitochondrial function during development",
            authorsDisplay: "Andrew Dillin et al.",
            journal: "Science",
            year: "2002",
            doi: "10.1126/science.1077780",
            pdfURL: nil
        )
        let result = try #require(try store.savePaywalledPaperImport(
            sourceURL: sourceURL,
            normalizedURL: URLNormalizer.normalize(sourceURL),
            titleOverride: nil,
            pageMetadata: page,
            scholarlyMetadata: nil,
            doi: "10.1126/science.1077780",
            evidence: "publisher denied access (HTTP 403)",
            connectorLabel: nil
        ))
        #expect(result.hasPrefix("Added paper 'Rates of behavior and aging"))
        #expect(result.contains("marked it paywalled: publisher denied access (HTTP 403)"))
        #expect(result.contains("attach_pdf_to_paper"))
        #expect(result.contains("recheck_paywalled_papers"))

        let id = try sourceID(in: store, url: sourceURL)
        let saved = try #require(try store.knowledgeStore().loadSourceForSync(id))
        #expect(saved.sourceType == .paper)
        #expect(saved.hasPaywallMarker)
        #expect(saved.isPaywalled)
        #expect(saved.statusFlag == .paywall)
        #expect(saved.state == .error)
        #expect(saved.resolvedPDFPath == nil)
        #expect(saved.author == "Andrew Dillin et al.")
        #expect(saved.journal == "Science")
        #expect(saved.publishedYear == "2002")
        #expect(saved.doi == "10.1126/science.1077780")
        #expect(saved.discoveryOrigin == .manual)

        // The saved row is the one every recovery path works from.
        #expect(try store.listSourceActions(id).contains("recheck_paywalled_papers"))
        #expect(try store.existingPaperByDOI("10.1126/science.1077780")?.id == id)
    }

    /// https://doi.org/10.1016/j.cmet.2022.02.001 on 2026-09-18: the DOI resolves
    /// to linkinghub.elsevier.com, whose interstitial is titled "Redirecting" and
    /// carries no citation meta, the PDF is behind the paywall, and Crossref has
    /// the whole record. The paper was saved as "Redirecting" — author, journal,
    /// year and DOI all right, title the interstitial's. The Crossref title is
    /// the paper's whenever there is one; the page's stands in only without it,
    /// and an interstitial's never does.
    @Test("A paywalled Elsevier DOI import takes the Crossref title, not the interstitial's")
    func paywalledElsevierImportPrefersCrossrefTitleOverRedirecting() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        let sourceURL = "https://doi.org/10.1016/j.cmet.2022.02.001"
        let doi = "10.1016/j.cmet.2022.02.001"
        let crossrefTitle = "The NADPARK study: A randomized phase I trial of nicotinamide riboside supplementation in Parkinson's disease"
        // What the page-metadata fetch used to hand back for the interstitial:
        // a title and nothing else.
        let interstitial = PaperService.PaperPageMetadata(
            title: "Redirecting", authorsDisplay: nil, journal: nil, year: nil, doi: nil, pdfURL: nil
        )
        let crossref = PaperService.CrossrefMetadata(
            authorsDisplay: "Brage Brakedal et al.",
            journal: "Cell Metabolism",
            year: "2022",
            title: crossrefTitle,
            doi: doi
        )

        let result = try #require(try store.savePaywalledPaperImport(
            sourceURL: sourceURL,
            normalizedURL: URLNormalizer.normalize(sourceURL),
            titleOverride: nil,
            pageMetadata: interstitial,
            scholarlyMetadata: crossref,
            doi: doi,
            evidence: "publisher served a web page instead of the PDF",
            connectorLabel: nil
        ))
        #expect(result.hasPrefix("Added paper '\(crossrefTitle)'"))

        let id = try sourceID(in: store, url: sourceURL)
        let saved = try #require(try store.knowledgeStore().loadSourceForSync(id))
        #expect(saved.title == crossrefTitle)
        #expect(saved.isPaywalled)
        #expect(saved.author == "Brage Brakedal et al.")
        #expect(saved.journal == "Cell Metabolism")
        #expect(saved.publishedYear == "2022")
        #expect(saved.doi == doi)
    }

    @Test("A paywalled import with a Crossref record takes its title over the page's")
    func paywalledImportPrefersCrossrefTitleWheneverPresent() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        // The page-metadata fetch now yields nothing for a redirect page, so
        // the DOI record is the only title there is.
        let redirectOnly = "https://doi.org/10.1016/j.neuron.2026.04.048"
        let neuronTitle = "A neuron paper the interstitial never named"
        let neuron = try #require(try store.savePaywalledPaperImport(
            sourceURL: redirectOnly,
            normalizedURL: URLNormalizer.normalize(redirectOnly),
            titleOverride: nil,
            pageMetadata: nil,
            scholarlyMetadata: PaperService.CrossrefMetadata(
                authorsDisplay: "A. Author et al.", journal: "Neuron", year: "2026",
                title: neuronTitle, doi: "10.1016/j.neuron.2026.04.048"
            ),
            doi: "10.1016/j.neuron.2026.04.048",
            evidence: "no open-access PDF found for \(redirectOnly) (direct link, PMC, and Unpaywall all came up empty)",
            connectorLabel: nil
        ))
        #expect(neuron.hasPrefix("Added paper '\(neuronTitle)'"))

        // A landing page that does name the paper still yields to the DOI
        // record's title when there is one…
        let both = "https://doi.org/10.1016/j.bbabio.2024.149193"
        let page = PaperService.PaperPageMetadata(
            title: "BBA Bioenergetics article page title", authorsDisplay: nil, journal: nil, year: nil, doi: nil, pdfURL: nil
        )
        let bothSaved = try #require(try store.savePaywalledPaperImport(
            sourceURL: both,
            normalizedURL: URLNormalizer.normalize(both),
            titleOverride: nil,
            pageMetadata: page,
            scholarlyMetadata: PaperService.CrossrefMetadata(
                authorsDisplay: nil, journal: nil, year: nil,
                title: "Mitochondrial supercomplexes in bioenergetics", doi: "10.1016/j.bbabio.2024.149193"
            ),
            doi: "10.1016/j.bbabio.2024.149193",
            evidence: "publisher denied access (HTTP 403)",
            connectorLabel: nil
        ))
        #expect(bothSaved.hasPrefix("Added paper 'Mitochondrial supercomplexes in bioenergetics'"))

        // …and stands in when the record has no title of its own.
        let pageOnly = "https://doi.org/10.1016/j.neubiorev.2024.105971"
        let pageOnlySaved = try #require(try store.savePaywalledPaperImport(
            sourceURL: pageOnly,
            normalizedURL: URLNormalizer.normalize(pageOnly),
            titleOverride: nil,
            pageMetadata: PaperService.PaperPageMetadata(
                title: "A review the landing page named", authorsDisplay: nil, journal: nil, year: nil, doi: nil, pdfURL: nil
            ),
            scholarlyMetadata: PaperService.CrossrefMetadata(
                authorsDisplay: "B. Author", journal: "Neuroscience & Biobehavioral Reviews", year: "2024",
                title: nil, doi: "10.1016/j.neubiorev.2024.105971"
            ),
            doi: "10.1016/j.neubiorev.2024.105971",
            evidence: "publisher denied access (HTTP 403)",
            connectorLabel: nil
        ))
        #expect(pageOnlySaved.hasPrefix("Added paper 'A review the landing page named'"))
    }

    @Test("An interstitial title with no Crossref record falls back to the URL, not 'Redirecting'")
    func paywalledImportNeverKeepsInterstitialTitle() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        let sourceURL = "https://doi.org/10.1016/j.cmet.2022.02.001"
        let result = try #require(try store.savePaywalledPaperImport(
            sourceURL: sourceURL,
            normalizedURL: URLNormalizer.normalize(sourceURL),
            titleOverride: nil,
            pageMetadata: PaperService.PaperPageMetadata(
                title: "Redirecting", authorsDisplay: nil, journal: nil, year: nil, doi: nil, pdfURL: nil
            ),
            scholarlyMetadata: nil,
            doi: "10.1016/j.cmet.2022.02.001",
            evidence: "publisher served a web page instead of the PDF",
            connectorLabel: nil
        ))
        #expect(!result.contains("'Redirecting'"))
        let id = try sourceID(in: store, url: sourceURL)
        let saved = try #require(try store.knowledgeStore().loadSourceForSync(id))
        #expect(saved.title != "Redirecting")
        #expect(!saved.title.isEmpty)

        #expect(store.titleNeedsReplacement("Redirecting", sourceURL: sourceURL))
        #expect(store.titleNeedsReplacement("linkinghub.elsevier.com", sourceURL: "https://linkinghub.elsevier.com/retrieve/pii/S1550413122000456"))
        #expect(!store.titleNeedsReplacement("Redirecting T cells against cancer", sourceURL: sourceURL))
        #expect(store.usablePageTitle("Redirecting", sourceURL: sourceURL) == nil)
        #expect(store.usablePageTitle("  A real title ", sourceURL: sourceURL) == "A real title")
    }

    @Test("A paywall-shaped failure with no paper identity adds nothing")
    func paywalledURLImportWithoutIdentitySavesNothing() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        let sourceURL = "https://example.com/some/page"
        let result = try store.savePaywalledPaperImport(
            sourceURL: sourceURL,
            normalizedURL: URLNormalizer.normalize(sourceURL),
            titleOverride: nil,
            pageMetadata: nil,
            scholarlyMetadata: nil,
            doi: nil,
            evidence: "publisher served a web page instead of the PDF",
            connectorLabel: nil
        )
        #expect(result == nil)
        let kstore = try store.knowledgeStore()
        #expect(kstore.sourceExistsByURL(sourceURL) == nil)
    }

    @Test("attachPDFToPaper fails closed when the PDF has no readable paper text")
    func attachPDFToPaperRequiresReadablePaperText() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let paperURL = "https://example.com/attach-paper"

        let paper = StudioArticle(
            url: paperURL,
            title: "Attach Paper",
            sourceType: .paper
        )
        try store.knowledgeStore().saveSource(paper)
        let id = paper.id
        let sourcePDF = URL(fileURLWithPath: tmpPath).appendingPathComponent("source.pdf")
        try makeTestPDF(at: sourcePDF, text: "")

        do {
            _ = try await store.attachPDFToPaper(
                sourceID: id,
                filePath: sourcePDF.path,
                pdfURL: nil
            )
            Issue.record("Attaching a paper without readable text should fail")
        } catch {
            #expect(error is MCPError)
        }
        #expect(try scalarString(dbPath: dbPath, "SELECT url FROM papers WHERE source_id = '\(id)'") == paperURL)
        let localPath = try scalarString(dbPath: dbPath, "SELECT local_file_path FROM papers WHERE source_id = '\(id)'")
        #expect(localPath?.hasPrefix("Papers/") == true)
        #expect(localPath?.hasSuffix(".pdf") == true)
        #expect(try scalarString(dbPath: dbPath, "SELECT state FROM sources WHERE id = '\(id)'") == "error")
        #expect(try scalarString(dbPath: dbPath, "SELECT paper_ingestion_method FROM papers WHERE source_id = '\(id)'") == nil)
    }

    @Test("removeSource dismisses and archives a normal source")
    func removeSourceArchivesAndDismisses() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        let addResult = try store.addSource(
            url: "https://example.com/remove-me",
            title: "Remove Me",
            sourceType: "article",
            content: "Cached source text",
            parentGroup: nil,
            author: nil
        )
        let id = addResult.components(separatedBy: "id: ").last?.components(separatedBy: ",").first ?? ""

        let result = try store.removeSource(id)

        #expect(result.contains("archived"))
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM dismissed_sources WHERE url = 'https://example.com/remove-me'") == 1)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM sources WHERE id = '\(id)' AND status = 'archived'") == 1)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM source_content WHERE source_id = '\(id)'") == 0)
    }

    @Test("unarchiveSource reverses removal without leaving a dismissal tombstone")
    func unarchiveSourceClearsRemovalDismissal() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let url = "https://example.com/restore-me"

        let addResult = try store.addSource(
            url: url,
            title: "Restore Me",
            sourceType: "article",
            content: "Cached source text",
            parentGroup: nil,
            author: nil
        )
        let id = addResult.components(separatedBy: "id: ").last?.components(separatedBy: ",").first ?? ""
        _ = try store.removeSource(id)

        let result = try store.unarchiveSourceRestoringContent(id)

        #expect(result.contains("Unarchived source"))
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM dismissed_sources WHERE url = '\(url)'") == 0)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM sources WHERE id = '\(id)' AND status = 'active'") == 1)
    }

    @Test("searchSourcesSemantic returns nearest embedded sources first")
    func searchSourcesSemanticRanksResults() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-a",
            title: "Partial Reprogramming Overview",
            content: "Yamanaka factors and cellular rejuvenation."
        )
        try insertSource(
            dbPath: dbPath,
            id: "source-b",
            title: "Epigenetic Clocks in Aging",
            content: "Age reversal biomarkers and methylation clocks."
        )
        try insertSource(
            dbPath: dbPath,
            id: "source-c",
            title: "Completely Different Topic",
            content: "Compiler optimization and static analysis."
        )

        try insertEmbedding(dbPath: dbPath, entityId: "source-a", vector: [1, 0, 0])
        try insertEmbedding(dbPath: dbPath, entityId: "source-b", vector: [0.8, 0.2, 0])
        try insertEmbedding(dbPath: dbPath, entityId: "source-c", vector: [0, 1, 0])

        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )

        let result = try await store.searchSourcesSemantic(queryText: "partial reprogramming", limit: 2, threshold: 0.1)

        #expect(result.contains("Partial Reprogramming Overview"))
        #expect(result.contains("Epigenetic Clocks in Aging"))
        #expect(!result.contains("Completely Different Topic"))

        let firstIndex = result.range(of: "Partial Reprogramming Overview")?.lowerBound
        let secondIndex = result.range(of: "Epigenetic Clocks in Aging")?.lowerBound
        #expect(firstIndex != nil)
        #expect(secondIndex != nil)
        if let firstIndex, let secondIndex {
            #expect(firstIndex < secondIndex)
        }
    }

    @Test("Discovery suggests only what the model judges to fit, and a Notebook made from a chat takes the chat in")
    func discoveryKeepsJudgedFitAndFilesTheCallingChat() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(dbPath: dbPath, id: "source-a", title: "Partial Reprogramming Overview",
                         content: "Yamanaka factors and cellular rejuvenation.")
        try insertSource(dbPath: dbPath, id: "source-b", title: "Epigenetic Clocks in Aging",
                         content: "Age reversal biomarkers and methylation clocks.")
        try insertSource(dbPath: dbPath, id: "source-c", title: "Completely Different Topic",
                         content: "Compiler optimization and static analysis.")
        // Every source sits near the topic, as the anisotropic embedding has
        // it, so similarity alone would suggest all three.
        try insertEmbedding(dbPath: dbPath, entityId: "source-a", vector: [1, 0, 0])
        try insertEmbedding(dbPath: dbPath, entityId: "source-b", vector: [0.95, 0.05, 0])
        try insertEmbedding(dbPath: dbPath, entityId: "source-c", vector: [0.93, 0.07, 0])

        let judged = JudgedCandidates()
        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] },
            libraryFitJudge: { notebook, candidates in
                await judged.record(notebook: notebook.title, candidates: candidates.map(\.title))
                return Set(candidates.map(\.id).filter { $0 != "source-c" })
            }
        )
        let ks = try store.knowledgeStore()
        try ks.createReviewSession(id: "chat-host", topic: "Make me a notebook on reprogramming", sourceIDs: [])

        let result = try await store.createNotebook(
            title: "Partial reprogramming", description: nil, topic: nil, endDateString: "",
            sourceIDs: [], dailyTarget: nil, discover: true, hostSessionID: "chat-host"
        )

        let notebookID = try #require(createdNotebookID(in: result))
        let notebook = try #require(try ks.loadLearningGoal(notebookID))
        #expect(Set(notebook.items.filter(\.isPendingApproval).map(\.sourceID)) == ["source-a", "source-b"])
        #expect(await judged.notebook == "Partial reprogramming")
        #expect(await judged.candidates.contains("Completely Different Topic"))

        // The chat that asked is filed in the Notebook, and its reply is told
        // not to list or show what it made.
        #expect(try ks.loadReviewSessionGoalID(sessionID: "chat-host") == notebookID)
        #expect(result.contains("filed this chat in it"))
        #expect(result.hasPrefix("Created Notebook ‘Partial reprogramming’, filed this chat in it"))
        #expect(result.contains("Do not list its sources or the suggestions"))
        #expect(!result.contains("Pass notebook_id"))
    }

    private actor JudgedCandidates {
        var notebook: String?
        var candidates: [String] = []
        func record(notebook: String, candidates: [String]) {
            self.notebook = notebook
            self.candidates = candidates
        }
    }

    /// A library shaped like the one the 2026-10-11 notebook was made in. Its embedding
    /// is anisotropic, so every source sits near every query, and here the three
    /// off-topic ones sit nearest the topic. The paper the chat was about (`seed-paper`)
    /// and the one on-topic source share its rare words (Polycomb, bivalent, H3K27me3,
    /// chromatin); nothing else does, and neither title says the topic's words.
    private func makeSeededDiscoveryLibrary(_ ks: KnowledgeStore, dbPath: String) throws {
        func vector(_ weights: [Int: Float]) -> [Float] {
            var values = [Float](repeating: 0, count: StorageService.sourceEmbeddingDimensions)
            for (axis, weight) in weights { values[axis] = weight }
            return values
        }
        func add(_ id: String, title: String, body: String, near weights: [Int: Float]?) throws {
            try insertSource(dbPath: dbPath, id: id, title: title, content: body)
            try ks.replaceSourceFTS(sourceID: id, title: title, author: "", body: body)
            if let weights {
                try ks.saveEmbedding(
                    entityType: .sourceChunk,
                    entityId: StorageService.sourceChunkEmbeddingId(sourceId: id, index: 0),
                    vector: vector(weights),
                    model: StorageService.sourceEmbeddingModel
                )
            }
        }
        try add("far-terahertz", title: "Terahertz waves and conscious experience",
                body: "Terahertz radiation, microtubules and awareness.", near: [0: 1])
        try add("far-deglycase", title: "A deglycase in early parkinsonism",
                body: "Oxidative stress, a deglycase and dopaminergic neurons.", near: [0: 0.98, 1: 0.2])
        try add("far-tunnelling", title: "Proton tunnelling in enzymes",
                body: "Quantum tunnelling of protons speeds enzyme catalysis.", near: [0: 0.95, 1: 0.31])
        try add("seed-paper", title: "Polycomb marks and bivalent chromatin in development",
                body: "Polycomb complexes keep bivalent promoters poised. H3K27me3 spreads where Polycomb silences. "
                    + "Bivalent chromatin resolves in development, and H3K27me3 returns with Polycomb.",
                near: [0: 0.8, 1: 0.6])
        try add("on-topic", title: "Silencing drift in old tissue",
                body: "Polycomb occupancy and H3K27me3 fall with age, and bivalent promoters lose their poise. "
                    + "Chromatin drifts as Polycomb is lost.",
                near: [0: 0.6, 1: 0.8])
        // Enough of a library that the shared words are rare in it.
        for index in 0..<20 {
            try add("filler-\(index)", title: "Unrelated note \(index)",
                    body: "General prose about compilers, history and exercise.", near: nil)
        }
    }

    /// The query vector the topic embeds to in `makeSeededDiscoveryLibrary`'s library.
    private static let seededDiscoveryQuery: [Float] = {
        var values = [Float](repeating: 0, count: StorageService.sourceEmbeddingDimensions)
        values[0] = 1
        return values
    }()

    @Test("Discovery seeded by a Notebook's own source ranks what shares its rare words first")
    func discoverySeededBySourceRanksSharedRareTermsFirst() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let store = MCPDataStore(dbPath: dbPath, sourceEmbeddingProvider: { _ in Self.seededDiscoveryQuery })
        let ks = try store.knowledgeStore()
        try makeSeededDiscoveryLibrary(ks, dbPath: dbPath)

        // The topic alone: the embedding puts every off-topic source ahead of the one
        // that belongs, which is how twelve unrelated papers were suggested.
        let topicOnly = try await store.companionDiscover(
            topic: "Grammar of cellular identity", excluding: ["seed-paper"],
            sinceReferenceTimestamp: nil, limit: 24
        )
        // (The three off-topic sources tie closely, so their order among themselves is not the point.)
        #expect(Set(topicOnly.map(\.sourceID).dropLast()) == ["far-terahertz", "far-deglycase", "far-tunnelling"])
        #expect(topicOnly.last?.sourceID == "on-topic")

        // Seeded by the paper the Notebook was made from, the source sharing its rare
        // words leads, and the seed itself is never suggested back.
        let seeded = try await store.companionDiscover(
            topic: "Grammar of cellular identity", seedSourceIDs: ["seed-paper"], excluding: [],
            sinceReferenceTimestamp: nil, limit: 24
        )
        #expect(seeded.first?.sourceID == "on-topic")
        #expect(!seeded.map(\.sourceID).contains("seed-paper"))
        #expect(Set(seeded.map(\.sourceID)) == ["on-topic", "far-terahertz", "far-deglycase", "far-tunnelling"])

        // A seed with no full-text row yet gives up its share of the vote rather than
        // diluting the others': the ranking comes out as if it were not there.
        let withUnindexedSeed = try await store.companionDiscover(
            topic: "Grammar of cellular identity", seedSourceIDs: ["not-indexed", "seed-paper"], excluding: [],
            sinceReferenceTimestamp: nil, limit: 24
        )
        #expect(withUnindexedSeed.map(\.sourceID) == seeded.map(\.sourceID))
        #expect(withUnindexedSeed.map(\.relevance) == seeded.map(\.relevance))
    }

    @Test("A Notebook made from a chat starts with the sources the chat discussed, and they steer its suggestions")
    func notebookFromChatIsSeededByWhatTheChatDiscussed() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let judged = JudgedCandidates()
        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in Self.seededDiscoveryQuery },
            libraryFitJudge: { notebook, candidates in
                await judged.record(notebook: notebook.title, candidates: candidates.map(\.title))
                return Set(candidates.map(\.id).filter { $0 == "on-topic" })
            }
        )
        let ks = try store.knowledgeStore()
        try makeSeededDiscoveryLibrary(ks, dbPath: dbPath)

        // The chat was opened on no source; its reply cites the paper by in-app link,
        // and once a source the library does not hold.
        try ks.createReviewSession(id: "chat-host", topic: "About a paper", sourceIDs: [])
        _ = try ks.addReviewExchange(
            sessionID: "chat-host",
            question: "",
            answer: "Turn this into a notebook",
            evaluation: "As [the paper](foreverlm://source/seed-paper) argues, and [a lost one](foreverlm://source/not-in-library-0000) too.",
            score: nil,
            knowledgeNote: nil,
            sourceRefs: []
        )

        let result = try await store.createNotebook(
            title: "Grammar of cellular identity", description: nil, topic: nil, endDateString: "",
            sourceIDs: [], dailyTarget: nil, discover: true, hostSessionID: "chat-host"
        )

        let notebookID = try #require(createdNotebookID(in: result))
        let notebook = try #require(try ks.loadLearningGoal(notebookID))
        #expect(notebook.items.filter(\.isApproved).map(\.sourceID) == ["seed-paper"])
        #expect(notebook.items.filter(\.isPendingApproval).map(\.sourceID) == ["on-topic"])
        #expect(result.contains("Seeds: 1, 1 of them the sources this chat discussed."))
        // The judge read the seeded ranking: the source sharing the paper's words first.
        #expect(await judged.candidates.first == "Silencing drift in old tissue")
        #expect(try ks.loadReviewSessionGoalID(sessionID: "chat-host") == notebookID)

        // A caller's own sources come first, and the chat's are not repeated.
        let given = try await store.createNotebook(
            title: "Grammar of cellular identity, again", description: nil, topic: nil, endDateString: "",
            sourceIDs: ["far-terahertz", "seed-paper"], dailyTarget: nil, discover: false, hostSessionID: "chat-host"
        )
        let givenID = try #require(createdNotebookID(in: given))
        let givenNotebook = try #require(try ks.loadLearningGoal(givenID))
        #expect(Set(givenNotebook.items.filter(\.isApproved).map(\.sourceID)) == ["far-terahertz", "seed-paper"])
        #expect(given.contains("Seeds: 2."))
    }

    @Test("A Notebook made from a chat takes every source the chat linked or read, past the discovery seed limit")
    func notebookFromChatTakesEverySourceLinkedOrRead() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let store = MCPDataStore(dbPath: dbPath)
        let ks = try store.knowledgeStore()

        let linked = (1...8).map { "linked-\($0)" }
        for id in linked + ["read-only"] {
            try insertSource(dbPath: dbPath, id: id, title: "Source \(id)", content: "Body of \(id).")
        }
        try ks.createReviewSession(id: "chat-host", topic: "Delivery", sourceIDs: [])
        for pair in stride(from: 0, to: linked.count, by: 2) {
            _ = try ks.addReviewExchange(
                sessionID: "chat-host", question: "", answer: "And these?",
                evaluation: "See [one](foreverlm://source/\(linked[pair])) and [two](foreverlm://source/\(linked[pair + 1])).",
                score: nil, knowledgeNote: nil, sourceRefs: []
            )
        }
        // Read through a tool and never linked in a reply.
        try ks.updateReviewSessionLoadedSources(sessionID: "chat-host", sourceIDs: ["read-only", "linked-1"])
        #expect(linked.count + 1 > store.companionDiscoverySeedLimit)

        let result = try await store.createNotebook(
            title: "Delivery routes", description: nil, topic: nil, endDateString: "",
            sourceIDs: [], dailyTarget: nil, discover: false, hostSessionID: "chat-host"
        )
        let notebookID = try #require(createdNotebookID(in: result))
        let notebook = try #require(try ks.loadLearningGoal(notebookID))
        #expect(Set(notebook.items.filter(\.isApproved).map(\.sourceID)) == Set(linked + ["read-only"]))
        #expect(result.contains("Seeds: 9, 9 of them the sources this chat discussed."))
    }

    @Test("A Notebook made from a chat takes in the Pages the chat wrote")
    func notebookFromChatFilesTheChatsPages() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let store = MCPDataStore(dbPath: dbPath)
        let ks = try store.knowledgeStore()
        let pages = store.notebookFileStorage

        let elsewhere = try #require(createdNotebookID(in: try await store.createNotebook(
            title: "Elsewhere", description: nil, topic: nil, endDateString: "",
            sourceIDs: [], dailyTarget: nil, discover: false
        )))
        let loose = try await pages.createArtifact(title: "Delivery comparison", homeNotebookID: nil, linkedNotebookIDs: []).artifact
        let homed = try await pages.createArtifact(title: "Homed page", homeNotebookID: elsewhere, linkedNotebookIDs: []).artifact
        let unrelated = try await pages.createArtifact(title: "Not this chat's", homeNotebookID: nil, linkedNotebookIDs: []).artifact
        let thisTurn = try await pages.createArtifact(title: "Written this turn", homeNotebookID: nil, linkedNotebookIDs: []).artifact

        // The chat's replies carry the Pages it wrote as card lines; a Page
        // linked in prose is not one it wrote.
        try ks.createReviewSession(id: "chat-host", topic: "Delivery", sourceIDs: [])
        for page in [loose, homed] {
            _ = try ks.addReviewExchange(
                sessionID: "chat-host", question: "", answer: "Write it up",
                evaluation: ChatWrittenPage.storing("Done. See also [this](foreverlm://doc/\(unrelated.id)).",
                                                    with: [ChatWrittenPage(id: page.id, title: page.title)]),
                score: nil, knowledgeNote: nil, sourceRefs: []
            )
        }

        let result = try await store.createNotebook(
            title: "In vivo delivery", description: nil, topic: nil, endDateString: "",
            sourceIDs: [], dailyTarget: nil, discover: false, hostSessionID: "chat-host"
        )
        let notebookID = try #require(createdNotebookID(in: result))
        #expect(result.contains("Pages this chat wrote, now in it: ‘Delivery comparison’, ‘Homed page’."))

        #expect(try ks.loadArtifact(loose.id)?.homeNotebookID == notebookID)
        let homedAfter = try #require(try ks.loadArtifact(homed.id))
        #expect(homedAfter.homeNotebookID == elsewhere)
        #expect(homedAfter.linkedNotebookIDs.contains(notebookID))
        #expect(try ks.loadArtifact(unrelated.id)?.homeNotebookID == nil)

        // The running turn's Pages, not stored yet, are filed when named; a
        // second filing moves nothing.
        let filed = try await pages.fileChatPages(sessionID: "chat-host", pageIDs: [thisTurn.id], inNotebook: notebookID)
        #expect(filed.map(\.id) == [thisTurn.id])
        #expect(try ks.loadArtifact(thisTurn.id)?.homeNotebookID == notebookID)
        #expect(try await pages.fileChatPages(sessionID: "chat-host", pageIDs: [thisTurn.id], inNotebook: notebookID).isEmpty)
    }

    @Test("searchSourcesSemantic filters a relative-date meeting lookup deterministically")
    func searchSourcesSemanticFiltersMeetingDateWithoutEmbeddingGuesswork() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let targetDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 30)))
        let previousDay = try #require(calendar.date(byAdding: .day, value: -1, to: targetDay))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let targetDate = formatter.string(from: targetDay)

        try insertSource(
            dbPath: dbPath,
            id: "meeting-yesterday",
            title: "Journal Club — Somatic Mutations in Hashimoto's Thyroiditis",
            content: "A discussion of somatic mutation burden in thyroid tissue.",
            sourceType: "meeting"
        )
        try insertSource(
            dbPath: dbPath,
            id: "meeting-older",
            title: "Partial Reprogramming Case Study",
            content: "A commercially focused partial reprogramming discussion.",
            sourceType: "meeting"
        )
        try insertSource(
            dbPath: dbPath,
            id: "article-yesterday",
            title: "Thyroid News",
            content: "An article imported on the same day.",
            sourceType: "article"
        )
        try execSQL(
            dbPath: dbPath,
            "UPDATE sources SET date_added = \(targetDay.timeIntervalSinceReferenceDate) WHERE id IN ('meeting-yesterday', 'article-yesterday'); "
                + "UPDATE sources SET date_added = \(previousDay.timeIntervalSinceReferenceDate) WHERE id = 'meeting-older';"
        )

        let searchStore = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in
                Issue.record("A date-and-type-only lookup must not invoke semantic embedding")
                return [1, 0, 0]
            }
        )
        let result = try await searchStore.searchSourcesSemantic(
            queryText: "",
            sourceType: "meeting",
            addedFrom: targetDate,
            addedTo: targetDate
        )

        #expect(result.contains("Journal Club — Somatic Mutations in Hashimoto's Thyroiditis"))
        #expect(result.contains("occurred: \(targetDate)"))
        #expect(!result.contains("Partial Reprogramming Case Study"))
        #expect(!result.contains("Thyroid News"))
    }

    @Test("A source search takes back the timestamp it printed, and says which axis found nothing")
    func searchSourcesSemanticRoundTripsItsOwnPrintedDate() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 30, hour: 16, minute: 53)))

        try insertSource(
            dbPath: dbPath,
            id: "meeting-printed",
            title: "Journal Club — Elamipretide",
            content: "A discussion of the SS-31 trial results.",
            sourceType: "meeting"
        )
        try execSQL(
            dbPath: dbPath,
            "UPDATE sources SET date_added = \(day.timeIntervalSinceReferenceDate) WHERE id = 'meeting-printed';"
        )

        let searchStore = MCPDataStore(dbPath: dbPath, sourceEmbeddingProvider: { _ in [1, 0, 0] })

        // The exact string the search prints for a meeting — "occurred:
        // 2026-08-30 16:53 PDT". A model narrowing its next call hands that
        // back, and the tool used to refuse the timestamp it had just written.
        let printed = DateFormatter()
        printed.locale = Locale(identifier: "en_US_POSIX")
        printed.timeZone = .current
        printed.dateFormat = "yyyy-MM-dd HH:mm zzz"
        let stamp = printed.string(from: day)

        let narrowed = try await searchStore.searchSourcesSemantic(
            queryText: "",
            sourceType: "meeting",
            addedFrom: stamp,
            addedTo: stamp
        )
        #expect(narrowed.contains("Journal Club — Elamipretide"))

        // A publication year spelled as a real day is well-formed and matches
        // nothing. The empty result has to name the axis it filtered on, or it
        // reads as "your library has no such source".
        let empty = try await searchStore.searchSourcesSemantic(
            queryText: "",
            sourceType: "meeting",
            addedFrom: "2019-01-01",
            addedTo: "2019-12-31"
        )
        #expect(empty.contains("2019-01-01"))
        #expect(empty.contains("added to the library"))
        #expect(empty.contains("never on when it was published"))
    }

    @Test("searchSourcesSemantic omits sources already in the excluded Notebook")
    func searchSourcesSemanticExcludesNotebookSources() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-a",
            title: "Partial Reprogramming Overview",
            content: "Yamanaka factors and cellular rejuvenation."
        )
        try insertSource(
            dbPath: dbPath,
            id: "source-b",
            title: "Epigenetic Clocks in Aging",
            content: "Age reversal biomarkers and methylation clocks."
        )
        try insertEmbedding(dbPath: dbPath, entityId: "source-a", vector: [1, 0, 0])
        try insertEmbedding(dbPath: dbPath, entityId: "source-b", vector: [0.8, 0.2, 0])

        let ks = try store.knowledgeStore()
        let goal = try ks.createCompanionGoal(
            title: "Rejuvenation",
            topic: "partial reprogramming",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,  // a Notebook: open-ended since schema 120
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["source-a"]
        )

        let searchStore = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )

        // Without the exclusion, the source already in the Notebook ranks first.
        let unfiltered = try await searchStore.searchSourcesSemantic(
            queryText: "partial reprogramming",
            limit: 5,
            threshold: 0.1
        )
        #expect(unfiltered.contains("Partial Reprogramming Overview"))

        // With it, the top hit drops out and the limit is filled from what remains.
        let filtered = try await searchStore.searchSourcesSemantic(
            queryText: "partial reprogramming",
            limit: 5,
            threshold: 0.1,
            excludeNotebookID: goal.id
        )
        #expect(!filtered.contains("Partial Reprogramming Overview"))
        #expect(filtered.contains("Epigenetic Clocks in Aging"))
        #expect(filtered.contains("excluding 1 already in Notebook 'Rejuvenation'"))
    }

    @Test("searchSourcesSemantic can restrict results to a Notebook's approved pool")
    func searchSourcesSemanticRestrictsToNotebookSources() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-a",
            title: "Notebook Reprogramming Notes",
            content: "Yamanaka factors and partial reprogramming."
        )
        try insertSource(
            dbPath: dbPath,
            id: "source-b",
            title: "Outside Reprogramming Survey",
            content: "A broader survey of partial reprogramming."
        )
        try insertEmbedding(dbPath: dbPath, entityId: "source-a", vector: [0.8, 0.2, 0])
        try insertEmbedding(dbPath: dbPath, entityId: "source-b", vector: [1, 0, 0])

        let notebook = try store.knowledgeStore().createCompanionGoal(
            title: "Scoped Rejuvenation",
            topic: "partial reprogramming",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["source-a"]
        )
        let searchStore = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )

        let scoped = try await searchStore.searchSourcesSemantic(
            queryText: "partial reprogramming",
            limit: 5,
            threshold: 0.1,
            notebookID: notebook.id
        )

        #expect(scoped.contains("Notebook Reprogramming Notes"))
        #expect(!scoped.contains("Outside Reprogramming Survey"))
        #expect(scoped.contains("in Notebook 'Scoped Rejuvenation'"))

        await #expect(throws: MCPError.self) {
            _ = try await searchStore.searchSourcesSemantic(
                queryText: "partial reprogramming",
                notebookID: notebook.id,
                excludeNotebookID: notebook.id
            )
        }
    }

    @Test("searchSourcesSemantic reports when no embeddings pass threshold")
    func searchSourcesSemanticNoResults() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-a",
            title: "Epigenetic Clocks in Aging",
            content: "Yamanaka factors and cellular rejuvenation."
        )
        try insertEmbedding(dbPath: dbPath, entityId: "source-a", vector: [0, 1, 0])

        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )

        let result = try await store.searchSourcesSemantic(queryText: "partial reprogramming", limit: 5, threshold: 0.95)
        #expect(result.contains("No semantically or text-matched sources found"))
    }

    @Test("searchSourcesSemantic includes exact acronym text matches")
    func searchSourcesSemanticIncludesAcronymTextMatches() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-gwas",
            title: "Book Chapter on Genetics",
            content: "The author criticizes GWAS repeatedly as part of a broader attack on gene-centric explanations."
        )
        try insertEmbedding(dbPath: dbPath, entityId: "source-gwas", vector: [0, 1, 0])

        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )

        let result = try await store.searchSourcesSemantic(queryText: "GWAS", limit: 5, threshold: 0.95)

        #expect(result.contains("Book Chapter on Genetics"))
        #expect(result.contains("GWAS"))
        #expect(result.contains("text:"))
    }

    @Test("source search bounds term-statistics work while preserving a trailing anchor")
    func sourceSearchTermsAreBounded() {
        let terms = (0..<40).map { "term\($0)" }.joined(separator: " ") + " GDF15"
        let parsed = SourceSearchEngine.searchTerms(for: terms)

        #expect(parsed.count == SourceSearchEngine.maximumStatisticalTerms)
        #expect(parsed.first == "term0")
        #expect(parsed.last == "gdf15")
    }

    @Test("word-delimiter analysis reduces both spellings of a term to the same parts")
    func sourceSearchAnalyzesHyphenationAway() {
        // The point of the analysis: whichever way the learner writes it, the word
        // arrives as the same parts, so the alternatives offered to FTS are identical.
        let bare = SourceSearchEngine.analyzedWords(for: "GDF15")
        let hyphenated = SourceSearchEngine.analyzedWords(for: "gdf-15")
        #expect(bare.map(\.parts) == [["gdf", "15"]])
        #expect(hyphenated.map(\.parts) == [["gdf", "15"]])
        #expect(bare.first?.variants == ["gdf15", "gdf 15"])
        #expect(bare.first?.variants == hyphenated.first?.variants)

        // Typed tokens stay as typed — those are the keys corpus statistics use.
        #expect(bare.first?.typedTokens == ["gdf15"])
        #expect(hyphenated.first?.typedTokens == ["gdf", "15"])

        // A run of letters carries no boundary to split on, so it is left alone
        // rather than guessed at.
        #expect(SourceSearchEngine.analyzedWords(for: "cfmtDNA").map(\.parts) == [["cfmtdna"]])
        #expect(SourceSearchEngine.analyzedWords(for: "cf-mtDNA").map(\.parts) == [["cf", "mtdna"]])

        // The text-side fold closes up punctuation within a word but keeps the spaces
        // between words: a boundary the writer put there is not one to match across.
        #expect(SourceSearchEngine.catenatedFold("GDF-15 as a Biomarker") == "gdf15 as a biomarker")
        #expect(SourceSearchEngine.catenatedFold("the rapist") == "the rapist")
    }

    @Test("index-time analysis adds the closed-up spelling and keeps the split one")
    func sourceSearchIndexAnalysisAddsSymbolTokens() {
        // Added, not substituted: the tokens `unicode61` would produce are all still
        // there, so "Windows 10" keeps working on a body that wrote "Windows-10".
        #expect(SourceSearchEngine.indexAnalyzedTokens(in: "GDF-15") == ["GDF", "15", "GDF15"])
        #expect(SourceSearchEngine.indexAnalyzedTokens(in: "Windows-10") == ["Windows", "10", "Windows10"])
        #expect(SourceSearchEngine.indexAnalyzedTokens(in: "5-HT") == ["5", "HT", "5HT"])

        // A letters/letters boundary carries no symbol to close up, and structured text
        // must not be mangled: a DOI's "1038" and "s41586" are not one word.
        #expect(SourceSearchEngine.indexAnalyzedTokens(in: "state-of-the-art")
            == ["state", "of", "the", "art"])
        #expect(SourceSearchEngine.indexAnalyzedTokens(in: "10.1038/s41586-023")
            == ["10", "1038", "s41586", "023"])

        // Ordinary prose passes through untouched; only the symbol-like word grows.
        #expect(SourceSearchEngine.indexAnalyzedText("Circulating GDF-15 rises in muscle")
            == "Circulating GDF 15 GDF15 rises in muscle")
        #expect(SourceSearchEngine.indexAnalyzedText("no punctuation here")
            == "no punctuation here")
    }

    @Test("analyzed MATCH expressions offer every spelling as an alternative")
    func sourceSearchExpressionsCoverVariants() {
        let words = SourceSearchEngine.analyzedWords(for: "GDF15 biomarker")

        // A space inside a quoted FTS5 string is a phrase — adjacent tokens — which is
        // how the index stored "GDF-15".
        #expect(SourceSearchEngine.ftsMatchExpression(for: words)
            == "(\"gdf15\" OR \"gdf 15\") OR \"biomarker\"")
        #expect(SourceSearchEngine.ftsAllTermsMatchExpression(for: words)
            == "(\"gdf15\" OR \"gdf 15\") AND \"biomarker\"")

        // The hyphenated query produces the same expression, which is the symmetry.
        let hyphenated = SourceSearchEngine.analyzedWords(for: "GDF-15 biomarker")
        #expect(SourceSearchEngine.ftsMatchExpression(for: hyphenated)
            == SourceSearchEngine.ftsMatchExpression(for: words))
    }

    @Test("more like this keeps a source's own rare words, by how often it says them and how rare they are")
    func moreLikeThisChoosesDistinctiveTerms() {
        let text = "Polycomb POLYCOMB polycomb bivalent Bivalent the the the the cells cells cells "
            + "Ezh2 EZH2 2026 2026 ab ab once café cafe"
        // Folded as the index folds; a number, a two-letter token and a word said once
        // never name a subject. Most frequent first, ties by spelling.
        let candidates = SourceSearchEngine.moreLikeThisCandidateTerms(in: text)
        #expect(candidates.map(\.term) == ["the", "cells", "polycomb", "bivalent", "cafe", "ezh2"])
        #expect(candidates.map(\.count) == [4, 3, 3, 2, 2, 2])

        // In a library of 100: "the" and "cells" are ordinary vocabulary, "ezh2" is held
        // by no other source and can retrieve nothing, and a word never measured is
        // left out. The rest by tf·idf: polycomb (3 × 3.36) before bivalent (2 × 2.91)
        // before cafe (2 × 1.60).
        let terms = SourceSearchEngine.moreLikeThisTerms(
            candidates: candidates,
            documentFrequencies: ["the": 99, "cells": 60, "polycomb": 3, "bivalent": 5, "ezh2": 1, "cafe": 20],
            corpusSize: 100
        )
        #expect(terms == ["polycomb", "bivalent", "cafe"])

        // A long source still asks with a bounded number of words.
        let many = (0..<30).map { (term: "term\(String(format: "%02d", $0))", count: 2) }
        let bounded = SourceSearchEngine.moreLikeThisTerms(
            candidates: many,
            documentFrequencies: Dictionary(uniqueKeysWithValues: many.map { ($0.term, 2) }),
            corpusSize: 100
        )
        #expect(bounded.count == SourceSearchEngine.moreLikeThisTermCount)
        #expect(bounded.first == "term00")
    }

    @Test("fused ranking adds each ranking's weighted reciprocal rank, an id once per ranking")
    func fusedRankingAddsWeightedReciprocalRanks() {
        let fused = SourceSearchEngine.fusedRanking([
            (ids: ["a", "b", "c"], weight: 1),
            (ids: ["c", "d"], weight: 0.5),
            (ids: ["c", "e", "c"], weight: 0.5),
        ])
        // c is in all three, so it leads though no ranking put it first alone; d and e
        // tie and go by id.
        #expect(fused.map(\.id) == ["c", "a", "b", "d", "e"])
        let k = SourceSearchEngine.rrfK
        let c = fused.first { $0.id == "c" }?.score ?? 0
        #expect(abs(c - (1 / (k + 3) + 0.5 / (k + 1) + 0.5 / (k + 1))) < 1e-6)
        #expect(SourceSearchEngine.fusedRanking([]).isEmpty)
    }

    @Test("body-text search finds a term written the other way round")
    func searchSourcesSemanticFindsHyphenationVariants() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        // Neither title names the protein: only the bodies do, and each spells it the
        // other way. This is the case the in-app metadata filter cannot reach.
        let hyphenatedBody = "Circulating GDF-15 rises with mitochondrial dysfunction in muscle."
        let bareBody = "GDF15 remains poorly understood as a signal of cellular stress."
        try insertSource(
            dbPath: dbPath,
            id: "source-hyphenated",
            title: "Mitochondrial stress markers",
            content: hyphenatedBody
        )
        try insertSource(
            dbPath: dbPath,
            id: "source-bare",
            title: "A mystery hormone",
            content: bareBody
        )
        // Indexed the way the background indexer would, so this exercises the full-text
        // branch — where `unicode61` stores the hyphenated spelling as two adjacent
        // tokens and the bare one as a single token — rather than the substring scan
        // that only stands in while the index is behind.
        try execSQL(dbPath: dbPath, """
            INSERT INTO source_fts (source_id, title, author, body) VALUES
              ('source-hyphenated', 'Mitochondrial stress markers', '', '\(hyphenatedBody)'),
              ('source-bare', 'A mystery hormone', '', '\(bareBody)');
            """)

        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )

        // A threshold no cosine similarity can clear keeps the semantic branch out of
        // it, so the full-text branch is what answers in both directions.
        let bareQuery = try await store.searchSourcesSemantic(queryText: "GDF15", limit: 5, threshold: 1.5)
        #expect(bareQuery.contains("Mitochondrial stress markers"))
        #expect(bareQuery.contains("A mystery hormone"))

        let hyphenQuery = try await store.searchSourcesSemantic(queryText: "GDF-15", limit: 5, threshold: 1.5)
        #expect(hyphenQuery.contains("Mitochondrial stress markers"))
        #expect(hyphenQuery.contains("A mystery hormone"))

        // A different protein still matches neither.
        let unrelated = try await store.searchSourcesSemantic(queryText: "GDF16", limit: 5, threshold: 1.5)
        #expect(!unrelated.contains("Mitochondrial stress markers"))
        #expect(!unrelated.contains("A mystery hormone"))
    }

    @Test("the scan that stands in for an unbuilt index reads both spellings too")
    func searchSourcesSemanticScanFallbackFindsHyphenationVariants() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        // No `source_fts` rows: a source added moments ago, before the indexer reached
        // it. Retrieval falls back to a content scan, and that window must not change
        // which spelling works.
        try insertSource(
            dbPath: dbPath,
            id: "source-hyphenated",
            title: "Mitochondrial stress markers",
            content: "Circulating GDF-15 rises with mitochondrial dysfunction in muscle."
        )

        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )

        let bareQuery = try await store.searchSourcesSemantic(queryText: "GDF15", limit: 5, threshold: 1.5)
        #expect(bareQuery.contains("Mitochondrial stress markers"))

        let unrelated = try await store.searchSourcesSemantic(queryText: "GDF16", limit: 5, threshold: 1.5)
        #expect(!unrelated.contains("Mitochondrial stress markers"))
    }

    @Test("source search recognizes only complete DOI identifiers")
    func sourceSearchDOIIdentifierParsing() {
        #expect(SourceSearchEngine.doiIdentifier(from: "10.1038/S41586-023-06004-9") == "10.1038/s41586-023-06004-9")
        #expect(SourceSearchEngine.doiIdentifier(from: "https://doi.org/10.1038/s41586-023-06004-9") == "10.1038/s41586-023-06004-9")
        #expect(SourceSearchEngine.doiIdentifier(from: "paper 10.1038/s41586-023-06004-9") == nil)
    }

    @Test("exact DOI lookup returns a paper without relying on token search")
    func searchSourcesSemanticFindsExactDOI() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "doi-paper",
            title: "A title with no identifier tokens",
            content: "Body text with no identifier tokens.",
            sourceType: "paper"
        )
        try execSQL(
            dbPath: dbPath,
            "UPDATE papers SET doi = '10.1038/s41586-023-06004-9' WHERE source_id = 'doi-paper'"
        )

        let store = MCPDataStore(dbPath: dbPath, sourceEmbeddingProvider: { _ in [1, 0, 0] })
        let result = try await store.searchSourcesSemantic(
            queryText: "https://doi.org/10.1038/s41586-023-06004-9",
            limit: 5
        )

        #expect(result.contains("A title with no identifier tokens"))
    }

    @Test("nearby query terms outrank the same terms scattered through a source")
    func searchSourcesSemanticUsesTermProximity() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let nearBody = "alpha beta gamma " + String(repeating: "padding ", count: 20)
        let farBody = "alpha " + String(repeating: "padding ", count: 14) + "beta gamma "

        try insertSource(dbPath: dbPath, id: "a-far", title: "Scattered evidence", content: farBody)
        try insertFTS(dbPath: dbPath, id: "a-far", title: "", body: farBody)
        try insertSource(dbPath: dbPath, id: "z-near", title: "Nearby evidence", content: nearBody)
        try insertFTS(dbPath: dbPath, id: "z-near", title: "", body: nearBody)

        let store = MCPDataStore(dbPath: dbPath, sourceEmbeddingProvider: { _ in [1, 0, 0] })
        let result = try await store.searchSourcesSemantic(queryText: "alpha beta gamma", limit: 2)
        let nearIndex = result.range(of: "Nearby evidence")?.lowerBound
        let farIndex = result.range(of: "Scattered evidence")?.lowerBound

        #expect(nearIndex != nil)
        #expect(farIndex != nil)
        if let nearIndex, let farIndex {
            #expect(nearIndex < farIndex)
        }
    }
}

#endif
