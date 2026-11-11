// The MCP protocol, HTTP response, relay, argument normalization, tool contract and local import tests.

import Testing
import AppKit
import Foundation
import PDFKit
import SQLite3
@testable import ForeverLM

#if os(macOS)

@Suite("MCP Protocol")
struct MCPProtocolTests {
    private func request(
        method: String,
        headers: [String: String] = [:],
        params: [String: Any] = [:],
        id: Any? = 1
    ) throws -> HTTPRequest {
        var body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        if let id {
            body["id"] = id
        }

        return HTTPRequest(
            method: "POST",
            path: "/mcp",
            queryString: "",
            headers: headers,
            body: try JSONSerialization.data(withJSONObject: body)
        )
    }

    private func jsonBody(_ response: HTTPResponse) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    @Test("initialized notification returns accepted empty response")
    func initializedNotificationReturnsAcceptedEmptyResponse() async throws {
        let response = await MCPProtocolHandler.shared.handleRequest(
            try request(method: "notifications/initialized", id: nil),
            access: .internalFullAccess
        )

        #expect(response.status == 202)
        #expect(response.body.isEmpty)
        #expect(response.headers["Content-Type"] == nil)
    }

    @Test("Expired MCP sessions tell clients to initialize again")
    func expiredSessionReturnsNotFound() async throws {
        let response = await MCPProtocolHandler.shared.handleRequest(
            try request(
                method: "tools/list",
                headers: ["mcp-session-id": "expired-after-app-relaunch"],
                id: 1
            ),
            access: .internalFullAccess
        )
        let json = try jsonBody(response)
        let error = try #require(json["error"] as? [String: Any])

        #expect(response.status == 404)
        #expect(error["code"] as? Int == -32600)
        #expect((error["message"] as? String)?.contains("initialize") == true)
    }

    @Test("Missing MCP session IDs remain bad requests")
    func missingSessionReturnsBadRequest() async throws {
        let response = await MCPProtocolHandler.shared.handleRequest(
            try request(method: "tools/list", id: 1),
            access: .internalFullAccess
        )

        #expect(response.status == 400)
    }

    @Test("resource list handlers advertise empty resources")
    func resourceListHandlersAdvertiseEmptyResources() async throws {
        let initialize = await MCPProtocolHandler.shared.handleRequest(
            try request(method: "initialize", id: 1),
            access: .internalFullAccess
        )
        let sessionID = try #require(initialize.headers["Mcp-Session-Id"])
        let headers = ["mcp-session-id": sessionID]

        let resources = await MCPProtocolHandler.shared.handleRequest(
            try request(method: "resources/list", headers: headers, id: 2),
            access: .internalFullAccess
        )
        let resourcesJSON = try jsonBody(resources)
        let resourcesResult = try #require(resourcesJSON["result"] as? [String: Any])
        let resourceItems = try #require(resourcesResult["resources"] as? [Any])
        #expect(resourceItems.isEmpty)

        let templates = await MCPProtocolHandler.shared.handleRequest(
            try request(method: "resources/templates/list", headers: headers, id: 3),
            access: .internalFullAccess
        )
        let templatesJSON = try jsonBody(templates)
        let templatesResult = try #require(templatesJSON["result"] as? [String: Any])
        let templateItems = try #require(templatesResult["resourceTemplates"] as? [Any])
        #expect(templateItems.isEmpty)
    }

    @Test("MCP status tool call returns active status")
    func mcpStatusToolCallReturnsActiveStatus() async throws {
        let initialize = await MCPProtocolHandler.shared.handleRequest(
            try request(method: "initialize", id: 1),
            access: .internalFullAccess
        )
        let sessionID = try #require(initialize.headers["Mcp-Session-Id"])
        let headers = ["mcp-session-id": sessionID]

        let response = await MCPProtocolHandler.shared.handleRequest(
            try request(
                method: "tools/call",
                headers: headers,
                params: [
                    "name": "get_mcp_status",
                    "arguments": [:] as [String: Any],
                ],
                id: 2
            ),
            access: .internalFullAccess
        )
        let json = try jsonBody(response)
        let result = try #require(json["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])

        #expect(payload["status"] as? String == "active")
        #expect(payload["server"] as? String == "ForeverLM MCP")
    }

    @Test("Ingest-scoped requests see and reach only the ingest surface")
    func ingestScopedRequestsAreFiltered() async throws {
        let ingest = MCPAccessContext(clientID: "dyn_conn", scope: .ingest, connectorLabel: "Feed Bot")

        let initialize = await MCPProtocolHandler.shared.handleRequest(
            try request(method: "initialize", id: 1),
            access: ingest
        )
        let initJSON = try jsonBody(initialize)
        let initResult = try #require(initJSON["result"] as? [String: Any])
        let instructions = try #require(initResult["instructions"] as? String)
        #expect(instructions.contains("ingest-only"))

        let sessionID = try #require(initialize.headers["Mcp-Session-Id"])
        let headers = ["mcp-session-id": sessionID]

        let list = await MCPProtocolHandler.shared.handleRequest(
            try request(method: "tools/list", headers: headers, id: 2),
            access: ingest
        )
        let listJSON = try jsonBody(list)
        let listResult = try #require(listJSON["result"] as? [String: Any])
        let toolDicts = try #require(listResult["tools"] as? [[String: Any]])
        let names = Set(toolDicts.compactMap { $0["name"] as? String })
        #expect(names == MCPToolRegistry.ingestAllowedTools)

        let refusal = await MCPProtocolHandler.shared.handleRequest(
            try request(
                method: "tools/call",
                headers: headers,
                params: [
                    "name": "list_sources",
                    "arguments": [:] as [String: Any],
                ],
                id: 3
            ),
            access: ingest
        )
        let refusalJSON = try jsonBody(refusal)
        let error = try #require(refusalJSON["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32001)
        #expect((error["message"] as? String)?.contains("mcp:ingest") == true)

        // A tool alias cannot slip past the gate either.
        let aliasRefusal = await MCPProtocolHandler.shared.handleRequest(
            try request(
                method: "tools/call",
                headers: headers,
                params: [
                    "name": "start_review_session",
                    "arguments": [:] as [String: Any],
                ],
                id: 4
            ),
            access: ingest
        )
        let aliasJSON = try jsonBody(aliasRefusal)
        #expect(aliasJSON["error"] != nil)
    }
}

// HTTPResponse.json takes Any; a scalar top level must serialize instead of
// producing an empty body (JSONSerialization would otherwise throw an ObjC
// exception that `try?` cannot catch).
@Suite("MCP HTTP JSON Responses")
struct MCPHTTPResponseJSONTests {
    @Test("dictionary payloads serialize to a JSON body")
    func dictionaryPayloadSerializes() throws {
        let response = HTTPResponse.json(["ok": true])
        let text = try #require(String(data: response.body, encoding: .utf8))
        #expect(text == #"{"ok":true}"#)
        #expect(response.status == 200)
    }

    @Test("scalar top-level values serialize instead of returning an empty body")
    func scalarPayloadSerializes() throws {
        let stringResponse = HTTPResponse.json("ok")
        #expect(String(data: stringResponse.body, encoding: .utf8) == #""ok""#)

        let numberResponse = HTTPResponse.json(42)
        #expect(String(data: numberResponse.body, encoding: .utf8) == "42")
    }
}

@Suite("MCP relay recovery")
struct MCPRelayRecoveryTests {
    @Test("only unanimous explicit auth rejection invalidates credentials")
    func explicitAuthenticationRejection() {
        #expect(
            MCPRelayClient.failureKind(forHTTPStatusCodes: [401, 403])
                == .authenticationRejected
        )
    }

    @Test("network and ambiguous failures preserve credentials")
    func transientFailuresPreserveCredentials() {
        #expect(MCPRelayClient.failureKind(forHTTPStatusCodes: []) == .transient)
        #expect(MCPRelayClient.failureKind(forHTTPStatusCodes: [nil, nil]) == .transient)
        #expect(MCPRelayClient.failureKind(forHTTPStatusCodes: [500, 503]) == .transient)
        #expect(MCPRelayClient.failureKind(forHTTPStatusCodes: [401, nil]) == .transient)
        #expect(MCPRelayClient.failureKind(forHTTPStatusCodes: [401, 500]) == .transient)
    }
}

@Suite("MCP tool argument normalization")
struct MCPToolArgumentNormalizationTests {
    /// The bug this guards against: a model that fills every slot sends
    /// `added_from ""`, and the date parser refused it as "not a date" — twice
    /// in one turn on 2026-09-02 — when the caller plainly meant no filter.
    @Test("blank optional filters on a read-only tool are dropped")
    func blankFiltersOnReadOnlyToolAreDropped() {
        let normalized = MCPToolRegistry.normalizedArguments(
            toolName: "search_sources_semantic",
            arguments: [
                "query": "aging atlas",
                "added_from": "",
                "added_to": "  \n",
                "source_type": "",
                "limit": 8,
            ]
        )
        #expect(normalized["query"] as? String == "aging atlas")
        #expect(normalized["limit"] as? Int == 8)
        #expect(normalized["added_from"] == nil)
        #expect(normalized["added_to"] == nil)
        #expect(normalized["source_type"] == nil)
    }

    /// The bug this guards against: `"keywords": "telomere"` was cast to
    /// `[String]`, came out nil, and the search failed as if no keyword had
    /// been sent (2026-11-10).
    @Test("a value in the wrong JSON shape is read as the shape the schema declares")
    func wrongShapedValuesTakeTheDeclaredShape() {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "keywords": ["type": "array", "items": ["type": "string"]],
                "source_ids": ["type": "array", "items": ["type": "string"]],
                "rows": ["type": "array", "items": ["type": "object"]],
                "limit": ["type": "integer"],
                "snippets_per_source": ["type": "integer"],
                "threshold": ["type": "number"],
                "include_archived": ["type": "boolean"],
                "source_id": ["type": "string"],
                "match": ["type": "string"],
            ] as [String: Any],
        ]
        let shaped = MCPToolRegistry.argumentsShaped(toSchema: schema, arguments: [
            "keywords": "telomere, p53",
            "source_ids": "[\"src_a\", \"src_b\"]",
            "rows": "not a list",
            "limit": "5",
            "snippets_per_source": "3.0",
            "threshold": "0.25",
            "include_archived": "TRUE",
            "source_id": ["src_a"],
            "match": "all",
            "unknown": "kept",
        ])
        #expect(shaped["keywords"] as? [String] == ["telomere, p53"])
        #expect(shaped["source_ids"] as? [String] == ["src_a", "src_b"])
        #expect(shaped["rows"] as? String == "not a list")
        #expect(shaped["limit"] as? Int == 5)
        #expect(shaped["snippets_per_source"] as? Int == 3)
        #expect(shaped["threshold"] as? Double == 0.25)
        #expect(shaped["include_archived"] as? Bool == true)
        #expect(shaped["source_id"] as? String == "src_a")
        #expect(shaped["match"] as? String == "all")
        #expect(shaped["unknown"] as? String == "kept")
    }

    /// A value already in its declared shape, or one that does not say the
    /// same thing in it, is passed on as sent.
    @Test("well-shaped and unreadable values are left as sent")
    func rightShapedValuesAreUntouched() {
        let schema: [String: Any] = [
            "properties": [
                "keywords": ["type": "array", "items": ["type": "string"]],
                "limit": ["type": "integer"],
                "flag": ["type": "boolean"],
                "source_id": ["type": "string"],
            ] as [String: Any],
        ]
        let shaped = MCPToolRegistry.argumentsShaped(toSchema: schema, arguments: [
            "keywords": ["a", "b"],
            "limit": "many",
            "flag": "yes",
            "source_id": ["a", "b"],
        ])
        #expect(shaped["keywords"] as? [String] == ["a", "b"])
        #expect(shaped["limit"] as? String == "many")
        #expect(shaped["flag"] as? String == "yes")
        #expect((shaped["source_id"] as? [String])?.count == 2)
    }

    /// Mutating tools document `""` as a deliberate value ("pass instructions
    /// \"\" to clear"), so nothing may be dropped from them.
    @Test("mutating tools keep an empty string as sent")
    func mutatingToolsKeepEmptyStrings() {
        let arguments: [String: Any] = ["notebook_id": "p1", "instructions": ""]
        let normalized = MCPToolRegistry.normalizedArguments(
            toolName: "update_notebook",
            arguments: arguments
        )
        #expect(normalized["instructions"] as? String == "")
        #expect(normalized.count == 2)
    }


}


/// The Cloudflare gateway used to carry a second, hand-written copy of this
/// contract, and it had silently fallen 98 tools behind the app. The registry is
/// now the only source of truth: this suite writes it out for the Worker to
/// compile, and fails the moment the two disagree.
@Suite("MCP tool contract")
struct MCPToolContractTests {

    /// `workers/shared/mcp-tools.generated.json`, resolved from this file so the
    /// test does not depend on the working directory a runner happens to use.
    static var catalogueURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UnitTests
            .deletingLastPathComponent()   // ForeverLMApp
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("workers/shared/mcp-tools.generated.json")
    }

    /// Sorted by name with sorted keys throughout, so the committed file changes
    /// only when a tool's contract changes — never because a dictionary iterated
    /// in a different order. `readOnlyHint` is the gateway's only read-only list:
    /// it publishes it and lets only those calls fall back to the hosted mirror
    /// after the relay may have handed them to the Mac.
    static func canonicalJSON(for tools: [MCPToolDef]) throws -> String {
        let entries: [[String: Any]] = tools
            .sorted { $0.name < $1.name }
            .map {
                [
                    "name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema,
                    "readOnlyHint": MCPToolRegistry.isReadOnlyTool($0.name),
                ]
            }
        let data = try JSONSerialization.data(
            withJSONObject: entries,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPError.invalidInput("tool catalogue is not UTF-8")
        }
        return text + "\n"
    }

    @Test("every registry tool is in the catalogue the gateway publishes")
    func catalogueMatchesRegistry() throws {
        let generated = try Self.canonicalJSON(for: MCPToolRegistry().tools)

        // Regenerating is `rm workers/shared/mcp-tools.generated.json` and running
        // this suite again: a missing catalogue is written rather than reported,
        // because xcodebuild does not reliably forward an environment variable to
        // the test host. A catalogue that exists and disagrees is still a failure.
        let missing = !FileManager.default.fileExists(atPath: Self.catalogueURL.path)
        if missing || ProcessInfo.processInfo.environment["FOREVERLM_WRITE_TOOL_CONTRACT"] == "1" {
            try generated.write(to: Self.catalogueURL, atomically: true, encoding: .utf8)
            return
        }

        let committed = try String(contentsOf: Self.catalogueURL, encoding: .utf8)
        #expect(
            committed == generated,
            """
            workers/shared/mcp-tools.generated.json is out of date with MCPToolRegistry.
            Regenerate it:
              rm workers/shared/mcp-tools.generated.json
              xcodebuild test -scheme 'ForeverLM (macOS)' \
                -only-testing:ForeverLMMacUnitTests/MCPToolContractTests
            """
        )
    }

    /// The gateway sends a read to the hosted mirror after the Mac may have run
    /// it, and never a write (design review 2026-10-09, fix-first 2), so a tool on
    /// the read-only list must change nothing. These five were on the wrong side.
    @Test("report_connector_status is a write; the reading view, animations, canvas versions and share requests are reads")
    func readOnlyClassification() {
        for name in ["get_article_reading_view", "list_animations", "list_canvas_versions", "list_share_requests"] {
            #expect(MCPToolRegistry.isReadOnlyTool(name), "\(name)")
            #expect(MCPToolRegistry.annotations(for: name)["readOnlyHint"] as? Bool == true, "\(name)")
            #expect(MCPToolRegistry.storeGateMode(for: name) == .shared, "\(name)")
        }
        // It records the plugin's health on this Mac's Device record and in the
        // connector's preferences.
        #expect(!MCPToolRegistry.isReadOnlyTool("report_connector_status"))
        #expect(MCPToolRegistry.annotations(for: "report_connector_status")["readOnlyHint"] as? Bool == false)
        #expect(MCPToolRegistry.storeGateMode(for: "report_connector_status") == .exclusive)
    }

    @Test("no tool is advertised without a description or an object schema")
    func everyToolCarriesAContract() throws {
        for tool in MCPToolRegistry().tools {
            #expect(!tool.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(tool.name) has no description")
            #expect(tool.inputSchema["type"] as? String == "object", "\(tool.name) has no object input schema")
        }
    }

    @Test("save_card_drafts tells assistants to use useful images by default")
    func cardDraftImagesAreTheDefault() throws {
        let tool = try #require(MCPToolRegistry().tools.first { $0.name == "save_card_drafts" })
        #expect(tool.description.contains("Images are the default"))

        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        let cards = try #require(properties["cards"] as? [String: Any])
        let items = try #require(cards["items"] as? [String: Any])
        let cardProperties = try #require(items["properties"] as? [String: Any])
        for field in ["front_images", "back_images"] {
            let imageSchema = try #require(cardProperties[field] as? [String: Any])
            let description = try #require(imageSchema["description"] as? String)
            #expect(description.contains("by default"), "\(field) should advertise the image default")
        }
    }

    /// Schema v2 §3.5.3 (WP12b): under generation 2 every synced key that stays a Setting is settable over
    /// MCP, a Notebook Collection's name only through `update_notebook_collection` and never through
    /// `set_app_setting`. The catalog's `records` hold keys that generation 2 moves into records, except
    /// `studio.courseOrder` and `meetingFolder.image.*`, which stay Settings for now (WP9's correction, and
    /// the icon satellite still to come); they keep their generation-1 routes.
    @Test("every Setting under generation 2 is settable over MCP, a collection's name only through update_notebook_collection")
    @MainActor
    func everyGenerationTwoSettingIsSettableOverMCP() throws {
        let catalog = try SettingsCatalogTests.loadCatalog()
        let records = Set(catalog.records.keys)
        // A retired key is never written (the generator refuses a route on one), so there is
        // nothing to set: only the live keys and patterns need a route.
        for key in SyncedPreferenceKeys.synced where SyncedPreferenceKeys.isSetting(key) && !records.contains(key) {
            let row = catalog.keys[key]
            #expect(row != nil && (row?["retired"] as? Bool == true || SettingsCatalogTests.mcp(row ?? [:]) != nil),
                    "\(key) is a Setting with no MCP route in the catalog")
        }
        for prefix in SyncedPreferenceKeys.liveSyncedPrefixes where !records.contains(prefix) {
            let routed = (catalog.families[prefix] ?? []).allSatisfy { $0["retired"] as? Bool == true || SettingsCatalogTests.mcp($0) != nil }
                && catalog.families[prefix] != nil
            #expect(routed || catalog.leftOut[prefix] != nil, "\(prefix) is a Setting family with no MCP route and not left out to its own writer")
        }
        let collectionName = NotebookCollections.namePreferenceKeyPrefix + "nbc-1"
        #expect(SyncedPreferenceKeys.isSetting(collectionName) && catalog.leftOut[NotebookCollections.namePreferenceKeyPrefix] != nil)
        let tools = Set(MCPToolRegistry().tools.map(\.name))
        #expect(tools.contains("update_notebook_collection"))
        for entry in MCPDataStore.appSettingsCatalog() {
            #expect(!entry.preferenceKeys.contains { $0.hasPrefix(NotebookCollections.namePreferenceKeyPrefix) },
                    "set_app_setting's \(entry.id) writes a Notebook Collection's name")
        }
    }
}

@Suite("import_local_file routes")
struct MCPLocalFileImportRouteTests {
    private func kind(_ ext: String, pages: Int? = nil, _ requested: String? = nil) throws -> MCPDataStore.LocalFileImportKind {
        try MCPDataStore.localFileImportKind(fileExtension: ext, pdfPageCount: pages, requested: requested)
    }

    @Test("Left to the tool, a long PDF is a book and a short one a paper")
    func pdfByPageCount() throws {
        #expect(try kind("pdf", pages: 12) == .paper)
        #expect(try kind("pdf", pages: 99, "auto") == .paper)
        #expect(try kind("PDF", pages: 100) == .book)
        #expect(try kind("pdf", pages: 400, " Auto ") == .book)
    }

    @Test("An asked-for kind wins for a PDF, but a PDF is never text")
    func pdfAsAsked() throws {
        #expect(try kind("pdf", pages: 400, "paper") == .paper)
        #expect(try kind("pdf", pages: 8, "book") == .book)
        #expect(throws: MCPError.self) { try kind("pdf", pages: 8, "text") }
    }

    @Test("EPUB and Kindle files are books, text and Markdown files text")
    func otherFormats() throws {
        for ext in ["epub", "azw", "azw3", "mobi", "prc"] {
            #expect(try kind(ext) == .book, "\(ext)")
            #expect(throws: MCPError.self) { try kind(ext, "paper") }
        }
        for ext in ["txt", "md", "markdown"] {
            #expect(try kind(ext) == .text, "\(ext)")
            #expect(throws: MCPError.self) { try kind(ext, "book") }
        }
    }

    @Test("An unknown format or kind is refused")
    func refusals() {
        #expect(throws: MCPError.self) { try kind("mp4") }
        #expect(throws: MCPError.self) { try kind("") }
        #expect(throws: MCPError.self) { try kind("pdf", pages: 3, "novel") }
    }

    @Test("import_local_file is registered as paid, open-world work no ingest plugin may call")
    func registration() {
        #expect(MCPToolRegistry.shared.tools.contains { $0.name == "import_local_file" })
        #expect(MCPToolRegistry.paidWorkToolNames.contains("import_local_file"))
        #expect(!MCPToolRegistry.isToolAllowed("import_local_file", scope: .ingest))
    }
}

/// On 2026-10-12 seven `import_local_pdf_as_paper` calls sent together held
/// the store alone one after another, a minute or more each; three clients
/// timed out, a `filter_sources` waited behind them, and a call cancelled
/// during Source Content Cleanup deleted the PDF of the paper it had just
/// saved, which then read "PDF needed" with no content.
@Suite("A local PDF imported as a paper")
struct MCPLocalPaperImportTests {
    private static let paperText = "Phase separated droplets concentrate enzymes with their substrates, and the cell tunes them by temperature and salt."

    private func makeStore() throws -> (MCPDataStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_local_paper_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = MCPDataStore(dbPath: dir.appendingPathComponent("knowledge.db").path)
        _ = try store.knowledgeStore()
        return (store, dir)
    }

    /// One US-letter page per string, drawn with CoreText so PDFKit reads the
    /// words back; an empty string is a blank page.
    private func writePDF(_ pages: [String], to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for text in pages {
            context.beginPDFPage(nil)
            if !text.isEmpty {
                let line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: text,
                    attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 10, nil)]
                ))
                context.textPosition = CGPoint(x: 36, y: 700)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func stage(_ store: MCPDataStore, pages: [String], in dir: URL) async throws -> MCPDataStore.StagedLocalPaper {
        let pdf = dir.appendingPathComponent("Droplets.pdf")
        try writePDF(pages, to: pdf)
        guard case .staged(let staged) = try await store.stageLocalPDFAsPaper(filePath: pdf.path, title: "Droplets in the cell") else {
            throw MCPError.invalidInput("the PDF was taken for a paper the library already held")
        }
        return staged
    }

    /// A loaded source's path is resolved against the app's own content root
    /// (`readSourceRow`), which a test store does not use, so the PDF is looked
    /// for where the import copied it: `Papers/` under the test's folder.
    private func pdfIsOnDisk(_ article: StudioArticle, in dir: URL) -> Bool {
        guard let path = article.localFilePath, path.hasSuffix("Papers/Droplets.pdf") else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("Papers/Droplets.pdf").path)
    }

    @Test("The paper is saved with its PDF and its text before any model reads it")
    func stagedPaperIsSavedWithItsPDF() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try await stage(store, pages: [Self.paperText], in: dir)

        let saved = try #require(try store.knowledgeStore().loadSourceForSync(staged.article.id))
        #expect(saved.sourceType == .paper)
        #expect(saved.title == "Droplets in the cell")
        #expect(saved.state == .queued)
        #expect(saved.requiresPaperMetadataAI, "the Paper Metadata model has not read it yet")
        #expect(saved.localFilePath?.hasSuffix("/Papers/Droplets.pdf") == true)
        #expect(pdfIsOnDisk(saved, in: dir))
        let raw = try store.knowledgeStore().loadPaperContentPreparation(saved.id)?.raw
        #expect(raw?.contains("Phase separated droplets") == true)
        #expect(staged.firstPageText.contains("Phase separated droplets"))

        // Staging held the store only around its own match and save.
        await store.acquireToolOperation(.exclusive)
        await store.releaseToolOperation()
    }

    @Test("A read that fails is saved on the paper, which keeps its PDF")
    func failedReadKeepsThePDF() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A blank first page fails the metadata step before any model call.
        let staged = try await stage(store, pages: ["", Self.paperText], in: dir)
        #expect(staged.firstPageText.isEmpty)

        do {
            _ = try await store.finishStagedLocalPaper(staged)
            Issue.record("a paper with no first-page text was read")
        } catch {
            #expect(error.localizedDescription.contains("no readable paper text"))
            #expect(error.localizedDescription.contains("stays in the library with its PDF (id: \(staged.article.id))"))
        }
        let saved = try #require(try store.knowledgeStore().loadSourceForSync(staged.article.id))
        #expect(saved.state == .error)
        #expect(saved.errorMessage?.contains("no readable paper text") == true)
        #expect(pdfIsOnDisk(saved, in: dir), "the failure took the PDF away from the paper")
    }

    @Test("A stopped read leaves the paper pending with its PDF, not failed")
    func stoppedReadLeavesThePaperPending() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try await stage(store, pages: [Self.paperText], in: dir)

        await #expect(throws: CancellationError.self) {
            _ = try await store.finishStagedLocalPaper(staged) { _, _ in throw CancellationError() }
        }
        let saved = try #require(try store.knowledgeStore().loadSourceForSync(staged.article.id))
        #expect(saved.state == .queued)
        #expect(saved.errorMessage == nil)
        #expect(saved.requiresPaperMetadataAI, "the app's own metadata pass finishes it")
        #expect(pdfIsOnDisk(saved, in: dir), "a stopped import took the PDF away from the paper it saved")
    }

    @Test("Another call takes the store, even alone, while a paper's models read it")
    func readingHoldsNoGate() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try await stage(store, pages: [Self.paperText], in: dir)

        let entered = MCPTestSignal()
        let release = MCPTestSignal()
        let finishing = Task {
            try await store.finishStagedLocalPaper(staged) { article, firstPage in
                await entered.signal()
                await release.wait()
                #expect(firstPage.contains("Phase separated droplets"))
                article.title = "Droplets, read"
                article.author = "Zara Holt"
                _ = article.attestPaperMetadataExtractionAfterLLM()
                return "read by the test"
            }
        }
        await entered.wait()

        // A writer waits for every holder of the gate, so being let in while
        // the models read shows the read holds nothing.
        let admitted = MCPTestSignal()
        let writer = Task {
            await store.acquireToolOperation(.exclusive)
            await admitted.signal()
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await admitted.hasSignaled, "a call waited behind a paper's models")
        await release.signal()
        await writer.value
        await store.releaseToolOperation()

        let outcome = try await finishing.value
        #expect(outcome.sourceID == staged.article.id)
        #expect(outcome.message.contains("read by the test"))
        let saved = try #require(try store.knowledgeStore().loadSourceForSync(staged.article.id))
        #expect(saved.title == "Droplets, read")
        #expect(saved.hasPaperIngestionAttestation)
        #expect(pdfIsOnDisk(saved, in: dir))
    }

    @Test("Read in the background, a paper answers with a work_id listed until it is saved")
    func backgroundReadingIsListedRunningWork() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try await stage(store, pages: [Self.paperText], in: dir)

        let release = MCPTestSignal()
        let workID = store.startStagedLocalPaperReading(
            staged,
            tool: "import_local_pdf_as_paper",
            spendLimitUSD: nil
        ) { article, _ in
            await release.wait()
            article.author = "Zara Holt"
            _ = article.attestPaperMetadataExtractionAfterLLM()
            return "read in the background"
        }
        #expect(workID.hasPrefix("task-"))
        let entry = try #require(MCPRunningWork.shared.snapshot.first { $0.id == workID })
        #expect(entry.tool == "import_local_pdf_as_paper")
        #expect(entry.kind == .background)
        #expect(entry.spendLimitUSD == MCPRunningWork.defaultSpendLimitUSD)

        await release.signal()
        for _ in 0..<100 where MCPRunningWork.shared.snapshot.contains(where: { $0.id == workID }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!MCPRunningWork.shared.snapshot.contains { $0.id == workID })
        let saved = try #require(try store.knowledgeStore().loadSourceForSync(staged.article.id))
        #expect(saved.hasPaperIngestionAttestation)
    }

    @Test("The waiting line lets its width through and hands each place on in turn")
    func waitingLineHandsPlacesOn() async throws {
        let line = MCPWaitingLine(width: 2)
        await line.enter()
        await line.enter()
        let third = MCPTestSignal()
        let waiter = Task {
            await line.enter()
            await third.signal()
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!(await third.hasSignaled))
        #expect(await line.waitingCount == 1)
        await line.leave()
        await waiter.value
        #expect(await third.hasSignaled)
        #expect(await line.waitingCount == 0)
    }

    @Test("A downloaded paper answers as a URL import does, with its PDF's path and bibliography")
    func downloadedPaperAnswersAsAURLImport() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var staged = try await stage(store, pages: [Self.paperText], in: dir)
        staged.downloadedFrom = "https://example.org/papers/droplets.pdf"

        let outcome = try await store.finishStagedLocalPaper(staged) { article, _ in
            article.author = "Zara Holt"
            _ = article.attestPaperMetadataExtractionAfterLLM()
            return "read by the test"
        }
        #expect(outcome.message.hasPrefix("Imported paper 'Droplets in the cell' (id: \(staged.article.id), PDF: Papers/Droplets.pdf, author: Zara Holt"))
        #expect(outcome.message.hasSuffix("; read by the test)"))
    }

    @Test("Two downloads under one name both land in the Papers folder, neither overwritten")
    func downloadsClaimTheirOwnNames() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let papers = dir.appendingPathComponent("Papers", isDirectory: true)
        try FileManager.default.createDirectory(at: papers, withIntermediateDirectories: true)
        var landed: [URL] = []
        for (index, url) in ["https://example.org/a/fulltext.pdf", "https://example.org/b/fulltext.pdf"].enumerated() {
            let download = dir.appendingPathComponent("download-\(index).pdf")
            try Data("pdf \(index)".utf8).write(to: download)
            landed.append(try store.movePaperIntoPapersFolder(download, papersDir: papers, doi: nil, sourceURL: url))
        }
        #expect(landed.map(\.lastPathComponent) == ["fulltext.pdf", "fulltext-2.pdf"])
        #expect(try String(contentsOf: landed[0], encoding: .utf8) == "pdf 0")
        #expect(try String(contentsOf: landed[1], encoding: .utf8) == "pdf 1")
    }

    @Test("The paper imports gate only their own store stretches")
    func paperImportsAreSelfGated() {
        for name in ["import_local_pdf_as_paper", "import_local_file", "import_paper_from_url"] {
            #expect(MCPToolRegistry.selfGatedToolNames.contains(name), "\(name)")
            #expect(MCPToolRegistry.paidWorkToolNames.contains(name), "\(name)")
        }
    }
}

#endif
