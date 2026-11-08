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
/// everything in voice mode"). Read only: a tool that changes anything is
/// refused, as before — with one exception, a Notebook's audio overview
/// (`make_audio_overview`), which voice can start once the learner has said
/// yes to its price out loud (product owner, 2026-11-08: "i have to be able
/// to fire that off in voice mode too").
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
                RealtimeVoiceAssistant.function("list_meetings", "The learner's recurring meetings (series), with their group_id and how many sessions each has."),
                RealtimeVoiceAssistant.function(
                    "get_meeting_series",
                    "One meeting series' sessions, newest first: each session's day, its talk's title and its source_id for open_source.",
                    properties: ["group_id": ["type": "string", "description": "The group_id from list_meetings."]],
                    required: ["group_id"]
                ),
                RealtimeVoiceAssistant.function(
                    "make_audio_overview",
                    "Starts a custom podcast (an audio overview) over a notebook's sources, written in the background and narrated with the learner's voice. The first call only prices it; call again with confirm_cost true once the learner has said yes to that price.",
                    properties: [
                        "notebook_id": ["type": "string", "description": "The notebook it is written from and filed in, from the notebooks you know or list_notebooks."],
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Only these of the notebook's own sources. Leave out for the sources ticked in the notebook."],
                        "focus": ["type": "string", "description": "What it should be about or the question it should think through, in the learner's words."],
                        "format": ["type": "string", "enum": ["deep_dive", "brief", "critique"], "description": "deep_dive (the default), brief (about two minutes) or critique."],
                        "length": ["type": "string", "enum": ["shorter", "default", "longer"], "description": "For deep_dive and critique only."],
                        "confirm_cost": ["type": "boolean", "description": "True only after the learner has heard the price and said yes."],
                    ],
                    required: ["notebook_id"]
                ),
                RealtimeVoiceAssistant.function(
                    "find_app_tools",
                    "Finds ForeverLM's other read tools by what they do: notebooks and their sources, Pages, cards, courses, highlights, ideas, open questions, past chats, canvases and more. Says how to call each.",
                    properties: ["query": ["type": "string", "description": "A few words for what you need, like \"notebook sources\" or \"due cards\"."]],
                    required: ["query"]
                ),
                RealtimeVoiceAssistant.function(
                    "use_app_tool",
                    "Runs one tool find_app_tools named, with the arguments its parameters ask for.",
                    properties: [
                        "name": ["type": "string", "description": "The tool's exact name from find_app_tools."],
                        "arguments": ["type": "object", "description": "The tool's arguments, as its parameters describe. {} when it takes none."],
                    ],
                    required: ["name"]
                ),
            ]
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
            case "list_meetings":
                return await mcp("list_meeting_groups", [:])
            case "get_meeting_series":
                return await meetingSeries((arguments["group_id"] as? String) ?? "")
            case "make_audio_overview":
                return await mcp("generate_audio_overview", Self.audioOverviewArguments(arguments))
            case "find_app_tools":
                return Self.findAppTools((arguments["query"] as? String) ?? "")
            case "use_app_tool":
                return await useAppTool(name: (arguments["name"] as? String) ?? "", arguments: arguments["arguments"])
            default:
                return #"{"error":"Unknown tool."}"#
            }
        }

        func openedSourceIDs() async -> [String] { opened.ids }

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
            let yesterday = formatter.string(from: Date().addingTimeInterval(-86_400))
            async let todayActivity = mcp("get_day_activity", ["date": today])
            async let yesterdayActivity = mcp("get_day_activity", ["date": yesterday])
            async let chats = mcp("get_review_sessions", [:])
            return await "Today:\n\(todayActivity)\n\nYesterday:\n\(yesterdayActivity)\n\nChats:\n\(String(chats.prefix(4_000)))"
        }

        private func searchLibrary(_ query: String) async -> String {
            let storage = StorageService()
            let sources = (try? await storage.loadActiveSources()) ?? []
            let meetingGroups = (try? await storage.loadMeetingMetadata()) ?? [:]
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

        /// `get_meeting_group` cut to what a voice conversation needs: the
        /// whole listing carries every artifact's link (over 100k characters
        /// for a weekly series), while a session is found by its day and talk.
        private func meetingSeries(_ groupID: String) async -> String {
            let raw = await mcp("get_meeting_group", ["group_id": groupID])
            guard let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
                return raw
            }
            let sessions = (object["sessions"] as? [[String: Any]]) ?? []
            let rows = sessions.map { Self.meetingSessionRow($0) }
            var payload: [String: Any] = ["series": object["title"] as? String ?? groupID, "sessions": rows]
            if rows.isEmpty { payload["note"] = "This series has no sessions yet." }
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
            return String(data: data, encoding: .utf8) ?? raw
        }

        /// One session as voice says it: its day, its talk (the title its
        /// notes or recording carry, without the date and kind it repeats),
        /// and the source_id to open.
        static func meetingSessionRow(_ session: [String: Any], calendar: Calendar = .current) -> [String: Any] {
            var row: [String: Any] = ["source_id": session["source_id"] as? String ?? ""]
            if let seconds = (session["date_added"] as? NSNumber)?.doubleValue {
                row["date"] = RealtimeVoiceLibrarySearch.dayFormatter(calendar: calendar)
                    .string(from: Date(timeIntervalSinceReferenceDate: seconds))
            }
            let artifactTitles = ((session["artifacts"] as? [[String: Any]]) ?? []).compactMap { $0["title"] as? String }
            let talk = artifactTitles.lazy.map(Self.talkTitle).first { !$0.isEmpty }
            row["title"] = talk ?? (session["title"] as? String ?? "")
            if let state = session["state"] as? String, state != "ready" { row["state"] = state }
            return row
        }

        /// "2026-10-25 - [Notes] - JC: The Rise of X - A. Speaker" → "JC: The Rise of X - A. Speaker".
        static func talkTitle(_ artifactTitle: String) -> String {
            var parts = artifactTitle.components(separatedBy: " - ")
            if let first = parts.first, first.range(of: #"^\d{4}[-/.]\d{1,2}[-/.]\d{1,2}$"#, options: .regularExpression) != nil {
                parts.removeFirst()
            }
            if let first = parts.first, first.hasPrefix("["), first.hasSuffix("]") {
                parts.removeFirst()
            }
            return parts.joined(separator: " - ").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // MARK: The rest of the app

        /// Tools voice carries itself in its own shape, kept out of
        /// `find_app_tools` (`get_meeting_group` whole is too long to hand a
        /// voice call; `get_meeting_series` is its cut).
        static let ownToolNames: Set<String> = [
            "get_plan", "get_calendar_events", "get_schedule",
            "list_meeting_groups", "get_meeting_group", "get_mcp_status",
        ]

        /// `make_audio_overview`'s arguments as `generate_audio_overview`
        /// takes them: only the recipe and the learner's yes. The spend
        /// ceiling is never raised by voice, so a run stays under the
        /// operation's default, and the audio is always narrated.
        static func audioOverviewArguments(_ arguments: [String: Any]) -> [String: Any] {
            var forwarded: [String: Any] = [:]
            for key in ["notebook_id", "focus", "format", "length"] {
                if let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    forwarded[key] = value
                }
            }
            let sourceIDs = ((arguments["source_ids"] as? [Any]) ?? []).compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !sourceIDs.isEmpty { forwarded["source_ids"] = sourceIDs }
            if (arguments["confirm_cost"] as? Bool) == true { forwarded["confirm_cost"] = true }
            return forwarded
        }

        /// Output a borrowed tool hands the conversation at most. A realtime
        /// event is capped near 200 KB (`RealtimeVoiceSession.maximumMessageBytes`),
        /// and a long listing read out of a voice call is no use anyway.
        static let appToolOutputBudget = 50_000

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
            if name == "generate_audio_overview" {
                return #"{"error":"Use make_audio_overview for an audio overview."}"#
            }
            guard MCPToolRegistry.isReadOnlyTool(name) else {
                return #"{"error":"Voice mode only reads, and that tool changes things. Tell the learner they can ask for it in a typed chat."}"#
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
            guard text.count > Self.appToolOutputBudget else { return text }
            return String(text.prefix(Self.appToolOutputBudget))
                + "\n… (cut here: the answer was longer. Ask the tool for less, with a narrower filter or a limit, for anything further.)"
        }

        private func openSource(_ id: String) async -> String {
            let storage = StorageService()
            guard let article = try? await storage.loadSourceWithoutContent(id) else {
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
#endif
