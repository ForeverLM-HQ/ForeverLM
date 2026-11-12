#if os(macOS)
import Foundation
import OSLog

/// The voice assistant on the Mac (`RealtimeVoiceAssistant`): the same tools by
/// the same names as the iPhone's (`MobileRealtimeAssistant`), answered from
/// the Mac's own library. The plan, calendar, schedule, goals and recent work
/// are read through the in-app MCP tools (`MCPToolRegistry`), the same readers
/// the Mac's chat uses, so what voice says matches what chat says. Beyond its
/// own tools it reaches every other read tool the chat has (`find_app_tools`,
/// `use_app_tool`), so a notebook, a meeting or a Page is never out of reach
/// by voice (product owner, 2026-11-08: "it needs to be able to access
/// everything in voice mode"). Voice itself only reads: a tool that changes
/// anything is refused. Two ways reach further. A Notebook's audio overview
/// (`make_audio_overview`) starts once the learner has said yes to its price
/// out loud (product owner, 2026-11-08: "i have to be able to fire that off
/// in voice mode too"). Anything else is handed to a background task
/// (`start_background_task`, `VoiceBackgroundTasks`): a typed chat with every
/// tool the chat has, which runs on while the conversation goes on and comes
/// back with its conclusion (product owner, 2026-11-08: "or just in general
/// do stuff in teh background yes; like pull up sources etc and come to its
/// conclusion"). Asked to play a source itself, it hands the audio to that
/// source's narration (`listen_to_source`, `RealtimeVoiceListen`): the Mac's
/// own Listen, started once the conversation has ended.
enum MacRealtimeAssistant {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "RealtimeAssistant")

    /// `continuing` is a typed chat carried on out loud
    /// (`RealtimeVoiceChatContinuation`): the assistant also knows the chat so
    /// far and opens by picking it up.
    static func brief(continuing chat: RealtimeVoiceChatContinuation.Chat? = nil) async -> RealtimeVoiceBrief {
        let toolbox = Toolbox()
        async let plan = toolbox.mcp("get_plan", [:])
        async let calendar = toolbox.mcp("get_calendar_events", ["days": 7])
        async let goals = toolbox.goalsText()
        async let recent = toolbox.recentText()
        var sections = await [
            RealtimeVoiceAssistant.Section(title: "Quarter plan", text: plan),
            RealtimeVoiceAssistant.Section(title: "Calendar this week", text: calendar),
            RealtimeVoiceAssistant.Section(title: "Goals and notebooks", text: goals),
            RealtimeVoiceAssistant.Section(title: "Recent work", text: recent),
        ]
        var instructions: String
        let kickoff: String
        if let chat {
            sections.append(RealtimeVoiceChatContinuation.section(for: chat))
            instructions = RealtimeVoiceAssistant.instructions(sections: sections, setting: .mac)
            instructions += "\n\n" + RealtimeVoiceChatContinuation.instructions
            kickoff = RealtimeVoiceChatContinuation.kickoff(hasMessages: !chat.turns.isEmpty)
        } else {
            instructions = RealtimeVoiceAssistant.instructions(sections: sections, setting: .mac)
            kickoff = RealtimeVoiceAssistant.kickoff(setting: .mac)
        }
        return RealtimeVoiceBrief(
            title: chat.map { $0.title.isEmpty ? RealtimeVoiceAssistant.title : $0.title } ?? RealtimeVoiceAssistant.title,
            instructions: instructions,
            kickoff: kickoff,
            toolbox: toolbox,
            source: nil
        )
    }

    final class Toolbox: RealtimeVoiceToolbox, @unchecked Sendable {
        private let opened = RealtimeVoiceOpenedSources()
        private let noticeLock = AppLock()
        private var noticeHandler: (@Sendable (String) -> Void)?

        func setNoticeHandler(_ handler: @escaping @Sendable (String) -> Void) {
            noticeLock.withLock { noticeHandler = handler }
        }

        private var notify: (@Sendable (String) -> Void)? {
            noticeLock.withLock { noticeHandler }
        }

        var toolDefinitions: [[String: Any]] {
            let query = ["type": "string", "description": "A few words: title words, an author, a topic."]
            let sourceID = ["type": "string", "description": "The source_id from search_library or recent work."]
            let days = ["type": "integer", "description": "How many days from today, 1 to 14."]
            return [
                RealtimeVoiceAssistant.function(
                    "search_library",
                    "Finds sources in the learner's library by title words, author, a meeting's series, or a day (\"October 25\"), newest first among equals.",
                    properties: ["query": ["type": "string", "description": "The learner's words: title words, an author, a series, a day."]],
                    required: ["query"]
                ),
                RealtimeVoiceAssistant.function(
                    "open_source",
                    "Reads one source's text so you can talk about it or quiz the learner on it.",
                    properties: ["source_id": sourceID],
                    required: ["source_id"]
                ),
                RealtimeVoiceAssistant.function(
                    "search_source",
                    "Finds exact passages in a source you opened. Defaults to the last one opened.",
                    properties: ["query": query, "source_id": sourceID],
                    required: ["query"]
                ),
                RealtimeVoiceAssistant.function("get_plan", "The learner's plan Page for this quarter: big picture, objectives, strategies and habits."),
                RealtimeVoiceAssistant.function(
                    "get_calendar",
                    "The learner's calendar events from today on: their week and day plan, with free time left today.",
                    properties: ["days": days]
                ),
                RealtimeVoiceAssistant.function("get_schedule", "Sources the learner placed on days in their Schedule, with what is done."),
                RealtimeVoiceAssistant.function("get_goals", "The learner's goals and notebooks."),
                RealtimeVoiceAssistant.function("get_recent_work", "What the learner did today and yesterday, and their latest chats."),
                RealtimeVoiceListen.toolDefinition,
            ] + RealtimeVoiceReach.toolDefinitions
        }

        func run(name: String, argumentsJSON: String) async -> String {
            let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
            switch name {
            case "search_library":
                return await searchLibrary((arguments["query"] as? String) ?? "")
            case "open_source":
                return await openSource((arguments["source_id"] as? String) ?? "")
            case "search_source":
                return opened.search(sourceID: arguments["source_id"] as? String, query: (arguments["query"] as? String) ?? "")
            case "get_plan":
                return await mcp("get_plan", [:])
            case "get_calendar":
                let days = min(max((arguments["days"] as? NSNumber)?.intValue ?? 7, 1), 14)
                return await mcp("get_calendar_events", ["days": days])
            case "get_schedule":
                return await mcp("get_schedule", ["include_completed": false])
            case "get_goals":
                return await goalsText()
            case "get_recent_work":
                return await recentText()
            case RealtimeVoiceListen.toolName:
                return await listenToSource((arguments["source_id"] as? String) ?? "")
            case "list_meetings":
                return await mcp("list_meeting_groups", [:])
            case "get_meeting_series":
                return await meetingSeries((arguments["group_id"] as? String) ?? "")
            case "make_audio_overview":
                return await mcp("generate_audio_overview", RealtimeVoiceReach.audioOverviewArguments(arguments))
            case "find_app_tools":
                return Self.findAppTools((arguments["query"] as? String) ?? "")
            case "use_app_tool":
                return await useAppTool(name: (arguments["name"] as? String) ?? "", arguments: arguments["arguments"])
            case "start_background_task":
                let request = VoiceBackgroundTasks.Request(arguments)
                let notify = notify
                return await MainActor.run { VoiceBackgroundTasks.shared.start(request, notify: notify) }
            case "check_background_tasks":
                let id = (arguments["task_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return await MainActor.run { VoiceBackgroundTasks.shared.check(id?.isEmpty == false ? id : nil) }
            case "stop_background_task":
                let id = ((arguments["task_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return await MainActor.run { VoiceBackgroundTasks.shared.stop(id) }
            default:
                return #"{"error":"Unknown tool."}"#
            }
        }

        func openedSourceIDs() async -> [String] { opened.ids }

        // MARK: Listening

        private let listenLock = AppLock()
        /// The source whose narration plays when this conversation ends.
        private var pendingListen: StudioArticle?

        /// Nothing plays yet: the conversation holds the audio. A source
        /// Listen can read is remembered, and played in `conversationEnded`.
        /// On the Mac the learner is at the screen, so a narration that has
        /// to be made asks its price there, as Listen always does; voice
        /// never says a price here.
        private func listenToSource(_ rawID: String) async -> String {
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            let storage = StorageService()
            let loaded: StudioArticle?
            do {
                loaded = try await storage.loadSourceWithoutContent(id)
            } catch {
                MacRealtimeAssistant.logger.error("Reading source \(id, privacy: .public) to play its narration failed: \(error.localizedDescription, privacy: .public)")
                loaded = nil
            }
            guard var article = loaded else {
                return RealtimeVoiceListen.output(.refused("No source with that id. Use search_library to find it."))
            }
            article.content = await storage.loadSourceContent(id)
            guard ArticleSpeechContent.canAttemptRead(article) else {
                let kind = RealtimeVoiceTutor.spokenKind(article.sourceType.rawValue)
                return RealtimeVoiceListen.output(.refused(
                    ArticleSpeechContent.isOriginalAudioSource(article)
                        ? RealtimeVoiceListen.ownAudioRefusal(kind: kind)
                        : "This \(kind) has no readable text yet, so there is nothing to read aloud; it may still be importing."
                ))
            }
            let isMade = await Task.detached(priority: .userInitiated) {
                ArticleSpeechAudioCache.hasCachedAudio(sourceID: id)
            }.value
            listenLock.withLock { pendingListen = article }
            return RealtimeVoiceListen.output(.starting(title: article.title, isMade: isMade))
        }

        func conversationEnded() async {
            let article = listenLock.withLock { () -> StudioArticle? in
                defer { pendingListen = nil }
                return pendingListen
            }
            guard let article else { return }
            await MainActor.run {
                ArticleSpeechService.shared.listen(to: article)
            }
        }

        /// One in-app MCP read, as text. Its error is an answer too.
        func mcp(_ name: String, _ arguments: [String: Any]) async -> String {
            let data = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
            return await Task.detached(priority: .userInitiated) {
                let decoded = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                let outcome = await MCPToolRegistry.shared.callToolDetailed(name: name, arguments: decoded)
                return outcome.text
            }.value
        }

        func goalsText() async -> String {
            let goals = await mcp("list_goals", ["include_completed": false])
            let notebooks = await mcp("list_notebooks", ["include_completed": false])
            return "Goals:\n\(goals)\n\nNotebooks:\n\(notebooks)"
        }

        func recentText() async -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let today = formatter.string(from: Date())
            let yesterday = formatter.string(from: Date().addingTimeInterval(-MemoryTutorScheduler.secondsPerDay))
            async let todayActivity = mcp("get_day_activity", ["date": today])
            async let yesterdayActivity = mcp("get_day_activity", ["date": yesterday])
            async let chats = mcp("get_review_sessions", [:])
            return await "Today:\n\(todayActivity)\n\nYesterday:\n\(yesterdayActivity)\n\nChats:\n\(String(chats.prefix(4_000)))"
        }

        private func searchLibrary(_ query: String) async -> String {
            let storage = StorageService()
            let sources: [StudioArticle]
            do {
                sources = try await storage.loadActiveSources()
            } catch {
                MacRealtimeAssistant.logger.error("Reading the library for a voice search failed: \(error.localizedDescription, privacy: .public)")
                sources = []
            }
            let meetingGroups: [String: MeetingMetadata]
            do {
                meetingGroups = try await storage.loadMeetingMetadata()
            } catch {
                MacRealtimeAssistant.logger.error("Reading the meeting groups for a voice search failed: \(error.localizedDescription, privacy: .public)")
                meetingGroups = [:]
            }
            let items = sources.map { article in
                RealtimeVoiceLibraryItem(
                    id: article.id,
                    title: article.title,
                    sourceType: article.sourceType.rawValue,
                    byline: [article.author, article.journal].compactMap { $0 }.joined(separator: " · "),
                    addedAt: article.dateAdded,
                    lastAttentionAt: nil,
                    group: article.sourceType == .meeting ? Self.meetingSeriesTitle(article.parentGroup, in: meetingGroups) : nil
                )
            }
            return RealtimeVoiceLibrarySearch.toolOutput(RealtimeVoiceLibrarySearch.rank(query, in: items))
        }

        /// A meeting's series by name, following a series merged into another.
        static func meetingSeriesTitle(_ groupID: String?, in groups: [String: MeetingMetadata]) -> String? {
            guard var id = groupID, !id.isEmpty else { return nil }
            var seen: Set<String> = []
            while let next = groups[id]?.mergedIntoGroupID, !next.isEmpty, seen.insert(id).inserted {
                id = next
            }
            let title = groups[id]?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? id : title
        }

        /// `get_meeting_group` cut to what a voice conversation needs
        /// (`RealtimeVoiceReach.meetingSeries`).
        private func meetingSeries(_ groupID: String) async -> String {
            RealtimeVoiceReach.meetingSeries(fromGroupListing: await mcp("get_meeting_group", ["group_id": groupID]), groupID: groupID)
        }

        // MARK: The rest of the app

        /// Tools voice carries itself in its own shape, kept out of
        /// `find_app_tools` (`get_meeting_group` whole is too long to hand a
        /// voice call; `get_meeting_series` is its cut).
        static let ownToolNames: Set<String> = [
            "get_plan", "get_calendar_events", "get_schedule",
            "list_meeting_groups", "get_meeting_group", "get_mcp_status",
        ]

        static func appToolCatalog() -> [ReviewSessionManager.AppToolDefinition] {
            MCPToolRegistry.shared.tools
                .filter { MCPToolRegistry.isReadOnlyTool($0.name) && !ownToolNames.contains($0.name) }
                .map { tool in
                    let schema = (try? JSONSerialization.data(withJSONObject: tool.inputSchema, options: [.sortedKeys]))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    return ReviewSessionManager.AppToolDefinition(name: tool.name, description: tool.description, inputSchemaJSON: schema)
                }
        }

        static func findAppTools(_ query: String, catalog: [ReviewSessionManager.AppToolDefinition] = appToolCatalog()) -> String {
            let matches = ReviewSessionManager.appTools(matching: query, in: catalog, limit: 5)
            guard !matches.isEmpty else {
                return #"{"tools":[],"note":"No read tool matches those words. Try other words for what you need."}"#
            }
            let tools: [[String: Any]] = matches.map { tool in
                [
                    "name": tool.name,
                    "description": String(tool.description.prefix(700)),
                    "parameters": String(tool.inputSchemaJSON.prefix(3_000)),
                ]
            }
            let data = (try? JSONSerialization.data(withJSONObject: ["tools": tools], options: [.sortedKeys])) ?? Data()
            return String(data: data, encoding: .utf8) ?? #"{"tools":[]}"#
        }

        private func useAppTool(name rawName: String, arguments raw: Any?) async -> String {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard MCPToolRegistry.shared.tools.contains(where: { $0.name == name }) else {
                return #"{"error":"No tool by that name. Call find_app_tools first and use a name it gave."}"#
            }
            if let refusal = RealtimeVoiceReach.useAppToolRefusal(name, isReadOnly: MCPToolRegistry.isReadOnlyTool(name)) {
                return refusal
            }
            let arguments: [String: Any]
            if let object = raw as? [String: Any] {
                arguments = object
            } else if let text = raw as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
                    return #"{"error":"arguments must be a JSON object."}"#
                }
                arguments = object
            } else {
                arguments = [:]
            }
            let text = await mcp(name, arguments)
            return RealtimeVoiceReach.capped(text)
        }

        private func openSource(_ id: String) async -> String {
            let storage = StorageService()
            let loaded: StudioArticle?
            do {
                loaded = try await storage.loadSourceWithoutContent(id)
            } catch {
                MacRealtimeAssistant.logger.error("Reading source \(id, privacy: .public) for the voice assistant failed: \(error.localizedDescription, privacy: .public)")
                loaded = nil
            }
            guard let article = loaded else {
                return #"{"error":"No source with that id. Use search_library to find it."}"#
            }
            guard let text = await storage.loadSourceContent(id),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return #"{"error":"This source has no text yet; it may still be importing."}"#
            }
            let byline = [article.author, article.journal].compactMap { $0 }.joined(separator: " · ")
            return opened.open(RealtimeVoiceSource(
                id: article.id,
                title: article.title,
                sourceType: article.sourceType.rawValue,
                byline: byline.isEmpty ? nil : byline,
                text: text,
                reviewGuide: nil
            ))
        }
    }
}

/// Work voice hands off (`start_background_task`): each task is an ordinary
/// chat, started the way a scheduled task's run is (`ScheduledTaskRunner`),
/// with the same manager, the whole app tool surface, the chat's model,
/// persistence and cost ledger, so it lands in the learner's chats where they
/// can read it, continue it or delete it. It runs while ForeverLM is open,
/// whether or not the voice call goes on, and is listed as running work
/// (`MCPRunningWork`), where the Background work list, `list_running_ai_work`
/// and `cancel_ai_work` see and stop it. Like any work an assistant starts,
/// it stops at the default spend ceiling.
///
/// The chat runs on the Chat model (Deep Research on its own route): the
/// learner asked for it and waits on its answer, so it is not unattended work
/// on a Background route. No backup model takes over a failure; the failure
/// is what voice says.
@MainActor
final class VoiceBackgroundTasks {
    static let shared = VoiceBackgroundTasks()

    /// Background chats running at once. More would compete for the same rate
    /// limits and balance, as `ScheduledTaskRunner` runs its tasks one by one.
    static let maximumRunning = 3
    /// A conclusion as voice reads it at most; the whole reply is in the chat.
    static let conclusionBudget = 12_000
    static let workTool = "voice_task"

    /// Model-only context on the task's opening message (`contextualContent`):
    /// never shown in the chat, never stored as the learner's words.
    static let handoffNote = """
    This request was handed over from a voice conversation. The learner is not watching this chat while it runs, \
    so do the whole task now with your tools without asking them anything first: where something is unclear, make \
    the sensible choice and say which you made. Change their library, notes, plan or calendar only as far as the \
    request asks. End with your conclusion in a few short paragraphs of plain prose that read well aloud: what you \
    found or did, where it is (name any Page you wrote), and anything left for them to decide.
    """

    struct Request {
        var task: String
        var title: String
        var sourceIDs: [String]
        var deepResearch: Bool

        init(task: String, title: String, sourceIDs: [String] = [], deepResearch: Bool = false) {
            self.task = task
            self.title = title
            self.sourceIDs = sourceIDs
            self.deepResearch = deepResearch
        }

        /// From the voice tool's arguments: the words trimmed, an empty title
        /// taken from the task's opening words.
        init(_ arguments: [String: Any]) {
            let task = ((arguments["task"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var title = ((arguments["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty {
                let words = task.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
                title = words.isEmpty ? "Voice task" : words
            }
            var seen: Set<String> = []
            let sourceIDs = ((arguments["source_ids"] as? [Any]) ?? []).compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            self.init(
                task: task,
                title: String(title.prefix(80)),
                sourceIDs: sourceIDs,
                deepResearch: (arguments["deep_research"] as? Bool) == true
            )
        }
    }

    enum State: String {
        case running, finished, failed, stopped
    }

    struct Record {
        let id: String
        let title: String
        let deepResearch: Bool
        let startedAt: Date
        var state: State = .running
        var workID: String?
        var sessionID: String?
        var conclusion: String?
        var failure: String?
        var finishedAt: Date?
        /// Stopped by `stop_background_task`, so voice need not be told.
        var stoppedByVoice = false
    }

    private(set) var records: [String: Record] = [:]
    private var managers: [String: ReviewSessionManager] = [:]

    private init() {}

    var runningCount: Int { records.values.filter { $0.state == .running }.count }

    /// Starts one task. The answer is the tool's: its task_id, or why not.
    func start(_ request: Request, notify: (@Sendable (String) -> Void)?) -> String {
        guard !request.task.isEmpty else {
            return Self.json(["error": "Say what the task is: task is empty."])
        }
        guard runningCount < Self.maximumRunning else {
            return Self.json(["error": "\(Self.maximumRunning) background tasks are already running. Wait for one to finish, or stop one with stop_background_task."])
        }
        let id = "voice-task-" + UUID().uuidString.prefix(8).lowercased()
        let manager = StudioAssistantSession.makeManager()
        manager.modelOverride = nil
        managers[id] = manager
        records[id] = Record(id: id, title: request.title, deepResearch: request.deepResearch, startedAt: Date())

        let articles = request.sourceIDs.isEmpty ? [] : (ScheduledTaskRunner.shared.articleProvider?(request.sourceIDs) ?? [])
        let missing = request.sourceIDs.count - articles.count
        let mode: ReviewSessionManager.InitialPromptMode = request.deepResearch ? .deepResearch : .assistant
        let note = Self.handoffNote
        let workID = MCPRunningWork.shared.startBackground(
            tool: Self.workTool,
            about: request.title,
            spendLimitUSD: MCPRunningWork.defaultSpendLimitUSD
        ) { [request] in
            await withTaskCancellationHandler {
                await manager.sendMessage(
                    request.task,
                    topic: request.title,
                    articles: articles,
                    initialMode: mode,
                    contextualContent: note
                )
            } onCancel: {
                Task { @MainActor in manager.stopGeneration() }
            }
            let cancelled = Task.isCancelled
            await VoiceBackgroundTasks.shared.finish(id, cancelled: cancelled, notify: notify)
        }
        records[id]?.workID = workID

        var answer: [String: Any] = [
            "task_id": id,
            "title": request.title,
            "state": State.running.rawValue,
            "note": "Started. It runs on the learner's chat model and stops at $\(Self.dollars(MCPRunningWork.defaultSpendLimitUSD)). Carry on with the learner; a note will tell you when it is done.",
        ]
        if missing > 0 {
            answer["sources_not_found"] = "\(missing) of the source_ids were not found; it will look for what it needs itself."
        }
        return Self.json(answer)
    }

    func check(_ id: String?, now: Date = Date()) -> String {
        if let id {
            guard let record = records[id] else {
                return Self.json(["error": "No background task by that id. Leave task_id out to list them all."])
            }
            return Self.json(["task": Self.row(record, now: now)])
        }
        let rows = records.values.sorted { $0.startedAt > $1.startedAt }.map { Self.row($0, now: now) }
        if rows.isEmpty {
            return Self.json(["tasks": [], "note": "No background task has been started by voice since ForeverLM opened."])
        }
        return Self.json(["tasks": rows])
    }

    func stop(_ id: String) -> String {
        guard var record = records[id] else {
            return Self.json(["error": "No background task by that id. check_background_tasks lists them."])
        }
        guard record.state == .running else {
            return Self.json(["task_id": id, "state": record.state.rawValue, "note": "It is not running any more."])
        }
        record.stoppedByVoice = true
        records[id] = record
        if let workID = record.workID {
            _ = MCPRunningWork.shared.stop(workID, by: .learner)
        } else {
            managers[id]?.stopGeneration()
        }
        return Self.json(["task_id": id, "state": "stopping", "note": "Stopping. What it already did stays, and its chat keeps the reply so far."])
    }

    /// The task's chat answered, failed or was stopped: its record says how,
    /// and voice hears it if the call that started it is still on.
    private func finish(_ id: String, cancelled: Bool, notify: (@Sendable (String) -> Void)?) {
        guard var record = records[id] else { return }
        let manager = managers.removeValue(forKey: id)
        record.sessionID = manager?.currentSessionID
        record.finishedAt = Date()
        let failure = (manager?.errorMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if cancelled || record.stoppedByVoice {
            record.state = .stopped
        } else if !failure.isEmpty {
            record.state = .failed
            record.failure = failure
        } else if let conclusion = manager.flatMap({ Self.conclusion(from: $0.chatMessages) }) {
            record.state = .finished
            record.conclusion = conclusion
        } else {
            record.state = .failed
            record.failure = "The chat ended without a reply."
        }
        records[id] = record
        if let notice = Self.notice(for: record) { notify?(notice) }
    }

    /// The chat's last reply as voice reads it, cut to `conclusionBudget`.
    static func conclusion(from messages: [ReviewSessionManager.Message]) -> String? {
        guard let last = messages.last(where: { $0.role == .assistant }),
              let text = ReviewSessionManager.displayableMessageContent(role: .assistant, content: last.content)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        guard text.count > conclusionBudget else { return text }
        return String(text.prefix(conclusionBudget)) + "\n… (cut here; the whole reply is in the chat.)"
    }

    /// What voice is told when a task ends (`RealtimeVoiceReach.backgroundTaskNotice`).
    static func notice(for record: Record) -> String? {
        RealtimeVoiceReach.backgroundTaskNotice(
            taskID: record.id,
            title: record.title,
            state: record.state.rawValue,
            conclusion: record.conclusion,
            failure: record.failure,
            stoppedByVoice: record.stoppedByVoice
        )
    }

    static func row(_ record: Record, now: Date) -> [String: Any] {
        var row: [String: Any] = [
            "task_id": record.id,
            "title": record.title,
            "state": record.state.rawValue,
            "minutes_since_start": max(0, Int(now.timeIntervalSince(record.startedAt) / 60)),
        ]
        if record.deepResearch { row["deep_research"] = true }
        if let sessionID = record.sessionID { row["chat_id"] = sessionID }
        if let conclusion = record.conclusion { row["conclusion"] = conclusion }
        if let failure = record.failure { row["error"] = failure }
        return row
    }

    private static func dollars(_ amount: Double) -> String {
        amount.rounded() == amount ? String(Int(amount)) : String(format: "%.2f", amount)
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// What the iPhone's voice mode asks this Mac for (`MobileRealtimeAssistant`),
/// through the gateway's `POST /web/call`, which lets these names through
/// along with the read tools (`workers/mcp-gateway/src/web-desktop.ts`): the
/// iPhone has no app tools of its own, so it finds read tools here and hands
/// background tasks to this Mac (product owner, 2026-11-08: "make sure the
/// iphone also has all that functionality"). They are answered before the
/// registry (`MCPProtocolHandler.handleToolsCall`), never listed in
/// `tools/list`, and not in the public contract: the gateway's `/mcp` refuses
/// a name outside that contract, so no connected assistant reaches them.
enum MacVoiceRelayTools {
    static let names: Set<String> = [
        "voice_find_app_tools",
        "voice_start_background_task",
        "voice_check_background_tasks",
        "voice_stop_background_task",
    ]

    /// The tool's answer, or nil for a name that is not one of these.
    static func call(_ name: String, arguments: [String: Any]) async -> String? {
        switch name {
        case "voice_find_app_tools":
            return MacRealtimeAssistant.Toolbox.findAppTools((arguments["query"] as? String) ?? "")
        case "voice_start_background_task":
            let request = VoiceBackgroundTasks.Request(arguments)
            // The iPhone asks after it with voice_check_background_tasks; this
            // Mac has no way to speak into a call on the phone.
            return await MainActor.run { VoiceBackgroundTasks.shared.start(request, notify: nil) }
        case "voice_check_background_tasks":
            let id = (arguments["task_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return await MainActor.run { VoiceBackgroundTasks.shared.check(id?.isEmpty == false ? id : nil) }
        case "voice_stop_background_task":
            let id = ((arguments["task_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return await MainActor.run { VoiceBackgroundTasks.shared.stop(id) }
        default:
            return nil
        }
    }
}
#endif
