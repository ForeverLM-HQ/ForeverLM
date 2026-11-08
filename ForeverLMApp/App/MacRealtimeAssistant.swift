#if os(macOS)
import Foundation
import OSLog

/// The voice assistant on the Mac (`RealtimeVoiceAssistant`): the same tools by
/// the same names as the iPhone's (`MobileRealtimeAssistant`), answered from
/// the Mac's own library. The plan, calendar, schedule, goals and recent work
/// are read through the in-app MCP tools (`MCPToolRegistry`), the same readers
/// the Mac's chat uses, so what voice says matches what chat says. Read only.
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
                    "Finds sources in the learner's library by title words, author or topic, newest first among equals.",
                    properties: ["query": query],
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
            let sources = (try? await StorageService().loadActiveSources()) ?? []
            let items = sources.map { article in
                RealtimeVoiceLibraryItem(
                    id: article.id,
                    title: article.title,
                    sourceType: article.sourceType.rawValue,
                    byline: [article.author, article.journal].compactMap { $0 }.joined(separator: " · "),
                    addedAt: article.dateAdded,
                    lastAttentionAt: nil
                )
            }
            return RealtimeVoiceLibrarySearch.toolOutput(RealtimeVoiceLibrarySearch.rank(query, in: items))
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
