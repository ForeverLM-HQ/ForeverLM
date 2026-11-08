import EventKit
import Foundation
import OSLog

/// The voice assistant on the iPhone and in CarPlay (`RealtimeVoiceAssistant`):
/// what it knows when it starts, read from the phone's own replica of the
/// library, and the tools it looks further with. Everything is read on the
/// device; nothing is written, so a misheard word can never change the library.
///
/// What it reads:
/// - the quarter plan Page (`PlanQuarter`, from the Space store);
/// - the week and the day: the learner's calendar, through EventKit (the same
///   calendars the Mac plans onto, synced by iCloud), once access is granted;
/// - the Schedule (sources placed on days);
/// - goals and notebooks, with what each notebook is for;
/// - what the learner read, listened to, watched or discussed lately, and their
///   latest chats.
enum MobileRealtimeAssistant {
    private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "RealtimeAssistant")

    /// The brief a conversation starts on. Each part is read independently, so
    /// one that fails (no calendar access, a plan not yet synced) only leaves
    /// that part out.
    static func brief(setting: RealtimeVoiceAssistant.Setting) async -> RealtimeVoiceBrief {
        let toolbox = Toolbox()
        let now = Date()
        async let plan = toolbox.planText()
        async let calendar = toolbox.calendarText(days: 7, now: now)
        async let schedule = toolbox.scheduleText(days: 7, now: now)
        async let goals = toolbox.goalsText()
        async let recent = toolbox.recentText(now: now)
        let sections = await [
            RealtimeVoiceAssistant.Section(title: "Quarter plan", text: plan ?? ""),
            RealtimeVoiceAssistant.Section(title: "Calendar this week", text: calendar),
            RealtimeVoiceAssistant.Section(title: "Schedule", text: schedule),
            RealtimeVoiceAssistant.Section(title: "Goals and notebooks", text: goals),
            RealtimeVoiceAssistant.Section(title: "Recent work", text: recent),
        ]
        return RealtimeVoiceBrief(
            title: RealtimeVoiceAssistant.title,
            instructions: RealtimeVoiceAssistant.instructions(sections: sections, setting: setting, now: now),
            kickoff: RealtimeVoiceAssistant.kickoff(setting: setting),
            toolbox: toolbox,
            source: nil
        )
    }

    final class Toolbox: RealtimeVoiceToolbox, @unchecked Sendable {
        private let opened = RealtimeVoiceOpenedSources()
        private let catalog = MobileCloudSourceCatalog.shared

        var toolDefinitions: [[String: Any]] {
            let query = ["type": "string", "description": "A few words: title words, an author, a topic."]
            let sourceID = ["type": "string", "description": "The source_id from search_library or recent work."]
            let days = ["type": "integer", "description": "How many days from today, 1 to 14."]
            return [
                RealtimeVoiceAssistant.function(
                    "search_library",
                    "Finds sources in the learner's library by title words, author or topic, recently attended ones first.",
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
                    "The learner's calendar events from today on: their week and day plan.",
                    properties: ["days": days]
                ),
                RealtimeVoiceAssistant.function(
                    "get_schedule",
                    "Sources the learner placed on days in their Schedule, from today on, with what is done.",
                    properties: ["days": days]
                ),
                RealtimeVoiceAssistant.function("get_goals", "The learner's goals and notebooks, with what each notebook is for."),
                RealtimeVoiceAssistant.function("get_recent_work", "What the learner read, listened to, watched or discussed in the last two weeks, and their latest chats."),
                RealtimeVoiceAssistant.function("start_memory_review", "Starts today's memory review (spaced-repetition cards, spoken) when the learner asks for it. After calling it, say in a few words that the review is starting, then call end_conversation."),
            ]
        }

        func run(name: String, argumentsJSON: String) async -> String {
            let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
            let days = min(max((arguments["days"] as? NSNumber)?.intValue ?? 7, 1), 14)
            switch name {
            case "search_library":
                return await searchLibrary((arguments["query"] as? String) ?? "")
            case "open_source":
                return await openSource((arguments["source_id"] as? String) ?? "")
            case "search_source":
                return opened.search(sourceID: arguments["source_id"] as? String, query: (arguments["query"] as? String) ?? "")
            case "get_plan":
                return await planText() ?? "There is no plan Page for this quarter on this iPhone yet."
            case "get_calendar":
                return await calendarText(days: days, now: Date())
            case "get_schedule":
                return await scheduleText(days: days, now: Date())
            case "get_goals":
                return await goalsText()
            case "get_recent_work":
                return await recentText(now: Date())
            case "start_memory_review":
                await MainActor.run { MobileRealtimeVoice.pendingMemoryReview = true }
                return #"{"ok":true,"next":"Say the review is starting, then call end_conversation."}"#
            default:
                return #"{"error":"Unknown tool."}"#
            }
        }

        func openedSourceIDs() async -> [String] { opened.ids }

        // MARK: Library

        private func libraryItems(now: Date) async -> [RealtimeVoiceLibraryItem] {
            let sources = await catalog.currentSources()
            let attention = MemoryTutorRecency(await catalog.currentRecentSourceAttention(now: now))
            return sources.map { source in
                RealtimeVoiceLibraryItem(
                    id: source.id,
                    title: source.title,
                    sourceType: source.sourceType,
                    byline: source.citationSubtitle,
                    addedAt: source.dateAdded,
                    lastAttentionAt: attention.latest(forSourceID: source.id)
                )
            }
        }

        private func searchLibrary(_ query: String) async -> String {
            let now = Date()
            return RealtimeVoiceLibrarySearch.toolOutput(
                RealtimeVoiceLibrarySearch.rank(query, in: await libraryItems(now: now), now: now),
                now: now
            )
        }

        private func openSource(_ id: String) async -> String {
            guard let source = await catalog.currentSources().first(where: { $0.id == id }) else {
                return #"{"error":"No source with that id. Use search_library to find it."}"#
            }
            do {
                let text = try await MobileCloudSourceTextStore.shared.loadSourceText(sourceID: id)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return #"{"error":"This source has no text on the iPhone yet. Say so: its text arrives once the Mac has prepared it."}"#
                }
                return opened.open(RealtimeVoiceSource(
                    id: source.id,
                    title: source.title,
                    sourceType: source.sourceType,
                    byline: source.citationSubtitle,
                    text: text,
                    reviewGuide: nil
                ))
            } catch {
                logger.error("open_source failed: \(error.localizedDescription, privacy: .public)")
                return #"{"error":"The source's text could not be read on the iPhone right now."}"#
            }
        }

        // MARK: The picture

        func planText() async -> String? {
            let quarter = PlanQuarter.containing(Date())
            do {
                let body = try await MobileSpaceStore.shared.body(of: quarter.id)
                let markdown = body.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
                return markdown.isEmpty ? nil : "\(quarter.title):\n\(markdown)"
            } catch {
                return nil
            }
        }

        func calendarText(days: Int, now: Date) async -> String {
            await MobileCalendarReader.shared.eventsText(days: days, from: now)
        }

        func scheduleText(days: Int, now: Date) async -> String {
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: now)
            guard let end = calendar.date(byAdding: .day, value: days, to: start) else { return "" }
            let items = await catalog.currentScheduleItems()
                .filter { $0.plannedAt >= start && $0.plannedAt < end }
                .sorted { $0.plannedAt < $1.plannedAt }
            guard !items.isEmpty else { return "Nothing is placed on the Schedule for these days." }
            let day = DateFormatter()
            day.dateFormat = "EEEE d MMM"
            return items.prefix(40).map { item in
                var line = "\(day.string(from: item.plannedAt)): \(item.source.title) (\(RealtimeVoiceTutor.spokenKind(item.source.sourceType)))"
                if item.isCompleted { line += ", done" }
                if !item.goalTitles.isEmpty { line += ", for \(item.goalTitles.joined(separator: ", "))" }
                return line
            }.joined(separator: "\n")
        }

        func goalsText() async -> String {
            let goals = await catalog.currentGoals().filter(\.isActive)
            let notebooks = await catalog.currentNotebooks()
            var lines: [String] = []
            if !goals.isEmpty {
                lines.append("Goals:")
                lines += goals.sorted { $0.updatedAt > $1.updatedAt }.prefix(25).map { "- \($0.title)" }
            }
            if !notebooks.isEmpty {
                lines.append("Notebooks (what the learner studies):")
                lines += notebooks.prefix(40).map { notebook in
                    var line = "- \(notebook.title)"
                    if let summary = notebook.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                        line += ": \(summary.prefix(200))"
                    }
                    line += " (\(notebook.sourceIDs.count) sources)"
                    return line
                }
            }
            return lines.joined(separator: "\n")
        }

        func recentText(now: Date) async -> String {
            let sources = Dictionary(
                (await catalog.currentSources()).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var latest: [String: Date] = [:]
            for entry in await catalog.currentRecentSourceAttention(now: now) {
                latest[entry.sourceID] = max(latest[entry.sourceID] ?? .distantPast, entry.discussedAt)
            }
            let attention = latest.sorted { $0.value > $1.value }
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .full
            var lines: [String] = []
            let recentSources = attention.compactMap { id, at -> String? in
                guard let source = sources[id] else { return nil }
                return "- \(source.title) (\(RealtimeVoiceTutor.spokenKind(source.sourceType))), \(relative.localizedString(for: at, relativeTo: now))"
            }
            if !recentSources.isEmpty {
                lines.append("Sources attended to lately, newest first:")
                lines += recentSources.prefix(20)
            }
            let chats = (await catalog.currentNotebookChats()).values.flatMap { $0 }
                .sorted { $0.lastActivityAt > $1.lastActivityAt }
                .prefix(10)
            if !chats.isEmpty {
                lines.append("Latest chats:")
                lines += chats.map { "- \($0.title), \(relative.localizedString(for: $0.lastActivityAt, relativeTo: now))" }
            }
            return lines.joined(separator: "\n")
        }
    }
}

/// Reads the learner's calendars for the assistant: the week and day plan the
/// Mac puts on the calendar reach the phone through iCloud. Read only. Access
/// is asked for once, on the phone, the first time the assistant starts.
actor MobileCalendarReader {
    static let shared = MobileCalendarReader()

    private let store = EKEventStore()

    func eventsText(days: Int, from now: Date) async -> String {
        guard await hasAccess() else {
            return "Calendar access is off for ForeverLM, so the calendar cannot be read. The learner can turn it on in Settings › Privacy & Security › Calendars."
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: max(1, days), to: start) else { return "" }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        guard !events.isEmpty else { return "No calendar events in these days." }
        let day = DateFormatter()
        day.dateFormat = "EEEE d MMM"
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        return events.prefix(80).map { event in
            let when = event.isAllDay
                ? "\(day.string(from: event.startDate)), all day"
                : "\(day.string(from: event.startDate)) \(time.string(from: event.startDate))–\(time.string(from: event.endDate))"
            var line = "\(when): \(event.title ?? "Untitled")"
            if event.endDate < now { line += " (past)" }
            if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                line += " — \(notes.prefix(160))"
            }
            return line
        }.joined(separator: "\n")
    }

    private func hasAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .notDetermined:
            return (try? await store.requestFullAccessToEvents()) ?? false
        default:
            return false
        }
    }
}
