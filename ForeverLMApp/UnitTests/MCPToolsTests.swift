import Testing
import AppKit
import Foundation
import PDFKit
import SQLite3
@testable import ForeverLM

#if os(macOS)

/// An explainer writer that answers with a canned draft, so `generate_explainer`
/// can be driven without a model route.
struct CannedMCPExplainerBackend: ExplainerModelBackend {
    var draft: ExplainerDraft

    func write(
        request: ExplainerRequest,
        source: StudioArticle,
        text: String,
        truncated: Bool,
        figureLines: [String]
    ) async throws -> ExplainerDraft {
        draft
    }
}

/// An explainer writer that waits in its model call until released, so a test
/// can hold a paid writer open and see what else runs meanwhile.
struct HeldMCPExplainerBackend: ExplainerModelBackend {
    let entered: MCPTestSignal
    let release: MCPTestSignal
    let draft: ExplainerDraft

    func write(
        request: ExplainerRequest,
        source: StudioArticle,
        text: String,
        truncated: Bool,
        figureLines: [String]
    ) async throws -> ExplainerDraft {
        await entered.signal()
        await release.wait()
        return draft
    }
}

/// Counts the explainers written, each held until `release`.
struct CountingHeldExplainerBackend: ExplainerModelBackend {
    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        var value: Int { lock.withLock { stored } }
        func increment() { lock.withLock { stored += 1 } }
    }

    let writes: Count
    let release: MCPTestSignal
    let draft: ExplainerDraft

    func write(
        request: ExplainerRequest,
        source: StudioArticle,
        text: String,
        truncated: Bool,
        figureLines: [String]
    ) async throws -> ExplainerDraft {
        writes.increment()
        await release.wait()
        return draft
    }
}

/// The value of an answer's own `key: value` line, where a tool result hands
/// back a new id instead of writing it beside a name (Prompts.hiddenIDs).
func mcpAnswerValue(_ key: String, in text: String) -> String? {
    text.split(separator: "\n").lazy
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { $0.hasPrefix(key + ": ") }
        .map { String($0.dropFirst(key.count + 2)).trimmingCharacters(in: .whitespaces) }
}

/// The Notebook create_notebook made: its `notebook_id:` line when it filed
/// the calling chat, else the id its next-call line names
/// ("Pass notebook_id X explicitly …").
func createdNotebookID(in text: String) -> String? {
    if let line = mcpAnswerValue("notebook_id", in: text) { return line }
    guard let range = text.range(of: "Pass notebook_id ") else { return nil }
    return text[range.upperBound...].split(separator: " ").first.map(String.init)
}

actor MCPTestSignal {
    private var isSet = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !isSet else { return }
        isSet = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        if isSet { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    var hasSignaled: Bool { isSet }
}

@Suite("MCP integer arguments")
struct MCPIntegerArgumentTests {
    @Test("Whole numbers read as Int from a number, a whole decimal or a string")
    func readsWholeNumbers() throws {
        #expect(try MCPDataStore.intValue(7, "page") == 7)
        #expect(try MCPDataStore.intValue(7.0, "page") == 7)
        #expect(try MCPDataStore.intValue(" 7 ", "page") == 7)
        #expect(try MCPDataStore.intValue(nil, "page") == nil)
        #expect(try MCPDataStore.intValue(NSNull(), "page") == nil)
        #expect(try MCPDataStore.intArgument(["page": 12.0], "page") == 12)
    }

    /// `Int(1e30)` traps; one such call once took the app and its tunnel down.
    @Test("A number Int cannot hold is refused, not trapped on", arguments: [1e30, -1e30, Double.infinity, Double.nan, 9.3e18])
    func refusesUnrepresentableNumbers(_ value: Double) {
        #expect(throws: MCPError.self) { try MCPDataStore.intValue(value, "page") }
        #expect(throws: MCPError.self) { try MCPDataStore.intArgument(["page": value], "page") }
        #expect(throws: MCPError.self) { try MCPDataStore.cardPageChange(value) }
    }
}

@Suite("MCP OAuth consent labels")
struct MCPOAuthConsentLabelTests {
    @Test("Claude dynamic clients use a friendly name")
    func claudeDynamicClientName() {
        #expect(MCPOAuthProvider.clientDisplayName(
            clientID: "dyn_0123456789abcdef0123456789abcdef",
            redirectURI: "https://claude.ai/api/mcp/auth_callback"
        ) == "Claude")
    }

    @Test("Unknown dynamic clients do not expose machine identifiers")
    func unknownDynamicClientName() {
        #expect(MCPOAuthProvider.clientDisplayName(
            clientID: "dyn_123456",
            redirectURI: "https://example.com/oauth/callback"
        ) == "An AI assistant")
    }
}

/// A plugin is known by the client_name it registered, and an authorization
/// request does not carry it. On 2026-10-10 the move to Apple team XXXXXXXXXX
/// emptied the store of registrations; a plugin that came back with its old id
/// was recreated with no name, so its sources would have filed under the raw
/// `dyn_…` id instead of "Read AI Meetings".
@Suite("MCP OAuth forgotten clients")
struct MCPOAuthForgottenClientTests {
    private let loopback = "http://127.0.0.1:53682/callback"
    private let forgottenID = "dyn_0123456789abcdef"

    @Test("A forgotten plugin client is refused, so it registers again under its name")
    func forgottenPluginClientIsRefused() {
        #expect(!MCPOAuthProvider.mayRecoverDynamicClient(
            clientID: forgottenID, redirectURI: loopback, requestedScope: "mcp:ingest"))
    }

    @Test("A forgotten local assistant asking for full access is still recovered")
    func forgottenFullAccessClientIsRecovered() {
        #expect(MCPOAuthProvider.mayRecoverDynamicClient(
            clientID: forgottenID, redirectURI: loopback, requestedScope: nil))
        #expect(MCPOAuthProvider.mayRecoverDynamicClient(
            clientID: forgottenID, redirectURI: loopback, requestedScope: "mcp:tools"))
        #expect(MCPOAuthProvider.mayRecoverDynamicClient(
            clientID: forgottenID, redirectURI: loopback, requestedScope: "mcp:ingest mcp:tools"))
        #expect(MCPOAuthProvider.mayRecoverDynamicClient(
            clientID: forgottenID, redirectURI: "http://localhost:8080/callback", requestedScope: nil))
    }

    @Test("Only loopback dynamic clients are ever recovered")
    func onlyLoopbackDynamicClientsRecover() {
        #expect(!MCPOAuthProvider.mayRecoverDynamicClient(
            clientID: forgottenID, redirectURI: "https://example.com/callback", requestedScope: nil))
        #expect(!MCPOAuthProvider.mayRecoverDynamicClient(
            clientID: "foreverlm-provisioned", redirectURI: loopback, requestedScope: nil))
    }

    @Test("Refusing a forgotten client says to register again")
    func refusalSaysToRegisterAgain() throws {
        let response = MCPOAuthProvider.unknownClientResponse(clientID: forgottenID, status: 401)
        #expect(response.status == 401)
        let body = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: String])
        #expect(body["error"] == "invalid_client")
        #expect(body["error_description"]?.contains("/oauth/register") == true)
        #expect(body["error_description"]?.contains("same client_name") == true)

        let other = MCPOAuthProvider.unknownClientResponse(clientID: "someone-else", status: 400)
        #expect(other.status == 400)
        #expect(try JSONSerialization.jsonObject(with: other.body) as? [String: String] == ["error": "invalid_client"])
    }
}

/// Every authorization is approved by the learner in the app (match code) or
/// with the pairing code. The waiting page once fetched a loopback
/// `/oauth/local-approve` that approved by itself; a forged Origin or a crafted
/// authorize link could drive it, so it is gone, and the page only polls.
@Suite("MCP OAuth waiting page")
struct MCPOAuthWaitingPageTests {
    @Test("The waiting page only polls for the learner's decision; nothing on it approves")
    func waitingPageNeverApprovesByItself() throws {
        let response = MCPOAuthProvider.waitingPageResponse(
            requestID: "req123",
            params: [
                "response_type": "code",
                "client_id": "dyn_example",
                "redirect_uri": "https://claude.ai/api/mcp/auth_callback",
                "code_challenge": "abc",
                "code_challenge_method": "S256",
                "state": "s",
            ],
            clientName: "Claude",
            matchCode: "42",
            scope: .full
        )
        #expect(response.status == 200)
        let html = try #require(String(data: response.body, encoding: .utf8))
        #expect(html.contains("/oauth/pending?request=req123"), "the page polls for the decision")
        #expect(html.contains(">42<"), "the page shows the match code the app shows")
        #expect(!html.contains("local-approve"))
        #expect(!html.contains("127.0.0.1"))
        #expect(!html.contains("localhost"))
        #expect(response.headers["Content-Security-Policy"] == "frame-ancestors 'none'")
    }
}

// MARK: - MCP Tools Tests

@Suite("MCP Data Store", .cardWordingPasses)
struct MCPDataStoreTests {

    func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("A chat is filed under a Goal as well as a Notebook, and a pool of sources still refuses a Goal")
    func chatFiledUnderGoal() async throws {
        let (store, path) = try TestStores.mcp()
        defer { cleanup(path) }
        let ks = try store.knowledgeStore()
        let now = Date()
        let notebook = try ks.createCompanionGoal(
            title: "Mitochondria", topic: "mitochondria", startAt: now, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
        let goal = try ks.createCompanionGoal(
            title: "Understand pooled in vivo screening", topic: "screens", startAt: now, endAt: now.addingTimeInterval(7 * 86_400),
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: notebook.id
        )
        #expect(goal.isGoal && !goal.isNotebook)
        try ks.createReviewSession(id: "chat-1", topic: "The Missing Dimension in Pooled Screens", sourceIDs: [])

        // Moved onto the Goal, and back off it.
        _ = try store.updateReviewSession(sessionID: "chat-1", title: nil, notebookID: goal.id)
        #expect(try ks.loadReviewSessionLinks().first { $0.id == "chat-1" }?.goalID == goal.id)
        _ = try store.updateReviewSession(sessionID: "chat-1", title: nil, notebookID: notebook.id)
        #expect(try ks.loadReviewSessionLinks().first { $0.id == "chat-1" }?.goalID == notebook.id)
        _ = try store.updateReviewSession(sessionID: "chat-1", title: nil, notebookID: "")
        #expect(try ks.loadReviewSessionLinks().first { $0.id == "chat-1" }?.goalID == nil)

        // An id that names neither is refused with both lists named.
        #expect(throws: MCPError.self) {
            _ = try store.updateReviewSession(sessionID: "chat-1", title: nil, notebookID: "nothing-here")
        }
        // Where a Notebook's pool is meant, a Goal is still not one.
        #expect(throws: MCPError.self) {
            _ = try store.resolveMCPNotebookGoal(notebookID: goal.id, store: ks)
        }
        #expect(try store.resolveMCPChatHome(notebookID: goal.id, store: ks).id == goal.id)
        #expect(try store.resolveMCPChatHome(notebookID: notebook.id, store: ks).id == notebook.id)
    }

    /// Screen record mode's switches normally live in `UserDefaults.standard`,
    /// which every test in the process shares, and with a Dev build on this
    /// Mac. Runs `body` against a throwaway suite bound for this task only
    /// (`ScreenRecordMode.overrideDefaults`), so no neighbour sees the mode.
    private func withScreenRecordDefaults(_ body: () throws -> Void) throws {
        let suiteName = "MCPDataStoreTests.screenRecord.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw MCPError.invalidInput("Could not open a defaults suite for the test.")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try ScreenRecordMode.$overrideDefaults.withValue(ScreenRecordMode.DefaultsOverride(defaults: defaults)) {
            try body()
        }
    }

    /// The product owner, 2026-09-24: a filmed "@ForeverLM" take must see only the
    /// recording Notebook's sources and what the take itself made. Everything
    /// here was made before the cutoff except the one source and the one
    /// chat stamped after it. A source added during the take shows only as a
    /// deliberate browser Reading List capture (70f8842), and older work filed
    /// under the recording Notebook stays off screen (560f8a8).
    @Test("Screen record mode narrows the connector's listings to the recording Notebook and the take's own work")
    func screenRecordModeNarrowsListings() throws {
        let (store, path) = try TestStores.mcp()
        defer { cleanup(path) }
        let ks = try store.knowledgeStore()
        let cutoff = Date().addingTimeInterval(5)
        let before = cutoff.addingTimeInterval(-3_600)
        let after = cutoff.addingTimeInterval(60)

        func seedArticle(_ id: String, title: String, addedAt: Date, origin: DiscoveryOrigin = .manual) throws {
            let url = "https://example.org/\(id)"
            var article = StudioArticle(url: url, title: title, sourceType: .article, discoveryOrigin: origin, id: id)
            article.domain = "example.org"
            article.normalizedURL = URLNormalizer.normalize(url)
            article.content = "Readable text this library holds for the test."
            article.wordCount = 8
            article.state = .ready
            article.dateAdded = addedAt
            try ks.saveSource(article)
        }
        try seedArticle("src-recording", title: "Recording Notebook paper", addedAt: before)
        try seedArticle("src-private", title: "Private older reading", addedAt: before)
        try seedArticle("src-during-take", title: "Saved during the take", addedAt: after, origin: .safari)
        try seedArticle("src-synced-during-take", title: "Arrived by sync during the take", addedAt: after)

        let recording = try ks.createCompanionGoal(
            title: "Filmed Notebook", topic: "demo", startAt: before, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: ["src-recording"]
        )
        let privateNotebook = try ks.createCompanionGoal(
            title: "Private Notebook", topic: "private", startAt: before, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: ["src-private"]
        )
        try ks.createReviewSession(id: "chat-recording", topic: "About the filmed paper", sourceIDs: ["src-recording"], startedAt: before)
        try ks.createReviewSession(id: "chat-filed", topic: "Filed under the filmed Notebook", sourceIDs: [], startedAt: before, goalID: recording.id)
        try ks.createReviewSession(id: "chat-private", topic: "An older private chat", sourceIDs: ["src-private"], startedAt: before)
        try ks.createReviewSession(id: "chat-during-take", topic: "Asked on camera", sourceIDs: [], startedAt: after)

        try withScreenRecordDefaults {
            ScreenRecordMode.setEnabled(true, now: cutoff)
            ScreenRecordMode.setNotebookID(recording.id)
            ScreenRecordMode.recordAdminStatus(true)
            #expect(ScreenRecordMode.isEffective)

            let sources = try store.listSources()
            #expect(sources.contains("src-recording"))
            #expect(sources.contains("src-during-take"))
            #expect(!sources.contains("src-synced-during-take"))
            #expect(!sources.contains("src-private"))

            let filtered = try store.filterSources(
                show: nil, author: nil, titleContains: nil, text: nil,
                sourceType: "article", includeArchived: false, limit: 50
            )
            #expect(filtered.contains("src-recording"))
            #expect(!filtered.contains("src-private"))

            let notebooks = try store.listNotebooks(includeCompleted: true)
            #expect(notebooks.contains(recording.id))
            #expect(!notebooks.contains(privateNotebook.id))
            #expect(throws: MCPError.self) {
                _ = try store.getNotebookDetail(notebookID: privateNotebook.id)
            }

            // A chat about a filmed source is still the learner's own, and so
            // is an older chat filed under the recording Notebook: only one
            // started on camera shows.
            let links = try store.listReviewSessionLinks()
            #expect(!links.contains("chat-filed"))
            #expect(links.contains("chat-during-take"))
            #expect(!links.contains("chat-recording"))
            #expect(!links.contains("chat-private"))
            let sessions = try store.getReviewSessions(topic: nil)
            #expect(!sessions.contains("chat-filed"))
            #expect(sessions.contains("chat-during-take"))
            #expect(!sessions.contains("chat-recording"))
            #expect(!sessions.contains("chat-private"))

            // The same stored switch on an account the proxy does not call an
            // admin is inert: every listing is whole again.
            ScreenRecordMode.recordAdminStatus(false)
            #expect(!ScreenRecordMode.isEffective)
            let allSources = try store.listSources()
            #expect(allSources.contains("src-private"))
            #expect(allSources.contains("src-recording"))
            #expect(try store.listNotebooks(includeCompleted: true).contains(privateNotebook.id))
            #expect(try store.listReviewSessionLinks().contains("chat-private"))
            #expect(try store.getReviewSessions(topic: nil).contains("chat-private"))
            _ = try store.getNotebookDetail(notebookID: privateNotebook.id)
        }
    }

    /// A source the store accepts as ready: `ready` needs durable readable text,
    /// so the row carries content the way an import leaves it.
    @discardableResult
    static func seedReadySource(
        _ store: KnowledgeStore, id: String, url: String, title: String, sourceType: StudioSourceType,
        content: String = "Readable text this library holds for the test."
    ) throws -> StudioArticle {
        var article = StudioArticle(url: url, title: title, sourceType: sourceType, discoveryOrigin: .manual, id: id)
        article.domain = URL(string: url)?.host ?? ""
        article.normalizedURL = URLNormalizer.normalize(url)
        article.content = content
        article.wordCount = content.split(separator: " ").count
        article.state = .ready
        try store.saveSource(article)
        return article
    }

    /// Re-importing a paper gives it a new source row and leaves the old Schedule
    /// placement behind. That placement's id is a digest of the paper's portable
    /// key (its DOI or normalized URL), so the new row lands on exactly the same
    /// id while the lookup — by source_id — finds nothing. Before 2026-09-18 the
    /// insert then failed the whole call with
    /// `UNIQUE constraint failed: scheduled_sources.id`, which is how
    /// get_source_content came to refuse to read a paper that had just been
    /// unarchived. The production store held 11 such orphaned placements.
    @Test("reads a source whose re-import left an orphaned Schedule placement behind")
    func adoptsOrphanedScheduledSourcePlacement() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let kstore = try store.knowledgeStore()
        try Self.seedReadySource(
            kstore,
            id: "src-reimported",
            url: "https://doi.org/10.1038/s41586-026-10391-0",
            title: "Cell-type-targeted mitochondrial transplantation",
            sourceType: .article
        )

        let portableKey = try kstore.portableMemorySourceKey(sourceID: "src-reimported")
        let placementID = MemoryTutorIdentity.scheduledSourcePlacementID(portableSourceKey: portableKey)
        let now = Date().timeIntervalSinceReferenceDate
        // The row the earlier copy of this paper left behind: same placement id,
        // pointing at a source row that no longer exists.
        try execSQL(dbPath: "\(tmpPath)/knowledge.db", """
            INSERT INTO scheduled_sources (id, source_id, planned_at, added_at, completed_at, created_at, updated_at)
            VALUES ('\(placementID)', 'src-deleted-original', \(now), \(now), NULL, \(now), \(now));
        """)

        // recordChatActivity is what get_source_content passes, and what used to
        // throw here.
        let content = try await store.getSourceContent("src-reimported", recordChatActivity: true)
        #expect(!content.isEmpty)

        // The orphan is adopted rather than duplicated: one row, now the live
        // source's, so the paper keeps the Schedule history it already had.
        // Generation 2 names a placement by its source (`pl:<source id>`, §3.5.21), so the
        // digest-named orphan is no clash to adopt: the live source gets its own row.
        let placements = try kstore.scheduledSourceID(forSource: "src-reimported")
        #expect(placements == "pl:src-reimported")
    }


    @Test("A share request is made, listed with can_fulfil, answered with My Library's copy, and closed for everyone")
    func shareRequestTools() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let kstore = try store.knowledgeStore()
        let now = Date()
        try kstore.saveTeam(TeamRecord(
            id: "team-bench", name: "Bench Lab", role: .owner, permission: .readWrite,
            zoneScope: .privateScope, zoneName: TeamRecord.zoneName(forTeamID: "team-bench"), zoneOwnerRecordName: nil,
            shareRecordName: nil, shareURL: nil, createdAt: now, joinedAt: now, updatedAt: now
        ))
        let held = try Self.seedReadySource(kstore, id: "src-held-book", url: "https://www.nature.com/articles/s41586-026-7", title: "Held book", sourceType: .book)

        // Ask, with the address spelled the way a Doc would cite it.
        let made = try await store.requestShare(teamID: "team-bench", url: "https://www.nature.com/articles/s41586-026-7?utm_source=doc", title: "Held paper", docID: nil)
        let madeJSON = try #require(try JSONSerialization.jsonObject(with: Data(made.utf8)) as? [String: Any])
        let request = try #require(madeJSON["request"] as? [String: Any])
        let requestID = try #require(request["id"] as? String)
        #expect(request["status"] as? String == "open")
        #expect(request["can_fulfil"] as? Bool == true, "this Mac holds the book, so it can answer")

        // Asking again while it stands returns the standing request.
        let again = try await store.requestShare(teamID: "team-bench", url: "https://www.nature.com/articles/s41586-026-7?utm_source=doc", title: nil, docID: nil)
        let againJSON = try #require(try JSONSerialization.jsonObject(with: Data(again.utf8)) as? [String: Any])
        #expect((againJSON["request"] as? [String: Any])?["id"] as? String == requestID)

        let listed = try await store.listShareRequests(teamID: nil, status: nil)
        let listedJSON = try #require(try JSONSerialization.jsonObject(with: Data(listed.utf8)) as? [String: Any])
        #expect(listedJSON["count"] as? Int == 1)
        #expect(((listedJSON["requests"] as? [[String: Any]])?.first)?["team_name"] as? String == "Bench Lab")

        // Bad input is refused before anything is written.
        await #expect(throws: MCPError.self) {
            _ = try await store.requestShare(teamID: "team-bench", url: "not a url", title: nil, docID: nil)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.listShareRequests(teamID: nil, status: "pending")
        }

        // Answering copies the source into the team and records the copy.
        let answered = try await store.fulfilShareRequest(requestID: requestID)
        let answeredJSON = try #require(try JSONSerialization.jsonObject(with: Data(answered.utf8)) as? [String: Any])
        let fulfilled = try #require(answeredJSON["request"] as? [String: Any])
        #expect(fulfilled["status"] as? String == "fulfilled")
        let copyID = try #require(fulfilled["team_copy_id"] as? String)
        #expect(kstore.activeSourceID(forReferenceURL: held.url, teamID: "team-bench") == copyID)
        #expect(try kstore.loadOpenShareRequests().isEmpty)

        // A closed request cannot be answered twice; a fresh one can be declined.
        await #expect(throws: MCPError.self) {
            _ = try await store.fulfilShareRequest(requestID: requestID)
        }
        // The team holds the source now, so a new request for it is refused.
        await #expect(throws: MCPError.self) {
            _ = try await store.requestShare(teamID: "team-bench", url: held.url, title: nil, docID: nil)
        }
        let other = try await store.requestShare(teamID: "team-bench", url: "https://example.org/not-held", title: "Not held", docID: nil)
        let otherJSON = try #require(try JSONSerialization.jsonObject(with: Data(other.utf8)) as? [String: Any])
        let otherRequest = try #require(otherJSON["request"] as? [String: Any])
        #expect(otherRequest["can_fulfil"] as? Bool == false, "nothing here to answer it with")
        let otherID = try #require(otherRequest["id"] as? String)
        await #expect(throws: MCPError.self) {
            _ = try await store.fulfilShareRequest(requestID: otherID)
        }
        let declined = try await store.declineShareRequest(requestID: otherID)
        let declinedJSON = try #require(try JSONSerialization.jsonObject(with: Data(declined.utf8)) as? [String: Any])
        #expect((declinedJSON["request"] as? [String: Any])?["status"] as? String == "declined")
        let all = try await store.listShareRequests(teamID: "team-bench", status: "all")
        let allJSON = try #require(try JSONSerialization.jsonObject(with: Data(all.utf8)) as? [String: Any])
        #expect(allJSON["count"] as? Int == 2)
    }

    @Test("Sharing a Doc carries the cited sources only this library holds by default, and reports what travelled")
    func shareDocWithCitedSources() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let kstore = try store.knowledgeStore()
        let now = Date()
        try kstore.saveTeam(TeamRecord(
            id: "team-bench", name: "Bench Lab", role: .owner, permission: .readWrite,
            zoneScope: .privateScope, zoneName: TeamRecord.zoneName(forTeamID: "team-bench"), zoneOwnerRecordName: nil,
            shareRecordName: nil, shareURL: nil, createdAt: now, joinedAt: now, updatedAt: now
        ))
        let paper = try Self.seedReadySource(kstore, id: "src-closed-book", url: "https://doi.org/10.1038/s41586-026-8", title: "Closed book", sourceType: .book)
        _ = try Self.seedReadySource(kstore, id: "src-open-article", url: "https://example.org/open-article", title: "Open article", sourceType: .article)
        let markdown = """
        # Landscape

        The key result is in [the paper](https://doi.org/10.1038/s41586-026-8), summarised by [a post](https://example.org/open-article).
        A bare link https://example.org/nowhere-in-library follows.
        """
        let created = try await store.createArtifact(title: "Landscape", homeNotebookID: nil, notebookIDs: [], markdown: markdown)
        let createdJSON = try #require(try JSONSerialization.jsonObject(with: Data(created.utf8)) as? [String: Any])
        let docID = try #require((createdJSON["doc"] as? [String: Any])?["id"] as? String)

        #expect(StorageService.webReferences(in: markdown) == [
            "https://doi.org/10.1038/s41586-026-8", "https://example.org/open-article", "https://example.org/nowhere-in-library",
        ])
        let toCarry = try await store.notebookFileStorage.citedSourcesToCarry(artifactID: docID, teamID: "team-bench")
        #expect(toCarry.map(\.id) == [paper.id], "the book travels, as a paper would; the article is a fetch away and the third link is not held")

        await #expect(throws: MCPError.self) {
            _ = try await store.shareWithTeam(teamID: "team-bench", kind: "source", ids: [paper.id], includeSources: nil, includeDocs: nil, includeChats: nil, includeCitedSources: true)
        }
        // Nothing asked: the cited source travels by default (docs/teams-design.md, decision 16).
        let shared = try await store.shareWithTeam(teamID: "team-bench", kind: "doc", ids: [docID], includeSources: nil, includeDocs: nil, includeChats: nil, includeCitedSources: nil)
        let sharedJSON = try #require(try JSONSerialization.jsonObject(with: Data(shared.utf8)) as? [String: Any])
        let travelled = try #require(sharedJSON["cited_sources_shared"] as? [[String: Any]])
        #expect(travelled.count == 1)
        #expect(travelled.first?["original_id"] as? String == paper.id)
        #expect(kstore.activeSourceID(forReferenceURL: paper.url, teamID: "team-bench") == travelled.first?["team_copy_id"] as? String)
        #expect((sharedJSON["linked_sources_shared"] as? [[String: Any]])?.isEmpty == true, "the Doc links no source of its own")
        #expect((sharedJSON["sources_not_shared"] as? [[String: Any]])?.isEmpty == true)
        #expect((sharedJSON["message"] as? String)?.contains("1 source the team lacked travelled with it (0 linked, 1 cited)") == true)
        let remaining = try await store.notebookFileStorage.citedSourcesToCarry(artifactID: docID, teamID: "team-bench")
        #expect(remaining.isEmpty, "nothing left to carry once it travelled")
        let again = try await store.shareWithTeam(teamID: "team-bench", kind: "doc", ids: [docID], includeSources: nil, includeDocs: nil, includeChats: nil, includeCitedSources: nil)
        let againJSON = try #require(try JSONSerialization.jsonObject(with: Data(again.utf8)) as? [String: Any])
        #expect((againJSON["message"] as? String)?.contains("already held every source") == true)
    }

    /// Resolve the id of a source the store just reported adding, by its URL.
    func sourceID(in store: MCPDataStore, url: String) throws -> String {
        let kstore = try store.knowledgeStore()
        let existing = kstore.sourceExistsByNormalizedURL(URLNormalizer.normalize(url)) ?? kstore.sourceExistsByURL(url)
        return try #require(existing).id
    }

    @Test("A day accepts YYYY-MM-DD or an ISO8601 timestamp, and still refuses impossible ones")
    func scheduleDateAcceptsBothSpellings() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))

        let plain = try store.parseScheduleDate("2026-07-26", calendar: calendar)
        #expect(calendar.dateComponents([.year, .month, .day], from: plain)
            == DateComponents(year: 2026, month: 7, day: 26))
        #expect(plain == calendar.startOfDay(for: plain))

        // What a model hands back after reading an `occurred` timestamp off a
        // source it just searched. This used to fail the whole source search,
        // one round before the tutor gave up and answered without the papers.
        #expect(try store.parseScheduleDate("2026-07-26T15:30:00Z", calendar: calendar) == plain)

        // Tolerance stops at dates that are not real: a lenient formatter would
        // roll this into August rather than say the model got it wrong.
        #expect(throws: MCPError.self) {
            try store.parseScheduleDate("2026-07-32", calendar: calendar)
        }
        #expect(throws: MCPError.self) {
            try store.parseScheduleDate("2026-02-31", calendar: calendar)
        }
        #expect(throws: MCPError.self) {
            try store.parseScheduleDate("last Tuesday", calendar: calendar)
        }
    }

    @Test("A day accepts the timestamp spellings the tools themselves print back")
    func scheduleDateAcceptsPrintedTimestamps() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let day = try store.parseScheduleDate("2026-06-10", calendar: calendar)

        // Exactly what a source search renders for a meeting — "occurred:
        // 2026-06-10 16:53 PDT". A model narrowing its next call hands the
        // string back verbatim, and refusing it meant refusing our own output.
        #expect(try store.parseScheduleDate("2026-06-10 16:53 PDT", calendar: calendar) == day)

        // Fractional seconds and a missing zone are both spellings of the same
        // day. The naive one is read in the learner's zone, not UTC: read as UTC
        // it would land on the 9th every afternoon west of Greenwich.
        #expect(try store.parseScheduleDate("2026-06-10T16:53:52.988Z", calendar: calendar) == day)
        #expect(try store.parseScheduleDate("2026-06-10T16:53:52", calendar: calendar) == day)
        #expect(try store.parseScheduleDate("2026-06-10T00:30:00", calendar: calendar) == day)

        // An offset names an instant, so it resolves to the local day that
        // instant falls on — 06:30 UTC is still the evening of the 9th in Los
        // Angeles, where the 10th does not start until 07:00 UTC.
        let ninth = try store.parseScheduleDate("2026-06-09", calendar: calendar)
        #expect(try store.parseScheduleDate("2026-06-10T06:30:00+00:00", calendar: calendar) == ninth)
        #expect(try store.parseScheduleDate("2026-06-10T07:30:00+00:00", calendar: calendar) == day)

        // Tolerance still stops where the value stops naming one day.
        for bad in ["2026", "2026-06", "06/10/2026", "last Tuesday", "2026-06-10 or so"] {
            #expect(throws: MCPError.self) {
                try store.parseScheduleDate(bad, calendar: calendar)
            }
        }
        // A day that does not exist is still refused when it arrives with a time.
        #expect(throws: MCPError.self) {
            try store.parseScheduleDate("2026-02-31 09:00 PST", calendar: calendar)
        }
    }

    @Test("A day accepts today, yesterday and tomorrow on the Mac's clock")
    func scheduleDateAcceptsRelativeDayWords() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-25T20:15:00-07:00"))
        let today = try store.parseScheduleDate("2026-09-25", calendar: calendar)

        // What a tutor sent for "quiz me on the videos I watched today", having
        // read "today" off the day-plan tools; refusing it failed the first call.
        #expect(try store.parseScheduleDate("today", calendar: calendar, now: now) == today)
        #expect(try store.parseScheduleDate(" Today ", calendar: calendar, now: now) == today)
        #expect(try store.parseScheduleDate("yesterday", calendar: calendar, now: now)
            == store.parseScheduleDate("2026-09-24", calendar: calendar))
        #expect(try store.parseScheduleDate("tomorrow", calendar: calendar, now: now)
            == store.parseScheduleDate("2026-09-26", calendar: calendar))
        #expect(throws: MCPError.self) {
            try store.parseScheduleDate("last Tuesday", calendar: calendar, now: now)
        }
    }

    @Test("A bare year is refused, and the refusal names the field and the value")
    func scheduleDateRefusesBareYearByName() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let calendar = Calendar(identifier: .gregorian)

        // What a model sends after reading the publication year off a book it
        // was asked about. The arguments of a failed tool call are not shown
        // anywhere, so the message is the only record of what it sent.
        for bad in ["2021", "2024-03"] {
            let error = #expect(throws: MCPError.self) {
                try store.parseScheduleDate(bad, calendar: calendar, field: "date_from")
            }
            let message = try #require(error?.localizedDescription)
            #expect(message.contains("date_from"))
            #expect(message.contains("\"\(bad)\""))
            #expect(message.contains("YYYY-MM-DD"))
        }

        let impossible = #expect(throws: MCPError.self) {
            try store.parseScheduleDate("2026-02-31", calendar: calendar, field: "date_to")
        }
        #expect(impossible?.localizedDescription.contains("date_to \"2026-02-31\"") == true)
    }

    @Test("A source search dated with a year says which axis the date is on")
    func sourceSearchDateRefusalNamesTheAddedAxis() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        // The search filters on the day a source was added, not when it was
        // published. If the refusal only fixed the spelling, the retry would
        // pass "2021-01-01" and silently find nothing.
        do {
            _ = try await store.searchSourcesSemantic(queryText: "Nick Lane Transformer", addedFrom: "2021")
            Issue.record("a bare year should not have been accepted")
        } catch let error as MCPError {
            let message = error.localizedDescription
            #expect(message.contains("added_from \"2021\""))
            #expect(message.contains("added to the library"))
            #expect(message.contains("not on when it was published"))
        }
    }

    @Test("add_source refuses a Codex site, names link_page, and writes nothing")
    func addSourceRefusesLinkedPages() throws {
        // The product owner (2026-09-09): "codex sites should always obviously be ingested
        // as a 'site' not as an article". Content passed with it changes nothing:
        // the page is a site whatever the caller read off it.
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let site = "https://techbio-companies-landscape.learner-1234.chatgpt.site/"

        let refusal = #expect(throws: MCPError.self) {
            try store.addSource(
                url: site,
                title: "TechBio companies landscape",
                sourceType: "article",
                content: "Sign in required",
                parentGroup: nil,
                author: nil
            )
        }
        let message = try #require(refusal?.localizedDescription)
        #expect(message.contains("Codex Site"))
        #expect(message.contains("link_page"))
        #expect(message.contains("Sites"))
        #expect(try store.knowledgeStore().sourceExistsByURL(site) == nil)

        // The other linked kinds are refused the same way, with their own name.
        for (url, label) in [
            ("https://claude.ai/code/artifact/a1b2c3d4-1e2f-4a5b-8c6d-7e8f9a0b1c2d", "Claude Artifact"),
            ("https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUvWxYz/edit", "Google Doc"),
        ] {
            let error = #expect(throws: MCPError.self) {
                try store.addSource(url: url, title: label, sourceType: "article", content: nil, parentGroup: nil, author: nil)
            }
            #expect(error?.localizedDescription.contains(label) == true, "\(url)")
            #expect(error?.localizedDescription.contains("link_page") == true, "\(url)")
        }

        // A plugin's batch reports the refusal per item and keeps going.
        let batch = try store.addSources([
            ["url": site, "title": "TechBio companies landscape", "source_type": "article"],
            ["url": "https://example.com/essay", "title": "Essay", "source_type": "article", "content": "Text"],
        ], connectorLabel: nil)
        #expect(batch.contains("1 added, 0 updated, 0 already existed, 1 failed (of 2)"))
        #expect(batch.contains("[0] Error:"))
        #expect(batch.contains("link_page"))
        #expect(batch.contains("[1] Added source 'Essay'"))
        #expect(try store.knowledgeStore().sourceExistsByURL(site) == nil)
    }

    /// 2026-09-28: two Peter Attia episodes added through add_source were
    /// listed under the channel "www.youtube.com", out of reach of a `show`
    /// search, because the row took the URL's host for its channel and waited
    /// for the app's backfill to name it. The uploader looked up before the
    /// save is the channel from the start.
    @Test("add_source files a YouTube video under its uploader's channel, and under the host only when none was found")
    func addSourceFilesVideoUnderItsChannel() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        _ = try store.addSource(
            url: "https://www.youtube.com/watch?v=EuPcbF9YVTo",
            title: "Preventing cardiovascular and Alzheimer's disease",
            sourceType: "video",
            content: "The transcript.",
            parentGroup: nil,
            author: nil,
            videoChannel: "Peter Attia MD"
        )
        _ = try store.addSource(
            url: "https://www.youtube.com/watch?v=GoNjdK-I0Bc",
            title: "Inside modern drug development",
            sourceType: "video",
            content: "The transcript.",
            parentGroup: nil,
            author: nil,
            videoChannel: nil
        )

        let shows = try store.listShows(kind: "youtube")
        #expect(shows.contains("[youtube] Peter Attia MD — 1 episode"))
        #expect(shows.contains("[youtube] www.youtube.com — 1 episode"))
        let attia = try store.filterSources(show: "Attia", author: nil, titleContains: nil, text: nil,
                                            sourceType: "video", includeArchived: false, limit: 10)
        #expect(attia.contains("Preventing cardiovascular"))
        #expect(!attia.contains("Inside modern drug development"))

        // The lookup waits on YouTube, so the tool takes the store gate only
        // for its save rather than holding it across the request.
        #expect(MCPToolRegistry.selfGatedToolNames.contains("add_source"))
    }

    /// A chat asked to sweep "the standups with Zoe" for a word passed the
    /// series' title as `show`, and the search failed with "No podcast show
    /// or YouTube channel is named like…": a meeting series is the show a
    /// learner names most, so it scopes like one.
    @Test("show scopes a search to a recurring meeting series, by its title or its group_id")
    func showScopesToMeetingSeries() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        var standup = MeetingMetadata()
        standup.title = "Ada <> Grace standup"
        try knowledge.saveMeetingGroup(name: "zoom:example.zoom.us", metadata: standup)
        var hidden = MeetingMetadata()
        hidden.title = "Old standup"
        hidden.isHidden = true
        try knowledge.saveMeetingGroup(name: "Old standup", metadata: hidden)
        try knowledge.saveMeetingGroup(name: "Journal Club", metadata: MeetingMetadata())
        _ = try store.addSource(url: "meeting://standup/1", title: "Standup 2026-11-03", sourceType: "meeting",
                                content: "The open question is which assay to run first.",
                                parentGroup: "zoom:example.zoom.us", author: nil)
        _ = try store.addSource(url: "meeting://club/1", title: "Club 2026-11-04", sourceType: "meeting",
                                content: "One question about the cohort.", parentGroup: "Journal Club", author: nil)
        _ = try store.addSource(url: "meeting://old/1", title: "Old 2026-01-04", sourceType: "meeting",
                                content: "A question from long ago.", parentGroup: "Old standup", author: nil)

        for show in ["Ada <> Grace standup", "grace standup", "zoom:example.zoom.us"] {
            let sweep = try store.searchSourcesKeyword(keywords: ["question"], show: show)
            #expect(sweep.contains("Standup 2026-11-03"), "show: \(show)")
            #expect(!sweep.contains("Club 2026-11-04"), "show: \(show)")
            #expect(sweep.contains("in Ada <> Grace standup"), "show: \(show)")
        }
        let listed = try store.filterSources(show: "Ada <> Grace", author: nil, titleContains: nil, text: nil,
                                             sourceType: nil, includeArchived: false, limit: 10)
        #expect(listed.contains("Standup 2026-11-03"))
        #expect(!listed.contains("Club 2026-11-04"))

        // A folder the learner hid is no show, as it is no row in list_meeting_groups.
        #expect(throws: MCPError.self) {
            _ = try store.searchSourcesKeyword(keywords: ["question"], show: "Old standup")
        }
        do {
            _ = try store.searchSourcesKeyword(keywords: ["question"], show: "Nowhere")
            Issue.record("An unknown show must throw")
        } catch {
            #expect("\(error)".contains("list_meeting_groups"))
        }
    }

    @Test("A new source's domain is a video's channel when one was found, and the URL's host otherwise")
    func newSourceDomainPrefersVideoChannel() {
        let video = "https://www.youtube.com/watch?v=JuoVZkPBiKk"
        #expect(MCPDataStore.newSourceDomain(url: video, sourceType: .video, parentGroup: nil, videoChannel: " Stanford Online ") == "Stanford Online")
        #expect(MCPDataStore.newSourceDomain(url: video, sourceType: .video, parentGroup: nil, videoChannel: nil) == "www.youtube.com")
        #expect(MCPDataStore.newSourceDomain(url: video, sourceType: .video, parentGroup: nil, videoChannel: "  ") == "www.youtube.com")
        // Only a video's domain is a channel.
        #expect(MCPDataStore.newSourceDomain(url: "https://example.com/essay", sourceType: .article, parentGroup: nil, videoChannel: "Stanford Online") == "example.com")
        #expect(MCPDataStore.newSourceDomain(url: "notes", sourceType: .manual, parentGroup: "Reading notes", videoChannel: nil) == "Reading notes")
    }

    @Test("Only a YouTube video's uploader is looked up before add_source saves it")
    func uploaderLookupSkipsWhatIsNotAYouTubeVideo() async {
        // None of these reaches YouTube: each answers nil before any request.
        #expect(await MCPDataStore.uploaderChannelForNewVideo(url: "https://www.youtube.com/watch?v=JuoVZkPBiKk", sourceType: "article") == nil)
        #expect(await MCPDataStore.uploaderChannelForNewVideo(url: "https://vimeo.com/76979871", sourceType: "video") == nil)
        #expect(await MCPDataStore.uploaderChannelForNewVideo(url: "https://www.youtube.com/playlist?list=PLoROMvodv4rMqXOcazWaTUHhq-yembLCV", sourceType: "video") == nil)
    }

    @Test("add_source refuses a Convoke query result on every route and writes nothing")
    func addSourceRefusesConvokeResults() throws {
        // The product owner (2026-09-12): "convoke bio results should not be ingested as
        // a source in foreverlm". These are the two addresses the plugin
        // labelled "ForeverLM Convoke Bio" pushed that day; content changes
        // nothing, a query result is not a page whatever the caller read.
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let result = "https://platform.convoke.bio/mcp#foreverlm-7e5456abb77e57b4e1e45b41"
        let synced = "https://platform.convoke.bio/mcp?foreverlm_sync=fb2cc9b56d17b44f1f08d5df"

        let refusal = #expect(throws: MCPError.self) {
            try store.addSource(
                url: result,
                title: "Convoke — active mitochondrial disease programs",
                sourceType: "article",
                content: "Program list",
                parentGroup: nil,
                author: nil,
                connectorLabel: "ForeverLM Convoke Bio"
            )
        }
        let message = try #require(refusal?.localizedDescription)
        #expect(message.contains("Convoke"))
        #expect(message.contains("not sources"))
        #expect(try store.knowledgeStore().sourceExistsByURL(result) == nil)

        // A plugin's batch reports the refusal per item and keeps going.
        let batch = try store.addSources([
            ["url": synced, "title": "Convoke — Friedreich ataxia catalysts through 2027-09-12", "source_type": "article", "content": "Catalysts"],
            ["url": "https://insights.convoke.bio/unmet-needs", "title": "Unmet Needs Index", "source_type": "article", "content": "Text"],
        ], connectorLabel: "ForeverLM Convoke Bio")
        #expect(batch.contains("1 added, 0 updated, 0 already existed, 1 failed (of 2)"))
        #expect(batch.contains("[0] Error:"))
        #expect(batch.contains("Convoke"))
        #expect(batch.contains("[1] Added source 'Unmet Needs Index'"))
        #expect(try store.knowledgeStore().sourceExistsByURL(synced) == nil)
        #expect(try store.knowledgeStore().sourceExistsByURL("https://insights.convoke.bio/unmet-needs") != nil)
    }

    @Test("Plugin adds stamp origin and label from the authenticated client")
    func pluginAddsStampProvenance() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        let result = try store.addSource(
            url: "https://example.com/feed/1",
            title: "Feed Item",
            sourceType: "article",
            content: "Plugin-pushed content",
            parentGroup: nil,
            author: nil,
            connectorLabel: "Readwise Sync"
        )
        #expect(result.contains("Added source 'Feed Item'"))

        let id = try sourceID(in: store, url: "https://example.com/feed/1")
        let article = try #require(try store.knowledgeStore().loadSourceForSync(id))
        #expect(article.connectorLabel == "Readwise Sync")
        #expect(article.discoveryOrigin == .plugin)

        // A plain add (full-scope assistant or in-app) stays unlabeled manual.
        _ = try store.addSource(
            url: "https://example.com/manual/1",
            title: "Manual Item",
            sourceType: "article",
            content: "By hand",
            parentGroup: nil,
            author: nil
        )
        let manualID = try sourceID(in: store, url: "https://example.com/manual/1")
        let manual = try #require(try store.knowledgeStore().loadSourceForSync(manualID))
        #expect(manual.connectorLabel == nil)
        #expect(manual.discoveryOrigin == .manual)
    }

    @Test("A chapter added without its book is refused, not filed loose")
    func addSourceRequiresBookGroup() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        let chapterPath = "Books/Radical Life Extension/Chapters/02 1) The Current Situation.xhtml"
        #expect(throws: MCPError.self) {
            _ = try store.addSource(
                url: chapterPath,
                title: "1) The Current Situation",
                sourceType: "book",
                content: "Chapter one",
                parentGroup: nil,
                author: nil
            )
        }
        // Nothing may be left behind by the refusal: an ungrouped chapter is a
        // row the Books tab shows as a loose path, and no later pass files it.
        #expect(try store.knowledgeStore().sourceExistsByURL(chapterPath) == nil)

        _ = try store.addSource(
            url: chapterPath,
            title: "1) The Current Situation",
            sourceType: "book",
            content: "Chapter one",
            parentGroup: "Radical Life Extension",
            author: nil
        )
        let id = try sourceID(in: store, url: chapterPath)
        let chapter = try #require(try store.knowledgeStore().loadSourceForSync(id))
        #expect(chapter.parentGroup == "Radical Life Extension")
    }

    @Test("A podcast host's link is filed as an episode to look up, whatever type the caller gave")
    func podcastHostLinkIsFiledAsPodcast() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        // 2026-10-02: with no podcast to pick, an assistant filed an Apple
        // Podcasts episode as a video, its page standing in for a transcript.
        let episode = "https://podcasts.apple.com/us/podcast/roche-will-pay-manifold-bio/id1796836887?i=1000735033082"
        let answer = try store.addSource(
            url: episode,
            title: "Roche will pay Manifold Bio $55M up front",
            sourceType: "video",
            content: "Search Home New Top Charts Sign In BiotechTV - News 16m Episode Webpage",
            parentGroup: nil,
            author: nil
        )
        #expect(answer.contains("type: podcast"))
        #expect(answer.contains("Filed as a podcast, not video"))
        #expect(answer.contains("not kept"))
        let episodeID = try sourceID(in: store, url: episode)
        let filed = try #require(try store.knowledgeStore().loadSourceForSync(episodeID))
        #expect(filed.sourceType == .podcast)
        #expect(try store.knowledgeStore().loadSourceContent(episodeID) == nil)
        // Queued with no text, so the app's first fetch finds it on Apple Podcasts.
        #expect(StudioViewModel.sourceNeedsInitialContentFetch(filed, alreadyAttempted: []))

        // A show's own episode page is a podcast when the caller says so.
        let showPage = "https://a16z.com/podcast/can-america-win-the-ai-biotech-race-against-china/"
        _ = try store.addSource(
            url: showPage,
            title: "Can America Win The AI Biotech Race Against China?",
            sourceType: "podcast",
            content: nil,
            parentGroup: nil,
            author: nil
        )
        let named = try #require(try store.knowledgeStore().loadSourceForSync(try sourceID(in: store, url: showPage)))
        #expect(named.sourceType == .podcast)

        // A video elsewhere keeps its type and its transcript.
        let talk = "https://vimeo.com/123456789"
        _ = try store.addSource(
            url: talk,
            title: "A talk",
            sourceType: "video",
            content: "What the speaker said",
            parentGroup: nil,
            author: nil
        )
        let talkID = try sourceID(in: store, url: talk)
        let video = try #require(try store.knowledgeStore().loadSourceForSync(talkID))
        #expect(video.sourceType == .video)
        #expect(try store.knowledgeStore().loadSourceContent(talkID) == "What the speaker said")
    }

    @Test("Branded meeting plugins preserve their provider origin")
    func meetingPluginPreservesProviderOrigin() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        _ = try store.addSource(
            url: "meeting://Study%20Group/Weekly%20Review%20-%202026/08/31%2010:00",
            title: "Weekly Review - 2026/08/31 10:00",
            sourceType: "meeting",
            content: "Transcript",
            parentGroup: "Study Group",
            author: nil,
            connectorLabel: "Read AI"
        )
        let id = try sourceID(
            in: store,
            url: "meeting://Study%20Group/Weekly%20Review%20-%202026/08/31%2010:00"
        )
        let meeting = try #require(try store.knowledgeStore().loadSourceForSync(id))
        #expect(meeting.connectorLabel == "Read AI")
        #expect(meeting.discoveryOrigin == .readAI)

        _ = try store.addSource(
            url: "https://example.com/read-ai-article",
            title: "Not a meeting",
            sourceType: "article",
            content: "Article",
            parentGroup: nil,
            author: nil,
            connectorLabel: "Read AI"
        )
        let articleID = try sourceID(in: store, url: "https://example.com/read-ai-article")
        let article = try #require(try store.knowledgeStore().loadSourceForSync(articleID))
        #expect(article.discoveryOrigin == .plugin)
    }

    @Test("Plugin paper inbox accepts only that plugin's staged PDFs")
    func pluginPaperInboxIsConfined() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        let response = try store.getConnectorInbox(connectorLabel: "Test Paper Plugin")
        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        )
        let inboxPath = try #require(payload["path"] as? String)
        let inboxURL = URL(fileURLWithPath: inboxPath, isDirectory: true)
        let stagedPDF = inboxURL.appendingPathComponent("paper.pdf")
        try Data("%PDF-1.4 staged".utf8).write(to: stagedPDF)

        let accepted = try store.validatePluginStagedPDF(
            stagedPDF.path,
            connectorLabel: "Test Paper Plugin"
        )
        #expect(accepted.path == stagedPDF.path)

        let outsidePDF = URL(fileURLWithPath: tmpPath).appendingPathComponent("outside.pdf")
        try Data("%PDF-1.4 outside".utf8).write(to: outsidePDF)
        #expect(throws: MCPError.self) {
            try store.validatePluginStagedPDF(
                outsidePDF.path,
                connectorLabel: "Test Paper Plugin"
            )
        }

        let otherInbox = try store.pluginInboxURL(connectorLabel: "Another Plugin")
        let otherPDF = otherInbox.appendingPathComponent("other.pdf")
        try Data("%PDF-1.4 other".utf8).write(to: otherPDF)
        #expect(throws: MCPError.self) {
            try store.validatePluginStagedPDF(
                otherPDF.path,
                connectorLabel: "Test Paper Plugin"
            )
        }
    }

    @Test("Plugin paper URLs reject local and private targets")
    func pluginPaperURLsRejectPrivateTargets() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        #expect(try store.validatePluginPaperURL("doi:10.1000/example") == "https://doi.org/10.1000/example")
        #expect(try store.validatePluginPaperURL("https://arxiv.org/abs/2401.00001") == "https://arxiv.org/abs/2401.00001")

        for blocked in [
            "http://localhost/paper.pdf",
            "http://127.0.0.1/paper.pdf",
            "http://10.0.0.5/paper.pdf",
            "http://192.168.1.5/paper.pdf",
            "http://[::1]/paper.pdf",
            "https://papers.local/paper.pdf",
            "https://example.com/paper.pdf",
            "https://arxiv.org:8443/abs/2401.00001",
            "http://arxiv.org/abs/2401.00001",
        ] {
            #expect(throws: MCPError.self) {
                try store.validatePluginPaperURL(blocked)
            }
        }
    }

    @Test("Ingest updates are confined to the plugin's own sources")
    func ingestUpdatesConfinedToOwnSources() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        _ = try store.addSource(
            url: "https://example.com/feed/2", title: "Owned", sourceType: "article",
            content: "v1", parentGroup: nil, author: nil, connectorLabel: "Readwise Sync"
        )
        _ = try store.addSource(
            url: "https://example.com/manual/2", title: "User's Own", sourceType: "article",
            content: "precious", parentGroup: nil, author: nil
        )
        let ownedID = try sourceID(in: store, url: "https://example.com/feed/2")
        let usersID = try sourceID(in: store, url: "https://example.com/manual/2")

        // Own source: allowed, content and word count refresh.
        let ok = try store.updateSourceContent(
            sourceID: ownedID, url: nil, content: "v2 has four words",
            title: nil, author: nil, restrictToPluginLabel: "Readwise Sync"
        )
        #expect(ok.contains("Updated content"))
        let updated = try #require(try store.knowledgeStore().loadSourceForSync(ownedID))
        #expect(updated.wordCount == 4)

        // The user's own source: refused for the ingest caller.
        let refusedUsers = try store.updateSourceContent(
            sourceID: usersID, url: nil, content: "overwritten",
            title: nil, author: nil, restrictToPluginLabel: "Readwise Sync"
        )
        #expect(refusedUsers.hasPrefix("Error:"))
        #expect(refusedUsers.contains("can only update sources it added itself"))

        // Another plugin's source: refused too.
        let refusedOther = try store.updateSourceContent(
            sourceID: ownedID, url: nil, content: "hijacked",
            title: nil, author: nil, restrictToPluginLabel: "Other Plugin"
        )
        #expect(refusedOther.hasPrefix("Error:"))

        // Full scope (no restriction) may update anything.
        let fullOK = try store.updateSourceContent(
            sourceID: usersID, url: nil, content: "assistant fixed the extraction",
            title: nil, author: nil, restrictToPluginLabel: nil
        )
        #expect(fullOK.contains("Updated content"))
    }

    @Test("add_sources batches per-item results and respects the cap")
    func addSourcesBatchesPerItem() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        _ = try store.addSource(
            url: "https://example.com/batch/existing", title: "Already Here", sourceType: "article",
            content: "old", parentGroup: nil, author: nil, connectorLabel: "Feed Bot"
        )

        let result = try store.addSources([
            ["url": "https://example.com/batch/a", "title": "A", "source_type": "article", "content": "aaa"],
            ["url": "https://example.com/batch/b", "title": "B", "source_type": "article"],
            ["url": "https://example.com/batch/existing", "title": "Already Here", "source_type": "article"],
            ["url": "https://example.com/batch/existing", "title": "Already Here", "source_type": "article",
             "content": "refreshed text", "update_existing": true],
            ["url": "", "title": "", "source_type": "article"],
        ], connectorLabel: "Feed Bot")

        #expect(result.contains("2 added"))
        #expect(result.contains("1 updated"))
        #expect(result.contains("1 already existed"))
        #expect(result.contains("1 failed"))

        let refreshedID = try sourceID(in: store, url: "https://example.com/batch/existing")
        let refreshed = try #require(try store.knowledgeStore().loadSourceForSync(refreshedID))
        #expect(refreshed.wordCount == 2)

        let oversized = try store.addSources(
            (0..<(MCPToolRegistry.maxBatchSourceItems + 1)).map {
                ["url": "https://example.com/over/\($0)", "title": "N\($0)", "source_type": "article"]
            },
            connectorLabel: nil
        )
        #expect(oversized.hasPrefix("Error:"))
        #expect(oversized.contains("at most \(MCPToolRegistry.maxBatchSourceItems)"))
    }

    @Test("A plugin meeting is dated by occurred_at and filed under its series by parent_group")
    func addSourceDatesMeetingByOccurredAtAndFilesItUnderItsSeries() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let kstore = try store.knowledgeStore()
        let occurred = try #require(MCPDataStore.parseFlexibleTimestamp("2026-08-19T16:54:00Z"))

        // What the Read AI plugin pushes: an https URL, not the app's own
        // meeting:// scheme, so nothing about the series can be read off it.
        let added = try store.addSource(
            url: "https://app.read.ai/analytics/meetings/01J1AGING0819",
            title: "[EF] Aging Biology Study Group - 2026/08/19 09:54",
            sourceType: "meeting",
            content: "Transcript",
            parentGroup: "Aging Biology Study Group",
            author: "Robin",
            occurredAt: "2026-08-19T16:54:00Z",
            connectorLabel: "Read AI Meetings"
        )
        #expect(added.contains("meeting: Aging Biology Study Group"))
        #expect(added.contains("occurred_at: 2026-08-19T16:54:00Z"))

        let id = try sourceID(in: store, url: "https://app.read.ai/analytics/meetings/01J1AGING0819")
        let meeting = try #require(try kstore.loadSourceForSync(id))
        #expect(meeting.dateAdded == occurred)
        // The group was created from the title, and the meeting sits in it.
        let groupID = try #require(try kstore.resolvedMeetingGroupID(matching: "Aging Biology Study Group"))
        #expect(meeting.parentGroup == groupID)
        #expect(try kstore.loadMeetingGroups()[groupID]?.title == "Aging Biology Study Group")
        // The Meetings tab's own date column is the same instant.
        let storedOccurredAt = try scalarString(
            dbPath: tmpPath + "/knowledge.db",
            "SELECT occurred_at FROM meeting_sources WHERE source_id = '\(id)'"
        )
        #expect(storedOccurredAt.flatMap(Double.init).map { abs($0 - occurred.timeIntervalSinceReferenceDate) < 0.001 } == true)

        // The next week's session names the series in a different case and
        // joins the same group instead of spawning a second one.
        _ = try store.addSource(
            url: "https://app.read.ai/analytics/meetings/01J1AGING0902",
            title: "[EF] Aging Biology Study Group",
            sourceType: "meeting",
            content: "Transcript",
            parentGroup: "aging biology study group",
            author: nil,
            occurredAt: "2026-09-02T16:55:00Z",
            connectorLabel: "Read AI Meetings"
        )
        let secondID = try sourceID(in: store, url: "https://app.read.ai/analytics/meetings/01J1AGING0902")
        #expect(try kstore.loadSourceForSync(secondID)?.parentGroup == groupID)
        #expect(try kstore.loadMeetingGroups().count == 1)

        // Only meetings have a date of their own, and a date has to parse:
        // silently ignoring either would recreate the bug this field fixes.
        #expect(throws: MCPError.self) {
            try store.addSource(
                url: "https://example.com/dated-article", title: "Dated", sourceType: "article",
                content: "x", parentGroup: nil, author: nil, occurredAt: "2026-09-02T16:55:00Z"
            )
        }
        #expect(throws: MCPError.self) {
            try store.addSource(
                url: "https://app.read.ai/analytics/meetings/BADDATE", title: "Bad date", sourceType: "meeting",
                content: "x", parentGroup: nil, author: nil, occurredAt: "last Tuesday"
            )
        }
    }

    @Test("add_source will not bring back a source the learner removed")
    func addSourceHonoursTheLearnersRemoval() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let kstore = try store.knowledgeStore()
        let url = "https://examplefellowship.zoom.us/rec/share/ExampleShareAAAA0000111122223333"
        let title = "Robin <> Zara standup"

        // Filed once — the way the recordings mailbox files a Zoom notice — then
        // removed in the app: `removeSelected` dismisses the URL and archives
        // the row, and deleting the series later takes the row away altogether.
        // Both shapes have to refuse; the second used to be re-added, because
        // only the row's existence was ever asked.
        _ = try store.addSource(
            url: url, title: title, sourceType: "meeting", content: nil,
            parentGroup: title, author: nil, occurredAt: "2026-09-09T17:39:09Z"
        )
        let id = try sourceID(in: store, url: url)
        try kstore.dismissSource(url: url, title: title)
        #expect(try kstore.loadSourceForSync(id)?.status == .archived)

        let archivedAnswer = try store.addSource(
            url: url, title: title, sourceType: "meeting", content: nil, parentGroup: title, author: nil
        )
        #expect(archivedAnswer.hasPrefix(MCPDataStore.removedByLearnerPrefix))
        #expect(archivedAnswer.contains("removed by the learner"))
        #expect(try kstore.loadSourceForSync(id)?.status == .archived)

        try kstore.deleteSource(id)
        let goneAnswer = try store.addSource(
            url: url, title: title, sourceType: "meeting", content: nil, parentGroup: title, author: nil
        )
        #expect(goneAnswer.hasPrefix(MCPDataStore.removedByLearnerPrefix))
        #expect(kstore.sourceExistsByURL(url)?.id == nil)

        // The batch form counts the refusal apart from an addition and a failure.
        let batch = try store.addSources([
            ["url": url, "title": title, "source_type": "meeting"],
            ["url": "https://example.com/fresh-article", "title": "Fresh", "source_type": "article", "content": "Text"],
        ], connectorLabel: nil)
        #expect(batch.contains("1 added, 0 updated, 0 already existed, 1 removed by the learner, 0 failed (of 2)"))
        #expect(kstore.sourceExistsByURL(url)?.id == nil)

        // Only the learner lifts it: an explicit re-add in the app clears the
        // tombstone, and the same call then adds.
        try kstore.undismissSource(url: url)
        let readded = try store.addSource(
            url: url, title: title, sourceType: "meeting", content: nil, parentGroup: title, author: nil
        )
        #expect(readded.hasPrefix("Added source"))
    }

    @Test("add_source will not stand a removed meeting series back up")
    func addSourceHonoursARemovedMeetingSeries() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let kstore = try store.knowledgeStore()
        let identityKey = StudioViewModel.removedMeetingGroupIdentitiesKey
        let titleKey = StudioViewModel.removedMeetingGroupTitlesKey
        let priorIdentities = UserDefaults.standard.stringArray(forKey: identityKey)
        let priorTitles = UserDefaults.standard.stringArray(forKey: titleKey)
        defer {
            if let priorIdentities {
                UserDefaults.standard.set(priorIdentities, forKey: identityKey)
            } else {
                UserDefaults.standard.removeObject(forKey: identityKey)
            }
            if let priorTitles {
                UserDefaults.standard.set(priorTitles, forKey: titleKey)
            } else {
                UserDefaults.standard.removeObject(forKey: titleKey)
            }
        }
        let groupID = "zoom:examplefellowship.zoom.us"
        let seriesTitle = "Robin <> Zara standup"
        let nextRecording = "https://examplefellowship.zoom.us/rec/share/ExampleShareBBBB4444555566667777"
        // What removeMeetingGroup records for a Zoom-account series.
        UserDefaults.standard.set(["group:\(groupID)"], forKey: identityKey)
        UserDefaults.standard.set([seriesTitle], forKey: titleKey)

        // The series is gone (deleted once the Undo window closed): its title,
        // in any case, must not create it again.
        let gone = try store.addSource(
            url: nextRecording, title: seriesTitle, sourceType: "meeting", content: nil,
            parentGroup: "robin <> zara standup", author: nil, occurredAt: "2026-09-10T02:19:46Z"
        )
        #expect(gone.hasPrefix(MCPDataStore.removedByLearnerPrefix))
        #expect(gone.contains("meeting series"))
        #expect(try kstore.loadMeetingGroups().isEmpty)
        #expect(kstore.sourceExistsByURL(nextRecording)?.id == nil)

        // While the Undo notice is up the series row is hidden and tombstoned:
        // the same answer, and nothing filed into the hidden row.
        var hidden = MeetingMetadata(title: seriesTitle)
        hidden.isHidden = true
        try kstore.saveMeetingGroup(name: groupID, metadata: hidden)
        let hiddenAnswer = try store.addSource(
            url: nextRecording, title: seriesTitle, sourceType: "meeting", content: nil,
            parentGroup: seriesTitle, author: nil
        )
        #expect(hiddenAnswer.hasPrefix(MCPDataStore.removedByLearnerPrefix))
        #expect(try kstore.loadSources().isEmpty)

        // A series the learner has visibly back is a series to file into,
        // whatever an older title tombstone still says.
        hidden.isHidden = false
        try kstore.saveMeetingGroup(name: groupID, metadata: hidden)
        let filed = try store.addSource(
            url: nextRecording, title: seriesTitle, sourceType: "meeting", content: nil,
            parentGroup: seriesTitle, author: nil
        )
        #expect(filed.contains("group_id: \(groupID)"))
        #expect(try kstore.loadSourceForSync(try sourceID(in: store, url: nextRecording))?.parentGroup == groupID)

        // A series that was never removed is created from its title as before.
        let other = try store.addSource(
            url: "https://app.read.ai/analytics/meetings/01J1AGING0819", title: "Aging Biology", sourceType: "meeting",
            content: "Transcript", parentGroup: "Aging Biology Study Group", author: nil
        )
        #expect(other.contains("meeting: Aging Biology Study Group"))
        #expect(try kstore.resolvedMeetingGroupID(matching: "Aging Biology Study Group") != nil)
    }

    @Test("A re-push with update_existing corrects a meeting's date and series")
    func addSourcesUpdateExistingCorrectsMeetingDateAndSeries() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let kstore = try store.knowledgeStore()
        let url = "https://app.read.ai/analytics/meetings/01J1BIOSTASIS0806"

        // The first push, from before the plugin sent either field: the
        // meeting is dated by the push and belongs to no series.
        let first = try store.addSources([
            ["url": url, "title": "[EF] Biostasis Working Group Sync (15 mins) - 2026/08/06 09:52",
             "source_type": "meeting", "content": "Transcript v1"],
        ], connectorLabel: "Read AI Meetings")
        #expect(first.contains("1 added"))
        let id = try sourceID(in: store, url: url)
        let before = try #require(try kstore.loadSourceForSync(id))
        #expect(before.parentGroup == nil)
        #expect(abs(before.dateAdded.timeIntervalSinceNow) < 60)

        // `sync --force`: the same item again with update_existing and both fields.
        let occurred = try #require(MCPDataStore.parseFlexibleTimestamp("2026-08-06T16:52:00Z"))
        let second = try store.addSources([
            ["url": url, "title": "[EF] Biostasis Working Group Sync (15 mins) - 2026/08/06 09:52",
             "source_type": "meeting", "content": "Transcript v1", "update_existing": true,
             "occurred_at": "2026-08-06T16:52:00Z", "parent_group": "Biostasis Working Group Sync (15 mins)"],
        ], connectorLabel: "Read AI Meetings")
        #expect(second.contains("1 updated"))
        #expect(second.contains("occurred_at, parent_group"))
        let after = try #require(try kstore.loadSourceForSync(id))
        #expect(after.dateAdded == occurred)
        let groupID = try #require(try kstore.resolvedMeetingGroupID(matching: "Biostasis Working Group Sync (15 mins)"))
        #expect(after.parentGroup == groupID)
        #expect(try scalarInt(
            dbPath: tmpPath + "/knowledge.db",
            "SELECT COUNT(*) FROM group_members WHERE source_id = '\(id)' AND group_id = '\(groupID)'"
        ) == 1)

        // Pushing the identical item a third time changes nothing and says so
        // per field: the date and series are already right.
        let third = try store.addSources([
            ["url": url, "title": "[EF] Biostasis Working Group Sync (15 mins) - 2026/08/06 09:52",
             "source_type": "meeting", "content": "Transcript v1", "update_existing": true,
             "occurred_at": "2026-08-06T16:52:00Z", "parent_group": "Biostasis Working Group Sync (15 mins)"],
        ], connectorLabel: "Read AI Meetings")
        #expect(third.contains("1 updated"))
        #expect(!third.contains("occurred_at"))
        #expect(!third.contains("parent_group"))

        // A bad date on an update is that item's failure, not the batch's.
        let bad = try store.addSources([
            ["url": url, "title": "x", "source_type": "meeting", "content": "Transcript v1",
             "update_existing": true, "occurred_at": "yesterday"],
            ["url": "https://app.read.ai/analytics/meetings/01J1OTHER", "title": "Other", "source_type": "meeting",
             "content": "t", "occurred_at": "2026-09-01T10:00:00Z", "parent_group": "One-off"],
        ], connectorLabel: "Read AI Meetings")
        #expect(bad.contains("1 added"))
        #expect(bad.contains("1 failed"))
        #expect(bad.contains("[0] Error:"))
        #expect(bad.contains("ISO 8601"))
    }

    @Test("remove_connector_sources removes exactly the plugin's sources")
    func removePluginSourcesRemovesOwnOnly() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }

        _ = try store.addSource(
            url: "https://example.com/rm/1", title: "R1", sourceType: "article",
            content: "x", parentGroup: nil, author: nil, connectorLabel: "Doomed Plugin"
        )
        _ = try store.addSource(
            url: "https://example.com/rm/2", title: "R2", sourceType: "article",
            content: "y", parentGroup: nil, author: nil, connectorLabel: "Doomed Plugin"
        )
        _ = try store.addSource(
            url: "https://example.com/rm/keep", title: "Keep", sourceType: "article",
            content: "z", parentGroup: nil, author: nil
        )

        let result = try store.removePluginSources(label: "Doomed Plugin")
        #expect(result.contains("Removed 2 of 2"))

        let kstore = try store.knowledgeStore()
        #expect(try kstore.activeSourceIDs(withPluginLabel: "Doomed Plugin").isEmpty)
        let keptID = try sourceID(in: store, url: "https://example.com/rm/keep")
        let kept = try #require(try kstore.loadSourceForSync(keptID))
        #expect(kept.status == .active)

        #expect(try store.removePluginSources(label: "Doomed Plugin")
            .contains("No active sources found"))
        #expect(try store.removePluginSources(label: "  ").hasPrefix("Error:"))
    }

    @Test("Knowledge exclusions follow source-family policy; hiding is visual and excludes nothing")
    func knowledgeSearchExcludedSourceIDs() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "read-ai",
            title: "Read AI meeting",
            content: "meeting notes",
            sourceType: "meeting",
            discoveryOrigin: DiscoveryOrigin.readAI.rawValue
        )
        try insertSource(
            dbPath: dbPath,
            id: "drive",
            title: "Drive meeting",
            content: "meeting notes",
            sourceType: "meeting",
            discoveryOrigin: DiscoveryOrigin.googleDriveMeetings.rawValue
        )
        try insertSource(
            dbPath: dbPath,
            id: "zoom",
            title: "Zoom recording",
            content: "recording transcript",
            sourceType: "meeting",
            discoveryOrigin: DiscoveryOrigin.zoom.rawValue,
            url: "https://example.zoom.us/rec/share/abc"
        )
        try insertSource(dbPath: dbPath, id: "hidden", title: "Hidden", content: "private notes")

        let knowledgeStore = try store.knowledgeStore()
        try knowledgeStore.setSourceHidden("hidden", hidden: true)
        let excluded = try knowledgeStore.knowledgeSearchExcludedSourceIDs(excludedTabs: [.meetings])

        // Meetings is one knowledge family across every provider, so excluding
        // it excludes the Drive and Zoom sessions as well as the Read AI one.
        //
        // This is a deliberate narrowing. The split tabs allowed "exclude Read
        // AI meetings from AI discovery but keep Drive meetings", because the
        // exclusion preference is keyed by tab and provider decided the tab.
        // One tab makes it all-or-nothing. Getting that back means a
        // provider-level preference of its own, which is the honest shape for a
        // provider-level policy — not a side effect of which tab a session sat in.
        #expect(excluded.contains("read-ai"))
        #expect(excluded.contains("drive"))
        #expect(excluded.contains("zoom"))
        // Hiding takes a source off the sources list and nowhere else
        // (product owner, 2026-09-11): it stays in knowledge.
        #expect(!excluded.contains("hidden"))

        // And with Meetings included, no provider's meetings are excluded.
        let meetingsIncluded = try knowledgeStore.knowledgeSearchExcludedSourceIDs(excludedTabs: [.videos])
        #expect(!meetingsIncluded.contains("read-ai"))
        #expect(!meetingsIncluded.contains("drive"))
        #expect(!meetingsIncluded.contains("zoom"))
        #expect(!meetingsIncluded.contains("hidden"))
        // And with nothing excluded, nothing is excluded — hidden or not.
        #expect(try knowledgeStore.knowledgeSearchExcludedSourceIDs(excludedTabs: []).isEmpty)

        // A hidden show is the exception: its episodes are muted for the AI
        // too, except one the learner unhid on its own. A show that is merely
        // hidden episode by episode is not.
        var muted = StudioArticle(url: "https://pod.example/muted-1", title: "Muted episode", sourceType: .podcast, id: "muted-1")
        muted.domain = "Muted Show"
        var unhidden = StudioArticle(url: "https://pod.example/muted-2", title: "Unhidden episode", sourceType: .podcast, id: "muted-2")
        unhidden.domain = "Muted Show"
        var loose = StudioArticle(url: "https://pod.example/loose", title: "Hidden by itself", sourceType: .podcast, id: "loose-hidden")
        loose.domain = "Open Show"
        for episode in [muted, unhidden, loose] {
            try knowledgeStore.saveSource(episode)
        }
        try knowledgeStore.setPodcastShowHidden("Muted Show", hidden: true)
        try knowledgeStore.setPodcastEpisodeVisibleOverride("muted-2", visible: true)
        try knowledgeStore.setSourceHidden("loose-hidden", hidden: true)
        let mutedShow = try knowledgeStore.knowledgeSearchExcludedSourceIDs(excludedTabs: [])
        #expect(mutedShow == ["muted-1"])
        try knowledgeStore.setPodcastShowHidden("Muted Show", hidden: false)
        #expect(try knowledgeStore.knowledgeSearchExcludedSourceIDs(excludedTabs: []).isEmpty)
    }

    @Test("Keyword search still sees hidden sources; an excluded family is skipped and its cap counts only what it shows")
    func keywordSearchSeesHiddenSourcesAndSkipsExcludedFamilies() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        // Hiding is visual (product owner, 2026-09-11): a hidden lecture leaves the
        // sources list and stays answerable, so search still returns it.
        // An article, since course material belongs to no Sources family and
        // so is never excluded by one (courses-design.md).
        try insertSource(dbPath: dbPath, id: "hidden-lecture", title: "MCB 80: Lecture 19 - Critical periods and aging",
                         content: "Alzheimer's disease and the aging brain", sourceType: "article")
        try insertSource(dbPath: dbPath, id: "paper-a", title: "Amyloid paper", content: "Alzheimer's disease pathology", sourceType: "paper")
        try insertSource(dbPath: dbPath, id: "paper-b", title: "Tau paper", content: "Alzheimer's disease and tau", sourceType: "paper")
        try store.knowledgeStore().setSourceHidden("hidden-lecture", hidden: true)

        let sweep = try store.searchSourcesKeyword(keywords: ["Alzheimer"])
        #expect(sweep.contains("paper-a"))
        #expect(sweep.contains("paper-b"))
        #expect(sweep.contains("hidden-lecture"))

        // Narrowed to articles, the hidden lecture is the answer.
        let articles = try store.searchSourcesKeyword(keywords: ["Alzheimer"], sourceType: "article")
        #expect(articles.contains("hidden-lecture"))

        // A source family excluded from knowledge in Settings is the boundary
        // that still applies, and an excluded row must not consume the page:
        // two visible matches fit a cap of two exactly, so the answer is
        // complete, not "2+".
        let defaults = UserDefaults.standard
        let key = StudioSidebarTab.knowledgeExclusionPreferenceKey
        let priorExclusion = defaults.stringArray(forKey: key)
        defer {
            if let priorExclusion { defaults.set(priorExclusion, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.set([StudioSidebarTab.articles.rawValue], forKey: key)
        #expect(try store.knowledgeStore().knowledgeSearchExcludedSourceIDs(includeArchived: true) == ["hidden-lecture"])
        let page = try store.searchSourcesKeyword(keywords: ["Alzheimer"], limit: 2)
        #expect(page.contains("paper-a"))
        #expect(page.contains("paper-b"))
        #expect(!page.contains("hidden-lecture"))
        #expect(page.contains("2 sources"))
        #expect(!page.contains("2+"))

        // And a cap of one is honestly truncated by the visible remainder.
        let one = try store.searchSourcesKeyword(keywords: ["Alzheimer"], limit: 1)
        #expect(one.contains("1+ sources"))
        #expect(!one.contains("hidden-lecture"))
    }

    @Test("The article family covers manually added and unclassified web pages")
    func keywordSearchArticleFamilyCoversWebPageStates() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(dbPath: dbPath, id: "web-article", title: "Classified article", content: "Alzheimer's disease research", sourceType: "article")
        try insertSource(dbPath: dbPath, id: "web-manual", title: "Manually added page", content: "Alzheimer's disease notes", sourceType: "manual")
        try insertSource(dbPath: dbPath, id: "web-pending", title: "Page awaiting classification", content: "Alzheimer's disease preprint", sourceType: "unclassified")
        try insertSource(dbPath: dbPath, id: "paper-a", title: "Amyloid paper", content: "Alzheimer's disease pathology", sourceType: "paper")

        // One filter, every saved web page: the schema offers article alone.
        let articles = try store.searchSourcesKeyword(keywords: ["Alzheimer"], sourceType: "article")
        #expect(articles.contains("web-article"))
        #expect(articles.contains("web-manual"))
        #expect(articles.contains("web-pending"))
        #expect(!articles.contains("paper-a"))
        #expect(articles.contains("3 sources"))

        // The storage states are still accepted from an older schema and mean
        // the same family, so a stale client gets the same answer.
        let pending = try store.searchSourcesKeyword(keywords: ["Alzheimer"], sourceType: "unclassified")
        #expect(pending == articles)

        // Other families stay exact.
        let papers = try store.searchSourcesKeyword(keywords: ["Alzheimer"], sourceType: "paper")
        #expect(papers.contains("paper-a"))
        #expect(!papers.contains("web-manual"))

        // And the schema no longer offers the storage states, only families.
        let schema = MCPToolRegistry(store: MCPDataStore()).tools
            .first { $0.name == "search_sources_keyword" }?
            .inputSchema["properties"] as? [String: Any]
        let offered = (schema?["source_type"] as? [String: Any])?["enum"] as? [String]
        #expect(offered == StudioSourceType.searchFamilyNames)
        #expect(offered?.contains("unclassified") == false)
        #expect(offered?.contains("manual") == false)

        #expect(throws: MCPError.self) {
            _ = try store.searchSourcesKeyword(keywords: ["Alzheimer"], sourceType: "slack")
        }
    }

    @Test("Keyword search reads only the named sources, takes 30 keywords, and names the ones found nowhere")
    func keywordSearchScopesToNamedSources() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        // The 2026-09-23 chat on two papers asked which of one paper's compounds
        // the other shares; a third paper naming them must stay out of the sweep.
        try insertSource(dbPath: dbPath, id: "twin", title: "Digital twin paper",
                         content: "Cells were treated with nocodazole and stained with MitoTracker Green; ATP was measured.", sourceType: "paper")
        try insertSource(dbPath: dbPath, id: "cardiac", title: "Cardiac paper",
                         content: "Sestamibi uptake fell after CCCP; ATP and calcium were measured.", sourceType: "paper")
        try insertSource(dbPath: dbPath, id: "elsewhere", title: "Unrelated paper",
                         content: "Nocodazole and CCCP appear here too.", sourceType: "paper")

        let scoped = try store.searchSourcesKeyword(
            keywords: ["nocodazole", "CCCP", "ATP", "oligomycin"],
            sourceIDs: ["twin", "cardiac"]
        )
        #expect(scoped.contains("id: twin"))
        #expect(scoped.contains("id: cardiac"))
        #expect(!scoped.contains("elsewhere"))
        #expect(scoped.contains("among the 2 given sources"))
        #expect(scoped.contains("In none of them: \"oligomycin\"."))

        // Thirty keywords go in one call; past that the refusal says how to split.
        let thirty = (1...30).map { "compound\($0)" }
        _ = try store.searchSourcesKeyword(keywords: thirty, sourceIDs: ["twin"])
        do {
            _ = try store.searchSourcesKeyword(keywords: thirty + ["compound31"])
            Issue.record("31 keywords should be refused")
        } catch MCPError.invalidInput(let message) {
            #expect(message.contains("has 31"))
            #expect(message.contains("several calls"))
        }

        // An id that is no source is refused rather than quietly searching nothing.
        #expect(throws: MCPError.self) {
            _ = try store.searchSourcesKeyword(keywords: ["ATP"], sourceIDs: ["no-such-source"])
        }

        // The schema carries the cap, so a model sees it before it calls.
        let schema = MCPToolRegistry(store: MCPDataStore()).tools
            .first { $0.name == "search_sources_keyword" }?
            .inputSchema["properties"] as? [String: Any]
        #expect((schema?["keywords"] as? [String: Any])?["maxItems"] as? Int == SourceKeywordSearch.maximumKeywords)
        #expect(schema?["source_ids"] != nil)
    }

    @Test("Keyword search finds a keyword that is not ASCII, and ASCII keywords the text spells with ligatures")
    func keywordSearchFoldsCaseBeyondASCII() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        // Bioenergetics Chapter 4 said Δψ 58 times, and the single keyword
        // "Δψ" answered that no source contains it (2026-09-26): SQL bound it
        // lowercased, as δψ, and LIKE folds only ASCII case.
        try insertSource(dbPath: dbPath, id: "chapter-4", title: "Chapter 4: Chemiosmotic Energy Transduction",
                         content: "Δp is dominant. The membrane potential (Δψ) and ΔpH add up; ΔΨ is the same quantity.", sourceType: "book")
        try insertSource(dbPath: dbPath, id: "worksheet", title: "Math 21 B: worksheet27",
                         content: "Diﬀerential Operators. Previously on Math 21b...", sourceType: "course")
        try insertSource(dbPath: dbPath, id: "german", title: "Stadtplan", content: "Die Straße nach Wien.")
        try insertSource(dbPath: dbPath, id: "english", title: "Unrelated", content: "This sis sa text about proton leak.")

        let greek = try store.searchSourcesKeyword(keywords: ["Δψ"])
        #expect(greek.contains("id: chapter-4"))
        #expect(greek.contains("Δψ ×2"))
        let lowercase = try store.searchSourcesKeyword(keywords: ["δψ"])
        #expect(lowercase.contains("id: chapter-4"))
        #expect(lowercase.contains("δψ ×2"))
        let mixed = try store.searchSourcesKeyword(keywords: ["ΔpH", "membrane"], matchAll: true)
        #expect(mixed.contains("id: chapter-4"))

        // PDFs extract "ff" as U+FB00, and a sweep for the ASCII word must
        // still find it; so must "strasse" find "Straße".
        let ligature = try store.searchSourcesKeyword(keywords: ["Differential Operators"])
        #expect(ligature.contains("id: worksheet"))
        let sharpS = try store.searchSourcesKeyword(keywords: ["strasse"])
        #expect(sharpS.contains("id: german"))

        // And "ß" means those letters, not "s" and any character after it.
        let strict = try store.searchSourcesKeyword(keywords: ["ß"])
        #expect(strict.contains("id: german"))
        #expect(!strict.contains("id: english"))
        #expect(strict.contains("ß ×1"))
    }

    @Test("Every source type a tool schema offers is one the tool accepts")
    func toolSchemasOfferOnlyKnownSourceTypes() throws {
        var checked = 0
        for tool in MCPToolRegistry(store: MCPDataStore()).tools {
            guard let properties = tool.inputSchema["properties"] as? [String: Any] else { continue }
            var offered: [String] = []
            if let single = properties["source_type"] as? [String: Any],
               let values = single["enum"] as? [String] {
                offered += values
            }
            if let many = properties["source_types"] as? [String: Any],
               let items = many["items"] as? [String: Any],
               let values = items["enum"] as? [String] {
                offered += values
            }
            for value in offered {
                checked += 1
                let accepted: StudioSourceType? = tool.name == "generate_source_audio"
                    ? MCPDataStore.audioGenerationSourceType(named: value)
                    : StudioSourceType(rawValue: value)
                #expect(accepted != nil, "\(tool.name) offers source type '\(value)', which the app has no source family for")
            }
        }
        // The search tools and the audio tool all carry a type list; a schema
        // refactor that drops them should be noticed here, not by a caller.
        #expect(checked >= 3)
    }

    /// "Look at the latest YouTube video" (2026-09-22) came back with another
    /// recent video: the chat reached for a ranked search, which orders by
    /// similarity. filter_sources with only a type is the recency listing, and
    /// it prints the minute so same-day imports read in order.
    @Test("filter_sources by type alone lists the most recently added first, with the time it was added")
    func filterSourcesLatestOfAType() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "video-morning", title: "Morning upload", content: "a", sourceType: "video")
        try insertSource(dbPath: dbPath, id: "video-afternoon", title: "Afternoon upload", content: "b", sourceType: "video")
        try insertSource(dbPath: dbPath, id: "video-yesterday", title: "Yesterday's upload", content: "c", sourceType: "video")
        try insertSource(dbPath: dbPath, id: "paper-newest", title: "Newest paper", content: "d", sourceType: "paper")
        var parts = DateComponents()
        parts.year = 2026; parts.month = 9; parts.day = 22; parts.hour = 9; parts.minute = 5
        let morning = try #require(Calendar.current.date(from: parts))
        let afternoon = morning.addingTimeInterval(6 * 3600)
        let yesterday = morning.addingTimeInterval(-86400)
        try execSQL(dbPath: dbPath, """
            UPDATE sources SET date_added = \(morning.timeIntervalSinceReferenceDate) WHERE id = 'video-morning';
            UPDATE sources SET date_added = \(afternoon.timeIntervalSinceReferenceDate) WHERE id = 'video-afternoon';
            UPDATE sources SET date_added = \(yesterday.timeIntervalSinceReferenceDate) WHERE id = 'video-yesterday';
            UPDATE sources SET date_added = \(afternoon.addingTimeInterval(60).timeIntervalSinceReferenceDate) WHERE id = 'paper-newest';
        """)

        let latest = try store.filterSources(show: nil, author: nil, titleContains: nil, text: nil,
                                             sourceType: "video", includeArchived: false, limit: 1)
        let lines = latest.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("3 sources, showing the 1 most recently added"))
        #expect(lines[1].contains("video-afternoon") && lines[1].contains("added 2026-09-22 15:05"))
        #expect(!latest.contains("paper-newest"))

        let all = try store.filterSources(show: nil, author: nil, titleContains: nil, text: nil,
                                          sourceType: "video", includeArchived: false, limit: 10)
        let order = ["video-afternoon", "video-morning", "video-yesterday"].map { all.range(of: $0)?.lowerBound }
        #expect(order.allSatisfy { $0 != nil })
        #expect(order[0]! < order[1]! && order[1]! < order[2]!)
    }

    /// 2026-09-22: "which Huberman episodes are on mitochondria" was answered
    /// by a ranked search over the whole library, where every other show's
    /// mitochondria episode competed for eight slots and the Jared Rutter
    /// episode never surfaced. A show or author is metadata, and listing by it
    /// has to be exhaustive.
    @Test("filter_sources lists every episode of a show and every paper by an author; a show scopes both searches")
    func filterSourcesByShowAndAuthor() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "ep-rutter", title: "How Mitochondria Control Your Metabolism | Dr. Jared Rutter",
                         content: "pyruvate enters the mitochondria", sourceType: "podcast")
        try insertSource(dbPath: dbPath, id: "ep-picard", title: "Improve Energy & Longevity by Optimizing Mitochondria | Dr. Martin Picard",
                         content: "mitochondria signal", sourceType: "podcast")
        try insertSource(dbPath: dbPath, id: "ep-sleep", title: "Master Your Sleep", content: "adenosine builds up", sourceType: "podcast")
        try insertSource(dbPath: dbPath, id: "ep-other", title: "Mitochondria with Martin Picard", content: "mitochondria everywhere", sourceType: "podcast")
        try insertSource(dbPath: dbPath, id: "paper-picard", title: "Mitochondrial psychobiology", content: "energy", sourceType: "paper")
        try insertSource(dbPath: dbPath, id: "paper-else", title: "Unrelated biology", content: "cells", sourceType: "paper")
        try execSQL(dbPath: dbPath, """
            UPDATE podcasts SET domain = 'Huberman Lab', show_name = 'Huberman Lab' WHERE source_id IN ('ep-rutter', 'ep-picard', 'ep-sleep');
            UPDATE podcasts SET domain = 'Mind & Matter', show_name = 'Mind & Matter' WHERE source_id = 'ep-other';
            UPDATE papers SET author = 'Martin Picard, Carmen Sandi' WHERE source_id = 'paper-picard';
            UPDATE papers SET author = 'Someone Else' WHERE source_id = 'paper-else';
        """)

        let shows = try store.listShows(kind: nil)
        #expect(shows.contains("[podcast] Huberman Lab — 3 episodes"))
        #expect(shows.contains("[podcast] Mind & Matter — 1 episode"))

        // Part of the name is enough, and every episode comes back.
        let huberman = try store.filterSources(show: "huberman", author: nil, titleContains: nil, text: nil,
                                               sourceType: nil, includeArchived: false, limit: 200)
        #expect(huberman.contains("ep-rutter") && huberman.contains("ep-picard") && huberman.contains("ep-sleep"))
        #expect(!huberman.contains("ep-other"))
        #expect(huberman.contains("3 sources"))

        let hubermanMito = try store.filterSources(show: "Huberman Lab", author: nil, titleContains: "mitochondria", text: nil,
                                                   sourceType: nil, includeArchived: false, limit: 200)
        #expect(hubermanMito.contains("ep-rutter") && hubermanMito.contains("ep-picard") && !hubermanMito.contains("ep-sleep"))

        let byAuthor = try store.filterSources(show: nil, author: "picard", titleContains: nil, text: nil,
                                               sourceType: "paper", includeArchived: false, limit: 200)
        #expect(byAuthor.contains("paper-picard") && !byAuthor.contains("paper-else"))

        // "Everything with Martin Picard": guest in a title or author of a paper.
        let person = try store.filterSources(show: nil, author: nil, titleContains: nil, text: "Martin Picard",
                                             sourceType: nil, includeArchived: false, limit: 200)
        #expect(person.contains("ep-picard") && person.contains("ep-other") && person.contains("paper-picard"))
        #expect(!person.contains("ep-rutter"))

        #expect(throws: MCPError.self) {
            _ = try store.filterSources(show: nil, author: nil, titleContains: nil, text: nil,
                                        sourceType: nil, includeArchived: false, limit: 200)
        }
        #expect(throws: MCPError.self) {
            _ = try store.filterSources(show: "No Such Show", author: nil, titleContains: nil, text: nil,
                                        sourceType: nil, includeArchived: false, limit: 200)
        }

        // The keyword sweep scoped to the show leaves the other show's episode out.
        let sweep = try store.searchSourcesKeyword(keywords: ["mitochondria"], show: "Huberman")
        #expect(sweep.contains("ep-rutter") && sweep.contains("ep-picard"))
        #expect(!sweep.contains("ep-other"))

        // A show alone is enough for the semantic tool to list that show.
        let listed = try await store.searchSourcesSemantic(queryText: "", show: "Huberman Lab")
        #expect(listed.contains("ep-rutter") && listed.contains("ep-sleep") && !listed.contains("ep-other"))
    }

    /// A book is stored as chapter-level sources; its title and author live on
    /// the book record, not on the chapters. "Do I have Power, Sex, Suicide by
    /// Nick Lane?" answered no (2026-10-03) because `author` and `text` only
    /// read the chapter rows.
    @Test("filter_sources finds a book's chapters by the book's title and author")
    func filterSourcesFindsBookChaptersByBookTitleAndAuthor() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "chapter-5", title: "5) Proton Power", content: "chemiosmosis", sourceType: "book")
        try insertSource(dbPath: dbPath, id: "chapter-6", title: "6) The Dynamo", content: "membranes", sourceType: "book")
        try insertSource(dbPath: dbPath, id: "other-chapter", title: "1) Intro", content: "other", sourceType: "book")
        try execSQL(dbPath: dbPath, """
            INSERT INTO books (id, title, author) VALUES ('book-power', 'Power, Sex, Suicide', 'Nick Lane');
            INSERT INTO books (id, title, author) VALUES ('book-other', 'Another Book', 'Someone Else');
            INSERT INTO group_members (source_id, group_id, sort_index)
            VALUES ('chapter-5', 'book-power', 5), ('chapter-6', 'book-power', 6), ('other-chapter', 'book-other', 1);
        """)

        let byAuthor = try store.filterSources(show: nil, author: "Nick Lane", titleContains: nil, text: nil,
                                               sourceType: nil, includeArchived: false, limit: 200)
        #expect(byAuthor.contains("chapter-5") && byAuthor.contains("chapter-6") && !byAuthor.contains("other-chapter"))
        #expect(byAuthor.contains("by Nick Lane"))

        let byText = try store.filterSources(show: nil, author: nil, titleContains: nil, text: "nick lane",
                                             sourceType: "book", includeArchived: false, limit: 200)
        #expect(byText.contains("chapter-5") && !byText.contains("other-chapter"))

        let byBookTitle = try store.filterSources(show: nil, author: nil, titleContains: nil, text: "Power, Sex, Suicide",
                                                  sourceType: nil, includeArchived: false, limit: 200)
        #expect(byBookTitle.contains("chapter-5") && byBookTitle.contains("chapter-6") && !byBookTitle.contains("other-chapter"))

        // `title_contains` reads the book's title too: the chat asked for
        // "Transformer" by title and found only a video about it, because the
        // chapters are each titled for themselves.
        let byTitleContains = try store.filterSources(show: nil, author: nil, titleContains: "sex, suicide", text: nil,
                                                      sourceType: nil, includeArchived: false, limit: 200)
        #expect(byTitleContains.contains("chapter-5") && byTitleContains.contains("chapter-6") && !byTitleContains.contains("other-chapter"))
    }

    func insertSource(
        dbPath: String,
        id: String,
        title: String,
        content: String,
        sourceType: String = "article",
        discoveryOrigin: String = "test",
        url: String? = nil
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw MCPError.database("Failed to open test DB for source insert")
        }
        defer { sqlite3_close(db) }

        var sourceStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO sources (id, date_added, state, source_type, status)
            VALUES (?, ?, ?, ?, 'active')
        """, -1, &sourceStmt, nil) == SQLITE_OK else {
            throw MCPError.database("Failed to prepare test source insert")
        }
        defer { sqlite3_finalize(sourceStmt) }

        sqlite3_bind_text(sourceStmt, 1, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(sourceStmt, 2, 0)
        sqlite3_bind_text(sourceStmt, 3, ("ready" as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(sourceStmt, 4, (sourceType as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(sourceStmt) == SQLITE_DONE else {
            throw MCPError.database("Failed to execute test source insert")
        }

        let subtypeTable: String
        switch sourceType {
        case "paper": subtypeTable = "papers"
        case "podcast": subtypeTable = "podcasts"
        case "book": subtypeTable = "book_sources"
        case "course": subtypeTable = "course_sources"
        case "meeting": subtypeTable = "meeting_sources"
        case "video": subtypeTable = "videos"
        case "xPost": subtypeTable = "x_posts"
        default: subtypeTable = "articles"
        }
        var subtypeStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO \(subtypeTable) (source_id, url, normalized_url, title, domain, discovery_origin, word_count)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, -1, &subtypeStmt, nil) == SQLITE_OK else {
            throw MCPError.database("Failed to prepare test subtype insert")
        }
        defer { sqlite3_finalize(subtypeStmt) }
        sqlite3_bind_text(subtypeStmt, 1, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let sourceURL = url ?? "https://example.com/\(id)"
        sqlite3_bind_text(subtypeStmt, 2, (sourceURL as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(subtypeStmt, 3, (sourceURL as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(subtypeStmt, 4, (title as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(subtypeStmt, 5, ("example.com" as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(subtypeStmt, 6, (discoveryOrigin as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(subtypeStmt, 7, Int64(content.split(separator: " ").count))
        guard sqlite3_step(subtypeStmt) == SQLITE_DONE else {
            throw MCPError.database("Failed to execute test subtype insert")
        }

        var contentStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO source_content (source_id, content) VALUES (?, ?)", -1, &contentStmt, nil) == SQLITE_OK else {
            throw MCPError.database("Failed to prepare test content insert")
        }
        defer { sqlite3_finalize(contentStmt) }

        sqlite3_bind_text(contentStmt, 1, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(contentStmt, 2, (content as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(contentStmt) == SQLITE_DONE else {
            throw MCPError.database("Failed to execute test content insert")
        }
    }

    func execSQL(dbPath: String, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw MCPError.database("Failed to open test DB")
        }
        defer { sqlite3_close(db) }

        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw MCPError.database(message)
        }
    }

    func scalarInt(dbPath: String, _ sql: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw MCPError.database("Failed to open test DB")
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MCPError.database("Failed to prepare scalar query")
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func scalarString(dbPath: String, _ sql: String) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw MCPError.database("Failed to open test DB")
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MCPError.database("Failed to prepare scalar query")
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let value = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: value)
    }

    func parsedSessionID(from response: String) -> String {
        response
            .components(separatedBy: "\n")
            .first { $0.hasPrefix("Session ID: ") }?
            .replacingOccurrences(of: "Session ID: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func makeTestPDF(at url: URL, text: String) throws {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 420, height: 640)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw MCPError.invalidInput("Could not create test PDF")
        }

        context.beginPDFPage(nil)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18),
            .foregroundColor: NSColor.black
        ]
        NSString(string: text).draw(
            in: CGRect(x: 36, y: 120, width: 340, height: 480),
            withAttributes: attributes
        )
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()

        try (data as Data).write(to: url)
    }

    func insertFTS(dbPath: String, id: String, title: String, author: String = "", body: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw MCPError.database("Failed to open test DB for full-text insert")
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO source_fts (source_id, title, author, body) VALUES (?, ?, ?, ?)
        """, -1, &stmt, nil) == SQLITE_OK else {
            throw MCPError.database("Failed to prepare full-text insert")
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, transient)
        sqlite3_bind_text(stmt, 2, (title as NSString).utf8String, -1, transient)
        sqlite3_bind_text(stmt, 3, (author as NSString).utf8String, -1, transient)
        sqlite3_bind_text(stmt, 4, (body as NSString).utf8String, -1, transient)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MCPError.database("Failed to insert full-text row")
        }
    }

    func insertEmbedding(dbPath: String, entityId: String, vector: [Float]) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw MCPError.database("Failed to open test DB for embedding insert")
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO embeddings (entity_type, entity_id, model, vector, updated_at)
            VALUES (?, ?, ?, ?, ?)
        """, -1, &stmt, nil) == SQLITE_OK else {
            throw MCPError.database("Failed to prepare embedding insert")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, ("source" as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, (entityId as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, (StorageService.sourceEmbeddingModel as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        _ = vector.withUnsafeBufferPointer { buffer in
            sqlite3_bind_blob(stmt, 4, buffer.baseAddress, Int32(buffer.count * MemoryLayout<Float>.size), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_bind_double(stmt, 5, 0)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MCPError.database("Failed to execute embedding insert")
        }
    }

    /// A timebound Goal (a companion row with a deadline and no Notebook) whose
    /// sources are in its pool and placed on the Schedule, tagged with it.
    func insertScheduleGoal(
        dbPath: String,
        goalID: String,
        startAt: Date,
        endAt: Date,
        items: [(id: String, sourceID: String, addedAt: Date, completedAt: Date?)]
    ) throws {
        let now = startAt.timeIntervalSinceReferenceDate
        try execSQL(dbPath: dbPath, """
            INSERT INTO learning_goals (id, title, start_at, end_at, created_at, updated_at, status, kind)
            VALUES ('\(goalID)', 'Study plan', \(startAt.timeIntervalSinceReferenceDate), \(endAt.timeIntervalSinceReferenceDate), \(now), \(now), 'active', 'companion');
        """)
        for item in items {
            let completedSQL = item.completedAt.map { "\($0.timeIntervalSinceReferenceDate)" } ?? "NULL"
            try execSQL(dbPath: dbPath, """
                INSERT INTO learning_goal_items (id, goal_id, source_id, added_at, completed_at)
                VALUES ('\(item.id)', '\(goalID)', '\(item.sourceID)', \(item.addedAt.timeIntervalSinceReferenceDate), \(completedSQL));
            """)
            // The Schedule tools read shared placements now: one scheduled_sources row
            // per source (planned day + completion), tagged to goals via
            // scheduled_source_goals. Each test source may appear in only one goal
            // (source_id is UNIQUE on scheduled_sources).
            let addedAtSQL = "\(item.addedAt.timeIntervalSinceReferenceDate)"
            try execSQL(dbPath: dbPath, """
                INSERT INTO scheduled_sources (id, source_id, planned_at, added_at, completed_at, created_at, updated_at)
                VALUES ('\(item.id)', '\(item.sourceID)', \(addedAtSQL), \(addedAtSQL), \(completedSQL), \(now), \(now));
            """)
            try execSQL(dbPath: dbPath, """
                INSERT INTO scheduled_source_goals (scheduled_source_id, goal_id, added_at)
                VALUES ('\(item.id)', '\(goalID)', \(addedAtSQL));
            """)
        }
    }

    func insertCompletedReviewSession(dbPath: String, sessionID: String, sourceID: String, endedAt: Date) throws {
        try execSQL(dbPath: dbPath, """
            INSERT INTO review_sessions (id, topic, started_at, ended_at, status, overall_score, summary)
            VALUES ('\(sessionID)', 'Review', \(endedAt.addingTimeInterval(-600).timeIntervalSinceReferenceDate), \(endedAt.timeIntervalSinceReferenceDate), 'completed', 0.9, 'Reviewed');
            INSERT INTO review_session_sources (session_id, source_id)
            VALUES ('\(sessionID)', '\(sourceID)');
        """)
    }

    func parseJSON(_ text: String) throws -> [String: Any] {
        let data = Data(text.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.invalidInput("Expected JSON object")
        }
        return object
    }

}

#endif
