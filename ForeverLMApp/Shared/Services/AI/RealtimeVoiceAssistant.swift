import Foundation
import os

/// Voice mode as a personal assistant: not about one source but about the
/// learner, their recent work, interests, goals and plans (product owner,
/// 2026-11-07: "It needs to basically know all the things I've worked on
/// recently, the things I'm interested in, my goals, my quarterly, weekly,
/// daily plan ... So really like a personal assistant"), in CarPlay above all,
/// where it must "just work". It is the same realtime conversation
/// (`RealtimeVoiceController`) with another brief: a picture of the learner
/// gathered when it starts, and tools to look further (each platform's
/// `RealtimeVoiceToolbox`: `MobileRealtimeAssistant` on the iPhone and in the
/// car, `MacRealtimeAssistant` on the Mac).
enum RealtimeVoiceAssistant {
    /// One part of the picture: "Quarter plan", "Today's calendar", ….
    struct Section: Equatable, Sendable {
        let title: String
        let text: String
    }

    /// Where the conversation happens, which changes how it may talk.
    enum Setting: Equatable, Sendable {
        case car
        case phone
        case mac
    }

    /// Each part of the picture is kept to this many characters (about 4k
    /// tokens), so the model starts knowing a lot without a tool call, and a
    /// long plan Page or a full calendar still never crowds out the conversation.
    static let sectionBudget = 16_000
    static let title = "ForeverLM"

    static func instructions(sections: [Section], setting: Setting, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        var parts: [String] = []
        parts.append("""
        You are ForeverLM, the learner's personal assistant and tutor, talking with them out loud. ForeverLM is \
        their learning system: their library of papers, articles, books, podcasts and videos, their notebooks, \
        their goals, and their plan (a quarter plan Page, and the week and the day on their calendar). You know \
        their recent work and plans from what is below, and you can look further with your tools.

        It is \(formatter.string(from: now)) where the learner is.

        How to talk:
        - This is a live spoken conversation. Answer in one to three short sentences, then hand it back. No lists, \
        headings, markdown, URLs or ids out loud; say titles, not ids.
        - Reply in the language the learner speaks.
        - Be concrete and personal: connect what they ask to what they have been reading, their goals and their plan.
        - Never invent a source, a plan item or a calendar event. If you have not looked something up, look it up; \
        if it is not there, say so.
        - Before a tool call that may take a moment, say a few words ("let me check your plan") so there is no silence.

        What you can do:
        - Talk through what they are working on, help them decide what to do next (always in light of the quarter \
        plan's objectives), and review their day or week.
        - Find a source in their library and talk about it or quiz them on it: search_library, then open_source to \
        read it, then search_source for exact passages. search_library knows titles, authors, a meeting's series and \
        the day it happened, so pass the words the learner said, a day included ("Norn session October 25"). A name \
        may reach you slightly misheard ("norm" for "Norn"): go by what it sounds like, and if you are unsure which \
        one they mean, ask. When quizzing, ask one question at a time that makes them \
        explain, say plainly whether the answer was right and what was missing, then go deeper.
        - Look up their plan, calendar, schedule, goals and notebooks with the matching tools when the picture below \
        is not enough.
        - When they say goodbye or that they are done, say a one-sentence goodbye, then call end_conversation.
        """)
        parts.append("""
        - Meetings: list_meetings names their recurring meetings (group sessions, journal clubs, standups); \
        get_meeting_series lists one series' sessions by date, each with its talk's title and source_id; \
        open_source reads a session's transcript and notes, so you can talk about it or quiz them on it.
        - Everything else in ForeverLM is yours to read too: a notebook's sources and notes, Pages, cards, \
        courses, highlights, ideas, open questions, past chats, canvases and more. Call find_app_tools with a few \
        words for what you need, then use_app_tool with the name and arguments it gave. Never tell the learner \
        you cannot reach something before you have looked this way. These tools only read.
        - Work you hand off: start_background_task gives a task to a typed chat that runs in the background with \
        every tool ForeverLM's chat has. It can pull up and read sources, search the literature (and the web, with \
        deep_research for a researched report), write Pages and notes, make cards, and change the plan or the \
        calendar, and it comes back with its conclusion. Use it when the learner wants something worked through or \
        done that is more than a quick look, and for any change to their things. Write task as a whole instruction \
        a colleague who never heard this conversation could act on: what to do, the sources, notebooks, meetings, \
        days and names it is about (with source_ids you found), and what to come back with. Say the task back in \
        one sentence and start it once they agree; it runs on their chat model and stops at $3. Then carry on \
        talking. When it ends, a note from ForeverLM tells you: say so at a natural pause, give its conclusion in \
        a sentence or two and offer to go through it. check_background_tasks says how each is doing and reads a \
        finished one's conclusion; stop_background_task stops one. Each is also a chat under their chats.
        - A custom podcast, an audio overview, over a notebook's sources is made with make_audio_overview, not a \
        background task. Pick the notebook they mean (ask if it is unclear), and pass what they want it to think \
        through as focus, in their words. Its sources are the notebook's own: if the ones they name are not in it, \
        say so. The first call only prices it: say the price in words and wait for a clear yes before calling again \
        with the same arguments and confirm_cost true. Once it has started, say it is being written and will be in \
        the notebook when it is ready, then carry on; it takes a few minutes.
        """)
        if setting != .mac {
            parts.append("""
            - Meetings, find_app_tools, use_app_tool, make_audio_overview and the background tasks reach the \
            learner's Mac: it does that work. If one says the Mac cannot be reached, tell them in a sentence that \
            ForeverLM has to be open on their Mac for it; everything else here still works.
            """)
        }
        if setting != .mac {
            parts.append("""
            - When they ask for their review or their cards, run it out loud: get_due_cards, then one card at a time. \
            Ask its question, let them answer, say plainly whether they had it and the answer in a sentence, call \
            grade_card, then ask the next. Stop when they want to or the cards run out, and say how it went.
            """)
        }
        switch setting {
        case .car:
            parts.append("""
            The learner is driving, talking through CarPlay. Keep every turn short and easy to follow by ear. Never ask \
            them to look at, read or tap anything; never spell things out. If they want something shown or saved for \
            later, say it will be in their chats on their phone and Mac.
            """)
        case .phone, .mac:
            break
        }
        let shown = sections.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if shown.isEmpty {
            parts.append("Nothing about the learner could be read at the start; use your tools.")
        } else {
            parts.append("What you know about the learner right now:")
            for section in shown {
                let text = section.text.count > sectionBudget
                    ? String(section.text.prefix(sectionBudget)) + "\n… (more with your tools)"
                    : section.text
                parts.append("<\(tag(section.title))>\n\(text)\n</\(tag(section.title))>")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    static func kickoff(setting: Setting) -> String {
        switch setting {
        case .car:
            return "(The learner just started ForeverLM in the car. Greet them in one short sentence, and offer one useful, specific thing from what you know: what is next in their plan, or the source they were last into. Then listen.)"
        case .phone, .mac:
            return "(The learner just opened ForeverLM's voice assistant. Greet them in one short sentence and ask what they would like to do, offering one specific suggestion from what you know.)"
        }
    }

    private static func tag(_ title: String) -> String {
        let lowered = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(lowered).split(separator: "_").joined(separator: "_")
    }

    /// The tool definitions both platforms' assistants share by name, so the
    /// instructions above stay true on each.
    static func function(_ name: String, _ description: String, properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": description,
            "parameters": [
                "type": "object",
                "properties": properties,
                "required": required,
            ] as [String: Any],
        ]
    }
}

/// Sources the assistant opened in one conversation, with their passages for
/// `search_source`. Thread-safe: tool calls arrive from the conversation's task.
final class RealtimeVoiceOpenedSources: @unchecked Sendable {
    /// What `open_source` hands the model whole. Longer text sends its opening
    /// and leaves the rest to `search_source`, so one long book does not take
    /// the conversation's whole window.
    static let openTextBudget = 80_000

    private struct Opened {
        let title: String
        let passages: [RealtimeVoicePassageSearch.Passage]
    }

    private let state = OSAllocatedUnfairLock(initialState: (order: [String](), opened: [String: Opened]()))

    var ids: [String] { state.withLock { $0.order } }

    /// The tool output for opening a source.
    func open(_ source: RealtimeVoiceSource) -> String {
        let passages = RealtimeVoicePassageSearch.chunks(of: source.text)
        state.withLock {
            if $0.opened[source.id] == nil { $0.order.append(source.id) }
            $0.opened[source.id] = Opened(title: source.title, passages: passages)
        }
        let whole = source.text.count <= Self.openTextBudget
        let text = whole ? source.text : String(source.text.prefix(Self.openTextBudget))
        var object: [String: Any] = [
            "source_id": source.id,
            "title": source.title,
            "kind": RealtimeVoiceTutor.spokenKind(source.sourceType),
            "text": text,
        ]
        if let byline = source.byline, !byline.isEmpty { object["by"] = byline }
        if !whole {
            object["note"] = "This is the opening only; the source is longer. Use search_source with this source_id for anything further on."
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"error":"The source could not be encoded."}"#
    }

    func search(sourceID: String?, query: String) -> String {
        let opened = state.withLock { state -> Opened? in
            if let sourceID, let found = state.opened[sourceID] { return found }
            return state.order.last.flatMap { state.opened[$0] }
        }
        guard let opened else {
            return #"{"error":"No source is open yet. Call open_source first."}"#
        }
        return RealtimeVoicePassageSearch.toolOutput(query: query, passages: opened.passages)
    }
}

/// A library entry the assistant can find by voice.
struct RealtimeVoiceLibraryItem: Equatable, Sendable {
    let id: String
    let title: String
    let sourceType: String
    let byline: String?
    let addedAt: Date
    /// When the learner last read, listened to, watched or discussed it.
    let lastAttentionAt: Date?
    /// The series a meeting belongs to ("Norn Group Nexus"), searched with the
    /// title and said with it: a meeting session's own title is often only its
    /// date ("2026/10/25"), so without it "the Norn session" finds nothing.
    var group: String? = nil
}

/// Ranks a library for a spoken query: title, byline and series words first,
/// a day the learner names next, recent attention breaking ties, so "the
/// mitochondria paper I read yesterday" and "the Norn session on October
/// 25th" both land.
enum RealtimeVoiceLibrarySearch {
    /// A day named out loud: "October 25th", "25 October", "Oct 25 2026", or
    /// only a month ("the October session").
    struct SpokenDate: Equatable, Sendable {
        let month: Int
        let day: Int?
        let year: Int?
        /// The query's words that named it, kept out of the title match.
        let words: Set<String>
    }

    private static let months: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4,
        "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8,
        "september": 9, "sept": 9, "sep": 9, "october": 10, "oct": 10, "november": 11, "nov": 11,
        "december": 12, "dec": 12,
    ]

    static func spokenDate(in query: String) -> SpokenDate? {
        let tokens = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        func dayNumber(_ token: String) -> Int? {
            var digits = token
            for suffix in ["st", "nd", "rd", "th"] where digits.hasSuffix(suffix) {
                digits.removeLast(suffix.count)
            }
            guard (1...2).contains(digits.count), let day = Int(digits), (1...31).contains(day) else { return nil }
            return day
        }
        for (index, token) in tokens.enumerated() {
            guard let month = months[token] else { continue }
            var words: Set<String> = [token]
            var day: Int?
            for neighbour in [index + 1, index - 1] where tokens.indices.contains(neighbour) {
                if let found = dayNumber(tokens[neighbour]) {
                    day = found
                    words.insert(tokens[neighbour])
                    break
                }
            }
            // "may" is a word before it is a month.
            if token == "may", day == nil { continue }
            let year = tokens.lazy.compactMap { token -> Int? in
                guard token.count == 4, let value = Int(token), (1900...2100).contains(value) else { return nil }
                return value
            }.first
            if let year { words.insert(String(year)) }
            return SpokenDate(month: month, day: day, year: year, words: words)
        }
        return nil
    }

    /// The day a source happened on, when it has one: a date its title
    /// carries ("2026-10-25 - [Notes] …", "2026/10/25"), else a meeting's own
    /// day, which is when it was added.
    static func occurrence(of item: RealtimeVoiceLibraryItem, calendar: Calendar = .current) -> DateComponents? {
        let pattern = #"(?<!\d)(19|20)\d{2}[-/.](1[0-2]|0?[1-9])[-/.](3[01]|[12]\d|0?[1-9])(?!\d)"#
        if let range = item.title.range(of: pattern, options: .regularExpression) {
            let parts = item.title[range].split(whereSeparator: { "-/.".contains($0) }).compactMap { Int($0) }
            if parts.count == 3 { return DateComponents(year: parts[0], month: parts[1], day: parts[2]) }
        }
        guard item.sourceType == "meeting" else { return nil }
        return calendar.dateComponents([.year, .month, .day], from: item.addedAt)
    }

    /// Whether two words are one letter apart (one changed, added or dropped):
    /// a name heard slightly wrong, "norm" for "Norn".
    static func oneEditApart(_ a: String, _ b: String) -> Bool {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= 1, a != b else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                i += 1; j += 1
                continue
            }
            edits += 1
            if edits > 1 { return false }
            if a.count > b.count { i += 1 } else if b.count > a.count { j += 1 } else { i += 1; j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }

    static func rank(
        _ query: String,
        in items: [RealtimeVoiceLibraryItem],
        limit: Int = 8,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [RealtimeVoiceLibraryItem] {
        let spoken = spokenDate(in: query)
        let terms = Set(RealtimeVoicePassageSearch.terms(query).filter { !(spoken?.words.contains($0) ?? false) })
        let scored: [(RealtimeVoiceLibraryItem, Double)] = items.compactMap { item in
            let haystack = RealtimeVoicePassageSearch.terms(
                [item.title, item.byline ?? "", item.group ?? ""].joined(separator: " ")
            )
            var score = 0.0
            if terms.isEmpty, spoken == nil {
                score = 0.01
            } else {
                var matched = 0.0
                for term in terms {
                    if haystack.contains(where: { $0 == term || ($0.hasPrefix(term) && term.count > 3) }) {
                        matched += 1
                    } else if term.count >= 4, haystack.contains(where: { $0.count >= 4 && oneEditApart($0, term) }) {
                        matched += 0.5
                    }
                }
                var dateScore = 0.0
                if let spoken, let day = occurrence(of: item, calendar: calendar),
                   day.month == spoken.month,
                   spoken.year == nil || day.year == spoken.year {
                    if let spokenDay = spoken.day {
                        if day.day == spokenDay { dateScore = 10 }
                    } else {
                        dateScore = 4
                    }
                }
                guard matched > 0 || dateScore > 0 else { return nil }
                score = (terms.isEmpty ? 0 : matched / Double(terms.count) * 10) + dateScore
                if RealtimeVoiceTutor.spokenKind(item.sourceType) != "source",
                   terms.contains(RealtimeVoiceTutor.spokenKind(item.sourceType)) || terms.contains(item.sourceType) {
                    score += 1
                }
            }
            if let last = item.lastAttentionAt {
                let days = max(0, now.timeIntervalSince(last) / 86_400)
                score += 3 / (1 + days)
            }
            return (item, score)
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.addedAt > $1.0.addedAt }
            .prefix(limit)
            .map(\.0)
    }

    static func toolOutput(_ items: [RealtimeVoiceLibraryItem], now: Date = Date(), calendar: Calendar = .current) -> String {
        guard !items.isEmpty else {
            return #"{"results":[],"note":"Nothing in the library matches. Ask for other words, or say it is not in the library."}"#
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let results = items.map { item -> [String: Any] in
            var row: [String: Any] = [
                "source_id": item.id,
                "title": item.title,
                "kind": RealtimeVoiceTutor.spokenKind(item.sourceType),
                "added": formatter.localizedString(for: item.addedAt, relativeTo: now),
            ]
            if let byline = item.byline, !byline.isEmpty { row["by"] = byline }
            if let group = item.group, !group.isEmpty { row["series"] = group }
            if let day = occurrence(of: item, calendar: calendar), let date = calendar.date(from: day) {
                row["date"] = dayFormatter(calendar: calendar).string(from: date)
            }
            if let last = item.lastAttentionAt { row["last_attention"] = formatter.localizedString(for: last, relativeTo: now) }
            return row
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["results": results], options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"results":[]}"#
    }

    /// "Sunday 25 October 2026": a day as it is said.
    static func dayFormatter(calendar: Calendar = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE d MMMM yyyy"
        return formatter
    }
}

/// The assistant's reach past its own picture, the same by name on the Mac
/// and the iPhone (product owner, 2026-11-08: "make sure the iphone also has
/// all that functionality"): meetings by series, every read tool in the app,
/// a notebook's audio overview, and background tasks, which are typed chats
/// with every tool the chat has. The Mac answers them itself
/// (`MacRealtimeAssistant`); the iPhone asks the learner's Mac for them
/// through the gateway (`MobileRealtimeAssistant`, `MacVoiceRelayTools`).
enum RealtimeVoiceReach {
    static var toolDefinitions: [[String: Any]] {
        [
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
            RealtimeVoiceAssistant.function(
                "start_background_task",
                "Hands a task to a typed chat that runs in the background with every tool ForeverLM's chat has: it can pull up and read sources, search the literature (and the web, with deep_research), write Pages and notes, make cards, and change the plan or the calendar. It works it through and comes to a conclusion, and a note tells you when it is done. Say the task back in one sentence and start it once the learner agrees.",
                properties: [
                    "task": ["type": "string", "description": "The whole instruction, as a colleague who never heard this conversation would need it: what to do, the sources, notebooks, meetings, days and names it is about, and what to come back with."],
                    "title": ["type": "string", "description": "A short name for it, a few words, which becomes the chat's title."],
                    "source_ids": ["type": "array", "items": ["type": "string"], "description": "Sources to hand it in full, from search_library or open_source. Optional: it can find sources itself."],
                    "deep_research": ["type": "boolean", "description": "True for a researched report that searches the web and the literature, written as a Page. Slower and costs more."],
                ],
                required: ["task", "title"]
            ),
            RealtimeVoiceAssistant.function(
                "check_background_tasks",
                "How the background tasks started in voice are doing, newest first, with each finished one's conclusion. Pass task_id for one.",
                properties: ["task_id": ["type": "string", "description": "The task_id start_background_task gave. Leave out for all."]]
            ),
            RealtimeVoiceAssistant.function(
                "stop_background_task",
                "Stops a background task that is still running. What it already did stays, and its chat keeps the reply so far.",
                properties: ["task_id": ["type": "string", "description": "The task_id start_background_task gave."]],
                required: ["task_id"]
            ),
        ]
    }

    /// Output a borrowed tool hands the conversation at most. A realtime
    /// event is capped near 200 KB (`RealtimeVoiceSession.maximumMessageBytes`),
    /// and a long listing read out of a voice call is no use anyway.
    static let appToolOutputBudget = 50_000

    /// The most an audio overview started by voice may spend: the default
    /// ceiling of work an assistant starts, never raised by voice.
    static let audioOverviewSpendCeilingUSD = 3.0

    static func capped(_ text: String) -> String {
        guard text.count > appToolOutputBudget else { return text }
        return String(text.prefix(appToolOutputBudget))
            + "\n… (cut here: the answer was longer. Ask the tool for less, with a narrower filter or a limit, for anything further.)"
    }

    /// Why `use_app_tool` will not run a tool, or nil when it may: voice runs
    /// reads only, and an audio overview has its own tool.
    static func useAppToolRefusal(_ name: String, isReadOnly: Bool) -> String? {
        if name == "generate_audio_overview" {
            return #"{"error":"Use make_audio_overview for an audio overview."}"#
        }
        guard isReadOnly else {
            return #"{"error":"That tool changes things, and voice only reads. Hand the change to start_background_task instead."}"#
        }
        return nil
    }

    /// `make_audio_overview`'s arguments as `generate_audio_overview`
    /// takes them: only the recipe and the learner's yes. The spend ceiling
    /// is never raised by voice, so a run stays under the operation's
    /// default, and the audio is always narrated. `approvingCeiling` names
    /// that ceiling with the yes, as the gateway's `/web/call` requires of a
    /// confirmed call (the iPhone's route).
    static func audioOverviewArguments(_ arguments: [String: Any], approvingCeiling: Bool = false) -> [String: Any] {
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
        if (arguments["confirm_cost"] as? Bool) == true {
            forwarded["confirm_cost"] = true
            if approvingCeiling { forwarded["approved_spend_usd"] = audioOverviewSpendCeilingUSD }
        }
        return forwarded
    }

    // MARK: Meetings

    /// `get_meeting_group` cut to what a voice conversation needs: the whole
    /// listing carries every artifact's link (over 100k characters for a
    /// weekly series), while a session is found by its day and talk. Anything
    /// that is not a listing (an error) passes through as it is.
    static func meetingSeries(fromGroupListing raw: String, groupID: String, calendar: Calendar = .current) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
            return raw
        }
        let sessions = (object["sessions"] as? [[String: Any]]) ?? []
        let rows = sessions.map { meetingSessionRow($0, calendar: calendar) }
        var payload: [String: Any] = ["series": object["title"] as? String ?? groupID, "sessions": rows]
        if rows.isEmpty { payload["note"] = "This series has no sessions yet." }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? raw
    }

    /// One session as voice says it: its day, its talk (the title its notes
    /// or recording carry, without the date and kind it repeats), and the
    /// source_id to open.
    static func meetingSessionRow(_ session: [String: Any], calendar: Calendar = .current) -> [String: Any] {
        var row: [String: Any] = ["source_id": session["source_id"] as? String ?? ""]
        if let seconds = (session["date_added"] as? NSNumber)?.doubleValue {
            row["date"] = RealtimeVoiceLibrarySearch.dayFormatter(calendar: calendar)
                .string(from: Date(timeIntervalSinceReferenceDate: seconds))
        }
        let artifactTitles = ((session["artifacts"] as? [[String: Any]]) ?? []).compactMap { $0["title"] as? String }
        let talk = artifactTitles.lazy.map(talkTitle).first { !$0.isEmpty }
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

    // MARK: Background tasks

    /// What voice is told when a background task ends: nothing while it runs
    /// or after voice itself stopped it.
    static func backgroundTaskNotice(
        taskID: String,
        title: String,
        state: String,
        conclusion: String?,
        failure: String?,
        stoppedByVoice: Bool
    ) -> String? {
        let named = "The background task \u{201C}\(title)\u{201D} (\(taskID))"
        switch state {
        case "finished":
            return """
            \(named) has finished. When there is a natural pause, tell the learner in a sentence or two what it \
            concluded, and offer to go through it. It is also a chat under their chats. Its conclusion:

            \(conclusion ?? "")
            """
        case "failed":
            return "\(named) failed: \(failure ?? "no reason given"). Tell the learner in one sentence, in plain words."
        case "stopped":
            return stoppedByVoice ? nil : "\(named) was stopped before it finished. Tell the learner in one sentence."
        default:
            return nil
        }
    }

    /// One task out of `check_background_tasks`' answer for one task_id
    /// (`{"task": {...}}`), or nil when the answer is not that.
    static func backgroundTaskRow(fromCheckAnswer text: String) -> [String: Any]? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        return object["task"] as? [String: Any]
    }

    /// The task_id in `start_background_task`'s answer, when it started one.
    static func startedTaskID(fromStartAnswer text: String) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let id = object["task_id"] as? String, !id.isEmpty else { return nil }
        return id
    }
}
