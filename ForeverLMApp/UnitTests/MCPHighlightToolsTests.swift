import Foundation
import Testing
@testable import ForeverLM

#if os(macOS)
import AppKit
import PDFKit
import SQLite3

/// Reader highlights over MCP: the learner's own marks, readable and writable
/// by an assistant the same way the reader's Note button writes them.
@Suite("MCP highlight tools")
struct MCPHighlightToolsTests {

    private static let articleText = """
    Retrieval practice beats rereading. Pulling an idea back out of memory strengthens \
    the trace far more than seeing it again does, which is why a learner who rereads a \
    chapter feels fluent and then fails the exam.

    Spacing compounds that effect. Two study sessions separated by a day beat two \
    sessions back to back, even when the total time is identical.
    """

    private func makeStore() throws -> (MCPDataStore, String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_highlight_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MCPDataStore(dbPath: directory.appendingPathComponent("knowledge.db").path)
        _ = try store.knowledgeStore()
        return (store, directory.path)
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @discardableResult
    private func seedArticle(
        in store: MCPDataStore,
        url: String = "https://example.com/retrieval-practice",
        title: String = "Retrieval Practice",
        content: String? = MCPHighlightToolsTests.articleText
    ) throws -> String {
        _ = try store.addSource(
            url: url,
            title: title,
            sourceType: "article",
            content: content,
            parentGroup: nil,
            author: nil
        )
        let knowledgeStore = try store.knowledgeStore()
        let existing = knowledgeStore.sourceExistsByNormalizedURL(URLNormalizer.normalize(url))
            ?? knowledgeStore.sourceExistsByURL(url)
        return try #require(existing).id
    }

    private func json(_ raw: String) throws -> [String: Any] {
        let data = try #require(raw.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Registration

    @Test("Highlight tools are registered with the right impact hints")
    func highlightToolsAreRegistered() {
        let toolNames = Set(MCPToolRegistry.shared.tools.map(\.name))
        #expect(toolNames.contains("list_source_highlights"))
        #expect(toolNames.contains("search_source_highlights"))
        #expect(toolNames.contains("create_source_highlight"))
        #expect(toolNames.contains("update_source_highlight"))
        #expect(toolNames.contains("delete_source_highlight"))

        #expect(MCPToolRegistry.annotations(for: "list_source_highlights")["readOnlyHint"] as? Bool == true)
        #expect(MCPToolRegistry.annotations(for: "search_source_highlights")["readOnlyHint"] as? Bool == true)
        #expect(MCPToolRegistry.annotations(for: "create_source_highlight")["readOnlyHint"] as? Bool == false)
        #expect(MCPToolRegistry.annotations(for: "delete_source_highlight")["destructiveHint"] as? Bool == true)
        // Marking a passage only writes to the learner's own library.
        #expect(MCPToolRegistry.annotations(for: "create_source_highlight")["openWorldHint"] as? Bool == false)

        #expect(Prompts.mcpServerInstructions.contains("list_source_highlights"))
        #expect(Prompts.mcpServerInstructions.contains("create_source_highlight"))
        #expect(Prompts.mcpServerInstructions.contains("verbatim"))
    }

    // MARK: Creating

    @Test("A quoted passage is anchored to the source's own wording")
    func createAnchorsToSourceText() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)

        let created = try json(try store.createSourceHighlight(
            sourceID: sourceID,
            quote: "Spacing compounds that effect.",
            note: "This is the bit I keep forgetting.",
            color: "green"
        ))
        #expect(created["status"] as? String == "created")
        let payload = try #require(created["highlight"] as? [String: Any])
        let highlightID = try #require(payload["highlight_id"] as? String)
        #expect(payload["note"] as? String == "This is the bit I keep forgetting.")
        #expect(payload["color"] as? String == "green")
        // A non-PDF mark carries no page geometry.
        #expect(payload["page"] == nil)

        let stored = try #require(try store.knowledgeStore().sourceHighlight(id: highlightID))
        #expect(stored.sourceID == sourceID)
        #expect(stored.quote == "Spacing compounds that effect.")
        // The anchor must be resolvable in the text the readers paint from, or
        // the mark exists in the database and nowhere on screen.
        let content = try #require(try store.knowledgeStore().loadSourceContent(sourceID))
        let range = try #require(stored.anchor.resolve(in: content))
        #expect(String(content[range]) == "Spacing compounds that effect.")
        #expect(!stored.anchor.prefix.isEmpty)
        #expect(!stored.anchor.suffix.isEmpty)
    }

    @Test("A re-spaced quote stores the passage as the document reads it")
    func createNormalizesWhitespace() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)

        // A model re-wrapping the passage it read is the ordinary case, not an
        // error: the anchor matches on collapsed whitespace.
        let created = try json(try store.createSourceHighlight(
            sourceID: sourceID,
            quote: "Retrieval practice beats rereading.\n   Pulling an idea back out of memory",
            note: nil,
            color: nil
        ))
        let payload = try #require(created["highlight"] as? [String: Any])
        let quote = try #require(payload["quote"] as? String)
        #expect(quote == "Retrieval practice beats rereading. Pulling an idea back out of memory")
        #expect(payload["note"] as? String == "")
        #expect(payload["color"] as? String == "yellow")
    }

    @Test("A passage that is not in the source is refused, not placed approximately")
    func createRefusesUnfoundQuote() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)

        #expect(throws: MCPError.self) {
            try store.createSourceHighlight(
                sourceID: sourceID,
                quote: "Interleaving beats blocked practice.",
                note: nil,
                color: nil
            )
        }
        #expect(try store.knowledgeStore().sourceHighlights(sourceID: sourceID).isEmpty)
    }

    @Test("Marking the same passage twice is refused with the existing ID")
    func createRefusesDuplicatePassage() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)

        let created = try json(try store.createSourceHighlight(
            sourceID: sourceID,
            quote: "Spacing compounds that effect.",
            note: nil,
            color: nil
        ))
        let existingID = try #require((created["highlight"] as? [String: Any])?["highlight_id"] as? String)

        var message = ""
        #expect(throws: MCPError.self) {
            do {
                _ = try store.createSourceHighlight(
                    sourceID: sourceID,
                    quote: "Spacing   compounds that effect.",
                    note: "second try",
                    color: nil
                )
            } catch let error as MCPError {
                message = error.errorDescription ?? ""
                throw error
            }
        }
        #expect(message.contains(existingID))
        #expect(try store.knowledgeStore().sourceHighlights(sourceID: sourceID).count == 1)
    }

    @Test("A picture is marked by its URL, with no words, and listed with the picture")
    func createMarksPictureByURL() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)

        let created = try json(try store.createSourceHighlight(
            sourceID: sourceID,
            quote: "",
            note: "The spatial readout figure.",
            color: "blue",
            imageURL: "https://images.example.com/uploads/spatial-screening.png?w=1600",
            imageAlt: "Spatial pooled screening"
        ))
        #expect(created["status"] as? String == "created")
        let payload = try #require(created["highlight"] as? [String: Any])
        #expect(payload["quote"] as? String == "")
        let pictures = try #require(payload["pictures"] as? [[String: Any]])
        #expect(pictures.count == 1)
        #expect(pictures.first?["url"] as? String == "https://images.example.com/uploads/spatial-screening.png?w=1600")
        #expect(pictures.first?["alt"] as? String == "Spatial pooled screening")
        #expect(payload["page"] == nil)

        // Stored in the geometry column, read back as a mark with no words.
        let highlightID = try #require(payload["highlight_id"] as? String)
        let stored = try #require(try store.knowledgeStore().sourceHighlight(id: highlightID))
        #expect(stored.isPictureOnly)
        #expect(stored.imageAnchors.map(\.fileName) == ["spatial-screening.png"])
        #expect(stored.pdfAnchor == nil)
        #expect(try store.knowledgeStore().sourceHighlights(sourceID: sourceID).map(\.id) == [highlightID])

        let listed = try json(try store.listSourceHighlights(sourceID: sourceID))
        let rows = try #require(listed["highlights"] as? [[String: Any]])
        #expect((rows.first?["pictures"] as? [[String: Any]])?.first?["alt"] as? String == "Spatial pooled screening")
        let searched = try json(try store.searchSourceHighlights(query: nil, limit: nil))
        let searchedRows = try #require(searched["highlights"] as? [[String: Any]])
        #expect((searchedRows.first?["pictures"] as? [[String: Any]])?.first?["url"] as? String == "https://images.example.com/uploads/spatial-screening.png?w=1600")

        // The same picture twice is the same mark.
        var message = ""
        #expect(throws: MCPError.self) {
            do {
                _ = try store.createSourceHighlight(
                    sourceID: sourceID, quote: "", note: nil, color: nil,
                    imageURL: "https://images.example.com/uploads/spatial-screening.png?w=1600", imageAlt: nil
                )
            } catch let error as MCPError {
                message = error.errorDescription ?? ""
                throw error
            }
        }
        #expect(message.contains(highlightID))
    }

    @Test("A quote and a picture together make one mark on both; a relative or blob URL is refused; nothing at all is refused")
    func createMarksWordsAndPicture() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)

        let created = try json(try store.createSourceHighlight(
            sourceID: sourceID,
            quote: "Spacing compounds that effect.",
            note: nil,
            color: nil,
            imageURL: "https://images.example.com/spacing.png",
            imageAlt: nil
        ))
        let payload = try #require(created["highlight"] as? [String: Any])
        #expect(payload["quote"] as? String == "Spacing compounds that effect.")
        #expect((payload["pictures"] as? [[String: Any]])?.count == 1)

        #expect(throws: MCPError.self) {
            try store.createSourceHighlight(sourceID: sourceID, quote: "", note: nil, color: nil, imageURL: "/uploads/fig.png", imageAlt: nil)
        }
        #expect(throws: MCPError.self) {
            try store.createSourceHighlight(sourceID: sourceID, quote: "", note: nil, color: nil, imageURL: "blob:https://x.example/abc", imageAlt: nil)
        }
        #expect(throws: MCPError.self) {
            try store.createSourceHighlight(sourceID: sourceID, quote: "   ", note: nil, color: nil)
        }
        #expect(try store.knowledgeStore().sourceHighlights(sourceID: sourceID).count == 1)
    }

    @Test("An unknown color is refused rather than silently defaulted")
    func createRefusesUnknownColor() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)

        #expect(throws: MCPError.self) {
            try store.createSourceHighlight(
                sourceID: sourceID,
                quote: "Spacing compounds that effect.",
                note: nil,
                color: "chartreuse"
            )
        }
    }

    @Test("A source with no stored text cannot carry a mark")
    func createRequiresStoredText() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(
            in: store,
            url: "https://example.com/unfetched",
            title: "Unfetched",
            content: nil
        )

        #expect(throws: MCPError.self) {
            try store.createSourceHighlight(
                sourceID: sourceID,
                quote: "anything at all",
                note: nil,
                color: nil
            )
        }
    }

    // MARK: Reading

    @Test("Listing returns the learner's marks oldest first with their notes")
    func listReturnsMarksInReadingOrder() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)

        _ = try store.createSourceHighlight(
            sourceID: sourceID,
            quote: "Retrieval practice beats rereading.",
            note: "Opening claim.",
            color: nil
        )
        _ = try store.createSourceHighlight(
            sourceID: sourceID,
            quote: "Spacing compounds that effect.",
            note: nil,
            color: "blue"
        )

        let listed = try json(try store.listSourceHighlights(sourceID: sourceID))
        #expect(listed["source_id"] as? String == sourceID)
        #expect(listed["title"] as? String == "Retrieval Practice")
        #expect(listed["highlight_count"] as? Int == 2)
        let highlights = try #require(listed["highlights"] as? [[String: Any]])
        #expect(highlights.first?["quote"] as? String == "Retrieval practice beats rereading.")
        #expect(highlights.first?["note"] as? String == "Opening claim.")
        #expect(highlights.last?["color"] as? String == "blue")
        #expect(highlights.last?["note"] as? String == "")
    }

    @Test("An empty library reports no marks rather than failing")
    func listOnUnmarkedSource() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)

        let listed = try json(try store.listSourceHighlights(sourceID: sourceID))
        #expect(listed["highlight_count"] as? Int == 0)
        #expect((listed["highlights"] as? [[String: Any]])?.isEmpty == true)
        #expect((listed["guidance"] as? String)?.contains("create_source_highlight") == true)
    }

    @Test("An unknown source is reported as missing")
    func listRejectsUnknownSource() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }

        #expect(throws: MCPError.self) {
            try store.listSourceHighlights(sourceID: "no-such-source-identifier")
        }
    }

    @Test("Search matches passage text and note text across sources")
    func searchSpansTheLibrary() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let firstID = try seedArticle(in: store)
        let secondID = try seedArticle(
            in: store,
            url: "https://example.com/spacing",
            title: "Spacing Effects",
            content: "Interleaving forces the learner to choose a strategy, not just execute one."
        )

        _ = try store.createSourceHighlight(
            sourceID: firstID,
            quote: "Spacing compounds that effect.",
            note: "Ties back to the interleaving argument.",
            color: nil
        )
        _ = try store.createSourceHighlight(
            sourceID: secondID,
            quote: "Interleaving forces the learner to choose a strategy",
            note: nil,
            color: nil
        )

        let all = try json(try store.searchSourceHighlights(query: nil, limit: nil))
        #expect(all["highlight_count"] as? Int == 2)

        let matched = try json(try store.searchSourceHighlights(query: "interleaving", limit: nil))
        // One matches in the passage, the other in the learner's own note.
        #expect(matched["highlight_count"] as? Int == 2)
        let sourceTitles = Set((matched["highlights"] as? [[String: Any]] ?? []).compactMap {
            $0["source_title"] as? String
        })
        #expect(sourceTitles == ["Retrieval Practice", "Spacing Effects"])

        let unmatched = try json(try store.searchSourceHighlights(query: "photosynthesis", limit: nil))
        #expect(unmatched["highlight_count"] as? Int == 0)
    }

    @Test("Search keeps one marker color across the library, so the follow-ups can be listed")
    func searchFiltersByColor() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let firstID = try seedArticle(in: store)
        let secondID = try seedArticle(
            in: store,
            url: "https://example.com/spacing",
            title: "Spacing Effects",
            content: "Interleaving forces the learner to choose a strategy, not just execute one."
        )
        _ = try store.createSourceHighlight(sourceID: firstID, quote: "Spacing compounds that effect.", note: nil, color: "blue")
        _ = try store.createSourceHighlight(sourceID: secondID, quote: "Interleaving forces the learner to choose a strategy", note: nil, color: "blue")
        _ = try store.createSourceHighlight(sourceID: secondID, quote: "not just execute one", note: nil, color: "pink")
        _ = try store.createSourceHighlight(sourceID: firstID, quote: "Retrieval practice beats rereading.", note: nil, color: nil)

        let followUps = try json(try store.searchSourceHighlights(query: nil, limit: nil, color: "blue"))
        #expect(followUps["highlight_count"] as? Int == 2)
        #expect(followUps["color"] as? String == "blue")
        let rows = try #require(followUps["highlights"] as? [[String: Any]])
        #expect(rows.allSatisfy { $0["color"] as? String == "blue" && $0["color_meaning"] as? String == "Follow up" })

        let doubts = try json(try store.searchSourceHighlights(query: nil, limit: nil, color: "Pink"))
        #expect(doubts["highlight_count"] as? Int == 1)

        // A color and a word narrow together.
        let both = try json(try store.searchSourceHighlights(query: "interleaving", limit: nil, color: "blue"))
        #expect(both["highlight_count"] as? Int == 1)

        // The default color is the one a mark written without a choice carries.
        let remembered = try json(try store.searchSourceHighlights(query: nil, limit: nil, color: "yellow"))
        #expect(remembered["highlight_count"] as? Int == 1)

        // No color, no narrowing; an unknown one is refused with the guide.
        let all = try json(try store.searchSourceHighlights(query: nil, limit: nil))
        #expect(all["highlight_count"] as? Int == 4)
        #expect(throws: (any Error).self) { _ = try store.searchSourceHighlights(query: nil, limit: nil, color: "red") }
    }

    @Test("A LIKE metacharacter in the query matches itself")
    func searchEscapesLikeMetacharacters() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)

        _ = try store.createSourceHighlight(
            sourceID: sourceID,
            quote: "Spacing compounds that effect.",
            note: "worth 100% of the grade",
            color: nil
        )

        #expect(try json(try store.searchSourceHighlights(query: "100%", limit: nil))["highlight_count"] as? Int == 1)
        // A bare wildcard must not behave as "match everything".
        #expect(try json(try store.searchSourceHighlights(query: "%z%", limit: nil))["highlight_count"] as? Int == 0)
    }

    @Test("Search honours its limit")
    func searchRespectsLimit() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)

        _ = try store.createSourceHighlight(
            sourceID: sourceID,
            quote: "Retrieval practice beats rereading.",
            note: nil,
            color: nil
        )
        _ = try store.createSourceHighlight(
            sourceID: sourceID,
            quote: "Spacing compounds that effect.",
            note: nil,
            color: nil
        )

        #expect(try json(try store.searchSourceHighlights(query: nil, limit: 1))["highlight_count"] as? Int == 1)
    }

    // MARK: Updating and deleting

    @Test("Updating rewrites the note and color and keeps the passage")
    func updateRewritesNote() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)

        let created = try json(try store.createSourceHighlight(
            sourceID: sourceID,
            quote: "Spacing compounds that effect.",
            note: "first pass",
            color: nil
        ))
        let highlightID = try #require((created["highlight"] as? [String: Any])?["highlight_id"] as? String)
        let originalCreatedAt = try #require(try store.knowledgeStore().sourceHighlight(id: highlightID)).createdAt

        let updated = try json(try store.updateSourceHighlight(
            highlightID: highlightID,
            note: "second pass, with the mechanism",
            color: "purple"
        ))
        #expect(updated["status"] as? String == "updated")
        let stored = try #require(try store.knowledgeStore().sourceHighlight(id: highlightID))
        #expect(stored.note == "second pass, with the mechanism")
        #expect(stored.color == .purple)
        #expect(stored.quote == "Spacing compounds that effect.")
        // Editing a note must not reshuffle the notes list.
        #expect(stored.createdAt == originalCreatedAt)
    }

    @Test("An empty note clears it back to a bare highlight")
    func updateClearsNote() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)

        let created = try json(try store.createSourceHighlight(
            sourceID: sourceID,
            quote: "Spacing compounds that effect.",
            note: "temporary",
            color: nil
        ))
        let highlightID = try #require((created["highlight"] as? [String: Any])?["highlight_id"] as? String)

        _ = try store.updateSourceHighlight(highlightID: highlightID, note: "", color: nil)
        let stored = try #require(try store.knowledgeStore().sourceHighlight(id: highlightID))
        #expect(stored.note.isEmpty)
        #expect(!stored.hasNote)
    }

    @Test("An update with nothing to change is refused")
    func updateRequiresAField() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)

        let created = try json(try store.createSourceHighlight(
            sourceID: sourceID,
            quote: "Spacing compounds that effect.",
            note: nil,
            color: nil
        ))
        let highlightID = try #require((created["highlight"] as? [String: Any])?["highlight_id"] as? String)

        #expect(throws: MCPError.self) {
            try store.updateSourceHighlight(highlightID: highlightID, note: nil, color: nil)
        }
        #expect(throws: MCPError.self) {
            try store.updateSourceHighlight(highlightID: "hl_missing", note: "x", color: nil)
        }
    }

    @Test("Deleting removes the mark and reports what was removed")
    func deleteRemovesMark() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)

        let created = try json(try store.createSourceHighlight(
            sourceID: sourceID,
            quote: "Spacing compounds that effect.",
            note: "keep for now",
            color: nil
        ))
        let highlightID = try #require((created["highlight"] as? [String: Any])?["highlight_id"] as? String)

        let deleted = try json(try store.deleteSourceHighlight(highlightID: highlightID))
        #expect(deleted["status"] as? String == "deleted")
        #expect(deleted["quote"] as? String == "Spacing compounds that effect.")
        #expect(deleted["note"] as? String == "keep for now")
        #expect(try store.knowledgeStore().sourceHighlights(sourceID: sourceID).isEmpty)

        #expect(throws: MCPError.self) {
            try store.deleteSourceHighlight(highlightID: highlightID)
        }
    }

    // MARK: Dispatch

    @Test("Every highlight tool is reachable by name through the tool registry")
    func toolsDispatchByName() async throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)
        let registry = MCPToolRegistry(store: store)

        let created = try json(await registry.callTool(
            name: "create_source_highlight",
            arguments: [
                "source_id": sourceID,
                "quote": "Spacing compounds that effect.",
                "note": "From the registry.",
                "color": "pink",
            ],
            access: .internalFullAccess
        ))
        let highlightID = try #require((created["highlight"] as? [String: Any])?["highlight_id"] as? String)

        let listed = try json(await registry.callTool(
            name: "list_source_highlights",
            arguments: ["source_id": sourceID],
            access: .internalFullAccess
        ))
        #expect(listed["highlight_count"] as? Int == 1)

        let searched = try json(await registry.callTool(
            name: "search_source_highlights",
            arguments: ["query": "registry"],
            access: .internalFullAccess
        ))
        #expect(searched["highlight_count"] as? Int == 1)

        let updated = try json(await registry.callTool(
            name: "update_source_highlight",
            arguments: ["highlight_id": highlightID, "color": "purple"],
            access: .internalFullAccess
        ))
        #expect((updated["highlight"] as? [String: Any])?["color"] as? String == "purple")

        let deleted = try json(await registry.callTool(
            name: "delete_source_highlight",
            arguments: ["highlight_id": highlightID],
            access: .internalFullAccess
        ))
        #expect(deleted["status"] as? String == "deleted")

        // A refusal must arrive as an error rather than as a success-shaped body.
        let refused = await registry.callToolDetailed(
            name: "create_source_highlight",
            arguments: ["source_id": sourceID, "quote": "Interleaving beats blocked practice."],
            access: .internalFullAccess
        )
        #expect(refused.isError)
        #expect(refused.text.contains("Copy the quote verbatim"))
    }

    // MARK: Sync

    @Test("Highlight writes stage CloudKit changes so other devices see them")
    func writesStageSyncChanges() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)

        let created = try json(try store.createSourceHighlight(
            sourceID: sourceID,
            quote: "Spacing compounds that effect.",
            note: "sync me",
            color: nil
        ))
        let highlightID = try #require((created["highlight"] as? [String: Any])?["highlight_id"] as? String)

        // A highlight save is deliberately withheld from `pendingSyncChanges`
        // until its parent source has been published to CloudKit, so the proof
        // that the write went through the tracked path is the staged change row.
        func stagedOperations() throws -> [String] {
            try store.withDB { db in
                try store.query(
                    db,
                    "SELECT operation FROM sync_changes WHERE entity_type = 'sourceHighlight' AND logical_key = ?",
                    params: [highlightID]
                ).compactMap { $0["operation"] as? String }
            }
        }
        #expect(try stagedOperations() == ["save"])

        _ = try store.deleteSourceHighlight(highlightID: highlightID)
        #expect(try stagedOperations() == ["delete"])
    }

    // MARK: Marks another app made on a PDF

    private static let firstLine = "Retrieval practice beats rereading."
    private static let secondLine = "Spacing compounds that effect."

    /// A one-page PDF of two lines, and where each line sits on the page.
    private func makeTwoLinePDF() throws -> (document: PDFDocument, first: CGRect, second: CGRect) {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 420, height: 640)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSString(string: "\(Self.firstLine)\n\n\(Self.secondLine)").draw(
            in: CGRect(x: 36, y: 120, width: 340, height: 480),
            withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black]
        )
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()

        let document = try #require(PDFDocument(data: data as Data))
        let page = try #require(document.page(at: 0))
        let first = try #require(document.findString(Self.firstLine, withOptions: []).first).bounds(for: page)
        let second = try #require(document.findString(Self.secondLine, withOptions: []).first).bounds(for: page)
        return (document, first, second)
    }

    private func markupAnnotation(over rect: CGRect, contents: String?, color: NSColor) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
        // Relative to the bounds, as PDFKit keeps them.
        annotation.quadrilateralPoints = [
            NSValue(point: NSPoint(x: 0, y: rect.height)),
            NSValue(point: NSPoint(x: rect.width, y: rect.height)),
            NSValue(point: .zero),
            NSValue(point: NSPoint(x: rect.width, y: 0)),
        ]
        annotation.contents = contents
        annotation.color = color
        return annotation
    }

    @Test("Highlights and notes saved inside a PDF arrive as the paper's highlights, once")
    func importsMarksSavedInThePDF() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)

        let (document, first, second) = try makeTwoLinePDF()
        let page = try #require(document.page(at: 0))
        page.addAnnotation(markupAnnotation(
            over: first,
            contents: "The core claim",
            color: NSColor(srgbRed: 0.18, green: 0.66, blue: 0.9, alpha: 1)
        ))
        // Acrobat keeps a bare highlight's own words as its comment.
        page.addAnnotation(markupAnnotation(over: second, contents: Self.secondLine, color: .yellow))
        // A sticky note in the margin, level with the first line.
        let sticky = PDFAnnotation(
            bounds: CGRect(x: 384, y: first.midY - 10, width: 20, height: 20),
            forType: .text,
            withProperties: nil
        )
        sticky.contents = "Ask about the effect size"
        page.addAnnotation(sticky)
        // ForeverLM's own painted mark and a link are not another app's marks.
        let painted = markupAnnotation(over: second, contents: nil, color: .green)
        painted.userName = ReaderPDFHighlightSupport.annotationPrefix + "hl_painted"
        page.addAnnotation(painted)
        page.addAnnotation(PDFAnnotation(bounds: first, forType: .link, withProperties: nil))

        let pdfURL = URL(fileURLWithPath: path).appendingPathComponent("annotated.pdf")
        #expect(document.write(to: pdfURL))

        let answer = store.importDocumentMarks(sourceID: sourceID, pdfPath: pdfURL.path)
        #expect(answer.contains("Brought in 3 highlights and notes"))

        let highlights = try store.knowledgeStore().sourceHighlights(sourceID: sourceID)
        #expect(highlights.count == 3)
        let claim = try #require(highlights.first { $0.note == "The core claim" })
        #expect(ReaderTextAnchor.normalize(claim.quote).text == Self.firstLine)
        #expect(claim.color == .blue)
        #expect(claim.pdfAnchor?.pageIndex == 0)
        #expect(claim.id.hasPrefix("hl_"))
        let bare = try #require(highlights.first { ReaderTextAnchor.normalize($0.quote).text == Self.secondLine })
        #expect(bare.note.isEmpty)
        #expect(bare.color == .yellow)
        let pinned = try #require(highlights.first { $0.note == "Ask about the effect size" })
        #expect(ReaderTextAnchor.normalize(pinned.quote).text == Self.firstLine)

        // A second import of the same file adds nothing.
        #expect(store.importDocumentMarks(sourceID: sourceID, pdfPath: pdfURL.path).isEmpty)
        #expect(try store.knowledgeStore().sourceHighlights(sourceID: sourceID).count == 3)
    }

    @Test("A Zotero mark keeps its date and comment, and one over no words is left out")
    func convertsLibraryMarks() throws {
        let (document, first, _) = try makeTwoLinePDF()
        let created = Date(timeIntervalSince1970: 1_682_931_600)
        let marks = [
            ImportedPDFMark(
                kind: .passage,
                pageIndex: 0,
                rects: [first],
                text: Self.firstLine,
                comment: "From Zotero",
                color: .green,
                createdAt: created,
                originKey: "zotero:ANNOT001"
            ),
            ImportedPDFMark(
                kind: .passage,
                pageIndex: 0,
                rects: [CGRect(x: 36, y: 20, width: 200, height: 18)],
                text: nil,
                comment: "Over the blank foot of the page",
                color: .yellow,
                createdAt: created,
                originKey: "zotero:ANNOT002"
            ),
            ImportedPDFMark(
                kind: .passage,
                pageIndex: 7,
                rects: [first],
                text: Self.firstLine,
                comment: "",
                color: .yellow,
                createdAt: created,
                originKey: "zotero:ANNOT003"
            ),
        ]

        let highlights = ReaderPDFHighlightSupport.importedHighlights(marks, sourceID: "src_1", in: document)
        let highlight = try #require(highlights.first)
        #expect(highlights.count == 1)
        #expect(highlight.id == ReaderPDFHighlightSupport.importedHighlightID(sourceID: "src_1", originKey: "zotero:ANNOT001"))
        #expect(highlight.id != ReaderPDFHighlightSupport.importedHighlightID(sourceID: "src_2", originKey: "zotero:ANNOT001"))
        #expect(ReaderTextAnchor.normalize(highlight.quote).text == Self.firstLine)
        #expect(highlight.anchor.exact == highlight.quote)
        #expect(highlight.note == "From Zotero")
        #expect(highlight.color == .green)
        #expect(highlight.createdAt == created)
        #expect(highlight.pdfAnchor?.rects == [first])
    }

    // MARK: Linked chats (What's New)

    /// Saves a research chat about `sourceID` the way an assistant does, and
    /// returns its id. `marksReviewed` false: research is not a review.
    private func importResearchChat(in store: MCPDataStore, sourceID: String, title: String = "What's new since 2013") throws -> String {
        let response = try store.importReviewChat(
            title: title,
            transcript: "You: What has changed since this was written?\nAssistant: Reverse electron transport happens in living tissue (Chouchani, Nature 2014).",
            sourceIDs: [sourceID],
            summary: nil,
            overallScore: nil,
            modelProvider: "Claude",
            modelID: nil,
            marksReviewed: false
        )
        // The new chat's id is on its own `session_id:` line.
        guard let id = mcpAnswerValue("session_id", in: response) else {
            Issue.record("No session id in: \(response)")
            return ""
        }
        return id
    }

    @Test("A mark links the chat its note came from, and every listing says so")
    func createLinksNamedChat() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)
        let chatID = try importResearchChat(in: store, sourceID: sourceID)

        let created = try json(try store.createSourceHighlight(
            sourceID: sourceID,
            quote: "Spacing compounds that effect.",
            note: "Since 2013: still holds.",
            color: "blue",
            sessionID: chatID
        ))
        let payload = try #require(created["highlight"] as? [String: Any])
        #expect(payload["session_id"] as? String == chatID)
        #expect(payload["chat_title"] as? String == "What's new since 2013")
        let highlightID = try #require(payload["highlight_id"] as? String)
        #expect(try store.knowledgeStore().sourceHighlight(id: highlightID)?.chatSessionID == chatID)

        let listed = try json(try store.listSourceHighlights(sourceID: sourceID))
        let listedMark = try #require((listed["highlights"] as? [[String: Any]])?.first)
        #expect(listedMark["session_id"] as? String == chatID)

        let searched = try json(try store.searchSourceHighlights(query: "Spacing", limit: nil))
        let searchedMark = try #require((searched["highlights"] as? [[String: Any]])?.first)
        #expect(searchedMark["session_id"] as? String == chatID)
    }

    @Test("A chat link names the chat as its bare id does")
    func createAcceptsChatLink() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)
        let chatID = try importResearchChat(in: store, sourceID: sourceID)

        let created = try json(try store.createSourceHighlight(
            sourceID: sourceID,
            quote: "Spacing compounds that effect.",
            note: nil,
            color: nil,
            sessionID: StudioEntityLink.chat(chatID).markdownDestination
        ))
        let payload = try #require(created["highlight"] as? [String: Any])
        #expect(payload["session_id"] as? String == chatID)
    }

    @Test("A chat that does not exist is refused, and nothing is marked")
    func createRefusesUnknownChat() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)

        #expect(throws: MCPError.self) {
            try store.createSourceHighlight(
                sourceID: sourceID,
                quote: "Spacing compounds that effect.",
                note: "Since 2013: …",
                color: "blue",
                sessionID: "no-such-chat"
            )
        }
        #expect(try store.knowledgeStore().sourceHighlights(sourceID: sourceID).isEmpty)
    }

    @Test("A mark made from a chat inside ForeverLM links that chat")
    func createFromInAppChatLinksIt() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)
        let chatID = try importResearchChat(in: store, sourceID: sourceID)

        let created = try json(try store.createSourceHighlight(
            sourceID: sourceID,
            quote: "Spacing compounds that effect.",
            note: nil,
            color: nil,
            hostSessionID: chatID
        ))
        let payload = try #require(created["highlight"] as? [String: Any])
        #expect(payload["session_id"] as? String == chatID)

        // A host chat that is gone links nothing rather than failing the mark.
        let second = try json(try store.createSourceHighlight(
            sourceID: sourceID,
            quote: "Retrieval practice beats rereading.",
            note: nil,
            color: nil,
            hostSessionID: "deleted-chat"
        ))
        #expect((second["highlight"] as? [String: Any])?["session_id"] == nil)
    }

    @Test("update_source_highlight links a chat, unlinks it with an empty session_id, and leaves the note alone")
    func updateLinksAndUnlinksChat() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)
        let chatID = try importResearchChat(in: store, sourceID: sourceID)
        let created = try json(try store.createSourceHighlight(
            sourceID: sourceID,
            quote: "Spacing compounds that effect.",
            note: "My own note.",
            color: "green"
        ))
        let highlightID = try #require((created["highlight"] as? [String: Any])?["highlight_id"] as? String)

        let linked = try json(try store.updateSourceHighlight(highlightID: highlightID, note: nil, color: nil, sessionID: chatID))
        #expect((linked["highlight"] as? [String: Any])?["session_id"] as? String == chatID)
        var stored = try #require(try store.knowledgeStore().sourceHighlight(id: highlightID))
        #expect(stored.chatSessionID == chatID)
        #expect(stored.note == "My own note.")
        #expect(stored.color == .green)

        _ = try store.updateSourceHighlight(highlightID: highlightID, note: nil, color: nil, sessionID: "")
        stored = try #require(try store.knowledgeStore().sourceHighlight(id: highlightID))
        #expect(stored.chatSessionID == nil)
        #expect(stored.note == "My own note.")

        #expect(throws: MCPError.self) {
            try store.updateSourceHighlight(highlightID: highlightID, note: nil, color: nil, sessionID: "no-such-chat")
        }
    }

    @Test("A research chat saved with mark_reviewed false leaves the Schedule alone; a review still checks its sources off")
    func researchChatLeavesScheduleAlone() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let researched = try seedArticle(in: store)
        let reviewed = try seedArticle(in: store, url: "https://example.com/reviewed", title: "Reviewed")

        let research = try store.importReviewChat(
            title: "What's new",
            transcript: "You: What changed?\nAssistant: A lot.",
            sourceIDs: [researched],
            summary: nil,
            overallScore: nil,
            modelProvider: nil,
            modelID: nil,
            marksReviewed: false
        )
        #expect(research.contains("without marking them reviewed"))
        #expect(!(try store.knowledgeStore().loadScheduledSources().contains { $0.placement.sourceID == researched }))

        _ = try store.importReviewChat(
            title: "Review",
            transcript: "Assistant: What is spacing?\nYou: Sessions apart beat sessions together.",
            sourceIDs: [reviewed],
            summary: nil,
            overallScore: nil,
            modelProvider: nil,
            modelID: nil
        )
        #expect(try store.knowledgeStore().loadScheduledSources().contains { $0.placement.sourceID == reviewed })
    }

    private func importedSessionID(in result: String) throws -> String {
        // The new chat's id is on its own `session_id:` line.
        try #require(mcpAnswerValue("session_id", in: result))
    }

    @Test("A chat saved with mark_reviewed false keeps the sources a later call links unreviewed, unless that call asks")
    func unreviewedChatStaysUnreviewedWhenSourcesAreAdded() throws {
        // 2026-09-28: a chat imported with mark_reviewed false had seven
        // sources linked by later calls with session_id, and every one came
        // back reviewed, placed on the Schedule done and stamped read.
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let first = try seedArticle(in: store, url: "https://example.com/first", title: "First")
        let added = try seedArticle(in: store, url: "https://example.com/added", title: "Added")
        let asked = try seedArticle(in: store, url: "https://example.com/asked", title: "Asked")
        let knowledge = try store.knowledgeStore()

        let opened = try store.importReviewChat(
            title: "What changed",
            transcript: "You: What changed?\nAssistant: A lot.",
            sourceIDs: [first],
            summary: nil,
            overallScore: nil,
            modelProvider: nil,
            modelID: nil,
            marksReviewed: false
        )
        let sessionID = try importedSessionID(in: opened)
        #expect(try knowledge.loadReviewSessionKind(sessionID: sessionID) == .chat, "the choice is kept on the chat")

        let appended = try store.importReviewChat(
            title: "",
            transcript: "You: And since then?\nAssistant: More again.",
            sourceIDs: [added],
            summary: nil,
            overallScore: nil,
            modelProvider: nil,
            modelID: nil,
            sessionID: sessionID
        )
        #expect(appended.contains("1 more source linked, without marking it reviewed"))
        #expect(try knowledge.loadReviewSessionForSync(sessionID)?.sourceIDs.contains(added) == true, "the source is still linked")
        #expect(!(try knowledge.loadScheduledSources().contains { $0.placement.sourceID == added }))
        #expect(try knowledge.loadSourceActivityDays(sourceID: added).isEmpty)
        #expect(try knowledge.loadSourceProgress(sourceID: added)?.readAt == nil)

        // A call that says the new source was reviewed still marks it.
        let reviewed = try store.importReviewChat(
            title: "",
            transcript: "Assistant: Explain it back?\nYou: Retrieval beats rereading.",
            sourceIDs: [asked],
            summary: nil,
            overallScore: nil,
            modelProvider: nil,
            modelID: nil,
            sessionID: sessionID,
            marksReviewed: true
        )
        #expect(reviewed.contains("1 more source linked, now counted as reviewed"))
        #expect(try knowledge.loadScheduledSources().contains { $0.placement.sourceID == asked && $0.placement.completedAt != nil })
    }

    @Test("A chat with no kind reads as the review its first import defaulted to, until a call says it is not one")
    func chatWithoutAKindLearnsItIsNotAReview() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let first = try seedArticle(in: store, url: "https://example.com/first", title: "First")
        let between = try seedArticle(in: store, url: "https://example.com/between", title: "Between")
        let declined = try seedArticle(in: store, url: "https://example.com/declined", title: "Declined")
        let after = try seedArticle(in: store, url: "https://example.com/after", title: "After")
        let knowledge = try store.knowledgeStore()

        let opened = try store.importReviewChat(
            title: "Review",
            transcript: "Assistant: What is spacing?\nYou: Sessions apart beat sessions together.",
            sourceIDs: [first],
            summary: nil,
            overallScore: nil,
            modelProvider: nil,
            modelID: nil
        )
        let sessionID = try importedSessionID(in: opened)
        #expect(try knowledge.loadReviewSessionKind(sessionID: sessionID) == nil, "a review import writes no kind, as before")

        // A review keeps reviewing what later calls add.
        _ = try store.importReviewChat(
            title: "", transcript: "Assistant: And interleaving?\nYou: Mixing problem types.",
            sourceIDs: [between], summary: nil, overallScore: nil, modelProvider: nil, modelID: nil,
            sessionID: sessionID
        )
        #expect(try knowledge.loadScheduledSources().contains { $0.placement.sourceID == between && $0.placement.completedAt != nil })

        // One call saying otherwise is remembered for the calls after it.
        let notReviewed = try store.importReviewChat(
            title: "", transcript: "You: Something else entirely.\nAssistant: Sure.",
            sourceIDs: [declined], summary: nil, overallScore: nil, modelProvider: nil, modelID: nil,
            sessionID: sessionID, marksReviewed: false
        )
        #expect(notReviewed.contains("without marking it reviewed"))
        // The chat's own `marks_reviewed` remembers it (§3.5.13).
        #expect(try knowledge.chatMarksReviewed(sessionID: sessionID) == false)
        let later = try store.importReviewChat(
            title: "", transcript: "You: One more thing.\nAssistant: Go on.",
            sourceIDs: [after], summary: nil, overallScore: nil, modelProvider: nil, modelID: nil,
            sessionID: sessionID
        )
        #expect(later.contains("without marking it reviewed"))
        let placed = Set(try knowledge.loadScheduledSources().map(\.placement.sourceID))
        #expect(!placed.contains(declined) && !placed.contains(after))
        #expect(try knowledge.loadSourceProgress(sourceID: after)?.readAt == nil)
    }

    // MARK: The link on the record

    @Test("A mark's chat rides the synced record, and a mark without one encodes as before")
    func chatLinkRoundTripsThroughSyncPayload() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var highlight = SourceHighlight(
            id: "hl_link",
            sourceID: "src_1",
            quote: "RET does not occur in intact mammalian cells.",
            note: "Since 2013: it does.",
            color: .blue,
            anchor: ReaderTextAnchor(exact: "RET does not occur in intact mammalian cells."),
            pdfAnchor: nil,
            chatSessionID: "chat-1",
            createdAt: now,
            updatedAt: now
        )
        let encoded = try JSONEncoder().encode(CloudKitSourceHighlightPayload(highlight: highlight, sourceIdentity: nil))
        let decoded = try JSONDecoder().decode(CloudKitSourceHighlightPayload.self, from: encoded)
        #expect(decoded.highlight.chatSessionID == "chat-1")

        highlight.chatSessionID = nil
        let bare = try JSONEncoder().encode(highlight)
        let object = try #require(try JSONSerialization.jsonObject(with: bare) as? [String: Any])
        #expect(object["chatSessionID"] == nil, "a mark with no chat keeps its old record shape")
        #expect(try JSONDecoder().decode(SourceHighlight.self, from: bare).chatSessionID == nil)

        // A record from a build that predates the field decodes as unlinked.
        let blank = SourceHighlight(
            id: "hl_blank", sourceID: "src_1", quote: "x", note: "", color: .yellow,
            anchor: ReaderTextAnchor(exact: "x"), pdfAnchor: nil, createdAt: now, updatedAt: now
        )
        #expect(try JSONDecoder().decode(SourceHighlight.self, from: JSONEncoder().encode(blank)).chatSessionID == nil)
    }

    @Test("The store keeps a mark's chat through saves, links and inbound records")
    func storeKeepsChatLink() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let sourceID = try seedArticle(in: store)
        let knowledge = try store.knowledgeStore()
        let now = Date()
        var highlight = SourceHighlight(
            id: SourceHighlight.newID(),
            sourceID: sourceID,
            quote: "Spacing compounds that effect.",
            note: "",
            color: .yellow,
            anchor: ReaderTextAnchor(exact: "Spacing compounds that effect."),
            pdfAnchor: nil,
            createdAt: now,
            updatedAt: now
        )
        try knowledge.saveSourceHighlight(highlight)
        #expect(try knowledge.sourceHighlight(id: highlight.id)?.chatSessionID == nil)

        let linked = try #require(try knowledge.linkSourceHighlight(id: highlight.id, toChat: "chat-7"))
        #expect(linked.chatSessionID == "chat-7")
        // A note written later, from the loaded mark, keeps the link.
        highlight = try #require(try knowledge.sourceHighlight(id: highlight.id))
        highlight.note = "Since 2013: …"
        try knowledge.saveSourceHighlight(highlight)
        #expect(try knowledge.sourceHighlights(sourceID: sourceID).first?.chatSessionID == "chat-7")
        #expect(try knowledge.sourceHighlights(sourceIDs: [sourceID])[sourceID]?.first?.chatSessionID == "chat-7")

        // What another Mac sends replaces it, link and all.
        var incoming = highlight
        incoming.chatSessionID = "chat-8"
        try knowledge.saveSourceHighlightRecord(CloudKitSourceHighlightPayload(highlight: incoming, sourceIdentity: nil))
        #expect(try knowledge.sourceHighlight(id: highlight.id)?.chatSessionID == "chat-8")

        try knowledge.linkSourceHighlight(id: highlight.id, toChat: nil)
        #expect(try knowledge.sourceHighlight(id: highlight.id)?.chatSessionID == nil)
        #expect(try knowledge.linkSourceHighlight(id: "hl_missing", toChat: "chat-7") == nil)
    }

    @Test("Deep Research carries the highlight tools; the study kinds do not")
    func deepResearchCarriesHighlightTools() {
        for tool in ["list_source_highlights", "create_source_highlight", "update_source_highlight"] {
            #expect(ReviewSessionManager.deepResearchExtraToolNames.contains(tool))
            #expect(!ReviewSessionManager.studySurfaceToolNames.contains(tool))
        }
    }

    @Test("A What's New request sends its steps after the passage, which the chat still reads back")
    func researchRequestContext() throws {
        let request = ReaderSelectionExplanationRequest(
            sourceID: "src_ch12",
            selectedText: "12.2.2 Oocytes and generational quality control",
            researchUpdate: ReaderResearchUpdate(
                highlightID: "hl_1",
                sourceDescription: "\"Chapter 12\", a chapter of Bioenergetics, 4th edition"
            )
        )
        let context = request.contextualContent(fallbackTitle: "Chapter 12")
        #expect(context.contains("What's New request."))
        #expect(context.contains("highlight_id hl_1"))
        #expect(context.contains("update_source_highlight"))
        #expect(context.contains("references"))
        #expect(context.contains("a chapter of Bioenergetics, 4th edition"))
        let passage = try #require(ChatPassageOrigin.parse(contextContent: context))
        #expect(passage.quote == "12.2.2 Oocytes and generational quality control")
        #expect(passage.sourceID == "src_ch12")
        #expect(request.isReaderSelection)
        // A plain selection carries no steps.
        #expect(!ReaderSelectionExplanationRequest(sourceID: "src_ch12", selectedText: "x")
            .contextualContent().contains("What's New request."))
    }
}

/// The papers a mark's note cites (schema 140): what a writer supplies, how
/// it is kept, and what the tools report.
@Suite("Highlight cited papers")
struct HighlightReferenceTests {
    private func makeStore() throws -> (MCPDataStore, String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_highlight_refs_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MCPDataStore(dbPath: directory.appendingPathComponent("knowledge.db").path)
        _ = try store.knowledgeStore()
        return (store, directory.path)
    }

    private func seedArticle(in store: MCPDataStore, url: String) throws -> String {
        _ = try store.addSource(
            url: url,
            title: "Retrieval Practice",
            sourceType: "article",
            content: "Retrieval practice beats rereading. Spacing compounds that effect.",
            parentGroup: nil,
            author: nil
        )
        let knowledge = try store.knowledgeStore()
        let existing = knowledge.sourceExistsByNormalizedURL(URLNormalizer.normalize(url)) ?? knowledge.sourceExistsByURL(url)
        return try #require(existing).id
    }

    private func json(_ raw: String) throws -> [String: Any] {
        let data = try #require(raw.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("A DOI is kept as its doi.org link however it is written, and an address as given")
    func makeNormalizesDOIs() {
        let link = "https://doi.org/10.1073/pnas.1320692111"
        #expect(SourceHighlightReference.make(citation: "Vozza et al., PNAS 2014", doi: "10.1073/pnas.1320692111")?.url == link)
        #expect(SourceHighlightReference.make(citation: "Vozza", doi: "doi:10.1073/pnas.1320692111")?.url == link)
        #expect(SourceHighlightReference.make(citation: "Vozza", doi: "https://dx.doi.org/10.1073/pnas.1320692111")?.url == link)
        #expect(SourceHighlightReference.make(citation: "Vozza", url: "10.1073/pnas.1320692111")?.url == link)
        #expect(SourceHighlightReference.make(citation: "Vozza", url: "http://doi.org/10.1073/pnas.1320692111")?.url == link)
        #expect(SourceHighlightReference.make(citation: "Page", url: "https://www.nature.com/articles/nature13909")?.url
            == "https://www.nature.com/articles/nature13909")
        #expect(SourceHighlightReference.make(citation: "  Vozza  ", title: "  UCP2  ", doi: "10.1/x")?.citation == "Vozza")
        #expect(SourceHighlightReference.make(citation: "  Vozza  ", title: "  UCP2  ", doi: "10.1/x")?.title == "UCP2")
        // Nothing the reader could open, or no name for it.
        #expect(SourceHighlightReference.make(citation: "Vozza") == nil)
        #expect(SourceHighlightReference.make(citation: "Vozza", url: "ftp://example.com/x") == nil)
        #expect(SourceHighlightReference.make(citation: "Vozza", doi: "not a doi") == nil)
        #expect(SourceHighlightReference.make(citation: "   ", doi: "10.1/x") == nil)
    }

    @Test("Cited papers ride the record, and a mark without any encodes as before")
    func referencesRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let references = [
            SourceHighlightReference(citation: "Vozza et al., PNAS 2014", title: "UCP2 transports C4 metabolites", url: "https://doi.org/10.1073/pnas.1320692111"),
            SourceHighlightReference(citation: "Chouchani et al., Nature 2014", url: "https://doi.org/10.1038/nature13909"),
        ]
        var highlight = SourceHighlight(
            id: "hl_refs", sourceID: "src_1", quote: "x", note: "Since 2013: …", color: .blue,
            anchor: ReaderTextAnchor(exact: "x"), pdfAnchor: nil, references: references, createdAt: now, updatedAt: now
        )
        let encoded = try JSONEncoder().encode(CloudKitSourceHighlightPayload(highlight: highlight, sourceIdentity: nil))
        #expect(try JSONDecoder().decode(CloudKitSourceHighlightPayload.self, from: encoded).highlight.references == references)

        highlight.references = []
        let bare = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(highlight)) as? [String: Any])
        #expect(bare["references"] == nil, "a mark with no papers keeps its old record shape")

        #expect(SourceHighlightReference.storedJSON([]) == nil)
        #expect(SourceHighlightReference.references(storedJSON: SourceHighlightReference.storedJSON(references)) == references)
        #expect(SourceHighlightReference.references(storedJSON: nil).isEmpty)
        #expect(SourceHighlightReference.references(storedJSON: "not json").isEmpty)
    }

    @Test("The store keeps a mark's papers through saves and inbound records")
    func storeKeepsReferences() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sourceID = try seedArticle(in: store, url: "https://example.com/retrieval-practice")
        let knowledge = try store.knowledgeStore()
        let now = Date()
        let reference = SourceHighlightReference(citation: "Vozza et al., PNAS 2014", url: "https://doi.org/10.1073/pnas.1320692111")
        var highlight = SourceHighlight(
            id: SourceHighlight.newID(), sourceID: sourceID, quote: "Spacing compounds that effect.", note: "",
            color: .blue, anchor: ReaderTextAnchor(exact: "Spacing compounds that effect."), pdfAnchor: nil,
            references: [reference], createdAt: now, updatedAt: now
        )
        try knowledge.saveSourceHighlight(highlight)
        #expect(try knowledge.sourceHighlight(id: highlight.id)?.references == [reference])
        #expect(try knowledge.sourceHighlights(sourceIDs: [sourceID])[sourceID]?.first?.references == [reference])

        // Linking a chat later keeps the papers.
        try knowledge.linkSourceHighlight(id: highlight.id, toChat: "chat-1")
        #expect(try knowledge.sourceHighlight(id: highlight.id)?.references == [reference])

        highlight.references = []
        try knowledge.saveSourceHighlightRecord(CloudKitSourceHighlightPayload(highlight: highlight, sourceIdentity: nil))
        #expect(try knowledge.sourceHighlight(id: highlight.id)?.references.isEmpty == true)
    }

    @Test("create_source_highlight keeps the papers a note cites and says which the library holds")
    func createCitesPapers() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sourceID = try seedArticle(in: store, url: "https://example.com/retrieval-practice")

        let created = try json(try store.createSourceHighlight(
            sourceID: sourceID,
            quote: "Spacing compounds that effect.",
            note: "Since 2013: still holds (Vozza et al., PNAS 2014).",
            color: "blue",
            references: [
                ["citation": "Vozza et al., PNAS 2014", "doi": "10.1073/pnas.1320692111", "title": "UCP2 transports C4 metabolites"],
                ["citation": "Retrieval Practice", "url": "https://example.com/retrieval-practice"],
                ["citation": "Vozza again", "doi": "https://doi.org/10.1073/pnas.1320692111"],
            ] as [Any]
        ))
        let payload = try #require(created["highlight"] as? [String: Any])
        let references = try #require(payload["references"] as? [[String: Any]])
        #expect(references.count == 2, "a paper named twice is kept once")
        #expect(references[0]["url"] as? String == "https://doi.org/10.1073/pnas.1320692111")
        #expect(references[0]["title"] as? String == "UCP2 transports C4 metabolites")
        #expect(references[0]["source_id"] == nil)
        #expect(references[1]["source_id"] as? String == sourceID, "a paper the library holds names its source")

        let highlightID = try #require(payload["highlight_id"] as? String)
        #expect(try store.knowledgeStore().sourceHighlight(id: highlightID)?.references.count == 2)

        let searched = try json(try store.searchSourceHighlights(query: "Spacing", limit: nil))
        let mark = try #require((searched["highlights"] as? [[String: Any]])?.first)
        #expect((mark["references"] as? [[String: Any]])?.count == 2)
    }

    @Test("A paper with no DOI or address, too many papers, or a list that is not one is refused")
    func referencesAreValidated() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sourceID = try seedArticle(in: store, url: "https://example.com/retrieval-practice")

        #expect(throws: MCPError.self) {
            try store.createSourceHighlight(
                sourceID: sourceID, quote: "Spacing compounds that effect.", note: nil, color: nil,
                references: [["citation": "Vozza et al., PNAS 2014"]] as [Any]
            )
        }
        let tooMany: [Any] = (0...SourceHighlightReference.maximumPerMark).map {
            ["citation": "Paper \($0)", "doi": "10.1000/\($0)"]
        }
        #expect(throws: MCPError.self) {
            try store.createSourceHighlight(
                sourceID: sourceID, quote: "Spacing compounds that effect.", note: nil, color: nil, references: tooMany
            )
        }
        #expect(throws: MCPError.self) {
            try store.createSourceHighlight(
                sourceID: sourceID, quote: "Spacing compounds that effect.", note: nil, color: nil, references: "Vozza 2014"
            )
        }
        #expect(try store.knowledgeStore().sourceHighlights(sourceID: sourceID).isEmpty, "nothing is marked on a refusal")
    }

    @Test("update_source_highlight replaces the papers, clears them with an empty list, and leaves the note alone")
    func updateReplacesReferences() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sourceID = try seedArticle(in: store, url: "https://example.com/retrieval-practice")
        let created = try json(try store.createSourceHighlight(
            sourceID: sourceID, quote: "Spacing compounds that effect.", note: "My note.", color: "green"
        ))
        let highlightID = try #require((created["highlight"] as? [String: Any])?["highlight_id"] as? String)

        _ = try store.updateSourceHighlight(
            highlightID: highlightID, note: nil, color: nil,
            references: [["citation": "Chouchani et al., Nature 2014", "doi": "10.1038/nature13909"]] as [Any]
        )
        var stored = try #require(try store.knowledgeStore().sourceHighlight(id: highlightID))
        #expect(stored.references.map(\.url) == ["https://doi.org/10.1038/nature13909"])
        #expect(stored.note == "My note.")

        _ = try store.updateSourceHighlight(highlightID: highlightID, note: nil, color: nil, references: [] as [Any])
        stored = try #require(try store.knowledgeStore().sourceHighlight(id: highlightID))
        #expect(stored.references.isEmpty)
        #expect(stored.color == .green)
    }
}

/// Schema 141: a mark's since-publication update, kept apart from the
/// learner's note.
@Suite("Highlight since-publication update")
struct HighlightPublicationUpdateTests {
    private func makeStore() throws -> (MCPDataStore, String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_highlight_update_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MCPDataStore(dbPath: directory.appendingPathComponent("knowledge.db").path)
        _ = try store.knowledgeStore()
        return (store, directory.path)
    }

    private func seedArticle(in store: MCPDataStore) throws -> String {
        let url = "https://example.com/metformin"
        _ = try store.addSource(
            url: url,
            title: "Metformin",
            sourceType: "article",
            content: "High concentrations of metformin weakly inhibit complex I. Its mechanism is controversial.",
            parentGroup: nil,
            author: nil
        )
        let knowledge = try store.knowledgeStore()
        let existing = knowledge.sourceExistsByNormalizedURL(URLNormalizer.normalize(url)) ?? knowledge.sourceExistsByURL(url)
        return try #require(existing).id
    }

    private func json(_ raw: String) throws -> [String: Any] {
        let data = try #require(raw.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static let update = "The binding site is now known.\nMetformin sits in the quinone channel (Bridges et al., Science 2023)."

    @Test("create and update write the update beside the note, and never over it")
    func updateStandsBesideTheNote() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sourceID = try seedArticle(in: store)
        let created = try json(try store.createSourceHighlight(
            sourceID: sourceID, quote: "High concentrations of metformin weakly inhibit complex I.",
            note: "Check against the 2023 structure.", color: "blue",
            references: [["citation": "Bridges et al., Science 2023", "doi": "10.1126/science.ade3332"]] as [Any],
            publicationUpdate: Self.update
        ))
        let payload = try #require(created["highlight"] as? [String: Any])
        #expect(payload["note"] as? String == "Check against the 2023 structure.")
        #expect(payload["publication_update"] as? String == Self.update)
        #expect(payload["publication_update_at"] is String)
        let highlightID = try #require(payload["highlight_id"] as? String)

        var stored = try #require(try store.knowledgeStore().sourceHighlight(id: highlightID))
        #expect(stored.publicationUpdate == Self.update)
        #expect(stored.publicationUpdateAt != nil)

        // Revising the note leaves the update; revising the update leaves the note.
        _ = try store.updateSourceHighlight(highlightID: highlightID, note: "Mine.", color: nil)
        stored = try #require(try store.knowledgeStore().sourceHighlight(id: highlightID))
        #expect(stored.note == "Mine.")
        #expect(stored.publicationUpdate == Self.update)
        _ = try store.updateSourceHighlight(highlightID: highlightID, note: nil, color: nil, publicationUpdate: "Still holds.")
        stored = try #require(try store.knowledgeStore().sourceHighlight(id: highlightID))
        #expect(stored.note == "Mine.")
        #expect(stored.publicationUpdate == "Still holds.")

        let searched = try json(try store.searchSourceHighlights(query: "Still holds", limit: nil))
        let mark = try #require((searched["highlights"] as? [[String: Any]])?.first)
        #expect(mark["publication_update"] as? String == "Still holds.")
        #expect(mark["publication_update_at"] is String)

        // An empty update clears it and its stamp.
        _ = try store.updateSourceHighlight(highlightID: highlightID, note: nil, color: nil, publicationUpdate: "")
        stored = try #require(try store.knowledgeStore().sourceHighlight(id: highlightID))
        #expect(stored.publicationUpdate.isEmpty)
        #expect(stored.publicationUpdateAt == nil)
        #expect(stored.note == "Mine.")
        let listed = try json(try store.listSourceHighlights(sourceID: sourceID))
        #expect((listed["highlights"] as? [[String: Any]])?.first?["publication_update"] == nil)
    }

    @Test("An update past the limit is refused")
    func updateLengthIsLimited() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sourceID = try seedArticle(in: store)
        #expect(throws: MCPError.self) {
            try store.createSourceHighlight(
                sourceID: sourceID, quote: "Its mechanism is controversial.", note: nil, color: nil,
                publicationUpdate: String(repeating: "a", count: MCPDataStore.maxHighlightUpdateCharacters + 1)
            )
        }
    }

    @Test("The update rides the CloudKit payload, and a mark without one encodes as before")
    func payloadRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var mark = SourceHighlight(
            id: "hl-a", sourceID: "src-a", quote: "Passage", note: "", color: .blue,
            anchor: ReaderTextAnchor(exact: "Passage"), pdfAnchor: nil, createdAt: now, updatedAt: now
        )
        let bare = try JSONEncoder().encode(mark)
        #expect(!String(decoding: bare, as: UTF8.self).contains("publicationUpdate"))

        mark.setPublicationUpdate("Since then, more.", at: now)
        let decoded = try JSONDecoder().decode(SourceHighlight.self, from: try JSONEncoder().encode(mark))
        #expect(decoded.publicationUpdate == "Since then, more.")
        #expect(decoded.publicationUpdateAt == now)
        #expect(try JSONDecoder().decode(SourceHighlight.self, from: bare).publicationUpdate.isEmpty)
    }

    private func rendered(_ segments: [PublicationUpdateLayout.Segment]?) -> String? {
        segments?.map { segment -> String in
            switch segment {
            case .text(let words): return words
            case .citation(let number, let words): return (words ?? "") + "[\(number)]"
            }
        }.joined()
    }

    @Test("The first line is the headline, and bracketed citations become their numbers")
    func layout() {
        let references = [
            SourceHighlightReference(citation: "Bridges et al., Science 2023", url: "https://doi.org/10.1/a"),
            SourceHighlightReference(citation: "Yap et al., Nat Med 2023", url: "https://doi.org/10.1/b"),
        ]
        let split = PublicationUpdateLayout(
            update: "The binding site is now known.\nIt sits in the channel (Bridges et al., Science 2023). It failed (Yap et al., Nat Med 2023).",
            references: references
        )
        #expect(rendered(split.headline) == "The binding site is now known.")
        #expect(rendered(split.body) == "It sits in the channel[1]. It failed[2].")

        let grouped = PublicationUpdateLayout(
            update: "Since 2013: one paragraph (Bridges et al., Science 2023; Yap et al., Nat Med 2023), and more.",
            references: references
        )
        #expect(grouped.headline == nil, "one paragraph has no headline")
        #expect(rendered(grouped.body) == "Since 2013: one paragraph[1][2], and more.")

        let inSentence = PublicationUpdateLayout(
            update: "Bridges et al., Science 2023 showed it (cryo-EM, Yap et al., Nat Med 2023).",
            references: references
        )
        #expect(
            rendered(inSentence.body) == "Bridges et al., Science 2023[1] showed it (cryo-EM, Yap et al., Nat Med 2023[2]).",
            "a citation in the sentence keeps its words, and a bracket with more in it stays"
        )

        let uncited = PublicationUpdateLayout(update: "No papers named.", references: references)
        #expect(uncited.body == [.text("No papers named.")])
    }
}

/// Schemas 139, 140 and 141: `source_highlights.chat_session_id`,
/// `source_highlights.references_json`, and `publication_update` with
/// `publication_update_at`.
@Suite("Highlight chat link and papers schema")
struct HighlightChatLinkSchemaTests {
    private static func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func scalar(at root: URL, _ sql: String) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("knowledge.db").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        var value = -1
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW {
            value = Int(sqlite3_column_int64(statement, 0))
        }
        sqlite3_finalize(statement)
        return value
    }

    private static func source(id: String) -> StudioArticle {
        var article = StudioArticle(
            url: "https://example.com/\(id)", title: "Source \(id)", sourceType: .article,
            discoveryOrigin: .manual, id: id
        )
        article.domain = "example.com"
        article.content = "Readable text of source \(id), long enough to count."
        article.wordCount = 9
        article.state = .ready
        return article
    }

    private static func highlight(id: String, sourceID: String) -> SourceHighlight {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        return SourceHighlight(
            id: id, sourceID: sourceID, quote: "Readable text", note: "A note", color: .yellow,
            anchor: ReaderTextAnchor(exact: "Readable text"), pdfAnchor: nil, createdAt: now, updatedAt: now
        )
    }

    /// The released v138 shape: `source_highlights` without `chat_session_id`
    /// or `references_json`. Dropping the columns rather than lowering the
    /// stamp is what makes the forward steps actually run their ALTERs.
    private static func reshapeToVersion138(_ store: KnowledgeStore) throws {
        try store.execForTesting("DROP VIEW IF EXISTS source_projection")
        try dropPublicationUpdate(store)
        try store.execForTesting("ALTER TABLE source_highlights DROP COLUMN references_json")
        try store.execForTesting("ALTER TABLE source_highlights DROP COLUMN chat_session_id")
        try store.execForTesting("PRAGMA user_version = 138")
    }

    /// The v139 shape main carried for an hour: the chat link without papers.
    private static func reshapeToVersion139(_ store: KnowledgeStore) throws {
        try store.execForTesting("DROP VIEW IF EXISTS source_projection")
        try dropPublicationUpdate(store)
        try store.execForTesting("ALTER TABLE source_highlights DROP COLUMN references_json")
        try store.execForTesting("PRAGMA user_version = 139")
    }

    /// The v140 shape build 153 shipped: papers, and no update columns.
    private static func reshapeToVersion140(_ store: KnowledgeStore) throws {
        try store.execForTesting("DROP VIEW IF EXISTS source_projection")
        try dropPublicationUpdate(store)
        try store.execForTesting("PRAGMA user_version = 140")
    }

    private static func dropPublicationUpdate(_ store: KnowledgeStore) throws {
        try store.execForTesting("ALTER TABLE source_highlights DROP COLUMN publication_update_at")
        try store.execForTesting("ALTER TABLE source_highlights DROP COLUMN publication_update")
    }

    @Test("A production-sized library migrates in well under a second")
    func migrationCostDoesNotFollowTheLibrary() throws {
        let root = try Self.temporaryRoot("schema-v139-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try KnowledgeStore(storeDirectory: root)
            for index in 0..<3_000 {
                try store.saveSource(Self.source(id: "src-\(index)"))
            }
            for index in 0..<2_000 {
                try store.saveSourceHighlight(Self.highlight(id: "hl-\(index)", sourceID: "src-\(index)"))
            }
            try Self.reshapeToVersion138(store)
        }
        let started = Date()
        let migrated = try KnowledgeStore(storeDirectory: root)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 1, "took \(elapsed) s")
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM source_highlights") == 2_000)
        #expect(try migrated.loadActiveSources().count == 3_000, "sources stay visible")
    }
}

#endif
