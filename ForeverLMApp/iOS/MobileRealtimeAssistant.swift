import CloudKit
import EventKit
import Foundation
import OSLog
import os

/// The voice assistant on the iPhone and in CarPlay (`RealtimeVoiceAssistant`):
/// what it knows when it starts, read from the phone's own replica of the
/// library, and the tools it looks further with. Everything is read on the
/// device. The one write here is a card's grade in a spoken card review
/// (`grade_card`, `MobileRealtimeCardTools`), recorded exactly as the phone's
/// card review records a Forgot or Remembered.
///
/// The rest of its reach is the Mac's, as voice on the Mac has it
/// (`RealtimeVoiceReach`; product owner, 2026-11-08: "make sure the iphone
/// also has all that functionality"): meetings by series, every read tool in
/// the app, a notebook's audio overview, and background tasks, the typed
/// chats with every tool that do work and come back with a conclusion. The
/// phone has none of those tools, so it asks the learner's Mac through the
/// gateway's `/web/call` (`MobileVoiceMac`), the way notebook Share does; with
/// ForeverLM closed on the Mac, voice says so and the rest still works.
///
/// What it reads:
/// - the quarter plan Page (`PlanQuarter`, from the Space store);
/// - the week and the day: the learner's calendar, through EventKit (the same
///   calendars the Mac plans onto, synced by iCloud), once access is granted;
/// - the Schedule (sources placed on days);
/// - goals and notebooks, with what each notebook is for;
/// - what the learner read, listened to, watched or discussed lately, and their
///   latest chats.
///
/// Asked to play a source itself, it hands the audio to that source's
/// narration (`listen_to_source`, `RealtimeVoiceListen`): the phone's own
/// Listen, started once the conversation has ended.
enum MobileRealtimeAssistant {
    private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "RealtimeAssistant")

    /// The brief a conversation starts on. Each part is read independently, so
    /// one that fails (no calendar access, a plan not yet synced) only leaves
    /// that part out.
    ///
    /// `narration` is the narration the learner comes back from (the car's
    /// Talk button, or one that ended): the assistant opens on it.
    static func brief(
        setting: RealtimeVoiceAssistant.Setting,
        returningFrom narration: RealtimeVoiceAssistant.NarrationReturn? = nil,
        voiceChangedTo newVoice: String? = nil
    ) async -> RealtimeVoiceBrief {
        let toolbox = Toolbox()
        toolbox.setting = setting
        let now = Date()
        async let plan = toolbox.planText()
        async let calendar = toolbox.calendarText(days: 7, now: now)
        async let schedule = toolbox.scheduleText(days: 7, now: now)
        async let goals = toolbox.goalsText()
        async let recent = toolbox.recentText(now: now)
        async let cards = dueCardsText()
        let sections = await [
            RealtimeVoiceAssistant.Section(title: "Quarter plan", text: plan ?? ""),
            RealtimeVoiceAssistant.Section(title: "Calendar this week", text: calendar),
            RealtimeVoiceAssistant.Section(title: "Schedule", text: schedule),
            RealtimeVoiceAssistant.Section(title: "Goals and notebooks", text: goals),
            RealtimeVoiceAssistant.Section(title: "Recent work", text: recent),
            // Last, and only so it can answer "how many cards do I have?":
            // voice never opens on the cards.
            RealtimeVoiceAssistant.Section(title: "Today's cards", text: cards),
        ]
        return RealtimeVoiceBrief(
            title: RealtimeVoiceAssistant.title,
            instructions: RealtimeVoiceAssistant.instructions(sections: sections, setting: setting, now: now),
            kickoff: RealtimeVoiceAssistant.kickoff(
                setting: setting,
                returningFrom: narration,
                voiceChangedTo: newVoice
            ),
            toolbox: toolbox,
            source: nil
        )
    }

    /// How many review cards wait today over every notebook, as the card
    /// review deals them.
    @MainActor
    private static func dueCardsText() async -> String {
        let count = await MobileCardReviewSession.Backend.live().deal(.today(.allNotebooks), .today, Date()).cards.count
        switch count {
        case 0: return "No review cards are due today."
        case 1: return "1 review card is due today."
        default: return "\(count) review cards are due today."
        }
    }

    final class Toolbox: RealtimeVoiceToolbox, @unchecked Sendable {
        private let opened = RealtimeVoiceOpenedSources()
        private let catalog = MobileCloudSourceCatalog.shared
        /// Where the conversation runs, for the one a voice change starts.
        var setting: RealtimeVoiceAssistant.Setting = .phone

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
                RealtimeVoiceCardReview.dueCardsTool(
                    description: "Today's review cards (spaced repetition), each with its question and answer, for a card review out loud when the learner asks for their review or their cards. Ask one card's question at a time, let them answer, say plainly whether they had it and the answer in a sentence, then call grade_card before the next."
                ),
                RealtimeVoiceCardReview.gradeCardTool,
                RealtimeVoiceCardReview.deleteCardTool,
                RealtimeVoiceCardReview.searchCardsTool(),
                RealtimeVoiceCardReview.listTopicsTool(),
                RealtimeVoiceCardsToCheck.listTool(
                    description: "The cards waiting in To Check (drafted from what the learner read, not yet kept or skipped), for going through them out loud when the learner asks to check their new cards. Ask one card's question at a time, let them answer, say the answer in a sentence, then ask whether to keep, change or skip it, and call decide_card only on their word."
                ),
                RealtimeVoiceCardsToCheck.decideTool,
                RealtimeVoiceListen.toolDefinition,
                RealtimeVoiceChange.toolDefinition,
            ] + RealtimeVoiceReach.toolDefinitions
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
            case RealtimeVoiceListen.toolName:
                return await listenToSource(
                    (arguments["source_id"] as? String) ?? "",
                    costConfirmed: (arguments["confirm_cost"] as? Bool) ?? false
                )
            case RealtimeVoiceChange.toolName:
                return await changeVoice(arguments["voice"] as? String)
            case "list_meetings":
                return await MobileVoiceMac.call("list_meeting_groups", [:])
            case "get_meeting_series":
                let groupID = ((arguments["group_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return RealtimeVoiceReach.meetingSeries(
                    fromGroupListing: await MobileVoiceMac.call("get_meeting_group", ["group_id": groupID]),
                    groupID: groupID
                )
            case "make_audio_overview":
                return await MobileVoiceMac.call(
                    "generate_audio_overview",
                    RealtimeVoiceReach.audioOverviewArguments(arguments, approvingCeiling: true)
                )
            case "find_app_tools":
                return await MobileVoiceMac.call("voice_find_app_tools", ["query": (arguments["query"] as? String) ?? ""])
            case "use_app_tool":
                return await useAppTool(name: (arguments["name"] as? String) ?? "", arguments: arguments["arguments"])
            case "start_background_task":
                return await startBackgroundTask(arguments)
            case "check_background_tasks":
                var forwarded: [String: Any] = [:]
                if let id = (arguments["task_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                    forwarded["task_id"] = id
                }
                return await MobileVoiceMac.call("voice_check_background_tasks", forwarded)
            case "stop_background_task":
                let id = ((arguments["task_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                tasks.markStoppedByVoice(id)
                return await MobileVoiceMac.call("voice_stop_background_task", ["task_id": id])
            default:
                if let answer = await toCheck.run(name: name, argumentsJSON: argumentsJSON, onlyNew: false) {
                    return answer
                }
                return await cards.run(name: name, argumentsJSON: argumentsJSON, onlyNew: false)
                    ?? #"{"error":"Unknown tool."}"#
            }
        }

        func openedSourceIDs() async -> [String] { opened.ids }

        func recordedAnswers() async -> [RealtimeVoiceAnswerRecord] { cards.recordedAnswers() }

        func setNoticeHandler(_ handler: @escaping @Sendable (String) -> Void) {
            tasks.setNoticeHandler(handler)
        }

        // MARK: Listening

        private let listenLock = AppLock()
        /// The source whose narration plays when this conversation ends.
        private var pendingListenSourceID: String?

        /// Nothing plays yet: the conversation holds the audio. A narration
        /// that can start is remembered, and started in `conversationEnded`.
        private func listenToSource(_ id: String, costConfirmed: Bool) async -> String {
            let answer = await Self.listenAnswer(sourceID: id, costConfirmed: costConfirmed)
            if case .starting = answer {
                let sourceID = id.trimmingCharacters(in: .whitespacesAndNewlines)
                listenLock.withLock { pendingListenSourceID = sourceID }
            }
            return RealtimeVoiceListen.output(answer)
        }

        @MainActor
        private static func listenAnswer(sourceID: String, costConfirmed: Bool) async -> RealtimeVoiceListen.Answer {
            await MobileAudioReviewViewModel.shared.voiceListenAnswer(sourceID: sourceID, costConfirmed: costConfirmed)
        }

        // MARK: A different voice

        /// The voice the next conversation opens in, once this one has ended.
        private var pendingVoice: String?

        /// Saves the pick where Settings saves it, the account row first: the
        /// next conversation reads that row, so a pick that did not reach it
        /// would start the new conversation in the old voice.
        private func changeVoice(_ requested: String?) async -> String {
            let current = RealtimeVoiceDefaults.resolvedVoice(MobileRealtimeVoicePick.lastSeen)
            let answer = RealtimeVoiceChange.pick(requested: requested, current: current)
            guard case .changing(let voice) = answer else { return RealtimeVoiceChange.output(answer) }
            do {
                try await MobileModelPreferenceStore.shared.set(voice, for: Prefs.ReadAloud.voiceModeVoice)
            } catch {
                MobileRealtimeAssistant.logger.error("Saving the voice picked by voice failed: \(error.localizedDescription, privacy: .public)")
                return RealtimeVoiceChange.output(.refused("The new voice could not be saved to the learner's account: \(error.localizedDescription) Nothing changed."))
            }
            MobileRealtimeVoicePick.remember(voice)
            listenLock.withLock { pendingVoice = voice }
            return RealtimeVoiceChange.output(answer)
        }

        func conversationEnded() async {
            let (sourceID, voice) = listenLock.withLock { () -> (String?, String?) in
                defer {
                    pendingListenSourceID = nil
                    pendingVoice = nil
                }
                return (pendingListenSourceID, pendingVoice)
            }
            if let voice, sourceID == nil {
                let setting = setting
                // Not awaited: the ended conversation still has what was said
                // to hand over, and the next one starts after it has.
                Task { @MainActor in
                    try? await Task.sleep(for: RealtimeVoiceChange.restartDelay)
                    guard !MobileRealtimeVoice.controller.isActive else { return }
                    await MobileRealtimeVoice.startAssistant(setting: setting, voiceChangedTo: voice)
                }
            }
            guard let sourceID else { return }
            // Not awaited: a narration that has to be made runs for minutes,
            // and ending the conversation must not wait for it.
            Task { @MainActor in
                await MobileAudioReviewViewModel.shared.startVoiceListen(sourceID: sourceID)
            }
        }

        // MARK: The Mac's reach

        private let tasks = MobileVoiceBackgroundTaskWatch()

        /// A read tool of the Mac's that find_app_tools named. The gateway
        /// lets only reads through; this says so before asking.
        private func useAppTool(name rawName: String, arguments raw: Any?) async -> String {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                return #"{"error":"No tool by that name. Call find_app_tools first and use a name it gave."}"#
            }
            if let refusal = RealtimeVoiceReach.useAppToolRefusal(name, isReadOnly: true) { return refusal }
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
            return RealtimeVoiceReach.capped(await MobileVoiceMac.call(name, arguments))
        }

        /// Hands the task to the Mac, then watches it there so voice hears
        /// when it ends (the Mac cannot speak into a call on the phone).
        private func startBackgroundTask(_ arguments: [String: Any]) async -> String {
            var forwarded: [String: Any] = [:]
            for key in ["task", "title"] {
                if let value = arguments[key] as? String { forwarded[key] = value }
            }
            if let ids = arguments["source_ids"] as? [Any] { forwarded["source_ids"] = ids.compactMap { $0 as? String } }
            if let deep = arguments["deep_research"] as? Bool { forwarded["deep_research"] = deep }
            let answer = await MobileVoiceMac.call("voice_start_background_task", forwarded)
            if let id = RealtimeVoiceReach.startedTaskID(fromStartAnswer: answer) {
                tasks.watch(id)
            }
            return answer
        }

        // MARK: Cards

        /// Today's cards over every notebook, and their grades.
        private let cards = MobileRealtimeCardTools(scope: .allNotebooks)
        /// The cards waiting in To Check over every notebook, and what was decided.
        private let toCheck = MobileRealtimeToCheckTools(scope: .allNotebooks)

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

/// Voice mode's calls to the learner's Mac, through the gateway's
/// `POST /web/call` (`MobileMacRelay`), authorized like notebook Share's: the
/// phone's Sign in with Apple session, and the iCloud account the Mac must
/// sync with. Every answer is text the realtime model reads, a refusal
/// included, so voice can say plainly why the Mac was not asked.
enum MobileVoiceMac {
    /// Past the relay's own minute, so its "still working" answer arrives.
    static let timeout: TimeInterval = 75

    static func call(_ name: String, _ arguments: [String: Any]) async -> String {
        guard let token = ManagedAI.requestSessionToken else {
            return error("Reaching the learner's Mac needs Sign in with Apple on this iPhone. Tell them it is under Settings.")
        }
        guard let container = MobileMacSearch.relayContainer,
              let user = try? await CKContainer(identifier: container).userRecordID().recordName else {
            return error("iCloud could not be reached on this iPhone, so the Mac could not be asked.")
        }
        let request = MobileMacRelay.toolRequest(token: token, iCloudUser: user, name: name, arguments: arguments, timeout: timeout)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return answer(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch {
            return self.error("The Mac could not be reached from this iPhone right now (\(error.localizedDescription)).")
        }
    }

    /// The Mac's own text, or why it was not asked, as the model reads it.
    static func answer(status: Int, body: Data) -> String {
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if status == 200, let text = payload?["text"] as? String {
            return text
        }
        if status == 401 {
            return error("The iPhone's Apple sign-in has lapsed, so the Mac could not be asked. Tell the learner to sign in with Apple again in Settings.")
        }
        switch payload?["error"] as? String {
        case "mac_offline":
            return error("ForeverLM is not open on the learner's Mac, so the Mac cannot do this right now.")
        case "mac_busy":
            return error("The learner's Mac did not answer in time. It may be busy; try once more in a moment.")
        case "mac_still_working":
            return error("The Mac took this and is still working on it; ask again in a minute.")
        case "tool_not_allowed":
            return error("The Mac cannot be asked for that tool from the iPhone.")
        case let account? where status == 409:
            return error(MobileMacRelay.MacLine.account(account))
        default:
            let detail = (payload?["error_description"] as? String).map { " (\($0))" } ?? ""
            return error("The Mac could not be reached from this iPhone\(detail).")
        }
    }

    private static func error(_ message: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"error":"The Mac could not be asked."}"#
    }
}

/// Background tasks voice handed to the Mac from this call, asked after
/// every so often while they run so voice hears when each ends: the Mac has
/// no way to speak into a call on the phone. Watching stops when a task ends,
/// after `longestWatch`, or once the call is gone (no handler is waiting).
final class MobileVoiceBackgroundTaskWatch: @unchecked Sendable {
    static let interval: Duration = .seconds(20)
    static let longestWatch: TimeInterval = 90 * 60

    private let lock = AppLock()
    private var handler: (@Sendable (String) -> Void)?
    private var stoppedByVoice: Set<String> = []
    private var watching: [String: Task<Void, Never>] = [:]

    deinit {
        for task in watching.values { task.cancel() }
    }

    func setNoticeHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func markStoppedByVoice(_ id: String) {
        _ = lock.withLock { stoppedByVoice.insert(id) }
    }

    func watch(_ id: String) {
        let task = Task { [weak self] in
            let started = Date()
            while !Task.isCancelled, Date().timeIntervalSince(started) < Self.longestWatch {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled, self != nil else { return }
                let answer = await MobileVoiceMac.call("voice_check_background_tasks", ["task_id": id])
                // An unreachable Mac is asked again next time; the task goes
                // on there either way.
                guard let row = RealtimeVoiceReach.backgroundTaskRow(fromCheckAnswer: answer),
                      let state = row["state"] as? String, state != "running" else { continue }
                self?.ended(id: id, row: row, state: state)
                return
            }
        }
        lock.withLock { watching[id] = task }
    }

    private func ended(id: String, row: [String: Any], state: String) {
        let (handler, stopped) = lock.withLock { () -> ((@Sendable (String) -> Void)?, Bool) in
            watching[id] = nil
            return (self.handler, stoppedByVoice.contains(id))
        }
        guard let notice = RealtimeVoiceReach.backgroundTaskNotice(
            taskID: id,
            title: row["title"] as? String ?? "",
            state: state,
            conclusion: row["conclusion"] as? String,
            failure: row["error"] as? String,
            stoppedByVoice: stopped
        ) else { return }
        handler?(notice)
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
