import Foundation
import Testing
@testable import ForeverLM

#if os(macOS)

/// The notes graph over MCP (docs/notes-graph-design.md, "MCP";
/// MCPTools+NotesGraph.swift): get_linked_references, get_block,
/// get_daily_note, append_to_daily_note and read_doc's resolve_references.
@Suite("Notes graph MCP tools")
struct NotesGraphMCPTests {

    private func makeStore() throws -> (MCPDataStore, String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes_graph_mcp_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MCPDataStore(dbPath: directory.appendingPathComponent("knowledge.db").path)
        _ = try store.knowledgeStore()
        return (store, directory.path)
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func json(_ raw: String) throws -> [String: Any] {
        let data = try #require(raw.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Noon on 2026-10-06, so no time zone moves the day.
    private static var october6: Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 12))!
    }

    private func message(of body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: The catalogue

    @Test("The notes graph's tools are registered with object schemas, no top-level anyOf, and teach the grammar")
    func toolsAreRegistered() throws {
        let tools = MCPToolRegistry(store: MCPDataStore()).tools
        let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for name in MCPToolRegistry.notesGraphToolNames {
            let tool = try #require(byName[name], "\(name) is not registered")
            #expect(tool.inputSchema["type"] as? String == "object", "\(name)")
            for keyword in ["anyOf", "oneOf", "allOf"] {
                #expect(tool.inputSchema[keyword] == nil, "\(name) has a top-level \(keyword)")
            }
            #expect(!tool.description.isEmpty)
        }
        #expect(byName["get_block"]?.inputSchema["required"] as? [String] == ["block_id"])
        #expect(byName["append_to_daily_note"]?.inputSchema["required"] as? [String] == ["markdown"])
        #expect(byName["get_linked_references"]?.inputSchema["required"] as? [String] == [])
        #expect(byName["get_daily_note"]?.inputSchema["required"] as? [String] == [])
        #expect(byName["get_plan"]?.inputSchema["required"] as? [String] == ["scale"])
        let plan = try #require(byName["get_plan"]?.description)
        for form in ["plan-2026-q4", "plan-2026-w45", "[[Q4 2026]]", "edit_doc", "create"] {
            #expect(plan.contains(form), "get_plan does not say \(form)")
        }

        // An assistant learns the grammar from the descriptions alone.
        let references = try #require(byName["get_linked_references"]?.description)
        for form in ["^id", "((id))", "{{embed: ((id))}}", "[[Title]]", "#tag", "#[[Two words]]",
                     "foreverlm://doc/", "foreverlm://idea/", "foreverlm://source/", "October 6th, 2026", "exactly one"] {
            #expect(references.contains(form), "get_linked_references does not teach \(form)")
        }
        let daily = try #require(byName["get_daily_note"]?.description)
        #expect(daily.contains("daily-YYYY-MM-DD"))
        #expect(daily.contains("[[October 6th, 2026]]"))
        let append = try #require(byName["append_to_daily_note"]?.description)
        for form in ["[[Title]]", "#tag", "((id))", "foreverlm://idea/"] {
            #expect(append.contains(form), "append_to_daily_note does not teach \(form)")
        }
        #expect(byName["get_block"]?.description.contains("^id") == true)
    }

    @Test("The reads are read-only, the daily note's tools write, none spends money or holds the store gate")
    func annotationsAndGate() {
        #expect(MCPToolRegistry.annotations(for: "get_linked_references")["readOnlyHint"] as? Bool == true)
        #expect(MCPToolRegistry.annotations(for: "get_block")["readOnlyHint"] as? Bool == true)
        // get_daily_note makes the day's empty note when create is true.
        #expect(MCPToolRegistry.annotations(for: "get_daily_note")["readOnlyHint"] as? Bool == false)
        #expect(MCPToolRegistry.annotations(for: "append_to_daily_note")["readOnlyHint"] as? Bool == false)
        // get_plan makes the plan from its template when create is true.
        #expect(MCPToolRegistry.annotations(for: "get_plan")["readOnlyHint"] as? Bool == false)
        #expect(MCPToolRegistry.annotations(for: "append_to_daily_note")["destructiveHint"] as? Bool == false)
        #expect(MCPToolRegistry.storeGateExemptToolNames.isSuperset(of: MCPToolRegistry.notesGraphToolNames))
        #expect(MCPToolRegistry.notesGraphToolNames.isDisjoint(with: MCPToolRegistry.paidWorkToolNames))
    }

    @Test("read_doc offers resolve_references as a boolean")
    func readDocOffersResolveReferences() throws {
        let tools = MCPToolRegistry(store: MCPDataStore()).tools
        let readDoc = try #require(tools.first { $0.name == "read_doc" })
        let properties = try #require(readDoc.inputSchema["properties"] as? [String: Any])
        let resolve = try #require(properties["resolve_references"] as? [String: Any])
        #expect(resolve["type"] as? String == "boolean")
        #expect(readDoc.inputSchema["required"] as? [String] == ["doc_id"])
    }

    // MARK: get_linked_references' target

    @Test("get_linked_references takes exactly one of doc_id, idea_id, source_id and block_id")
    func exactlyOneTarget() throws {
        let none = message { _ = try MCPDataStore.notesGraphReferenceRequest(from: [:]) }
        #expect(none?.contains("one of doc_id, idea_id, source_id or block_id") == true)

        let two = message { _ = try MCPDataStore.notesGraphReferenceRequest(from: ["doc_id": "d1", "idea_id": "i1"]) }
        #expect(two?.contains("exactly one") == true)
        let three = message {
            _ = try MCPDataStore.notesGraphReferenceRequest(from: ["source_id": "s1", "block_id": "abc123def", "doc_id": "d1"])
        }
        #expect(three?.contains("3 were given") == true)

        #expect(try MCPDataStore.notesGraphReferenceRequest(from: ["doc_id": "d1"]).target == .doc("d1"))
        #expect(try MCPDataStore.notesGraphReferenceRequest(from: ["idea_id": "i1"]).target == .idea("i1"))
        #expect(try MCPDataStore.notesGraphReferenceRequest(from: ["source_id": " s1 "]).target == .source("s1"))
        #expect(try MCPDataStore.notesGraphReferenceRequest(from: ["block_id": "abc123def"]).target == .block("abc123def"))
        // A blank argument is no argument, as a model that fills every slot sends it.
        #expect(try MCPDataStore.notesGraphReferenceRequest(from: ["doc_id": "  ", "idea_id": "i1", "source_id": ""]).target == .idea("i1"))
        // The links a Doc's Markdown writes are taken for their ids.
        #expect(try MCPDataStore.notesGraphReferenceRequest(from: ["doc_id": "foreverlm://doc/d7"]).target == .doc("d7"))
        #expect(try MCPDataStore.notesGraphReferenceRequest(from: ["idea_id": "foreverlm://idea/i9"]).target == .idea("i9"))
    }

    @Test("include_unlinked goes with doc_id only")
    func includeUnlinkedIsForDocs() throws {
        let doc = try MCPDataStore.notesGraphReferenceRequest(from: ["doc_id": "d1", "include_unlinked": true])
        #expect(doc.includeUnlinked)
        #expect(try MCPDataStore.notesGraphReferenceRequest(from: ["doc_id": "d1"]).includeUnlinked == false)
        for arguments: [String: Any] in [
            ["idea_id": "i1", "include_unlinked": true],
            ["source_id": "s1", "include_unlinked": true],
            ["block_id": "abc123def", "include_unlinked": true],
        ] {
            let refusal = message { _ = try MCPDataStore.notesGraphReferenceRequest(from: arguments) }
            #expect(refusal?.contains("doc_id only") == true)
        }
        // Asking for none is not asking for the wrong kind.
        #expect(try MCPDataStore.notesGraphReferenceRequest(from: ["idea_id": "i1", "include_unlinked": false]).target == .idea("i1"))
    }

    @Test("A block id is read bare, as ((id)) or as ^id, and nothing else is one")
    func blockIDForms() {
        #expect(MCPDataStore.notesGraphBlockID("abc123def") == "abc123def")
        #expect(MCPDataStore.notesGraphBlockID(" ((abc123def)) ") == "abc123def")
        #expect(MCPDataStore.notesGraphBlockID("^abc123def") == "abc123def")
        #expect(MCPDataStore.notesGraphBlockID("ABC123DEF") == "abc123def")
        #expect(MCPDataStore.notesGraphBlockID("abc123de") == nil)
        #expect(MCPDataStore.notesGraphBlockID("abc123defg") == nil)
        #expect(MCPDataStore.notesGraphBlockID("abc-23def") == nil)
        #expect(MCPDataStore.notesGraphBlockID("((abc123def)") == nil)
        #expect(MCPDataStore.notesGraphBlockID("") == nil)
        let refusal = message { _ = try MCPDataStore.notesGraphReferenceRequest(from: ["block_id": "nope"]) }
        #expect(refusal?.contains("nine lowercase letters and digits") == true)
    }

    // MARK: Days

    @Test("A day is YYYY-MM-DD, a day's title, today, yesterday or tomorrow; today when left out or blank")
    func dayKeys() throws {
        let now = Self.october6
        let calendar = Self.utc
        func key(_ value: Any?) throws -> String {
            try MCPDataStore.dailyNoteDayKey(from: value, now: now, calendar: calendar)
        }
        #expect(try key(nil) == "2026-10-06")
        #expect(try key(NSNull()) == "2026-10-06")
        #expect(try key("") == "2026-10-06")
        #expect(try key("   ") == "2026-10-06")
        #expect(try key("today") == "2026-10-06")
        #expect(try key("Today") == "2026-10-06")
        #expect(try key("yesterday") == "2026-10-05")
        #expect(try key("tomorrow") == "2026-10-07")
        #expect(try key("2026-12-31") == "2026-12-31")
        #expect(try key(" 2026-01-02 ") == "2026-01-02")
        #expect(try key("2024-02-29") == "2024-02-29")
        #expect(try key("October 7th, 2026") == "2026-10-07")
        #expect(try key("October 7, 2026") == "2026-10-07")
        // Tomorrow on the last day of the year is the next year's first.
        let newYearsEve = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 12))!
        #expect(try MCPDataStore.dailyNoteDayKey(from: "tomorrow", now: newYearsEve, calendar: calendar) == "2027-01-01")
    }

    @Test("A date that names no day is refused, saying the form")
    func badDates() {
        for value: Any in ["2026-02-30", "2026-13-01", "2026-10-7", "06/10/2026", "next week", 20261006, true] {
            let refusal = message { _ = try MCPDataStore.dailyNoteDayKey(from: value, now: Self.october6, calendar: Self.utc) }
            #expect(refusal?.contains("YYYY-MM-DD") == true, "\(value) was taken for a day")
        }
    }

    // MARK: Appending

    @Test("An addition is its own block: bullets after bullets join the list, anything else follows a blank line")
    func appendJoining() {
        func appended(_ addition: String, to existing: String) -> String {
            MCPDataStore.dailyNoteAppending(addition, to: existing)
        }
        // An empty note takes the addition as its whole body.
        #expect(appended("First thought", to: "") == "First thought\n")
        #expect(appended("- b", to: "  \n\t\n") == "- b\n")
        // A paragraph never runs into the one before it.
        #expect(appended("Second", to: "First\n") == "First\n\nSecond\n")
        #expect(appended("Line one\nLine two", to: "Para") == "Para\n\nLine one\nLine two\n")
        // The next bullet of an outline joins it.
        #expect(appended("- b", to: "- a\n") == "- a\n- b\n")
        #expect(appended("- b", to: "- a\n\n") == "- a\n- b\n")
        #expect(appended("- c", to: "- a\n  - nested\n") == "- a\n  - nested\n- c\n")
        #expect(appended("- b", to: "Intro\n- a") == "Intro\n- a\n- b\n")
        #expect(appended("- [ ] task", to: "- [x] done\n") == "- [x] done\n- [ ] task\n")
        #expect(appended("2. b", to: "1. a\n") == "1. a\n2. b\n")
        // Another kind of list, or something else, is set off.
        #expect(appended("- b", to: "* a\n") == "* a\n\n- b\n")
        #expect(appended("1) b", to: "1. a") == "1. a\n\n1) b\n")
        #expect(appended("Paragraph", to: "- a\n") == "- a\n\nParagraph\n")
        #expect(appended("- b", to: "Para\n") == "Para\n\n- b\n")
        #expect(appended("- b", to: "# Heading\n") == "# Heading\n\n- b\n")
        #expect(appended("- b", to: "---\n") == "---\n\n- b\n")
        #expect(appended("- b", to: "```\n- a\n```\n") == "```\n- a\n```\n\n- b\n")
        #expect(appended("- b", to: "> - quoted\n") == "> - quoted\n\n- b\n")
        // Blank lines around the addition go; its own line endings become \n.
        #expect(appended("\n\n- b\n\n", to: "- a\n\n\n") == "- a\n- b\n")
        #expect(appended("- b\r\n- c\r\n", to: "- a") == "- a\n- b\n- c\n")
        // Nothing to add changes nothing.
        #expect(appended("  \n ", to: "x") == "x")
    }

    @Test("A list marker is a bullet or a number at the margin, and a thematic break is not one")
    func listMarkers() {
        #expect(MCPDataStore.listMarker(of: "- item") == "-")
        #expect(MCPDataStore.listMarker(of: "* item") == "*")
        #expect(MCPDataStore.listMarker(of: "+ item") == "+")
        #expect(MCPDataStore.listMarker(of: "-") == "-")
        #expect(MCPDataStore.listMarker(of: "12. item") == "1.")
        #expect(MCPDataStore.listMarker(of: "3) item") == "1)")
        #expect(MCPDataStore.listMarker(of: "*emphasis*") == nil)
        #expect(MCPDataStore.listMarker(of: "-1 degrees") == nil)
        #expect(MCPDataStore.listMarker(of: "* * *") == nil)
        #expect(MCPDataStore.listMarker(of: "___") == nil)
        #expect(MCPDataStore.listMarker(of: "2026. A year") == "1.")
        #expect(MCPDataStore.trailingListMarker(of: "- a\n  continued\n  - b") == "-")
        #expect(MCPDataStore.trailingListMarker(of: "- a\n\nAfter") == nil)
        #expect(MCPDataStore.leadingListMarker(of: "  - indented") == nil)
    }

    // MARK: Through the registry

    @Test("Bad arguments come back as errors through the registry, before anything is read or written")
    func refusalsThroughTheRegistry() async throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let registry = MCPToolRegistry(store: store)

        let none = await registry.callToolDetailed(name: "get_linked_references", arguments: [:])
        #expect(none.isError)
        #expect(none.text.contains("one of doc_id, idea_id, source_id or block_id"))
        let two = await registry.callToolDetailed(name: "get_linked_references", arguments: ["doc_id": "d1", "block_id": "abc123def"])
        #expect(two.isError)
        #expect(two.text.contains("exactly one"))
        let missing = await registry.callToolDetailed(name: "get_linked_references", arguments: ["doc_id": "no-such-doc"])
        #expect(missing.isError)
        #expect(missing.text.contains("No Doc has the id no-such-doc"))
        let missingIdea = await registry.callToolDetailed(name: "get_linked_references", arguments: ["idea_id": "no-such-idea"])
        #expect(missingIdea.isError)
        #expect(missingIdea.text.contains("list_ideas"))
        let badBlock = await registry.callToolDetailed(name: "get_block", arguments: ["block_id": "nope"])
        #expect(badBlock.isError)
        let blank = await registry.callToolDetailed(name: "append_to_daily_note", arguments: ["markdown": "  \n "])
        #expect(blank.isError)
        #expect(blank.text.contains("markdown is required"))
        let badDate = await registry.callToolDetailed(name: "get_daily_note", arguments: ["date": "2026-02-30"])
        #expect(badDate.isError)
        #expect(badDate.text.contains("YYYY-MM-DD"))
        let badAppendDate = await registry.callToolDetailed(name: "append_to_daily_note", arguments: ["markdown": "x", "date": "soon"])
        #expect(badAppendDate.isError)
        #expect(try await store.notebookFileStorage.loadArtifacts().isEmpty, "a refused call made something")
    }

    @Test("get_daily_note says a day has no note, and makes none unless asked")
    func dailyNoteMissing() async throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let registry = MCPToolRegistry(store: store)
        let outcome = await registry.callToolDetailed(name: "get_daily_note", arguments: ["date": "2026-10-05"])
        #expect(!outcome.isError, "\(outcome.text)")
        let answer = try json(outcome.text)
        #expect(answer["exists"] as? Bool == false)
        #expect(answer["doc_id"] as? String == "daily-2026-10-05")
        #expect(answer["title"] as? String == "October 5th, 2026")
        #expect(answer["day"] as? String == "2026-10-05")
        #expect((answer["message"] as? String)?.contains("create: true") == true)
        #expect(try await store.notebookFileStorage.loadArtifact("daily-2026-10-05") == nil)
    }

    /// read_doc refused every empty Doc ("length must be between 1 and
    /// 50000") because it read the whole of an empty body as a length of 0;
    /// a day's new note and a page made by its title start empty.
    @Test("read_doc reads an empty Doc, and still bounds a length asked for")
    func readDocReadsAnEmptyDoc() async throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let snapshot = try await store.notebookFileStorage.createArtifact(
            title: "A page made by its title",
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            markdown: ""
        )
        let read = try json(try await store.readArtifact(artifactID: snapshot.artifact.id))
        #expect(read["markdown"] as? String == "")
        #expect(read["total_characters"] as? Int == 0)
        #expect(read["is_complete"] as? Bool == true)
        #expect(read["references_resolved"] == nil)
        await #expect(throws: (any Error).self) {
            _ = try await store.readArtifact(artifactID: snapshot.artifact.id, length: 0)
        }
        await #expect(throws: (any Error).self) {
            _ = try await store.readArtifact(artifactID: snapshot.artifact.id, length: 50_001)
        }
    }

    // MARK: With the graph's storage (StorageService+DocGraph.swift)

    @Test("read_doc with resolve_references reads references as their words; without it, as stored")
    func readDocResolvesReferences() async throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let storage = store.notebookFileStorage
        let claims = try await storage.createArtifact(
            title: "Mitophagy claims",
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            markdown: "# Claims\n\n- PINK1 builds up on depolarised mitochondria ^abc123def\n"
        )
        let essay = try await storage.createArtifact(
            title: "Essay",
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            markdown: "As shown, ((abc123def)), so Parkin follows.\n"
        )
        let registry = MCPToolRegistry(store: store)

        let stored = try json(await registry.callTool(
            name: "read_doc",
            arguments: ["doc_id": essay.artifact.id],
            access: .internalFullAccess
        ))
        #expect((stored["markdown"] as? String)?.contains("((abc123def))") == true)
        #expect(stored["references_resolved"] == nil)

        let resolved = try json(await registry.callTool(
            name: "read_doc",
            arguments: ["doc_id": essay.artifact.id, "resolve_references": true],
            access: .internalFullAccess
        ))
        let words = try #require(resolved["markdown"] as? String)
        #expect(words.contains("PINK1 builds up on depolarised mitochondria"))
        #expect(!words.contains("((abc123def))"))
        #expect(resolved["references_resolved"] as? Bool == true)
        // The revision is the stored Doc's, whichever way it was read.
        #expect(resolved["revision"] as? String == stored["revision"] as? String)

        let marker = try json(try await store.readArtifact(artifactID: claims.artifact.id, resolveReferences: true))
        #expect((marker["markdown"] as? String)?.contains("^abc123def") == false)
        #expect((marker["markdown"] as? String)?.contains("PINK1 builds up") == true)
    }

    @Test("append_to_daily_note makes the day's note and adds each addition at its end")
    func appendMakesAndAppends() async throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let registry = MCPToolRegistry(store: store)

        let first = await registry.callToolDetailed(
            name: "append_to_daily_note",
            arguments: ["markdown": "First thought of the day", "date": "2026-10-06"]
        )
        #expect(!first.isError, "\(first.text)")
        let made = try json(first.text)
        #expect(made["doc_id"] as? String == "daily-2026-10-06")
        #expect(made["created"] as? Bool == true)
        #expect(made["title"] as? String == "October 6th, 2026")

        for line in ["- read the [[Mitophagy]] review", "- ((abc123def)) still open"] {
            let outcome = await registry.callToolDetailed(
                name: "append_to_daily_note",
                arguments: ["markdown": line, "date": "2026-10-06"]
            )
            #expect(!outcome.isError, "\(outcome.text)")
            #expect(try json(outcome.text)["created"] as? Bool == false)
        }

        let read = try json(await registry.callTool(
            name: "get_daily_note",
            arguments: ["date": "2026-10-06"],
            access: .internalFullAccess
        ))
        #expect(read["exists"] as? Bool == true)
        #expect(read["created"] as? Bool == false)
        let body = try #require(read["markdown"] as? String)
        #expect(body.hasSuffix("First thought of the day\n\n- read the [[Mitophagy]] review\n- ((abc123def)) still open\n"))
        let revision = try #require(read["revision"] as? String)
        #expect(!revision.isEmpty)
        #expect(try await store.notebookFileStorage.loadArtifact("daily-2026-10-06")?.title == "October 6th, 2026")
    }

    @Test("get_daily_note with create makes the day's empty note once")
    func dailyNoteCreate() async throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let registry = MCPToolRegistry(store: store)
        let made = try json(await registry.callTool(
            name: "get_daily_note",
            arguments: ["date": "2026-10-04", "create": true],
            access: .internalFullAccess
        ))
        #expect(made["exists"] as? Bool == true)
        #expect(made["created"] as? Bool == true)
        #expect(made["doc_id"] as? String == "daily-2026-10-04")
        let again = try json(await registry.callTool(
            name: "get_daily_note",
            arguments: ["date": "2026-10-04", "create": true],
            access: .internalFullAccess
        ))
        #expect(again["created"] as? Bool == false)
        #expect(again["revision"] as? String == made["revision"] as? String)
    }

    @Test("get_linked_references lists the blocks that link a Doc or a block, and get_block reads one")
    func linkedReferencesAndBlocks() async throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let storage = store.notebookFileStorage
        let claims = try await storage.createArtifact(
            title: "Mitophagy claims",
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            markdown: "# Claims\n\n- PINK1 builds up on depolarised mitochondria ^abc123def\n  - measured in HeLa cells\n"
        )
        let essay = try await storage.createArtifact(
            title: "Essay",
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            markdown: "- Background\n  - See [Mitophagy claims](foreverlm://doc/\(claims.artifact.id))\n\nAs shown, ((abc123def)), so Parkin follows.\n"
        )
        let registry = MCPToolRegistry(store: store)

        let toDoc = try json(await registry.callTool(
            name: "get_linked_references",
            arguments: ["doc_id": claims.artifact.id],
            access: .internalFullAccess
        ))
        let docPages = try #require(toDoc["pages"] as? [[String: Any]])
        let fromEssay = try #require(docPages.first { $0["id"] as? String == essay.artifact.id })
        #expect(fromEssay["kind"] as? String == "doc")
        #expect(fromEssay["title"] as? String == "Essay")
        let linking = try #require(fromEssay["blocks"] as? [[String: Any]])
        #expect(linking.contains { ($0["markdown"] as? String)?.contains("foreverlm://doc/\(claims.artifact.id)") == true })
        #expect(linking.contains { ($0["breadcrumbs"] as? [String])?.contains("Background") == true })
        #expect((toDoc["target"] as? [String: Any])?["title"] as? String == "Mitophagy claims")

        let toBlock = try json(await registry.callTool(
            name: "get_linked_references",
            arguments: ["block_id": "((abc123def))"],
            access: .internalFullAccess
        ))
        let blockPages = try #require(toBlock["pages"] as? [[String: Any]])
        let referencing = try #require(blockPages.first { $0["id"] as? String == essay.artifact.id }?["blocks"] as? [[String: Any]])
        #expect(referencing.contains { ($0["markdown"] as? String)?.contains("((abc123def))") == true })

        let block = try json(await registry.callTool(
            name: "get_block",
            arguments: ["block_id": "abc123def"],
            access: .internalFullAccess
        ))
        #expect(block["doc_id"] as? String == claims.artifact.id)
        #expect(block["doc_title"] as? String == "Mitophagy claims")
        #expect(block["block_id"] as? String == "abc123def")
        #expect((block["plain_text"] as? String)?.contains("PINK1 builds up on depolarised mitochondria") == true)
        #expect((block["markdown"] as? String)?.contains("^abc123def") == false)
        #expect((block["children_markdown"] as? String)?.contains("measured in HeLa cells") == true)
        #expect((block["reference_count"] as? Int ?? 0) >= 1)

        let unknown = await registry.callToolDetailed(name: "get_block", arguments: ["block_id": "zzz999zzz"])
        #expect(unknown.isError)
        #expect(unknown.text.contains("((zzz999zzz))"))
    }
}

#endif
