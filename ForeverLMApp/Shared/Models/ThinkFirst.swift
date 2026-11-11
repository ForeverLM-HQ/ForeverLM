import Foundation

/// Think first (docs/fences-and-think-first-design.md, "Think first"): at a few
/// moments where ForeverLM is about to show something it wrote about the
/// learner's material, it first asks for the learner's own version in a line
/// or two. Return shows theirs beside ForeverLM's; Skip shows ForeverLM's at
/// once, with no penalty. The take is kept in the learner's words, never
/// corrected, and the two versions sit side by side with no grade.
///
/// The learner picks how much of it they want: one level for the library
/// (`thinkFirst.level`) and, over it, an optional level of a notebook's own
/// (`notebook.thinkFirst.<notebookID>`). Both are account Settings, so they
/// follow the learner to their other Macs and the web, and a notebook's is the
/// learner's alone: a teammate's choice never changes it.
enum ThinkFirstLevel: String, CaseIterable, Codable, Sendable {
    /// Nothing asks first. The design's default, and what an absent Setting means.
    case off
    /// A source's gist, a Studio report and Find directions ask first.
    case summariesAndStudio
    /// Those three, and a question asked in a notebook's chat.
    case alsoChat

    var title: String {
        switch self {
        case .off: return "Off"
        case .summariesAndStudio: return "Summaries and Studio"
        case .alsoChat: return "Also Chat"
        }
    }

    func asks(_ moment: ThinkFirstMoment) -> Bool {
        switch moment {
        case .sourceSummary, .report, .directions: return self != .off
        case .chat: return self == .alsoChat
        }
    }
}

/// The places Think first asks. The raw values are the device-local tally's
/// keys, so they keep their spelling.
enum ThinkFirstMoment: String, CaseIterable, Codable, Sendable {
    /// A source's gist in the Reader's Levels, the first time it is shown.
    case sourceSummary
    /// A Studio report.
    case report
    /// Find directions on a Goal, a notebook or an Idea.
    case directions
    /// A question asked in a notebook's chat.
    case chat
}

enum ThinkFirst {
    /// The library's level, an account Setting (`set_app_setting think_first.level`).
    static let levelKey = Prefs.Planner.thinkFirstLevel.name
    /// One notebook's own level over the library's, an account Setting written
    /// by the notebook's settings and `update_notebook`'s `think_first`.
    static let notebookKeyPrefix = Prefs.Families.notebookThinkFirst.prefix

    static func notebookKey(_ notebookID: String) -> String {
        Prefs.Families.notebookThinkFirst.name(notebookID)
    }

    /// The library's level. Absent is Off, as the design says; a word this
    /// build does not know (a level a newer build added) is read as Off too,
    /// so an older Mac never asks where it cannot say why.
    static func libraryLevel(defaults: UserDefaults = .standard) -> ThinkFirstLevel {
        defaults.string(forKey: Prefs.Planner.thinkFirstLevel.name).flatMap(ThinkFirstLevel.init(rawValue:)) ?? .off
    }

    static func setLibraryLevel(_ level: ThinkFirstLevel) {
        Preferences.set(level.rawValue, for: Prefs.Planner.thinkFirstLevel)
    }

    /// The notebook's own level, or nil when it follows the library's.
    static func notebookLevel(_ notebookID: String, defaults: UserDefaults = .standard) -> ThinkFirstLevel? {
        defaults.string(forKey: Prefs.Families.notebookThinkFirst.name(notebookID)).flatMap(ThinkFirstLevel.init(rawValue:))
    }

    /// Nil takes the notebook's own level away, so it follows the library's.
    static func setNotebookLevel(_ level: ThinkFirstLevel?, notebookID: String) {
        let key = Prefs.Families.notebookThinkFirst.key(notebookID)
        if let level {
            Preferences.set(level.rawValue, for: key)
        } else {
            Preferences.reset(key)
        }
    }

    /// The level that applies: the notebook's own when it has one, else the
    /// library's. Outside a notebook it is the library's.
    static func level(notebookID: String?, defaults: UserDefaults = .standard) -> ThinkFirstLevel {
        if let notebookID, let own = notebookLevel(notebookID, defaults: defaults) {
            return own
        }
        return libraryLevel(defaults: defaults)
    }

    static func asks(_ moment: ThinkFirstMoment, notebookID: String?, defaults: UserDefaults = .standard) -> Bool {
        level(notebookID: notebookID, defaults: defaults).asks(moment)
    }

    /// The learner's words with the ends trimmed, or nil when they wrote
    /// nothing: an empty take is a skip.
    static func take(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The sources whose gist this Mac has already asked about, answered or
/// skipped, so the ask comes once per source. A take answered on another Mac
/// is found in the source's understanding document instead
/// (`UnderstandingDocument.thinkFirstTakes`); a skip is this Mac's alone,
/// which at worst asks once more on the other one. The oldest fall off past
/// `limit`, which also only asks again.
enum ThinkFirstAskedSources {
    static let preferenceKey = Prefs.Planner.thinkFirstAskedSources.name
    static let limit = 2000

    static func contains(_ sourceID: String, defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: Prefs.Planner.thinkFirstAskedSources.name) ?? []).contains(sourceID)
    }

    static func insert(_ sourceID: String, defaults: UserDefaults = .standard) {
        var asked = defaults.stringArray(forKey: Prefs.Planner.thinkFirstAskedSources.name) ?? []
        guard !asked.contains(sourceID) else { return }
        asked.append(sourceID)
        if asked.count > limit {
            asked.removeFirst(asked.count - limit)
        }
        defaults.set(asked, forKey: Prefs.Planner.thinkFirstAskedSources.name)
    }
}

/// How often each moment was answered and skipped on this Mac: the design's
/// "measure before keeping". A moment the learner skips more than four times
/// in five is the wrong moment, and the record should say so and drop it.
/// Device-local on purpose: a count is enough, and nothing needs it elsewhere.
enum ThinkFirstTally {
    static let countsKey = Prefs.Planner.thinkFirstCounts.name

    struct Count: Equatable, Sendable {
        var answered = 0
        var skipped = 0

        var asked: Int { answered + skipped }

        /// Skipped more than four times in five, once it has been asked often
        /// enough for that to mean something.
        var isMostlySkipped: Bool {
            asked >= Self.minimumAsks && skipped * 5 > asked * 4
        }

        static let minimumAsks = 10
    }

    static func record(_ moment: ThinkFirstMoment, answered: Bool, defaults: UserDefaults = .standard) {
        var stored = defaults.dictionary(forKey: Prefs.Planner.thinkFirstCounts.name) as? [String: [String: Int]] ?? [:]
        var row = stored[moment.rawValue] ?? [:]
        let field = answered ? "answered" : "skipped"
        row[field, default: 0] += 1
        stored[moment.rawValue] = row
        defaults.set(stored, forKey: Prefs.Planner.thinkFirstCounts.name)
    }

    static func counts(defaults: UserDefaults = .standard) -> [ThinkFirstMoment: Count] {
        let stored = defaults.dictionary(forKey: Prefs.Planner.thinkFirstCounts.name) as? [String: [String: Int]] ?? [:]
        var counts: [ThinkFirstMoment: Count] = [:]
        for moment in ThinkFirstMoment.allCases {
            let row = stored[moment.rawValue] ?? [:]
            counts[moment] = Count(answered: row["answered"] ?? 0, skipped: row["skipped"] ?? 0)
        }
        return counts
    }
}
