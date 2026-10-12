import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// The day close (docs/memory-design.md, "The day close"): the evening pass
/// that folds the day's chats into understanding documents, warms ideas for
/// what was read, and moves a watermark so a run that repeats finds only
/// what is new. What has to hold: the clock decides like the morning's does;
/// a chat the learner wrote in is found once, closed once, and found again
/// only when it grows; the closer's documents and summary land where the
/// planner reads them; a store from before schema 127 gains the two tables
/// with nothing lost; and Settings › General › Memory review is reachable over MCP.
@Suite("Day close")
struct DayCloseTests {

    // MARK: - Fixtures

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func makeRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-dayclose-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A source with text, marked read at `readAt`, whose stored ideas already
    /// match its text so the pass warms it without a model call.
    private static func seedReadSource(
        _ id: String, title: String, readAt: Date, on storage: StorageService
    ) async throws {
        let text = "\(title) is the source text. It says one thing worth remembering about \(title.lowercased())."
        var article = StudioArticle(url: "https://example.com/\(id)", title: title, sourceType: .article, id: id)
        article.content = text
        article.state = .ready
        article.readAt = readAt
        try await storage.saveSource(article)
        let hash = PaperContentPreparationService.sha256(text)
        let idea = SourceIdea(
            id: SourceIdea.id(sourceID: id, contentHash: hash, index: 0),
            sourceID: id,
            statement: "\(title) says one thing worth remembering.",
            recallNote: "",
            anchors: [],
            wanted: false,
            contentHash: hash,
            sortIndex: 0,
            createdAt: readAt,
            updatedAt: readAt
        )
        try await storage.replaceSourceIdeas(sourceID: id, contentHash: hash, ideas: [idea])
    }

    private static func summary(of sessionID: String, in store: KnowledgeStore) throws -> String? {
        var summary: String?
        try store.queryBind("SELECT summary FROM review_sessions WHERE id = ?", bind: { stmt in
            store.bind(stmt, 1, sessionID)
        }) { stmt in
            summary = store.string(stmt, 0)
        }
        return summary
    }

    private static func tableExists(_ name: String, in store: KnowledgeStore) throws -> Bool {
        var exists = false
        try store.queryBind("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?", bind: { stmt in
            store.bind(stmt, 1, name)
        }) { stmt in
            exists = sqlite3_column_int64(stmt, 0) == 1
        }
        return exists
    }

    // MARK: - Timing

    @Test("Off means only an explicit close runs, whatever the clock says")
    func disabledNeverRuns() {
        let decision = DayCloseTiming.decide(
            now: date(2026, 9, 20, 23), isEnabled: false, hour: 22, lastRunDay: nil, calendar: calendar
        )
        #expect(decision == .disabled)
    }

    @Test("Before the hour the answer is not yet; from the hour on it is run; once run today it is done")
    func hourGatesTheClose() {
        #expect(DayCloseTiming.decide(now: date(2026, 9, 20, 21, 59), isEnabled: true, hour: 22, lastRunDay: nil, calendar: calendar) == .notYet)
        #expect(DayCloseTiming.decide(now: date(2026, 9, 20, 22), isEnabled: true, hour: 22, lastRunDay: nil, calendar: calendar) == .run)
        #expect(DayCloseTiming.decide(now: date(2026, 9, 20, 23, 30), isEnabled: true, hour: 22, lastRunDay: nil, calendar: calendar) == .run)
        // A shutdown at six already closed the day: the hour finds it done.
        #expect(DayCloseTiming.decide(now: date(2026, 9, 20, 22), isEnabled: true, hour: 22, lastRunDay: "memory-2026-09-20", calendar: calendar) == .alreadyRan)
        // Yesterday's run does not count for today.
        #expect(DayCloseTiming.decide(now: date(2026, 9, 21, 22), isEnabled: true, hour: 22, lastRunDay: "memory-2026-09-20", calendar: calendar) == .run)
    }

    @Test("The next instant is today's hour while ahead, otherwise tomorrow's; a first close reads from the start of yesterday")
    func instants() {
        #expect(DayCloseTiming.nextCloseInstant(after: date(2026, 9, 20, 18), hour: 22, calendar: calendar) == date(2026, 9, 20, 22))
        #expect(DayCloseTiming.nextCloseInstant(after: date(2026, 9, 20, 22), hour: 22, calendar: calendar) == date(2026, 9, 21, 22))
        #expect(DayCloseTiming.firstWatermark(now: date(2026, 9, 20, 22, 15), calendar: calendar) == date(2026, 9, 19, 0))
    }

    // MARK: - Storage

    @Test("A chat the learner wrote in is a subject once, and again only when it grows")
    func chatSubjectsFollowTheTranscript() async throws {
        let root = try Self.makeRoot("subjects")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let store = try await storage.cohortKnowledgeStore()
        let noon = date(2026, 9, 20, 12)
        let since = date(2026, 9, 19, 0)
        let now = date(2026, 9, 20, 22)

        try await Self.seedReadSource("src-a", title: "Alpha", readAt: date(2026, 9, 20, 9), on: storage)
        try await storage.createReviewSession(id: "chat-1", topic: "About Alpha", sourceIDs: ["src-a"], startedAt: noon, kind: .chat)
        // A chat with a tutor turn only is nobody's evidence.
        _ = try await storage.addReviewPrompt(sessionID: "chat-1", question: "What would you like to know?", sourceRefs: [])
        #expect(try store.dayCloseChatSubjects(since: since, now: now).isEmpty)

        _ = try await storage.addReviewExchange(
            sessionID: "chat-1", question: "Q", answer: "Why does alpha matter?", evaluation: "Because …",
            sourceRefs: ["src-a"], answeredAt: noon
        )
        let subjects = try store.dayCloseChatSubjects(since: since, now: now)
        #expect(subjects.map(\.sessionID) == ["chat-1"])
        let subject = try #require(subjects.first)
        #expect(subject.isReview == false)
        #expect(subject.recordedSourceIDs == ["src-a"])
        // Opened on one source: that source is what the chat discussed.
        #expect(try store.dayCloseDiscussedSourceIDs(for: subject) == ["src-a"])

        // Closed through its last turn: gone until it grows.
        try store.recordChatConsolidation(sessionID: "chat-1", throughSequence: subject.throughSequence, sourceCount: 1, now: now)
        #expect(try store.dayCloseChatSubjects(since: since, now: now).isEmpty)
        _ = try await storage.addReviewExchange(
            sessionID: "chat-1", question: "Q2", answer: "And beta?", evaluation: "Beta …",
            sourceRefs: ["src-a"], answeredAt: date(2026, 9, 20, 13)
        )
        let grown = try store.dayCloseChatSubjects(since: since, now: now)
        #expect(grown.map(\.sessionID) == ["chat-1"])
        #expect(try #require(grown.first).throughSequence > subject.throughSequence)

        // A turn before the watermark is last night's business, not tonight's.
        #expect(try store.dayCloseChatSubjects(since: date(2026, 9, 20, 14), now: now).isEmpty)
    }

    @Test("A memory review names its material; a chat over a whole Notebook vouches for nothing it did not cite")
    func discussedSourcesFollowTheKind() async throws {
        let root = try Self.makeRoot("discussed")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let store = try await storage.cohortKnowledgeStore()
        let noon = date(2026, 9, 20, 12)
        for (id, title) in [("src-a", "Alpha"), ("src-b", "Beta"), ("src-c", "Gamma")] {
            try await Self.seedReadSource(id, title: title, readAt: date(2026, 9, 19, 9), on: storage)
        }

        let memoryID = MemoryReviewSession.sessionID(for: noon, calendar: calendar)
        try await storage.createReviewSession(id: memoryID, topic: "Review", sourceIDs: ["src-a", "src-b", "chat-old"], startedAt: noon)
        _ = try await storage.addReviewExchange(sessionID: memoryID, question: "Contour?", answer: "Alpha says …", evaluation: "Graded.", sourceRefs: [], answeredAt: noon)

        try await storage.createReviewSession(id: "chat-2", topic: "Notebook chat", sourceIDs: ["src-a", "src-b", "src-c"], startedAt: noon, kind: .chat)
        _ = try await storage.addReviewExchange(
            sessionID: "chat-2", question: "Q", answer: "Compare them", evaluation: "See [Gamma](foreverlm://source/src-c) for the mechanism.",
            sourceRefs: [], answeredAt: date(2026, 9, 20, 13)
        )

        let subjects = try store.dayCloseChatSubjects(since: date(2026, 9, 19, 0), now: date(2026, 9, 20, 22))
        let byID = Dictionary(uniqueKeysWithValues: subjects.map { ($0.sessionID, $0) })
        let memory = try #require(byID[memoryID])
        #expect(memory.isMemoryReview && memory.isReview)
        // The chat in the material list has no sources row and is dropped.
        #expect(try store.dayCloseDiscussedSourceIDs(for: memory) == ["src-a", "src-b"])
        let notebook = try #require(byID["chat-2"])
        #expect(try store.dayCloseDiscussedSourceIDs(for: notebook) == ["src-c"])
    }

    @Test("The watermark, the summary and the reading window are read back as written")
    func stateSummaryAndReading() async throws {
        let root = try Self.makeRoot("state")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let store = try await storage.cohortKnowledgeStore()
        #expect(try store.dayCloseState() == nil)
        let mark = date(2026, 9, 20, 22)
        try store.recordDayCloseRun(watermark: mark, now: mark)
        #expect(try store.dayCloseState() == KnowledgeStore.DayCloseState(watermark: mark, lastRunAt: mark))
        let later = date(2026, 9, 21, 22)
        try store.recordDayCloseRun(watermark: later, now: later)
        #expect(try store.dayCloseState()?.watermark == later)

        try await storage.createReviewSession(id: "chat-3", topic: "Chat", sourceIDs: [], startedAt: mark, kind: .chat)
        try store.setReviewSessionSummary(sessionID: "chat-3", summary: "  Covered alpha; moved on beta; pick up gamma.  ")
        #expect(try Self.summary(of: "chat-3", in: store) == "Covered alpha; moved on beta; pick up gamma.")
        // A blank summary is not written over a real one.
        try store.setReviewSessionSummary(sessionID: "chat-3", summary: "   ")
        #expect(try Self.summary(of: "chat-3", in: store) == "Covered alpha; moved on beta; pick up gamma.")

        try await Self.seedReadSource("src-today", title: "Today", readAt: date(2026, 9, 20, 15), on: storage)
        try await Self.seedReadSource("src-old", title: "Old", readAt: date(2026, 9, 1, 15), on: storage)
        #expect(try store.sourceIDsReached(since: date(2026, 9, 19, 0), now: date(2026, 9, 20, 22)) == ["src-today"])
        #expect(try await storage.sourceIDsConsumed(since: date(2026, 9, 19, 0), now: date(2026, 9, 20, 22)) == ["src-today"])
    }

    // MARK: - The pass

    @Test("The pass closes a chat once, writes the closer's document and summary, and finds nothing the second time")
    func passIsIdempotent() async throws {
        let root = try Self.makeRoot("pass")
        let documents = try Self.makeRoot("pass-docs")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: documents)
            KnowledgeStore.understandingRootOverride = nil
        }
        KnowledgeStore.understandingRootOverride = documents.path

        let storage = StorageService(storeRoot: root)
        let store = try await storage.cohortKnowledgeStore()
        let noon = date(2026, 9, 20, 12)
        let now = date(2026, 9, 20, 22)
        try await Self.seedReadSource("src-a", title: "Alpha", readAt: date(2026, 9, 20, 9), on: storage)
        try await storage.createReviewSession(id: "chat-1", topic: "About Alpha", sourceIDs: ["src-a"], startedAt: noon, kind: .chat)
        _ = try await storage.addReviewExchange(
            sessionID: "chat-1", question: "Q", answer: "Why does alpha matter?", evaluation: "Because …",
            sourceRefs: ["src-a"], answeredAt: noon
        )

        DayCloseCloserStubURLProtocol.reset()
        let aiService = AIService(session: DayCloseCloserStubURLProtocol.mockSession())
        let config = AITaskConfig(provider: .anthropic, apiKey: "test-key", model: "claude-sonnet-4-6")
        let pass = DayClosePass(storage: storage, aiService: aiService, spendAllowed: { true }, variations: nil)

        let first = await pass.consolidate(now: now, closeConfig: config)
        #expect(first.failures.isEmpty, "\(first.failures)")
        #expect(first.consolidatedChats == 1)
        #expect(first.updatedUnderstandingDocuments == 1)
        #expect(first.warmedSources == 1, "the read source's ideas already match; warming costs no call")
        #expect(first.watermark == now)
        #expect(DayCloseCloserStubURLProtocol.requestCount() == 1)
        let requestBody = try #require(DayCloseCloserStubURLProtocol.requestBodies().first)
        #expect(requestBody.contains("ordinary conversation"), "the closer is told this was a chat, not a review")
        #expect(requestBody.contains("Why does alpha matter?"))

        let document = try #require(try store.loadUnderstandingDocument(sourceID: "src-a"))
        #expect(document.markdown.hasPrefix("# Alpha"))
        #expect(document.openThreadCount == 1)
        #expect(document.derivedThroughSessionID == "chat-1")
        #expect(try Self.summary(of: "chat-1", in: store) == "Asked why alpha matters; left beta open.")
        #expect(try store.chatConsolidationThroughSequence(sessionID: "chat-1") == 1)
        #expect(try store.dayCloseState()?.watermark == now)
        #expect(try store.unfinishedUnderstandingSourceIDs() == ["src-a"], "the open thread is the cohort's unfinished business")

        // Nothing new: no call, nothing counted, the watermark moves on.
        let later = date(2026, 9, 20, 23)
        let second = await pass.consolidate(now: later, closeConfig: config)
        #expect(second.isEmpty)
        #expect(second.failures.isEmpty)
        #expect(DayCloseCloserStubURLProtocol.requestCount() == 1)
        #expect(try store.dayCloseState()?.watermark == later)

        // The chat goes on the next morning: folded in again from where this stopped.
        _ = try await storage.addReviewExchange(
            sessionID: "chat-1", question: "Q2", answer: "And beta?", evaluation: "Beta …",
            sourceRefs: ["src-a"], answeredAt: date(2026, 9, 21, 8)
        )
        let third = await pass.consolidate(now: date(2026, 9, 21, 22), closeConfig: config)
        #expect(third.consolidatedChats == 1)
        #expect(DayCloseCloserStubURLProtocol.requestCount() == 2)
        #expect(try store.chatConsolidationThroughSequence(sessionID: "chat-1") == 2)
    }

    @Test("Without a model the chats wait and the watermark stays; a chat about nothing is closed without a call")
    func passWithoutModelAndWithoutSources() async throws {
        let root = try Self.makeRoot("nomodel")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let store = try await storage.cohortKnowledgeStore()
        let noon = date(2026, 9, 20, 12)
        let now = date(2026, 9, 20, 22)
        try await storage.createReviewSession(id: "chat-1", topic: "Small talk", sourceIDs: [], startedAt: noon, kind: .chat)
        _ = try await storage.addReviewExchange(sessionID: "chat-1", question: "Q", answer: "Hello", evaluation: "Hi.", sourceRefs: [], answeredAt: noon)

        DayCloseCloserStubURLProtocol.reset()
        let pass = DayClosePass(
            storage: storage,
            aiService: AIService(session: DayCloseCloserStubURLProtocol.mockSession()),
            spendAllowed: { true },
            variations: nil
        )

        let withoutModel = await pass.consolidate(now: now, closeConfig: nil)
        #expect(withoutModel.consolidatedChats == 0)
        #expect(withoutModel.failures.count == 1)
        #expect(try store.dayCloseState() == nil, "an unconsolidated day keeps its watermark")

        let config = AITaskConfig(provider: .anthropic, apiKey: "test-key", model: "claude-sonnet-4-6")
        let withModel = await pass.consolidate(now: now, closeConfig: config)
        #expect(withModel.consolidatedChats == 1)
        #expect(withModel.updatedUnderstandingDocuments == 0)
        #expect(DayCloseCloserStubURLProtocol.requestCount() == 0, "a chat that discussed no source needs no closer")
        #expect(try store.chatConsolidationThroughSequence(sessionID: "chat-1") == 1)
        #expect(try store.dayCloseState()?.watermark == now)
    }
}

/// Settings › General › Memory review over MCP: the reader says what the pane shows, the
/// writer goes through the pane's own entry points, and the three tools are
/// registered.
@Suite("Day close MCP tools", .serialized)
struct DayCloseMCPTests {

    private func makeStore() throws -> (MCPDataStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-dayclose-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (MCPDataStore(dbPath: root.appendingPathComponent("knowledge.db").path), root)
    }

    @Test("get_memory_review_settings and set_memory_review_settings are Settings › General › Memory review")
    func settingsToolsDriveTheMemoryPane() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults.standard
        let keys = [DayClosePreferences.hourKey, DailyReviewPreparation.hourKey]
        let prior = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in prior {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }

        func payload(_ json: String) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }

        let initial = try payload(try await store.getMemoryReviewSettings())
        #expect(initial["close_day_hour"] as? Int == DayClosePreferences.defaultHour)
        #expect(initial["ready_by_hour"] as? Int == DailyReviewPreparation.defaultHour)
        #expect(initial["budget_minutes"] as? Int == MemoryReviewBudget.minutes)
        #expect(initial["prepare_daily"] as? Bool == DailyReviewPreparation.isEnabled)
        let scope = try #require(initial["scope"] as? [String: String])
        #expect(scope["close_day_hour"] == "this Mac")

        let changed = try payload(try await store.setMemoryReviewSettings(budgetMinutes: nil, prepareDaily: nil, readyByHour: 6, closeDayHour: 21))
        #expect(changed["close_day_hour"] as? Int == 21)
        #expect(changed["ready_by_hour"] as? Int == 6)
        #expect(Set(changed["changed"] as? [String] ?? []) == ["ready_by_hour", "close_day_hour"])
        #expect(DayClosePreferences.hour == 21)
        #expect(DailyReviewPreparation.hour == 6)

        // Writing the same value again changes nothing.
        let same = try payload(try await store.setMemoryReviewSettings(budgetMinutes: nil, prepareDaily: nil, readyByHour: nil, closeDayHour: 21))
        #expect((same["changed"] as? [String])?.isEmpty == true)

        await #expect(throws: MCPError.self) {
            _ = try await store.setMemoryReviewSettings(budgetMinutes: nil, prepareDaily: nil, readyByHour: nil, closeDayHour: nil)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.setMemoryReviewSettings(budgetMinutes: nil, prepareDaily: nil, readyByHour: 24, closeDayHour: nil)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.setMemoryReviewSettings(budgetMinutes: 1, prepareDaily: nil, readyByHour: nil, closeDayHour: nil)
        }

        let tools = MCPToolRegistry(store: MCPDataStore()).tools
        for name in ["get_memory_review_settings", "set_memory_review_settings", "close_day"] {
            #expect(tools.contains { $0.name == name }, Comment(rawValue: name))
        }
    }

    @Test("The cards' settings and the day close's own switch round-trip over MCP, through the pane's own setters")
    func cardSettingsRoundTrip() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults.standard
        let keys = [
            MemoryCardSettings.newCardsPerDayKey, MemoryCardSettings.autoDraftKey,
            MemoryCardSettings.draftNudgesKey, MemoryCardSettings.prepareReviewQuestionsKey,
            DayClosePreferences.enabledKey,
        ]
        let prior = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in prior {
                if let value { PreferenceStore.set(value, forKey: key) } else { PreferenceStore.remove(forKey: key) }
            }
        }
        for key in keys { PreferenceStore.remove(forKey: key) }

        func payload(_ json: String) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }

        let initial = try payload(try await store.getMemoryReviewSettings())
        #expect(initial["new_cards_per_day"] as? Int == MemoryCardQueue.defaultNewPerDay)
        #expect(initial["auto_draft_cards"] as? Bool == true)
        #expect(initial["draft_nudges"] as? Bool == true)
        #expect(initial["prepare_review_questions"] as? Bool == true, "on until the learner turns it off")
        #expect(initial["close_day_daily"] as? Bool == DailyReviewPreparation.isEnabled, "unset, it follows the morning's switch")
        let scope = try #require(initial["scope"] as? [String: String])
        #expect(scope["new_cards_per_day"] == "your account")
        #expect(scope["close_day_daily"] == "your account")
        let drafting = try #require(initial["automatic_drafting"] as? [String: Any])
        #expect(drafting["sources_a_day"] as? Int == 3)

        let changed = try payload(try await store.setMemoryReviewSettings(
            budgetMinutes: nil, prepareDaily: nil, readyByHour: nil, closeDayHour: nil,
            newCardsPerDay: 20, autoDraftCards: false, draftNudges: false, closeDayDaily: !DayClosePreferences.isEnabled,
            prepareReviewQuestions: false
        ))
        #expect(Set(changed["changed"] as? [String] ?? []) == [
            "new_cards_per_day", "auto_draft_cards", "draft_nudges", "close_day_daily", "prepare_review_questions",
        ])
        #expect(changed["new_cards_per_day"] as? Int == 20)
        #expect(MemoryCardSettings.newCardsPerDay() == 20)
        #expect(!MemoryCardSettings.autoDraftsCards())
        #expect(!MemoryCardSettings.showsDraftNudges())
        #expect(!MemoryCardSettings.preparesReviewQuestions())
        #expect(changed["prepare_review_questions"] as? Bool == false)
        #expect((changed["automatic_drafting"] as? [String: Any])?["sources_a_day"] as? Int == 5)

        let same = try payload(try await store.setMemoryReviewSettings(
            budgetMinutes: nil, prepareDaily: nil, readyByHour: nil, closeDayHour: nil, newCardsPerDay: 20
        ))
        #expect((same["changed"] as? [String])?.isEmpty == true)

        for wrong in [0, 101] {
            await #expect(throws: MCPError.self) {
                _ = try await store.setMemoryReviewSettings(
                    budgetMinutes: nil, prepareDaily: nil, readyByHour: nil, closeDayHour: nil, newCardsPerDay: wrong
                )
            }
        }

        let tool = try #require(MCPToolRegistry(store: MCPDataStore()).tools.first { $0.name == "set_memory_review_settings" })
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        for name in ["new_cards_per_day", "auto_draft_cards", "draft_nudges", "close_day_daily", "prepare_review_questions"] {
            #expect(properties[name] != nil, Comment(rawValue: name))
        }
    }
}

/// Answers the closer over the managed proxy with one fixed result, whatever
/// route the config is sent down, and remembers every request body.
///
/// The day close makes more than the closer's call: since the working notes
/// came (old repo c025b06e8, 2026-10-10) `WorkingNoteExtractionPass` makes its
/// own call after the chats are folded in, whenever there was activity. The
/// counts below are the closer's alone, picked out by its user message
/// (`AIService.cohortCloserUserMessage` opens with "SOURCES DISCUSSED").
final class DayCloseCloserStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [String] = []

    static let closerResult = """
    {"session_summary": "Asked why alpha matters; left beta open.", \
    "sources": [{"source_id": "src-a", "understanding_markdown": "# Alpha\\n\\nCan say why alpha matters. Beta left open.", "open_thread_count": 1}]}
    """

    static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DayCloseCloserStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset() {
        lock.lock(); bodies = []; lock.unlock()
    }

    /// The closer's requests; any other call the day close makes is not counted.
    static func requestCount() -> Int {
        requestBodies().count
    }

    /// The closer's request bodies, in order.
    static func requestBodies() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return bodies.filter { $0.contains("SOURCES DISCUSSED") }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "ai.foreverlm.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let bodyText = Self.bodyText(for: request)
        Self.lock.lock(); Self.bodies.append(bodyText); Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let text = Self.closerResult
        let escaped = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) }
            ?? "\"\""
        let body: String
        if url.path.contains("/anthropic/") {
            body = #"{"content":[{"type":"text","text":\#(escaped)}],"usage":{"input_tokens":10,"output_tokens":10}}"#
        } else {
            body = #"{"choices":[{"message":{"role":"assistant","content":\#(escaped)}}],"usage":{"prompt_tokens":10,"completion_tokens":10}}"#
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyText(for request: URLRequest) -> String {
        if let body = request.httpBody { return String(data: body, encoding: .utf8) ?? "" }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
