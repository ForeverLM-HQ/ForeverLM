import Foundation

/// A journal ForeverLM follows: one publisher feed, checked on this Mac.
///
/// Feeds are device-local. The feed list, the cursor a check leaves behind
/// (`etag`, `lastModified`) and the last error are all statements about this
/// machine's polling, and a second Mac following the same journal would create
/// a second Source for the same article the moment both accepted it. The
/// suggestions a check produces are local too; a source the learner accepts is
/// ordinary library data and syncs like any other. See docs/journals-design.md.
struct JournalFeed: Identifiable, Equatable, Sendable {
    let id: String
    var feedURL: String
    var title: String
    var siteURL: String?
    var addedAt: Date
    var lastCheckedAt: Date?
    var lastSucceededAt: Date?
    var lastError: String?
    /// Validators from the last successful fetch, replayed as `If-None-Match`
    /// and `If-Modified-Since` so an unchanged feed costs one 304.
    var etag: String?
    var lastModified: String?
    var itemCount: Int

    init(
        id: String = UUID().uuidString,
        feedURL: String,
        title: String,
        siteURL: String? = nil,
        addedAt: Date = Date(),
        lastCheckedAt: Date? = nil,
        lastSucceededAt: Date? = nil,
        lastError: String? = nil,
        etag: String? = nil,
        lastModified: String? = nil,
        itemCount: Int = 0
    ) {
        self.id = id
        self.feedURL = feedURL
        self.title = title
        self.siteURL = siteURL
        self.addedAt = addedAt
        self.lastCheckedAt = lastCheckedAt
        self.lastSucceededAt = lastSucceededAt
        self.lastError = lastError
        self.etag = etag
        self.lastModified = lastModified
        self.itemCount = itemCount
    }

    /// The host a row shows under the journal's name.
    var host: String {
        URL(string: siteURL ?? feedURL)?.host?.replacingOccurrences(of: "www.", with: "") ?? feedURL
    }
}

/// One article a feed announced. The URL is the identity, so an article that
/// appears in several followed feeds (a journal's own feed and a subject feed)
/// is one row, judged once.
struct JournalFeedItem: Identifiable, Equatable, Sendable {
    var id: String { itemURL }
    let itemURL: String
    var feedID: String
    var title: String
    var summary: String?
    var authors: String?
    var doi: String?
    var journal: String?
    var publishedAt: Date?
    var firstSeenAt: Date
    /// Set once the matching call has seen the item, matched or not. An item
    /// with no verdict yet is judged on the next check, so a failed call costs
    /// a retry and never a lost article.
    var judgedAt: Date?
}

enum JournalArticleMatchState: String, Codable, Sendable {
    /// Waiting for the learner's answer to "include this in your sources?".
    case pending
    /// Imported into the library and added to the Notebook.
    case accepted
    /// Declined. Kept as a tombstone so the same article is never offered to
    /// the same Notebook twice.
    case dismissed
}

/// The matching call's verdict that one article belongs in one Notebook.
struct JournalArticleMatch: Identifiable, Equatable, Sendable {
    var id: String { "\(itemURL)|\(notebookID)" }
    let itemURL: String
    let notebookID: String
    /// The model's one-sentence reason, shown under the title so the learner
    /// can decide without opening the article.
    var reason: String?
    var matchedAt: Date
    var state: JournalArticleMatchState
    var decidedAt: Date?
    /// The library source an accepted match became.
    var sourceID: String?
}

/// A pending match joined with the article and the feed it came from — what
/// a Notebook's source pool shows as "New in journals".
struct JournalArticleSuggestion: Identifiable, Equatable, Sendable {
    var id: String { match.id }
    let match: JournalArticleMatch
    let item: JournalFeedItem
    let feedTitle: String

    var journalName: String {
        let journal = item.journal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return journal.isEmpty ? feedTitle : journal
    }
}

/// When journals are checked.
///
/// Event-driven like every other runner here: one timer for the next due
/// instant, re-armed on waking and activation. A feed is due when it has never
/// been checked or its last check is older than `checkInterval`. New articles
/// are judged as they appear, so checking more often than this only adds
/// requests that come back 304.
enum JournalWatch {
    /// Feeds are switched off for now: no Settings pane, no background check,
    /// no Notebook suggestions and no chat tools. The code and the device-local
    /// tables stay, so turning this back on restores the followed feeds.
    static let isEnabled = false

    static let checkInterval: TimeInterval = 12 * 60 * 60

    /// Articles older than this that matched nothing are pruned so the item
    /// table stays the size of a season, not of the subscription's lifetime.
    static let itemRetention: TimeInterval = 120 * 24 * 60 * 60

    /// How many articles one matching call judges. Enough to amortise the
    /// Notebook descriptions across the batch; small enough that a lost call
    /// re-judges little.
    static let matchingBatchSize = 40

    static func isDue(_ feed: JournalFeed, now: Date) -> Bool {
        guard let last = feed.lastCheckedAt else { return true }
        return now.timeIntervalSince(last) >= checkInterval
    }

    /// The instant the earliest feed comes due, or nil with nothing to check.
    static func nextCheckInstant(feeds: [JournalFeed], now: Date) -> Date? {
        guard !feeds.isEmpty else { return nil }
        let instants = feeds.map { feed -> Date in
            guard let last = feed.lastCheckedAt else { return now }
            return last.addingTimeInterval(checkInterval)
        }
        return instants.min().map { max($0, now) }
    }

    /// Device-local switch for the banner a check with new matches raises.
    /// Off by default: the learner opts in from Settings → Journals, and the
    /// key stays on this Mac because a banner is about the machine that found
    /// the article, not the account (`SyncedPreferenceKeys.excluded`).
    static let notifyOnMatchKey = Prefs.Planner.journalsNotifyOnMatch.name

    static var notifiesOnMatch: Bool {
        Preferences.value(Prefs.Planner.journalsNotifyOnMatch) ?? false
    }

    /// Splits a pasted block into candidate URLs: one per line, or several on
    /// one line separated by spaces or commas.
    static func candidateURLStrings(in text: String) -> [String] {
        var seen = Set<String>()
        return text
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }
}

extension Notification.Name {
    /// Posted on the main thread when a check found new matches. `userInfo`
    /// carries `JournalWatchNotificationInfo.notebookIDsKey` and `matchCountKey`.
    static let journalWatchDidFindMatches = Notification.Name("journalWatchDidFindMatches")
    /// Posted after any local write to feeds or matches so the runner reloads.
    static let journalWatchDidChange = Notification.Name("journalWatchDidChange")
    /// Asks Studio to open a Notebook's source pool, where its journal
    /// suggestions are listed. `object` is the Notebook id.
    static let requestNotebookJournalSuggestions = Notification.Name("requestNotebookJournalSuggestions")
}

enum JournalWatchNotificationInfo {
    static let notebookIDsKey = "notebookIDs"
    static let matchCountKey = "matchCount"
}
