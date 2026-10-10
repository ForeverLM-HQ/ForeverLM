import Foundation
import Testing
@testable import ForeverLM

/// Reading a Gemini Notebook: its address, the page's tokens, the
/// `batchexecute` form and answer, and each call's positional answer read
/// into sources, chats, notes and Studio items. The answer shapes are the ones
/// the community client `jacob-bd/gemini-notebook-mcp-cli` documents and pins
/// in its own tests (2026-09-30), since no public API describes them.
@Suite("Gemini Notebook service")
struct GeminiNotebookServiceTests {
    private static let notebookID = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

    private func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
    }

    // MARK: Addresses

    @Test("A notebook's address names its id on either host; other addresses are not notebooks")
    func recognisesNotebookAddresses() {
        let id = Self.notebookID
        #expect(GeminiNotebookService.notebookID(in: "https://notebook.google.com/notebook/\(id)") == id)
        #expect(GeminiNotebookService.notebookID(in: "https://notebooklm.google.com/notebook/\(id)?authuser=1") == id)
        #expect(GeminiNotebookService.notebookID(in: "notebook.google.com/notebook/\(id.uppercased())") == id)
        #expect(GeminiNotebookService.notebookID(in: "  https://notebook.google.com/notebook/\(id)/  ") == id)

        #expect(GeminiNotebookService.notebookID(in: "https://notebook.google.com/") == nil)
        #expect(GeminiNotebookService.notebookID(in: "https://notebook.google.com/notebook/") == nil)
        #expect(GeminiNotebookService.notebookID(in: "https://notebook.google.com/notebook/not-an-id") == nil)
        #expect(GeminiNotebookService.notebookID(in: "https://gemini.google.com/notebook/\(id)") == nil)
        #expect(GeminiNotebookService.notebookID(in: "https://example.com/notebook/\(id)") == nil)
        #expect(GeminiNotebookService.notebookID(in: "/Users/me/notebook/\(id)") == nil)
    }

    @Test("A text source's address is the notebook's, naming the source, and stays one source per id")
    func textSourceAddressIsItsIdentity() {
        let first = GeminiNotebookService.sourceAddress(notebookID: Self.notebookID, sourceID: "src-1")
        let second = GeminiNotebookService.sourceAddress(notebookID: Self.notebookID, sourceID: "src-2")
        #expect(first == "https://notebook.google.com/notebook/\(Self.notebookID)?source_id=src-1")
        #expect(URLNormalizer.normalize(first) != URLNormalizer.normalize(second))
        #expect(StudioArticle(url: first).id != StudioArticle(url: second).id)
    }

    @Test("A notebook link is never a source on the source bar's other routes")
    func notebookLinksStayOutOfDiscovery() {
        let notebook = StudioArticle(url: "https://notebook.google.com/notebook/\(Self.notebookID)")
        let article = StudioArticle(url: "https://example.com/post")
        #expect(StudioViewModel.excludingLinkedPages([notebook, article]).map(\.url) == [article.url])
    }

    // MARK: Routes

    @Test("A source's route follows its type and what the notebook records for it")
    func routesFollowTheSourceType() {
        typealias Kind = GeminiNotebookService.SourceKind
        #expect(GeminiNotebookService.route(kindCode: Kind.webPage, url: "https://example.com/a", driveDocumentID: nil) == .address("https://example.com/a"))
        #expect(GeminiNotebookService.route(kindCode: Kind.youtube, url: "https://www.youtube.com/watch?v=abc", driveDocumentID: nil) == .address("https://www.youtube.com/watch?v=abc"))
        #expect(GeminiNotebookService.route(kindCode: Kind.googleDocs, url: nil, driveDocumentID: "doc123") == .googleDoc(documentID: "doc123"))
        // No address of its own, or one the notebook holds only as text.
        #expect(GeminiNotebookService.route(kindCode: Kind.webPage, url: nil, driveDocumentID: nil) == .text(""))
        #expect(GeminiNotebookService.route(kindCode: Kind.pdf, url: nil, driveDocumentID: nil) == .text(""))
        #expect(GeminiNotebookService.route(kindCode: Kind.pastedText, url: nil, driveDocumentID: nil) == .text(""))
        #expect(GeminiNotebookService.route(kindCode: Kind.googleDocs, url: nil, driveDocumentID: nil) == .text(""))
        #expect(GeminiNotebookService.route(kindCode: nil, url: "https://example.com", driveDocumentID: nil) == .text(""))
        // A web source that is another notebook is not imported as that notebook.
        #expect(GeminiNotebookService.route(kindCode: Kind.webPage, url: "https://notebook.google.com/notebook/\(Self.notebookID)", driveDocumentID: nil) == .text(""))
    }

    // MARK: Page tokens and the call's form

    @Test("The page's request token, session and build are read from its configuration")
    func readsPageTokens() throws {
        let html = #"<script>window.WIZ_global_data = {"FdrFJe":"-4211","SNlM0e":"AKlE:1790=","cfb2h":"boq_labs-tailwind-frontend_20260920.01_p0","qwAQke":"x"};</script>"#
        let tokens = try #require(GeminiNotebookService.pageTokens(inPage: html))
        #expect(tokens.requestToken == "AKlE:1790=")
        #expect(tokens.sessionID == "-4211")
        #expect(tokens.buildLabel == "boq_labs-tailwind-frontend_20260920.01_p0")
        #expect(GeminiNotebookService.pageTokens(inPage: "<html>Sign in</html>") == nil)
    }

    @Test("A call is posted as f.req holding the parameters as JSON text, with the page's token")
    func buildsTheCallForm() throws {
        let tokens = GeminiNotebookService.PageTokens(requestToken: "tok/=", sessionID: "-42", buildLabel: "boq_x")
        let request = try GeminiNotebookService.batchExecuteRequest(
            rpcID: "rLM1Ne",
            parameters: [Self.notebookID, NSNull(), [2], NSNull(), 0],
            notebookID: Self.notebookID,
            tokens: tokens
        )
        #expect(request.httpMethod == "POST")
        let url = try #require(request.url)
        #expect(url.host == "notebook.google.com")
        #expect(url.path == "/_/LabsTailwindUi/data/batchexecute")
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["rpcids"] == "rLM1Ne")
        #expect(query["source-path"] == "/notebook/\(Self.notebookID)")
        #expect(query["bl"] == "boq_x")
        #expect(query["f.sid"] == "-42")
        #expect(query["rt"] == "c")
        #expect(request.value(forHTTPHeaderField: "X-Same-Domain") == "1")
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://notebook.google.com")

        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.hasSuffix("&"))
        let fields = Dictionary(uniqueKeysWithValues: body.split(separator: "&").map { pair -> (String, String) in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return (parts[0], (parts.count > 1 ? parts[1] : "").removingPercentEncoding ?? "")
        })
        #expect(fields["at"] == "tok/=")
        let form = try #require(fields["f.req"])
        let envelope = try #require(try json(form) as? [Any])
        let call = try #require((envelope.first as? [Any])?.first as? [Any])
        #expect(call[0] as? String == "rLM1Ne")
        #expect(call[1] as? String == #"["0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",null,[2],null,0]"#)
        #expect(call[2] is NSNull)
        #expect(call[3] as? String == "generic")
    }

    // MARK: The answer

    @Test("An answer's call result is its wrb.fr entry, decoded from the JSON text it carries")
    func readsTheCallResult() throws {
        let response = ")]}'\n\n104\n" + #"[["wrb.fr","rLM1Ne","[[\"My notebook\",[],\"nb\"]]",null,null,null,"generic"],["di",42],["af.httprm",41,"123",3]]"# + "\n25\n" + #"[["e",4,null,null,164]]"# + "\n"
        let result = try GeminiNotebookService.rpcResult(inResponse: response, rpcID: "rLM1Ne", call: "read the notebook")
        let outer = try #require(result as? [Any])
        #expect((outer.first as? [Any])?.first as? String == "My notebook")
    }

    @Test("An error in the answer is the server's refusal; 16 means signed out; a missing call means changed")
    func readsRefusals() {
        let signedOut = ")]}'\n" + #"[["wrb.fr","khqZz",null,null,null,[16],"generic"]]"#
        #expect(throws: GeminiNotebookService.GeminiNotebookError.signInRequired) {
            _ = try GeminiNotebookService.rpcResult(inResponse: signedOut, rpcID: "khqZz", call: "read a chat")
        }
        let denied = ")]}'\n" + #"[["wrb.fr","rLM1Ne",null,null,null,[7,null,[]],"generic"]]"#
        #expect(throws: GeminiNotebookService.GeminiNotebookError.refused(call: "read the notebook", code: 7)) {
            _ = try GeminiNotebookService.rpcResult(inResponse: denied, rpcID: "rLM1Ne", call: "read the notebook")
        }
        let other = ")]}'\n" + #"[["wrb.fr","zzzzzz","[]",null,null,null,"generic"]]"#
        #expect(throws: GeminiNotebookService.GeminiNotebookError.changed(call: "read the notebook")) {
            _ = try GeminiNotebookService.rpcResult(inResponse: other, rpcID: "rLM1Ne", call: "read the notebook")
        }
    }

    // MARK: Each call's answer

    @Test("The notebook's answer yields its title and each source with its type, address and route")
    func readsTheNotebook() throws {
        let result = try json(#"""
        [["Metabolism as Inference", [
          [["s-web"], "Metabolism as Inference - SoTA Letters", [null, 1200, [1790000000, 0], null, 5, null, null, ["https://sotaletters.com/metabolism"]], [null, 2]],
          [["s-yt"], "A talk", [null, 0, null, null, 9, null, null, ["https://www.youtube.com/watch?v=abcdefghijk"]], [null, 2]],
          [["s-doc"], "Lab notes", [["1AbCdocid"], 0, null, null, 1], [null, 2]],
          [["s-pdf"], "paper.pdf", [null, 0, null, null, 3], [null, 2]]
        ], "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", null, null, [1, false, true]]]
        """#)
        let notebook = try #require(GeminiNotebookService.notebook(fromResult: result))
        #expect(notebook.title == "Metabolism as Inference")
        #expect(notebook.sources.map(\.id) == ["s-web", "s-yt", "s-doc", "s-pdf"])
        #expect(notebook.sources.map(\.route) == [
            .address("https://sotaletters.com/metabolism"),
            .address("https://www.youtube.com/watch?v=abcdefghijk"),
            .googleDoc(documentID: "1AbCdocid"),
            .text(""),
        ])
        #expect(notebook.sources[3].title == "paper.pdf")
        #expect(GeminiNotebookService.notebook(fromResult: nil) == nil)
    }

    @Test("A source's text is every piece of its content blocks, a blank line apart")
    func readsSourceText() throws {
        let result = try json(#"""
        [[["s-pdf"], "paper.pdf", [null, 0, null, null, 3]], null, null,
         [[[0, 42, [[[0, 42, ["Mitochondria keep the cell alive."]]]]], [42, 90, [[[42, 90, ["Their computation is costly."]]]]]]]]
        """#)
        #expect(GeminiNotebookService.sourceText(fromResult: result) == "Mitochondria keep the cell alive.\n\nTheir computation is costly.")
        #expect(GeminiNotebookService.sourceText(fromResult: try json(#"[[["s"], "t", []], null, null, []]"#)).isEmpty)
    }

    @Test("The conversation list is read in each shape the server sends")
    func readsConversationIDs() throws {
        #expect(GeminiNotebookService.conversationIDs(fromResult: try json(#"[["conv-1", null, 12345]]"#)) == ["conv-1"])
        #expect(GeminiNotebookService.conversationIDs(fromResult: try json(#"[["conv-2"]]"#)) == ["conv-2"])
        #expect(GeminiNotebookService.conversationIDs(fromResult: try json(#"[[["conv-3"], ["conv-4", null, 2]]]"#)) == ["conv-3", "conv-4"])
        #expect(GeminiNotebookService.conversationIDs(fromResult: try json("[]")).isEmpty)
        #expect(GeminiNotebookService.conversationIDs(fromResult: nil).isEmpty)
    }

    @Test("A chat page's turns come newest first; read back they are the chat in order, stamped")
    func readsChatTurns() throws {
        let result = try json(#"""
        [[
          ["a2", [200, 500000000], 2, null, [["Second answer", null, ["c", "c", 1]], null, [[1, 2]]]],
          ["q2", [190, 0], 1, "Second question"],
          ["a1", [100, 0], 2, null, [["First answer", null, ["c", "c", 1]]]],
          ["q1", [90, 0], 1, "First question"]
        ], "token"]
        """#)
        let page = GeminiNotebookService.turnPage(fromResult: result)
        #expect(page.continuation == "token")
        #expect(page.turns.map(\.id) == ["a2", "q2", "a1", "q1"])
        let messages = Array(page.turns.map(\.message).reversed())
        #expect(messages.map(\.text) == ["First question", "First answer", "Second question", "Second answer"])
        #expect(messages.map(\.role) == [.learner, .assistant, .learner, .assistant])
        #expect(messages.last?.timestamp == Date(timeIntervalSince1970: 200.5))

        // Folded the way every imported chat is: the learner speaks first.
        let turns = ReviewTranscriptParser.turns(from: messages)
        #expect(turns.map(\.question) == [nil, "First answer", "Second answer"])
        #expect(turns.map(\.answer) == ["First question", "Second question", nil])

        let empty = GeminiNotebookService.turnPage(fromResult: try json("[[], null]"))
        #expect(empty.turns.isEmpty)
        #expect(empty.continuation == nil)
    }

    @Test("Notes skip deleted notes and mind maps and keep each note's title and body")
    func readsNotes() throws {
        let result = try json(#"""
        [[
          ["n1", ["n1", "## Key claims\n\nMortal computation.", [1, null, null], null, "Key claims"], 1],
          ["n2", null, 2],
          ["n3", ["n3", "{\"name\": \"Root\", \"children\": []}", [1], null, "Mind Map"], 1],
          ["n4", ["n4", "Untitled thought", [1], null, ""], 1]
        ], [1790000000, 0]]
        """#)
        let read = GeminiNotebookService.notes(fromResult: result)
        #expect(read.notes.map(\.id) == ["n1", "n4"])
        #expect(read.notes.first?.title == "Key claims")
        #expect(read.notes.first?.markdown == "## Key claims\n\nMortal computation.")
        #expect(read.mindMaps == [.init(title: "Mind Map", kind: "mind map")])
    }

    @Test("Studio's written reports become notes; every other item is named as left in the notebook")
    func readsStudio() throws {
        let result = try json(#"""
        [[
          ["r1", "Briefing Doc", 2, [["s-web"]], 3, null, null, [null, ["# Briefing\n\nThe abstraction fallacy."]]],
          ["f1", "Mitochondrial Flashcards", 4, [["s-web"]], 3],
          ["a1", "Deep Dive", 1, [["s-web"]], 3],
          ["x1", "App", 11, [["s-web"]], 3]
        ]]
        """#)
        let read = GeminiNotebookService.studio(fromResult: result)
        #expect(read.reports == [.init(id: "r1", title: "Briefing Doc", markdown: "# Briefing\n\nThe abstraction fallacy.")])
        #expect(read.leftBehind == [
            .init(title: "Mitochondrial Flashcards", kind: "flashcards or quiz"),
            .init(title: "Deep Dive", kind: "audio overview"),
            .init(title: "App", kind: "interactive report"),
        ])
    }

    // MARK: Filing

    @Test("Notes become Docs under their own titles, numbered when two share one")
    func docTitlesAreDistinct() {
        let notes = [
            GeminiNotebookService.NotebookNote(id: "1", title: "Summary", markdown: "a"),
            GeminiNotebookService.NotebookNote(id: "2", title: "  ", markdown: "b"),
            GeminiNotebookService.NotebookNote(id: "3", title: "Summary", markdown: "c"),
            GeminiNotebookService.NotebookNote(id: "4", title: "", markdown: "d"),
        ]
        #expect(StudioViewModel.geminiNotebookDocTitles(for: notes) == ["Summary", "Note", "Summary (2)", "Note (2)"])
    }

    @Test("An imported chat is a chat under its record's id, and importing it again brings it level without a copy")
    func importedChatIsKeptLevel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeminiNotebookChatTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let id = "0F3A2B1C-0000-4000-8000-000000000001"
        func message(_ role: ReviewTranscriptRole, _ text: String, _ seconds: TimeInterval) -> ReviewTranscriptMessage {
            ReviewTranscriptMessage(role: role, text: text, timestamp: Date(timeIntervalSince1970: 1_790_000_000 + seconds))
        }
        let first = [
            message(.learner, "What is the abstraction fallacy?", 0),
            message(.assistant, "Mistaking the map for the territory.", 30),
        ]
        let created = try await storage.saveImportedChat(
            id: id, title: "Metabolism as Inference", messages: first,
            sourceIDs: [], notebookID: nil, modelProvider: "Gemini Notebook"
        )
        #expect(created.created)
        #expect(try await storage.loadReviewSessionExchanges(sessionID: id).map(\.userAnswer) == ["What is the abstraction fallacy?", nil])
        let store = try await storage.notebookFilesKnowledgeStore()
        #expect(try store.loadReviewSessionKind(sessionID: id) == .chat)

        let longer = first + [
            message(.learner, "Why is inference passive in an LLM?", 600),
            message(.assistant, "Its output has no stake in its own continuation.", 630),
        ]
        let brought = try await storage.saveImportedChat(
            id: id, title: "Metabolism as Inference", messages: longer,
            sourceIDs: [], notebookID: nil, modelProvider: "Gemini Notebook"
        )
        #expect(!brought.created)
        let exchanges = try await storage.loadReviewSessionExchanges(sessionID: id)
        #expect(exchanges.map(\.question) == ["", "Mistaking the map for the territory.", "Its output has no stake in its own continuation."])
        #expect(exchanges.map(\.userAnswer) == ["What is the abstraction fallacy?", "Why is inference passive in an LLM?", nil])

        let again = try await storage.saveImportedChat(
            id: id, title: "Metabolism as Inference", messages: longer,
            sourceIDs: [], notebookID: nil, modelProvider: "Gemini Notebook"
        )
        #expect(again.appended == 0 && again.replaced == 0)
        // The learner spoke in it, so opening it never deletes it as abandoned.
        #expect(try await storage.deleteReviewSessionIfNoRecordedConversation(id) == false)
    }
}
