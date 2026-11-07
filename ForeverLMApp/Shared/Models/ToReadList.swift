import Foundation

/// The To Read list: what the learner saved and has not finished, newest
/// saved first, so a reading list, a share sheet or a bookmark import is not
/// a place things go to be forgotten (product owner, 2026-11-07: "i just save
/// stuff to my reading list, etc., but i kind of want to actually go back to
/// those later … a view where we have the things we last added").
///
/// View-free and Foundation-only: the Mac and the iPhone map their own source
/// models onto `ToReadCandidate` and draw what comes back, so both clients
/// answer "what is waiting?" with the same rule.
struct ToReadCandidate: Equatable, Sendable {
    let id: String
    /// `StudioSourceType.rawValue`.
    let sourceType: String
    let dateAdded: Date
    /// Read or listened to the end: `readAt` is set, or a video was watched.
    /// A source with only a saved reading position is not finished.
    let isFinished: Bool
    /// Hidden or archived: the learner put it away.
    let isPutAway: Bool
    /// Marked paywalled: it holds no text, so there is nothing to go back to.
    let isPaywalled: Bool
    /// A chapter, lecture or meeting artifact of something else
    /// (`parentGroup`): the book or course is what the learner saved.
    let belongsToGroup: Bool
    /// A spoken script ForeverLM wrote (an explainer, an audio overview's
    /// carrier), which sits under its source and never waits of its own.
    let isSpokenScript: Bool
}

enum ToReadList {
    /// The kinds a learner saves one at a time on purpose: a web page, a
    /// paper, an X post. Podcasts, YouTube, books, courses and meetings come
    /// in by feed, by follow or by folder, a hundred at once, and have their
    /// own tabs; counted here they would bury the few things saved by hand.
    static let savedSourceTypes: Set<String> = ["article", "manual", "unclassified", "paper", "xPost"]

    /// The ids still waiting, newest saved first. A tie keeps a fixed order
    /// (the id) so two sources added in one import do not swap between
    /// redraws.
    static func waiting(_ candidates: [ToReadCandidate]) -> [ToReadCandidate] {
        candidates
            .filter(isWaiting)
            .sorted { lhs, rhs in
                if lhs.dateAdded != rhs.dateAdded { return lhs.dateAdded > rhs.dateAdded }
                return lhs.id < rhs.id
            }
    }

    static func isWaiting(_ candidate: ToReadCandidate) -> Bool {
        savedSourceTypes.contains(candidate.sourceType)
            && !candidate.isFinished
            && !candidate.isPutAway
            && !candidate.isPaywalled
            && !candidate.belongsToGroup
            && !candidate.isSpokenScript
    }

    /// How far back a source was saved, as the list's section heads.
    enum Section: Int, CaseIterable, Comparable, Sendable {
        case today
        case yesterday
        case thisWeek
        case earlier

        var title: String {
            switch self {
            case .today: return "Today"
            case .yesterday: return "Yesterday"
            case .thisWeek: return "This Week"
            case .earlier: return "Earlier"
            }
        }

        static func < (lhs: Section, rhs: Section) -> Bool { lhs.rawValue < rhs.rawValue }

        /// The section a source saved at `date` falls in, by calendar day:
        /// the last seven days (the days after yesterday) are This Week.
        static func containing(_ date: Date, now: Date, calendar: Calendar = .current) -> Section {
            let today = calendar.startOfDay(for: now)
            let day = calendar.startOfDay(for: date)
            let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            switch daysAgo {
            case ...0: return .today
            case 1: return .yesterday
            case 2...6: return .thisWeek
            default: return .earlier
            }
        }
    }

    /// The waiting sources split under their section heads, in order, with
    /// no empty section. Reads `waiting`'s order, so it is newest first
    /// inside each.
    static func sections<Item>(
        _ items: [Item],
        dateAdded: (Item) -> Date,
        now: Date,
        calendar: Calendar = .current
    ) -> [(section: Section, items: [Item])] {
        var buckets: [Section: [Item]] = [:]
        for item in items {
            buckets[Section.containing(dateAdded(item), now: now, calendar: calendar), default: []].append(item)
        }
        return Section.allCases.compactMap { section in
            buckets[section].map { (section, $0) }
        }
    }
}
