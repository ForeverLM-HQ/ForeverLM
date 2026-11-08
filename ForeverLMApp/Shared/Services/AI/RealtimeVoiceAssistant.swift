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
        read it, then search_source for exact passages. When quizzing, ask one question at a time that makes them \
        explain, say plainly whether the answer was right and what was missing, then go deeper.
        - Look up their plan, calendar, schedule, goals and notebooks with the matching tools when the picture below \
        is not enough.
        - When they say goodbye or that they are done, say a one-sentence goodbye, then call end_conversation.
        """)
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
}

/// Ranks a library for a spoken query: title and byline words first, recent
/// attention breaking ties, so "the mitochondria paper I read yesterday" lands.
enum RealtimeVoiceLibrarySearch {
    static func rank(_ query: String, in items: [RealtimeVoiceLibraryItem], limit: Int = 8, now: Date = Date()) -> [RealtimeVoiceLibraryItem] {
        let terms = RealtimeVoicePassageSearch.terms(query)
        let scored: [(RealtimeVoiceLibraryItem, Double)] = items.compactMap { item in
            let haystack = RealtimeVoicePassageSearch.terms(item.title + " " + (item.byline ?? ""))
            var score = 0.0
            if terms.isEmpty {
                score = 0.01
            } else {
                var matched = 0
                for term in Set(terms) where haystack.contains(where: { $0 == term || ($0.hasPrefix(term) && term.count > 3) }) {
                    matched += 1
                }
                guard matched > 0 else { return nil }
                score = Double(matched) / Double(Set(terms).count) * 10
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

    static func toolOutput(_ items: [RealtimeVoiceLibraryItem], now: Date = Date()) -> String {
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
            if let last = item.lastAttentionAt { row["last_attention"] = formatter.localizedString(for: last, relativeTo: now) }
            return row
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["results": results], options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"results":[]}"#
    }
}
