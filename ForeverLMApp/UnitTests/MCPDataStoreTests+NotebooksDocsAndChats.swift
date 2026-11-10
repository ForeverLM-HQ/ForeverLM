// MCPDataStoreTests: registry exposure, Notebook artifacts, Docs, chats, meetings and linked pages.

import Testing
import AppKit
import Foundation
import PDFKit
import SQLite3
@testable import ForeverLM

#if os(macOS)

extension MCPDataStoreTests {
    @Test("semantic source search tool is exposed in MCP registry")
    func semanticSourceSearchToolIsRegistered() throws {
        let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "search_sources_semantic" })
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        #expect(properties["notebook_id"] != nil)
        #expect(properties["exclude_notebook_id"] != nil)
        #expect(properties["source_type"] != nil)
        // The advertised names carry the axis these filters are on. `date_from`
        // read as the source's own date, and models spent whole turns handing a
        // publication year to a filter on the day a source was saved.
        #expect(properties["added_from"] != nil)
        #expect(properties["added_to"] != nil)
        #expect(properties["date_from"] == nil)
        #expect(properties["date_to"] == nil)
        let required = try #require(tool.inputSchema["required"] as? [String])
        #expect(required.isEmpty)

        // A client holding the schema this tool shipped with keeps working.
        let legacy = MCPToolRegistry.searchAddedWindow(["date_from": "2026-08-01", "date_to": "2026-08-31"])
        #expect(legacy.from == "2026-08-01")
        #expect(legacy.to == "2026-08-31")
        let current = MCPToolRegistry.searchAddedWindow(["added_from": "2026-08-02", "date_from": "2026-08-01"])
        #expect(current.from == "2026-08-02")
        #expect(MCPToolRegistry.searchAddedWindow([:]).from == nil)
    }

    @Test("in-app tool schemas drop the caller-owned idempotency key")
    func inAppSchemasDropHostOwnedArguments() throws {
        let remoteNames = MCPToolRegistry.shared.tools.filter {
            ($0.inputSchema["properties"] as? [String: Any])?["operation_id"] != nil
        }.map(\.name)
        // The remote schema still offers it to clients with no session of their own.
        #expect(Set(remoteNames) == Set(["start_review_session", "memory_review"]))

        for tool in MCPToolRegistry.shared.tools {
            let properties = tool.inAppInputSchema["properties"] as? [String: Any] ?? [:]
            #expect(properties["operation_id"] == nil, "\(tool.name) still offers operation_id in-app")
            // Everything else is untouched, so the in-app schema is the remote one minus that key.
            let remoteProperties = tool.inputSchema["properties"] as? [String: Any] ?? [:]
            #expect(Set(properties.keys) == Set(remoteProperties.keys).subtracting(["operation_id"]))
        }
    }

    @Test("pre-generated source review guide tool is exposed with revision binding")
    func sourceReviewGuideToolIsRegistered() throws {
        let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "save_source_review_guide" })
        let required = try #require(tool.inputSchema["required"] as? [String])
        #expect(Set(required) == Set(["source_id", "content_sha256", "guide"]))
        #expect(MCPToolRegistry.annotations(for: tool.name)["readOnlyHint"] as? Bool == false)
        #expect(MCPToolRegistry.annotations(for: tool.name)["destructiveHint"] as? Bool == false)
        #expect(!MCPToolRegistry.isToolAllowed(tool.name, scope: .ingest))
    }

    @Test("MCP status tool is exposed first in MCP registry")
    func mcpStatusToolIsRegisteredFirst() {
        #expect(MCPToolRegistry.shared.tools.first?.name == "get_mcp_status")
    }

    @Test("MCP status tool returns active JSON")
    func mcpStatusToolReturnsActiveJSON() async throws {
        let result = await MCPToolRegistry.shared.callTool(name: "get_mcp_status", arguments: [:], access: .internalFullAccess)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])

        #expect(payload["status"] as? String == "active")
        #expect(payload["server"] as? String == "ForeverLM MCP")
        #expect(payload["tool_count"] as? Int == MCPToolRegistry.shared.tools.count)
        #expect((payload["message"] as? String)?.contains("responding to tool calls") == true)
        // Which iCloud account the library syncs with, for the gateway's web
        // identity check: the test host syncs with no iCloud, so no account.
        let account = try #require(payload["icloud_account"] as? [String: Any])
        #expect(account["syncs_with_icloud"] as? Bool == CloudRuntimeAvailability.isEnabled)
        #expect(account["environment"] as? String == CloudRuntimeAvailability.containerEnvironment.rawValue)
        if !CloudRuntimeAvailability.isEnabled { #expect(account["user_record_name"] == nil) }
    }

    @Test("MCP status names the iCloud account only when the Mac syncs with one and CloudKit said which")
    func mcpStatusICloudAccount() {
        let known = MCPDataStore.iCloudAccountStatus(syncs: true, userRecordName: "_0123abcd", environment: "production")
        #expect(known["syncs_with_icloud"] as? Bool == true)
        #expect(known["user_record_name"] as? String == "_0123abcd")
        #expect(known["environment"] as? String == "production")
        // Not known yet, or no iCloud at all: no name, which the gateway reads
        // as unverified and never as a match.
        #expect(MCPDataStore.iCloudAccountStatus(syncs: true, userRecordName: nil, environment: "production")["user_record_name"] == nil)
        #expect(MCPDataStore.iCloudAccountStatus(syncs: true, userRecordName: "", environment: "production")["user_record_name"] == nil)
        let signedOut = MCPDataStore.iCloudAccountStatus(syncs: false, userRecordName: "_stale", environment: "development")
        #expect(signedOut["syncs_with_icloud"] as? Bool == false)
        #expect(signedOut["user_record_name"] == nil)
        // The first lookup for an account can wait on CloudKit for seconds:
        // the call holds the store gate only for its index read, never for
        // that wait.
        #expect(MCPToolRegistry.selfGatedToolNames.contains("get_mcp_status"))
    }

    @Test("Notebook source tools are exposed in MCP registry")
    func notebookSourceToolsAreRegistered() {
        let toolNames = Set(MCPToolRegistry.shared.tools.map(\.name))
        #expect(toolNames.contains("list_notebooks"))
        #expect(toolNames.contains("create_notebook"))
        #expect(toolNames.contains("get_notebook"))
        #expect(toolNames.contains("add_notebook_sources"))
        #expect(toolNames.contains("list_notebook_sources"))
        #expect(toolNames.contains("reorder_notebook_sources"))
        #expect(toolNames.contains("set_notebook_source_selection"))
        #expect(toolNames.contains("get_notebook_context"))
        #expect(toolNames.contains("list_notebook_files"))
        #expect(toolNames.contains("read_notebook_markdown_file"))
        #expect(toolNames.contains("write_notebook_markdown_file"))
        #expect(toolNames.contains("list_docs"))
        #expect(toolNames.contains("create_doc"))
        #expect(toolNames.contains("read_doc"))
        #expect(toolNames.contains("write_doc"))
        #expect(toolNames.contains("edit_doc"))
        #expect(toolNames.contains("update_doc"))
        #expect(toolNames.contains("delete_doc"))
        #expect(toolNames.contains("link_page"))
        #expect(toolNames.contains("unlink_page"))
        #expect(toolNames.contains("link_google_doc"))
        #expect(toolNames.contains("unlink_google_doc"))
        #expect(toolNames.contains("publish_doc"))
        #expect(toolNames.contains("unpublish_doc"))
        // A chat asked to "make a site" makes a site, not a Doc (2026-09-09).
        #expect(toolNames.contains("save_site"))
        #expect(toolNames.contains("read_site_file"))
        // Lifecycle actions the UI had and MCP did not, closed 2026-09-05.
        #expect(toolNames.contains("update_review_session"))
        #expect(toolNames.contains("set_source_read"))
        #expect(toolNames.contains("merge_meeting_groups"))
        #expect(toolNames.contains("delete_meeting_group"))
        #expect(toolNames.contains("list_open_questions"))
        #expect(toolNames.contains("create_open_question"))
        #expect(toolNames.contains("update_open_question"))
        #expect(toolNames.contains("split_notebook"))
        #expect(toolNames.contains("merge_notebooks"))
        // The day is the Mac's Calendar (docs/planner-design.md); the Planner's
        // own tools went with it on 2026-09-30.
        for name in ["get_calendar_events", "create_calendar_event", "update_calendar_event", "delete_calendar_event", "get_day_activity", "get_day_settings", "set_day_settings"] {
            #expect(toolNames.contains(name), "\(name) is not registered")
        }
        for name in ["get_day_plan", "add_time_block", "update_time_block", "delete_time_block", "revise_day_plan", "update_day_plan", "get_planner_settings", "set_planner_settings"] {
            #expect(!toolNames.contains(name), "\(name) is still registered")
        }
        #expect(!toolNames.contains("set_notebook_slide_sources"))
        #expect(!toolNames.contains("list_notebook_slide_sources"))
        // Slide-specific notebook tools remain retired. Notebook-native Markdown
        // files and global artifacts provide the two editable document surfaces.
        #expect(!toolNames.contains("read_notebook_file"))
        // The notebook canvas tools stay retired; the only tools named for a
        // canvas are the Canvas's own (docs/sensemaking-design.md): reading
        // it, editing it on the learner's word (docs/knowledge-map-design.md),
        // and the learner's canvases in the Space ("Canvases in the Space").
        let canvasOwn = ["ask_canvas", "get_canvas_memory", "make_cards_from_canvas", "lint_canvas", "screenshot_canvas"]
            + MCPToolRegistry.canvasEditToolNames.filter { $0.contains("canvas") }
            + MCPToolRegistry.canvasCatalogToolNames
        #expect(toolNames.filter { $0.contains("canvas") }.sorted() == canvasOwn.sorted())
    }

    @Test("create_notebook stays open-ended and refuses a deadline before writing")
    func createNotebookCannotBecomeInvisibleGoal() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        let created = try await store.createNotebook(
            title: "Conference prep",
            description: nil,
            topic: nil,
            endDateString: "",
            sourceIDs: [],
            dailyTarget: nil,
            discover: false
        )
        let notebookID = try #require(createdNotebookID(in: created))
        let knowledge = try store.knowledgeStore()
        let notebook = try #require(try knowledge.loadLearningGoal(notebookID))
        #expect(notebook.isNotebook)
        #expect(try store.listNotebooks(includeCompleted: false).contains("Conference prep"))

        do {
            _ = try await store.createNotebook(
                title: "Timed notebook",
                description: nil,
                topic: nil,
                endDateString: "2099-12-31",
                sourceIDs: [],
                dailyTarget: nil,
                discover: false
            )
            Issue.record("create_notebook accepted a deadline and created a Goal")
        } catch {
            #expect(error.localizedDescription.contains("create_learning_goal"))
        }
        #expect(try knowledge.loadLearningGoals().allSatisfy { $0.title != "Timed notebook" })

        let createTool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "create_notebook" })
        let updateTool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "update_notebook" })
        let createProperties = try #require(createTool.inputSchema["properties"] as? [String: Any])
        let updateProperties = try #require(updateTool.inputSchema["properties"] as? [String: Any])
        #expect(createProperties["end_date"] == nil)
        #expect(updateProperties["end_date"] == nil)
        #expect(updateProperties["open_ended"] == nil)
    }

    @Test("MCP creates and revision-safely edits Notebook Markdown artifacts")
    func mcpEditsNotebookMarkdownArtifacts() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let notebook = try knowledge.createCompanionGoal(
            title: "Writing notebook",
            topic: "articles",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )

        let createdPayload = try parseJSON(try await store.writeNotebookMarkdownFile(
            notebookID: notebook.id,
            relativePath: "Article.md",
            markdown: "# Article\n\nFirst draft.",
            expectedRevision: nil
        ))
        let firstRevision = try #require(createdPayload["revision"] as? String)

        let listing = try parseJSON(try await store.listNotebookFiles(notebookID: notebook.id))
        let files = try #require(listing["files"] as? [[String: Any]])
        #expect(files.count == 1)
        #expect(files[0]["path"] as? String == "Article.md")
        #expect(files[0]["editable_markdown"] as? Bool == true)

        let readPayload = try parseJSON(try await store.readNotebookMarkdownFile(
            notebookID: notebook.id,
            relativePath: "Article.md"
        ))
        #expect(readPayload["markdown"] as? String == "# Article\n\nFirst draft.")
        #expect(readPayload["revision"] as? String == firstRevision)

        let updatedPayload = try parseJSON(try await store.writeNotebookMarkdownFile(
            notebookID: notebook.id,
            relativePath: "Article.md",
            markdown: "# Article\n\nRevised draft.",
            expectedRevision: firstRevision
        ))
        let secondRevision = try #require(updatedPayload["revision"] as? String)
        #expect(secondRevision != firstRevision)

        await #expect(throws: NotebookMarkdownFileError.self) {
            _ = try await store.writeNotebookMarkdownFile(
                notebookID: notebook.id,
                relativePath: "Article.md",
                markdown: "Stale overwrite",
                expectedRevision: firstRevision
            )
        }
    }

    @Test("MCP edits one canonical artifact across linked Notebooks")
    func mcpEditsGlobalArtifacts() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let first = try knowledge.createCompanionGoal(
            title: "Research",
            topic: "research",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        let second = try knowledge.createCompanionGoal(
            title: "Writing",
            topic: "writing",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )

        let created = try parseJSON(try await store.createArtifact(
            title: "Shared article",
            homeNotebookID: first.id,
            notebookIDs: [first.id, second.id],
            markdown: "# Shared\n\nFirst draft.",
            isDraft: true
        ))
        let artifactPayload = try #require(created["doc"] as? [String: Any])
        let artifactID = try #require(artifactPayload["id"] as? String)
        let revision = try #require(created["revision"] as? String)
        #expect(artifactPayload["is_draft"] as? Bool == true)

        let secondListing = try parseJSON(try await store.listArtifacts(notebookID: second.id))
        #expect(secondListing["doc_count"] as? Int == 1)
        let saved = try parseJSON(try await store.writeArtifact(
            artifactID: artifactID,
            markdown: "# Shared\n\nRevised once.",
            expectedRevision: revision
        ))
        #expect((saved["revision"] as? String) != revision)
        let read = try parseJSON(try await store.readArtifact(artifactID: artifactID))
        #expect(read["markdown"] as? String == "# Shared\n\nRevised once.")
        #expect(read["is_complete"] as? Bool == true)
        let range = try parseJSON(try await store.readArtifact(
            artifactID: artifactID,
            start: 2,
            length: 6
        ))
        #expect(range["markdown"] as? String == "Shared")
        #expect(range["range_start"] as? Int == 2)
        #expect(range["range_end"] as? Int == 8)
        #expect(range["is_complete"] as? Bool == false)
        #expect(range["revision"] as? String == read["revision"] as? String)

        _ = try await store.updateArtifact(
            artifactID: artifactID,
            title: nil,
            homeNotebookID: nil,
            notebookIDs: [second.id],
            isDraft: false
        )
        let firstListing = try parseJSON(try await store.listArtifacts(notebookID: first.id))
        #expect(firstListing["doc_count"] as? Int == 0)
        let globalListing = try parseJSON(try await store.listArtifacts(notebookID: nil))
        #expect(globalListing["doc_count"] as? Int == 1)
        let globalArtifacts = try #require(globalListing["docs"] as? [[String: Any]])
        #expect(globalArtifacts.first?["is_draft"] as? Bool == false)
        #expect(globalArtifacts.first?["is_archived"] as? Bool == false)
        #expect(globalArtifacts.first?["archived_at"] is NSNull)

        // Archive over MCP: the Doc stays listed with its links, marked and dated.
        let archived = try parseJSON(try await store.updateArtifact(
            artifactID: artifactID,
            title: nil,
            homeNotebookID: nil,
            notebookIDs: nil,
            isArchived: true
        ))
        let archivedDoc = try #require(archived["doc"] as? [String: Any])
        #expect(archivedDoc["is_archived"] as? Bool == true)
        #expect(archivedDoc["archived_at"] is String)
        #expect(archivedDoc["notebook_ids"] as? [String] == [second.id])
        let archivedListing = try parseJSON(try await store.listArtifacts(notebookID: second.id))
        #expect(archivedListing["doc_count"] as? Int == 1)

        let restored = try parseJSON(try await store.updateArtifact(
            artifactID: artifactID,
            title: nil,
            homeNotebookID: nil,
            notebookIDs: nil,
            isArchived: false
        ))
        let restoredDoc = try #require(restored["doc"] as? [String: Any])
        #expect(restoredDoc["is_archived"] as? Bool == false)
        #expect(restoredDoc["archived_at"] is NSNull)
        #expect(restoredDoc["is_hidden"] as? Bool == false)
        #expect(restoredDoc["hidden_at"] is NSNull)

        // Hide over MCP: this Mac's view only. The Doc stays listed with its
        // links, marked and dated, and its own date does not move — a call
        // that only hides never runs the record update.
        let hidden = try parseJSON(try await store.updateArtifact(
            artifactID: artifactID,
            title: nil,
            homeNotebookID: nil,
            notebookIDs: nil,
            isHidden: true
        ))
        let hiddenDoc = try #require(hidden["doc"] as? [String: Any])
        #expect(hiddenDoc["is_hidden"] as? Bool == true)
        #expect(hiddenDoc["hidden_at"] is String)
        #expect(hiddenDoc["is_archived"] as? Bool == false)
        #expect(hiddenDoc["updated_at"] as? String == restoredDoc["updated_at"] as? String)
        #expect(hiddenDoc["notebook_ids"] as? [String] == [second.id])
        let hiddenListing = try parseJSON(try await store.listArtifacts(notebookID: second.id))
        #expect(hiddenListing["doc_count"] as? Int == 1)

        let shown = try parseJSON(try await store.updateArtifact(
            artifactID: artifactID,
            title: nil,
            homeNotebookID: nil,
            notebookIDs: nil,
            isHidden: false
        ))
        let shownDoc = try #require(shown["doc"] as? [String: Any])
        #expect(shownDoc["is_hidden"] as? Bool == false)
        #expect(shownDoc["hidden_at"] is NSNull)
    }

    @Test("MCP moves a Doc to the Trash and removes a linked Google Doc from Docs")
    func mcpDeletesDocs() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let created = try parseJSON(try await store.createArtifact(
            title: "Working notes", homeNotebookID: nil, notebookIDs: [], markdown: "# Notes"
        ))
        let docID = try #require((created["doc"] as? [String: Any])?["id"] as? String)
        let url = try LinkedGoogleDoc.canonicalEditURL(from: "https://docs.google.com/document/d/1Del/edit")
        let linked = try await store.notebookFileStorage.createLinkedArtifact(
            url: url, title: "Shared plan", homeNotebookID: nil, linkedNotebookIDs: []
        )
        #expect(try parseJSON(try await store.listArtifacts(notebookID: nil))["doc_count"] as? Int == 2)

        let deleted = try parseJSON(try await store.deleteArtifact(artifactID: docID))
        #expect(deleted["status"] as? String == "deleted")
        #expect((deleted["message"] as? String)?.contains("Trash") == true)
        #expect((deleted["doc"] as? [String: Any])?["title"] as? String == "Working notes")

        // A linked doc is only taken out of Docs, and the answer says so.
        let removed = try parseJSON(try await store.deleteArtifact(artifactID: linked.id))
        #expect(removed["status"] as? String == "removed")
        #expect((removed["message"] as? String)?.contains("Google Doc itself was not touched") == true)

        #expect(try parseJSON(try await store.listArtifacts(notebookID: nil))["doc_count"] as? Int == 0)
        await #expect(throws: (any Error).self) { _ = try await store.readArtifact(artifactID: docID) }
        // Deleting what is already gone is a clear not-found, not a silent success.
        await #expect(throws: (any Error).self) { _ = try await store.deleteArtifact(artifactID: docID) }
        await #expect(throws: (any Error).self) { _ = try await store.deleteArtifact(artifactID: "  ") }
    }

    @Test("MCP links a Google Doc into Docs and unlinks it into a Markdown doc")
    func mcpLinksAndUnlinksGoogleDocs() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        await #expect(throws: (any Error).self) {
            _ = try await store.linkGoogleDocArtifact(
                urlString: "https://example.com/not-a-doc", title: nil, homeNotebookID: nil, notebookIDs: []
            )
        }

        let linked = try parseJSON(try await store.linkGoogleDocArtifact(
            urlString: "https://docs.google.com/document/d/1Lnk/edit?usp=sharing",
            title: nil, homeNotebookID: nil, notebookIDs: []
        ))
        #expect(linked["status"] as? String == "linked")
        let linkedDoc = try #require(linked["doc"] as? [String: Any])
        let docID = try #require(linkedDoc["id"] as? String)
        #expect(linkedDoc["kind"] as? String == "google_doc")
        #expect(linkedDoc["read_only"] as? Bool == true)
        #expect(linkedDoc["title"] as? String == LinkedGoogleDoc.placeholderTitle)
        #expect(linkedDoc["linked_url"] as? String == "https://docs.google.com/document/d/1Lnk/edit")

        // The same Google Doc, by another form of its link, is the same entry.
        let again = try parseJSON(try await store.linkGoogleDocArtifact(
            urlString: "https://docs.google.com/document/d/1Lnk/view", title: "Ignored", homeNotebookID: nil, notebookIDs: []
        ))
        #expect(again["status"] as? String == "already_linked")
        #expect((again["doc"] as? [String: Any])?["id"] as? String == docID)
        #expect(try parseJSON(try await store.listArtifacts(notebookID: nil))["doc_count"] as? Int == 1)

        // A passed title is kept.
        let titled = try parseJSON(try await store.linkGoogleDocArtifact(
            urlString: "https://docs.google.com/document/d/1Ttl/edit", title: "Q3 plan", homeNotebookID: nil, notebookIDs: []
        ))
        #expect((titled["doc"] as? [String: Any])?["title"] as? String == "Q3 plan")

        // Unlinking: the export becomes the editable body and write_doc works again.
        _ = try await store.notebookFileStorage.replaceLinkedArtifactExport(
            artifactID: docID, text: "Exported text."
        )
        let unlinked = try parseJSON(try await store.unlinkGoogleDocArtifact(artifactID: docID))
        #expect(unlinked["status"] as? String == "unlinked")
        let unlinkedDoc = try #require(unlinked["doc"] as? [String: Any])
        #expect(unlinkedDoc["kind"] as? String == "markdown")
        #expect(unlinkedDoc["read_only"] as? Bool == false)
        let revision = try #require(unlinked["revision"] as? String)
        let read = try parseJSON(try await store.readArtifact(artifactID: docID))
        #expect(read["markdown"] as? String == "Exported text.")
        #expect(read["revision"] as? String == revision)
        let saved = try parseJSON(try await store.writeArtifact(
            artifactID: docID, markdown: "# Mine now", expectedRevision: revision
        ))
        #expect((saved["revision"] as? String) != revision)
        // A Markdown doc cannot be unlinked.
        await #expect(throws: (any Error).self) { _ = try await store.unlinkGoogleDocArtifact(artifactID: docID) }
    }

    @Test("MCP links a Claude artifact and a Codex site, with an initial text copy, and reports their kinds")
    func mcpLinksClaudeArtifactsAndCodexSites() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        // Any other website, and a site on its own domain, is refused.
        await #expect(throws: (any Error).self) {
            _ = try await store.linkPageArtifact(
                urlString: "https://landscape.example.org/", title: nil, homeNotebookID: nil, notebookIDs: []
            )
        }
        await #expect(throws: (any Error).self) {
            _ = try await store.linkPageArtifact(
                urlString: "https://claude.ai/code/artifacts", title: nil, homeNotebookID: nil, notebookIDs: []
            )
        }

        // A Claude artifact, with the content the caller could read itself.
        let artifactURL = "https://claude.ai/code/artifact/a1b2c3d4-1e2f-4a5b-8c6d-7e8f9a0b1c2d"
        let linked = try parseJSON(try await store.linkPageArtifact(
            urlString: artifactURL + "?v=2",
            title: nil, text: "# Landscape\n\n\n\nFirst finding.  \n", homeNotebookID: nil, notebookIDs: []
        ))
        #expect(linked["status"] as? String == "linked")
        let doc = try #require(linked["doc"] as? [String: Any])
        let docID = try #require(doc["id"] as? String)
        #expect(doc["kind"] as? String == "claude_artifact")
        #expect(doc["read_only"] as? Bool == true)
        #expect(doc["title"] as? String == LinkedPageKind.claudeArtifact.placeholderTitle)
        #expect(doc["linked_url"] as? String == artifactURL)
        let read = try parseJSON(try await store.readArtifact(artifactID: docID))
        #expect(read["markdown"] as? String == "# Landscape\n\nFirst finding.")
        #expect(read["kind"] as? String == "claude_artifact")
        #expect((read["guidance"] as? String)?.contains("Claude Artifact") == true)
        // The same artifact by another form of its link is the same entry.
        let again = try parseJSON(try await store.linkPageArtifact(
            urlString: "claude.ai/code/artifact/A1B2C3D4-1E2F-4A5B-8C6D-7E8F9A0B1C2D#top",
            title: "Ignored", homeNotebookID: nil, notebookIDs: []
        ))
        #expect(again["status"] as? String == "already_linked")
        #expect((again["doc"] as? [String: Any])?["id"] as? String == docID)

        // A Codex site, with no copy yet.
        let site = try parseJSON(try await store.linkPageArtifact(
            urlString: "techbio-companies-landscape.learner-1234.chatgpt.site/?ref=x",
            title: nil, homeNotebookID: nil, notebookIDs: []
        ))
        let siteDoc = try #require(site["doc"] as? [String: Any])
        #expect(siteDoc["kind"] as? String == "codex_site")
        #expect(siteDoc["title"] as? String == "Codex Site")
        #expect(siteDoc["linked_url"] as? String == "https://techbio-companies-landscape.learner-1234.chatgpt.site/")
        #expect((site["message"] as? String)?.contains("read_doc returns an empty body") == true)
        let siteID = try #require(siteDoc["id"] as? String)
        let listed = try parseJSON(try await store.listArtifacts(notebookID: nil))
        let kinds = Set(((listed["docs"] as? [[String: Any]]) ?? []).compactMap { $0["kind"] as? String })
        #expect(kinds == ["claude_artifact", "codex_site"])

        // Neither can be edited or published here; both unlink into Markdown.
        // The refusal names the way a copy follows an edit made in the product.
        do {
            _ = try await store.writeArtifact(artifactID: docID, markdown: "x", expectedRevision: "")
            Issue.record("write_doc accepted a linked page")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("Claude Artifact"))
            #expect(message.contains("link_page"))
            #expect(message.contains("unlink_page"))
        }
        do {
            _ = try await store.editArtifact(
                artifactID: docID, edits: [.init(find: "First", replace: "Second")], append: nil, expectedRevision: ""
            )
            Issue.record("edit_doc accepted a linked page")
        } catch {
            #expect(error.localizedDescription.contains("link_page"))
        }
        // Linking the same page again with text is how the copy is refreshed
        // after the page changed where it lives.
        let refreshed = try parseJSON(try await store.linkPageArtifact(
            urlString: artifactURL, title: nil, text: "# Landscape\n\nSecond finding.", homeNotebookID: nil, notebookIDs: []
        ))
        #expect(refreshed["status"] as? String == "already_linked")
        #expect(refreshed["text_copy_refreshed"] as? Bool == true)
        let reread = try parseJSON(try await store.readArtifact(artifactID: docID))
        #expect(reread["markdown"] as? String == "# Landscape\n\nSecond finding.")
        let unchanged = try parseJSON(try await store.linkPageArtifact(
            urlString: artifactURL, title: nil, homeNotebookID: nil, notebookIDs: []
        ))
        #expect(unchanged["text_copy_refreshed"] as? Bool == false)
        #expect(try parseJSON(try await store.readArtifact(artifactID: docID))["markdown"] as? String == "# Landscape\n\nSecond finding.")
        let removed = try parseJSON(try await store.deleteArtifact(artifactID: siteID))
        #expect(removed["status"] as? String == "removed")
        #expect((removed["message"] as? String)?.contains("Codex Site itself was not touched") == true)
        let unlinked = try parseJSON(try await store.unlinkPageArtifact(artifactID: docID))
        #expect((unlinked["doc"] as? [String: Any])?["kind"] as? String == "markdown")
        #expect((unlinked["message"] as? String)?.contains("Claude Artifact itself was not touched") == true)
    }

    @Test("write_doc and edit_doc with publish save the Doc and say when there is no page to update")
    func mcpPublishFlagWithoutAPage() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let created = try parseJSON(try await store.createArtifact(
            title: "Landscape", homeNotebookID: nil, notebookIDs: [], markdown: "# Landscape\n\nDraft."
        ))
        let docID = try #require((created["doc"] as? [String: Any])?["id"] as? String)
        let revision = try #require(try parseJSON(try await store.readArtifact(artifactID: docID))["revision"] as? String)

        // Not signed in, so no page can be known: the body is saved and the
        // result says the page was not updated, without failing the write.
        let written = try parseJSON(try await store.writeArtifact(
            artifactID: docID, markdown: "# Landscape\n\nWritten.", expectedRevision: revision, publish: true
        ))
        #expect(written["page_updated"] as? Bool == false)
        #expect((written["guidance"] as? String)?.contains("publish_doc") == true)
        let revision2 = try #require(written["revision"] as? String)
        #expect(try parseJSON(try await store.readArtifact(artifactID: docID))["markdown"] as? String == "# Landscape\n\nWritten.")

        let edited = try parseJSON(try await store.editArtifact(
            artifactID: docID, edits: [.init(find: "Written.", replace: "Edited.")], append: nil,
            expectedRevision: revision2, publish: true
        ))
        #expect(edited["page_updated"] as? Bool == false)
        #expect(edited["replacements"] as? Int == 1)
        #expect(try parseJSON(try await store.readArtifact(artifactID: docID))["markdown"] as? String == "# Landscape\n\nEdited.")

        // Without the flag nothing about the result changes for an unpublished Doc.
        let revision3 = try #require(edited["revision"] as? String)
        let plain = try parseJSON(try await store.writeArtifact(
            artifactID: docID, markdown: "# Landscape\n\nPlain.", expectedRevision: revision3
        ))
        #expect(plain["page_updated"] == nil)
        #expect(plain["page_stale"] == nil)
    }

    @Test("A Doc write never saves a picture line the Doc cannot show, and an older such line never blocks an edit")
    func mcpDocWriteKeepsOnlyPicturesItCanShow() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let picture = "![Figure 1](foreverlm://image/src_missing/page/1)"

        // create_doc: refused, and no Doc is left behind.
        let before = try await store.notebookFileStorage.loadArtifacts(notebookID: nil).count
        do {
            _ = try await store.createArtifact(title: "Paper", homeNotebookID: nil, notebookIDs: [], markdown: "# Paper\n\n\(picture)\n")
            Issue.record("create_doc saved a picture it cannot show")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("Nothing was saved"))
            #expect(message.contains("foreverlm://image/src_missing/page/1: no source src_missing is in this library."))
        }
        #expect(try await store.notebookFileStorage.loadArtifacts(notebookID: nil).count == before)

        // write_doc: refused, body unchanged.
        let created = try parseJSON(try await store.createArtifact(
            title: "Paper", homeNotebookID: nil, notebookIDs: [], markdown: "# Paper\n\nText."
        ))
        let docID = try #require((created["doc"] as? [String: Any])?["id"] as? String)
        let revision = try #require(created["revision"] as? String)
        await #expect(throws: MCPError.self) {
            _ = try await store.writeArtifact(artifactID: docID, markdown: "# Paper\n\n\(picture)\n", expectedRevision: revision)
        }
        #expect(try parseJSON(try await store.readArtifact(artifactID: docID))["markdown"] as? String == "# Paper\n\nText.")

        // A line the Doc already carried — saved before Docs kept their
        // pictures — stays as it was while the rest of the Doc is edited.
        let legacy = try await store.notebookFileStorage.writeArtifactMarkdown(
            artifactID: docID, markdown: "# Paper\n\n\(picture)\n\nText.", expectedRevision: revision
        )
        let edited = try parseJSON(try await store.editArtifact(
            artifactID: docID, edits: [.init(find: "Text.", replace: "Edited.")], append: nil,
            expectedRevision: legacy.revision
        ))
        #expect(edited["replacements"] as? Int == 1)
        let notShown = try #require(edited["pictures_not_shown"] as? [[String: Any]])
        #expect(notShown.first?["address"] as? String == "foreverlm://image/src_missing/page/1")
        #expect(try parseJSON(try await store.readArtifact(artifactID: docID))["markdown"] as? String
            == "# Paper\n\n\(picture)\n\nEdited.")
    }

    @Test("MCP renames a chat and files it under a Notebook")
    func mcpUpdatesReviewSession() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let notebook = try knowledge.createCompanionGoal(
            title: "Metabolism", topic: "metabolism", startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt, dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
        let sessionID = "session-rename-\(UUID().uuidString)"
        try knowledge.saveReviewSessionRecord(
            CloudKitReviewSessionPayload(
                id: sessionID, topic: "Untitled chat", startedAt: Date(), endedAt: nil, status: "active",
                overallScore: nil, summary: nil, sourceIDs: [], cardIDs: [], exchangeCount: 0, goalID: nil,
                exchanges: [], sourceIdentities: []
            )
        )

        await #expect(throws: (any Error).self) {
            _ = try store.updateReviewSession(sessionID: sessionID, title: nil, notebookID: nil)
        }
        await #expect(throws: (any Error).self) {
            _ = try store.updateReviewSession(sessionID: sessionID, title: "   ", notebookID: nil)
        }
        await #expect(throws: (any Error).self) {
            _ = try store.updateReviewSession(sessionID: "missing-session", title: "X", notebookID: nil)
        }
        await #expect(throws: (any Error).self) {
            _ = try store.updateReviewSession(sessionID: sessionID, title: nil, notebookID: "no-such-notebook")
        }

        let renamed = try parseJSON(try store.updateReviewSession(
            sessionID: sessionID, title: "Mitochondria biotechs", notebookID: notebook.id
        ))
        #expect(renamed["title"] as? String == "Mitochondria biotechs")
        #expect(renamed["notebook_id"] as? String == notebook.id)
        let filed = try #require(try knowledge.loadReviewSessionForSync(sessionID))
        #expect(filed.topic == "Mitochondria biotechs")
        #expect(filed.goalID == notebook.id)

        // "" moves the chat out of every Notebook; the title is kept.
        let ungrouped = try parseJSON(try store.updateReviewSession(sessionID: sessionID, title: nil, notebookID: ""))
        #expect(ungrouped["notebook_id"] is NSNull)
        #expect(ungrouped["title"] as? String == "Mitochondria biotechs")
        #expect(ungrouped["is_hidden"] as? Bool == false)
        #expect(ungrouped["hidden_at"] is NSNull)
        #expect(try knowledge.loadReviewSessionForSync(sessionID)?.goalID == nil)
    }

    @Test("MCP hides a chat from the sidebar on every Mac and shows it again")
    func mcpHidesReviewSession() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let sessionID = "session-hide-\(UUID().uuidString)"
        let payload = CloudKitReviewSessionPayload(
            id: sessionID, topic: "Uncoupler pharmacology", startedAt: Date(), endedAt: nil, status: "active",
            overallScore: nil, summary: nil, sourceIDs: [], cardIDs: [], exchangeCount: 0, goalID: nil,
            exchanges: [], sourceIdentities: []
        )
        try knowledge.saveReviewSessionRecord(payload)

        // Hide over MCP: the row is marked and dated, nothing else about the
        // chat moves, and the chat itself is not republished — hiding is the
        // learner's view of the chat, not a record change. The hide travels
        // as a record of its own, so the learner's other Macs fold it too.
        let hidden = try parseJSON(try store.updateReviewSession(
            sessionID: sessionID, title: nil, notebookID: nil, isHidden: true
        ))
        #expect(hidden["is_hidden"] as? Bool == true)
        #expect(hidden["hidden_at"] is String)
        #expect(hidden["title"] as? String == "Uncoupler pharmacology")
        #expect((hidden["message"] as? String)?.contains("hidden from the sidebar") == true)
        let hiddenLink = try #require(try knowledge.loadReviewSessionLinks().first { $0.id == sessionID })
        #expect(hiddenLink.isHidden)
        let hiddenAt = try #require(hiddenLink.hiddenAt)
        // Still the learner's chat: the listing keeps it, marked, so an
        // assistant can find it and show it again.
        let listing = try store.getReviewSessions(topic: "Uncoupler")
        #expect(listing.contains("(id: \(sessionID))"))
        #expect(listing.contains("[hidden from the sidebar]"))

        // Re-hiding keeps the original date; a CloudKit merge of the same
        // chat leaves the learner's choice standing.
        _ = try store.updateReviewSession(sessionID: sessionID, title: nil, notebookID: nil, isHidden: true)
        try knowledge.saveReviewSessionRecord(payload)
        #expect(try knowledge.reviewSessionHiddenAt(sessionID: sessionID) == hiddenAt)

        // A rename while hidden keeps it hidden.
        let renamed = try parseJSON(try store.updateReviewSession(
            sessionID: sessionID, title: "Uncouplers", notebookID: nil
        ))
        #expect(renamed["title"] as? String == "Uncouplers")
        #expect(renamed["is_hidden"] as? Bool == true)

        let shown = try parseJSON(try store.updateReviewSession(
            sessionID: sessionID, title: nil, notebookID: nil, isHidden: false
        ))
        #expect(shown["is_hidden"] as? Bool == false)
        #expect(shown["hidden_at"] is NSNull)
        #expect(try knowledge.loadReviewSessionLinks().first { $0.id == sessionID }?.isHidden == false)
        #expect(!(try store.getReviewSessions(topic: "Uncouplers")).contains("[hidden"))
        // Showing it again tombstones the hide for the other Macs.

        // A hide of a chat that does not exist is refused, and is_hidden alone
        // is a complete request.
        await #expect(throws: (any Error).self) {
            _ = try store.updateReviewSession(sessionID: "missing-session", title: nil, notebookID: nil, isHidden: true)
        }
    }

    @Test("MCP marks a source read and unread, only where the app tracks it")
    func mcpSetsSourceRead() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        _ = try store.addSource(
            url: "https://example.com/read-me", title: "Read me", sourceType: "article",
            content: "Body", parentGroup: nil, author: nil
        )
        let articleID = try sourceID(in: store, url: "https://example.com/read-me")
        _ = try store.addSource(
            url: "https://example.com/podcast/1", title: "Episode", sourceType: "podcast",
            content: "Transcript", parentGroup: "Show", author: nil
        )
        let podcastID = try sourceID(in: store, url: "https://example.com/podcast/1")
        let knowledge = try store.knowledgeStore()

        let marked = try parseJSON(try store.setSourceRead(sourceID: articleID, read: true))
        #expect(marked["is_read"] as? Bool == true)
        #expect(marked["read_at"] is String)
        #expect(try knowledge.loadSourceForSync(articleID)?.readAt != nil)

        let cleared = try parseJSON(try store.setSourceRead(sourceID: articleID, read: false))
        #expect(cleared["is_read"] as? Bool == false)
        #expect(cleared["read_at"] is NSNull)
        #expect(try knowledge.loadSourceForSync(articleID)?.readAt == nil)

        // A podcast has no read state in the app, so the tool refuses rather
        // than stamping a field nothing shows.
        await #expect(throws: (any Error).self) { _ = try store.setSourceRead(sourceID: podcastID, read: true) }
        await #expect(throws: (any Error).self) { _ = try store.setSourceRead(sourceID: "missing", read: true) }
    }

    @Test("MCP marks a video not watched and watched, as the Sources sidebar does")
    func mcpSetsVideoWatched() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        var video = StudioArticle(
            url: "https://www.youtube.com/watch?v=mcp-watched",
            title: "Lecture",
            sourceType: .video,
            id: "mcp-watched-video"
        )
        video.readingPositionLocator = VideoWatchProgress(
            positionSeconds: 3500,
            watchedSeconds: 3550,
            durationSeconds: 3600
        ).encoded
        video.readAt = Date(timeIntervalSinceNow: -3600)
        try knowledge.saveSource(video)

        // read: false is Mark as Not Watched: the progress and the read stamp go.
        let cleared = try parseJSON(try store.setSourceRead(sourceID: video.id, read: false))
        #expect(cleared["status"] as? String == "updated")
        #expect(cleared["is_watched"] as? Bool == false)
        #expect(cleared["read_at"] is NSNull)
        let reloaded = try #require(try knowledge.loadSourceForSync(video.id))
        #expect(reloaded.readAt == nil)
        #expect(VideoWatchProgress.isUnwatchedMarker(reloaded.readingPositionLocator))

        let again = try parseJSON(try store.setSourceRead(sourceID: video.id, read: false))
        #expect(again["status"] as? String == "unchanged")

        // read: true is Mark as Watched, which the known length makes possible.
        let finished = try parseJSON(try store.setSourceRead(sourceID: video.id, read: true))
        #expect(finished["status"] as? String == "updated")
        #expect(finished["is_watched"] as? Bool == true)
        #expect(
            VideoWatchProgress(encoded: try knowledge.loadSourceReadingLocator(sourceID: video.id))?
                .isEssentiallyWatched == true
        )

        // A video that has never played has no length to finish it with.
        let unplayed = StudioArticle(
            url: "https://www.youtube.com/watch?v=mcp-unplayed",
            title: "Unplayed",
            sourceType: .video,
            id: "mcp-unplayed-video"
        )
        try knowledge.saveSource(unplayed)
        #expect(throws: (any Error).self) { _ = try store.setSourceRead(sourceID: unplayed.id, read: true) }
    }

    @Test("MCP merges meeting series and deletes one with its sessions")
    func mcpMergesAndDeletesMeetingGroups() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        try knowledge.saveMeetingGroup(name: "Lab Meeting", metadata: MeetingMetadata())
        try knowledge.saveMeetingGroup(name: "Lab meeting (old)", metadata: MeetingMetadata())
        try knowledge.saveMeetingGroup(name: "Journal Club", metadata: MeetingMetadata())
        _ = try store.addSource(
            url: "meeting://old/1", title: "Lab 2026-08-24", sourceType: "meeting",
            content: "Transcript one", parentGroup: "Lab meeting (old)", author: nil
        )
        _ = try store.addSource(
            url: "meeting://club/1", title: "Club 2026-08-25", sourceType: "meeting",
            content: "Transcript two", parentGroup: "Journal Club", author: nil
        )
        let oldSessionID = try sourceID(in: store, url: "meeting://old/1")
        let clubSessionID = try sourceID(in: store, url: "meeting://club/1")

        await #expect(throws: (any Error).self) {
            _ = try store.mergeMeetingGroups(sourceGroupID: "Lab meeting (old)", targetGroupID: "Lab meeting (old)")
        }
        await #expect(throws: (any Error).self) {
            _ = try store.mergeMeetingGroups(sourceGroupID: "Nope", targetGroupID: "Lab Meeting")
        }
        let merged = try parseJSON(try store.mergeMeetingGroups(
            sourceGroupID: "Lab meeting (old)", targetGroupID: "Lab Meeting"
        ))
        #expect(merged["status"] as? String == "merged")
        #expect(merged["sessions_moved"] as? Int == 1)
        #expect(merged["sessions_in_target"] as? Int == 1)
        #expect(try knowledge.loadSourceForSync(oldSessionID)?.parentGroup == "Lab Meeting")
        // The folded folder is gone from the list; its id still resolves.
        let groups = try parseJSON(try store.listMeetingGroups())
        let groupIDs = try #require(groups["meeting_groups"] as? [[String: Any]]).compactMap { $0["group_id"] as? String }
        #expect(groupIDs.contains("Lab Meeting"))
        #expect(!groupIDs.contains("Lab meeting (old)"))
        #expect(try knowledge.canonicalMeetingGroupID("Lab meeting (old)") == "Lab Meeting")

        let deleted = try parseJSON(try await store.deleteMeetingGroup(groupID: "Journal Club"))
        #expect(deleted["status"] as? String == "deleted")
        #expect(deleted["deleted_session_ids"] as? [String] == [clubSessionID])
        #expect(try knowledge.loadSourceForSync(clubSessionID) == nil)
        #expect(try knowledge.loadSourceForSync(oldSessionID) != nil)
        await #expect(throws: (any Error).self) { _ = try await store.deleteMeetingGroup(groupID: "Journal Club") }
    }

    @Test("MCP folds a series' same-day sessions into one, and answers nothing_to_merge the second time")
    func mcpMergesSameDayMeetingSessions() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let group = "Robin <> Zara standup"
        try knowledge.saveMeetingGroup(name: group, metadata: MeetingMetadata(title: group))

        // Filed the way import_meeting_transcript_files and the Zoom watcher
        // key a session: the start to the minute in the key, occurred_at set.
        let dayStart = try #require(DayPlan.startOfDay("2026-09-19"))
        func file(minutes: Int, text: String) throws -> String {
            let start = dayStart.addingTimeInterval(TimeInterval(minutes * 60))
            let key = StudioViewModel.readAISessionKey(title: group, date: start, includeTime: true)
            let url = "meeting://\(group)/\(StudioViewModel.percentEncodedMeetingPathComponent(key))"
            _ = try store.addSource(
                url: url, title: key, sourceType: "meeting", content: "# \(key)\n\n## Transcript\n\n\(text)",
                parentGroup: group, author: nil, occurredAt: MCPDataStore.iso8601String(start)
            )
            return try sourceID(in: store, url: url)
        }
        let first = try file(minutes: 510, text: "Part one.")
        let second = try file(minutes: 550, text: "Part two, after the drop.")
        let nextDayStart = try #require(DayPlan.startOfDay("2026-09-20"))
        let nextKey = StudioViewModel.readAISessionKey(title: group, date: nextDayStart.addingTimeInterval(510 * 60), includeTime: true)
        _ = try store.addSource(
            url: "meeting://\(group)/\(StudioViewModel.percentEncodedMeetingPathComponent(nextKey))", title: nextKey,
            sourceType: "meeting", content: "Another day.", parentGroup: group, author: nil,
            occurredAt: MCPDataStore.iso8601String(nextDayStart.addingTimeInterval(510 * 60))
        )

        await #expect(throws: (any Error).self) {
            _ = try await store.mergeMeetingSessions(groupID: nil, date: nil, sourceIDs: nil)
        }
        await #expect(throws: (any Error).self) {
            _ = try await store.mergeMeetingSessions(groupID: "Nope", date: nil, sourceIDs: nil)
        }
        await #expect(throws: (any Error).self) {
            _ = try await store.mergeMeetingSessions(groupID: group, date: "19 Sep", sourceIDs: nil)
        }
        await #expect(throws: (any Error).self) {
            _ = try await store.mergeMeetingSessions(groupID: nil, date: nil, sourceIDs: [first])
        }

        // A day the series met once has nothing to fold.
        let quiet = try parseJSON(try await store.mergeMeetingSessions(groupID: group, date: "2026-09-20", sourceIDs: nil))
        #expect(quiet["status"] as? String == "nothing_to_merge")

        let merged = try parseJSON(try await store.mergeMeetingSessions(groupID: group, date: nil, sourceIDs: nil))
        #expect(merged["status"] as? String == "merged")
        #expect(merged["sessions_folded"] as? Int == 1)
        let merges = try #require(merged["merges"] as? [[String: Any]])
        #expect(merges.count == 1)
        #expect(merges.first?["survivor_id"] as? String == first)
        #expect(merges.first?["absorbed_ids"] as? [String] == [second])
        #expect(merges.first?["date"] as? String == "2026-09-19")

        // The survivor holds both parts; the reconnect's row is archived and
        // still answers for its URL, so a re-push is "already exists", never a
        // second session.
        let content = try #require(try knowledge.loadSourceContent(first))
        #expect(content.contains("Part one."))
        #expect(content.contains("—— Reconnected at 09:10 ——"))
        #expect(content.contains("Part two, after the drop."))
        #expect(try knowledge.loadSourceForSync(second)?.status == .archived)
        #expect(try knowledge.loadActiveSources().filter { $0.sourceType == .meeting }.count == 2)
        let secondKey = StudioViewModel.readAISessionKey(title: group, date: dayStart.addingTimeInterval(550 * 60), includeTime: true)
        let repush = try store.addSource(
            url: "meeting://\(group)/\(StudioViewModel.percentEncodedMeetingPathComponent(secondKey))", title: secondKey,
            sourceType: "meeting", content: "Part two, after the drop.", parentGroup: group, author: nil
        )
        #expect(repush.hasPrefix("Source already exists"))

        // Idempotent.
        let again = try parseJSON(try await store.mergeMeetingSessions(groupID: group, date: nil, sourceIDs: nil))
        #expect(again["status"] as? String == "nothing_to_merge")

        // Explicit ids: a different series' session is refused as input.
        try knowledge.saveMeetingGroup(name: "Other", metadata: MeetingMetadata(title: "Other"))
        _ = try store.addSource(
            url: "meeting://Other/1", title: "Other - 2026/09/19 08:30", sourceType: "meeting",
            content: "Elsewhere.", parentGroup: "Other", author: nil
        )
        let other = try sourceID(in: store, url: "meeting://Other/1")
        await #expect(throws: (any Error).self) {
            _ = try await store.mergeMeetingSessions(groupID: nil, date: nil, sourceIDs: [first, other])
        }
    }

    @Test("A linked Google Doc is read-only through the doc tools")
    func mcpLinkedDocIsReadOnly() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let url = try LinkedGoogleDoc.canonicalEditURL(from: "https://docs.google.com/document/d/1AbC/edit?usp=sharing")
        let linked = try await store.notebookFileStorage.createLinkedArtifact(
            url: url,
            title: "Shared plan",
            homeNotebookID: nil,
            linkedNotebookIDs: []
        )
        _ = try await store.notebookFileStorage.replaceLinkedArtifactExport(
            artifactID: linked.id,
            text: "Q3 planning\n\nShip the linked doc."
        )

        let listing = try parseJSON(try await store.listArtifacts(notebookID: nil))
        let docs = try #require(listing["docs"] as? [[String: Any]])
        let listed = try #require(docs.first { $0["id"] as? String == linked.id })
        #expect(listed["kind"] as? String == "google_doc")
        #expect(listed["read_only"] as? Bool == true)
        #expect(listed["linked_url"] as? String == "https://docs.google.com/document/d/1AbC/edit")

        let read = try parseJSON(try await store.readArtifact(artifactID: linked.id))
        #expect(read["markdown"] as? String == "Q3 planning\n\nShip the linked doc.")
        #expect(read["read_only"] as? Bool == true)
        #expect(read["linked_url"] as? String == "https://docs.google.com/document/d/1AbC/edit")
        #expect((read["guidance"] as? String)?.contains("Google Doc") == true)
        let revision = try #require(read["revision"] as? String)

        // Refused with the route: edit it in Google Docs, refresh the copy with
        // link_page, or unlink it into a Doc of ForeverLM's own.
        do {
            _ = try await store.writeArtifact(
                artifactID: linked.id,
                markdown: "# Rewritten",
                expectedRevision: revision
            )
            Issue.record("write_doc accepted a linked Google Doc")
        } catch {
            #expect(error.localizedDescription.contains("Google Docs"))
            #expect(error.localizedDescription.contains("unlink_page"))
        }
        // Metadata is still the learner's to change: the title and Notebook links
        // describe where the doc sits in ForeverLM, not what it says.
        let renamed = try parseJSON(try await store.updateArtifact(
            artifactID: linked.id,
            title: "Q3 plan",
            homeNotebookID: nil,
            notebookIDs: nil
        ))
        let renamedDoc = try #require(renamed["doc"] as? [String: Any])
        #expect(renamedDoc["title"] as? String == "Q3 plan")
        #expect(renamedDoc["linked_url"] as? String == "https://docs.google.com/document/d/1AbC/edit")
        // A Markdown doc reports itself as one, with no link.
        let created = try parseJSON(try await store.createArtifact(
            title: "Own words", homeNotebookID: nil, notebookIDs: [], markdown: "# Mine"
        ))
        let createdDoc = try #require(created["doc"] as? [String: Any])
        #expect(createdDoc["kind"] as? String == "markdown")
        #expect(createdDoc["read_only"] as? Bool == false)
        #expect(createdDoc["linked_url"] is NSNull)
    }
}

#endif
