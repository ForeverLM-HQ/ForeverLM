import AppKit
import Foundation
import Observation
import OSLog
import UserNotifications

/// Checks the journals this Mac follows and offers what is new to Notebooks.
///
/// A check is three bounded steps: fetch each due feed (a 304 when nothing
/// was published), store the articles not seen before, then hand every
/// unjudged article to one matching call per batch alongside the active
/// Notebooks. A verdict becomes a pending suggestion in the Notebook's source
/// pool — "include this in your sources?" — and nothing enters the library
/// until the learner says yes (`StudioViewModel.acceptJournalSuggestion`).
///
/// **Timing is event-driven**, like `ScheduledTaskRunner`: one timer for the
/// next feed that comes due, re-armed on waking, activation and a clock
/// change. A feed is due every `JournalWatch.checkInterval`; a newly followed
/// journal is checked at once so the first suggestions arrive while the
/// learner is still looking at Settings.
///
/// **Nothing is judged twice.** An article is one row keyed by URL, marked
/// judged only after its batch's verdicts are stored, so a failed model call
/// costs a retry on the next check and never a lost article. Articles already
/// in the library are skipped by URL and DOI before the model sees them.
///
/// Everything is device-local (docs/journals-design.md); the runner never
/// touches sync.
@MainActor
@Observable
final class JournalWatchRunner {
    static let shared = JournalWatchRunner()

    private(set) var feeds: [JournalFeed] = []
    /// Every pending suggestion, all Notebooks, newest first.
    private(set) var suggestions: [JournalArticleSuggestion] = []
    private(set) var excludedNotebookIDs: Set<String> = []
    private(set) var isChecking = false
    private(set) var checkingFeedIDs: Set<String> = []
    private(set) var lastCheckAt: Date?
    /// One line for Settings: what the last check did.
    private(set) var lastCheckSummary: String?
    /// Why articles are waiting unjudged, in the provider's words, or nil.
    private(set) var lastMatchingError: String?
    private(set) var nextCheckAt: Date?

    private let storage = StorageService()
    private let logger = Logger(subsystem: "ForeverLM", category: "Journals")
    private var timer: Timer?
    private var hasStarted = false
    private var needsAnotherPass = false
    private var observers: [NSObjectProtocol] = []

    private init() {}

    // MARK: - Reading

    func suggestions(for notebookID: String) -> [JournalArticleSuggestion] {
        suggestions.filter { $0.match.notebookID == notebookID }
    }

    func pendingCount(for notebookID: String) -> Int {
        suggestions.reduce(0) { $0 + ($1.match.notebookID == notebookID ? 1 : 0) }
    }

    // MARK: - Lifecycle

    /// Called once from Studio's launch task.
    func start() {
        guard JournalWatch.isEnabled, !hasStarted else { return }
        hasStarted = true
        installObservers()
        scheduleRefresh()
    }

    private func installObservers() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        for (notificationCenter, name) in [
            (workspace, NSWorkspace.didWakeNotification),
            (center, NSApplication.didBecomeActiveNotification),
            (center, NSNotification.Name.NSSystemClockDidChange),
        ] {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in JournalWatchRunner.shared.scheduleRefresh() }
            })
        }
        // A suggestion accepted or dismissed from a Notebook's pool.
        observers.append(center.addObserver(forName: .journalWatchDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in await JournalWatchRunner.shared.reload() }
        })
    }

    func scheduleRefresh() {
        // A check is maintenance: it must queue behind a chat send or a paper
        // import on the storage lane, never ahead of one.
        Task(priority: .utility) { await refresh() }
    }

    /// Reloads, checks whatever is due, and re-arms.
    func refresh() async {
        await reload()
        await check(force: false)
        armTimer()
    }

    func reload() async {
        do {
            feeds = try await storage.loadJournalFeeds()
            suggestions = try await storage.loadPendingJournalSuggestions()
            excludedNotebookIDs = try await storage.journalWatchExcludedNotebookIDs()
        } catch {
            logger.error("Journals could not load: \(error.localizedDescription, privacy: .public)")
        }
        nextCheckAt = JournalWatch.nextCheckInstant(feeds: feeds, now: Date())
    }

    // MARK: - Editing

    /// Follows every address in a pasted block. Each is resolved to its feed —
    /// a journal's home page advertises one — stored, and checked at once.
    /// Returns one line per address that could not be followed.
    func addJournals(from text: String) async -> [String] {
        let inputs = JournalWatch.candidateURLStrings(in: text)
        guard !inputs.isEmpty else { return [] }
        var failures: [String] = []
        var added: [JournalFeed] = []
        var storedArticles = 0
        for input in inputs {
            do {
                let resolved = try await JournalFeedFetcher.resolve(userInput: input)
                let outcome = try await storage.addJournalFeed(
                    feedURL: resolved.feedURL.absoluteString,
                    title: resolved.feed.title.isEmpty ? (resolved.feedURL.host ?? input) : resolved.feed.title,
                    siteURL: resolved.feed.siteURL
                )
                guard outcome.inserted else { continue }
                // The resolving fetch already has the articles; store them now
                // so the check below only judges.
                let stored = try await storage.recordJournalFeedItems(feedID: outcome.feed.id, items: resolved.feed.items)
                storedArticles += stored.count
                try await storage.recordJournalFeedCheck(
                    feedID: outcome.feed.id,
                    at: Date(),
                    succeeded: true,
                    error: nil,
                    etag: resolved.etag,
                    lastModified: resolved.lastModified,
                    title: nil
                )
                added.append(outcome.feed)
            } catch {
                failures.append("\(input): \(error.localizedDescription)")
            }
        }
        await reload()
        if !added.isEmpty {
            // The new feeds were fetched above, so the check line should say
            // so, not "Nothing new" after a journal with eight articles.
            await check(force: false, alreadyFetched: added.count, alreadyStored: storedArticles)
            armTimer()
        }
        return failures
    }

    func removeFeed(_ feedID: String) async {
        do {
            try await storage.deleteJournalFeed(feedID)
        } catch {
            logger.error("Could not unfollow journal: \(error.localizedDescription, privacy: .public)")
        }
        await reload()
        armTimer()
    }

    /// Settings' "Check now": every feed, due or not.
    func checkNow() async {
        await check(force: true)
        armTimer()
    }

    // MARK: - Timer

    private func armTimer() {
        timer?.invalidate()
        timer = nil
        guard let next = JournalWatch.nextCheckInstant(feeds: feeds, now: Date()) else {
            nextCheckAt = nil
            return
        }
        nextCheckAt = next
        let interval = max(next.timeIntervalSinceNow, 1)
        let scheduled = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            Task { @MainActor in JournalWatchRunner.shared.scheduleRefresh() }
        }
        RunLoop.main.add(scheduled, forMode: .common)
        scheduled.tolerance = 60
        timer = scheduled
    }

    // MARK: - Checking

    /// `alreadyFetched` and `alreadyStored` describe feeds a follow fetched a
    /// moment ago, so the check line counts them with this pass.
    private func check(force: Bool, alreadyFetched: Int = 0, alreadyStored: Int = 0) async {
        if isChecking {
            // An event arriving mid-check records one more pass instead of
            // being dropped (the podcast library sync's shape).
            needsAnotherPass = true
            return
        }
        let now = Date()
        let due = feeds.filter { force || JournalWatch.isDue($0, now: now) }
        let hasUnjudged = ((try? await storage.loadUnjudgedJournalItems(limit: 1)) ?? []).isEmpty == false
        guard !due.isEmpty || hasUnjudged else { return }

        isChecking = true
        defer {
            isChecking = false
            checkingFeedIDs = []
        }

        var fetched = alreadyFetched
        var failed = 0
        var newArticles = alreadyStored
        for feed in due {
            checkingFeedIDs.insert(feed.id)
            do {
                let result = try await JournalFeedFetcher.fetch(
                    feedURL: feed.feedURL,
                    etag: feed.etag,
                    lastModified: feed.lastModified
                )
                switch result {
                case .notModified:
                    try await storage.recordJournalFeedCheck(
                        feedID: feed.id, at: Date(), succeeded: true, error: nil,
                        etag: nil, lastModified: nil, title: nil
                    )
                case .feed(let parsed, let etag, let lastModified):
                    let inserted = try await storage.recordJournalFeedItems(feedID: feed.id, items: parsed.items)
                    newArticles += inserted.count
                    try await storage.recordJournalFeedCheck(
                        feedID: feed.id, at: Date(), succeeded: true, error: nil,
                        etag: etag, lastModified: lastModified, title: parsed.title
                    )
                }
                fetched += 1
            } catch {
                failed += 1
                logger.error("Journal fetch failed for \(feed.feedURL, privacy: .public): \(error.localizedDescription, privacy: .public)")
                try? await storage.recordJournalFeedCheck(
                    feedID: feed.id, at: Date(), succeeded: false, error: error.localizedDescription,
                    etag: nil, lastModified: nil, title: nil
                )
            }
            checkingFeedIDs.remove(feed.id)
        }

        let newMatches = await judgeUnjudgedArticles()
        _ = try? await storage.pruneJournalItems(olderThan: now.addingTimeInterval(-JournalWatch.itemRetention))

        await reload()
        lastCheckAt = now
        lastCheckSummary = Self.summary(
            checked: fetched + failed, failed: failed, newArticles: newArticles,
            newMatches: newMatches.count, matchingError: lastMatchingError
        )
        if !newMatches.isEmpty {
            logger.notice("Journals matched \(newMatches.count) new article(s)")
            announce(newMatches)
        }

        if needsAnotherPass {
            needsAnotherPass = false
            isChecking = false
            await check(force: false)
        }
    }

    static func summary(checked: Int, failed: Int, newArticles: Int, newMatches: Int, matchingError: String?) -> String {
        var parts: [String] = []
        if checked > 0 {
            parts.append("Checked \(checked) feed\(checked == 1 ? "" : "s")" + (failed > 0 ? " (\(failed) failed)" : ""))
        }
        if newArticles > 0 {
            parts.append("\(newArticles) new article\(newArticles == 1 ? "" : "s")")
        }
        if newMatches > 0 {
            parts.append("\(newMatches) suggestion\(newMatches == 1 ? "" : "s")")
        } else if matchingError == nil, newArticles > 0 {
            parts.append("nothing for your notebooks")
        }
        if let matchingError {
            parts.append(matchingError)
        }
        return parts.isEmpty ? "Nothing new." : parts.joined(separator: " · ")
    }

    /// Hands every unjudged article to the matching call and files the verdicts.
    private func judgeUnjudgedArticles() async -> [JournalArticleMatch] {
        let items: [JournalFeedItem]
        do {
            items = try await storage.loadUnjudgedJournalItems()
        } catch {
            lastMatchingError = error.localizedDescription
            return []
        }
        guard !items.isEmpty else {
            // A clean pass with nothing to judge retires an earlier provider error.
            lastMatchingError = nil
            return []
        }

        // Deterministic identity first: an article already in the library is
        // never offered back as new, whatever the model would say.
        var candidates: [JournalFeedItem] = []
        var alreadyInLibrary: [String] = []
        for item in items {
            if (try? await storage.journalItemExistsInLibrary(url: item.itemURL, doi: item.doi)) == true {
                alreadyInLibrary.append(item.itemURL)
            } else {
                candidates.append(item)
            }
        }
        try? await storage.markJournalItemsJudged(alreadyInLibrary)
        guard !candidates.isEmpty else {
            lastMatchingError = nil
            return []
        }

        let goals = (try? await storage.loadLearningGoals()) ?? []
        let excluded = (try? await storage.journalWatchExcludedNotebookIDs()) ?? []
        let notebooks = goals.filter { $0.isNotebook && !$0.isArchived && !excluded.contains($0.id) }
        notebookTitles = Dictionary(uniqueKeysWithValues: notebooks.map { ($0.id, $0.title) })
        guard !notebooks.isEmpty else {
            // Nothing to match against: these articles are seen, not lost. A
            // Notebook created later is offered what is published from then on.
            try? await storage.markJournalItemsJudged(candidates.map(\.itemURL))
            lastMatchingError = nil
            return []
        }

        guard ManagedAI.isSignedIn else {
            lastMatchingError = "Sign in with Apple to let ForeverLM judge new articles."
            return []
        }
        guard let config = KeychainService.resolveConfig(for: .journalArticleMatching) else {
            // Consent is the usual cause and has its own wording; otherwise the
            // Background model itself could not be resolved.
            lastMatchingError = KeychainService.backgroundAIUnavailableMessage(for: .journalArticleMatching)
                ?? "No model is available for judging new articles. Check AI Usage (the sidebar's OpenRouter button)."
            return []
        }

        var matchingNotebooks: [JournalMatchingNotebook] = []
        for goal in notebooks {
            matchingNotebooks.append(JournalMatchingNotebook(
                id: goal.id,
                title: goal.title,
                instructions: goal.description,
                researchQuestions: goal.researchQuestions ?? [],
                topic: goal.topic,
                sampleSourceTitles: await sampleSourceTitles(for: goal)
            ))
        }

        let service = AIService()
        var newMatches: [JournalArticleMatch] = []
        var index = 0
        while index < candidates.count {
            let end = min(index + JournalWatch.matchingBatchSize, candidates.count)
            let batch = Array(candidates[index..<end])
            index = end
            // A journal article names its journal (`prism:publicationName`);
            // a blog post or newsletter issue names nothing, so the feed's own
            // title stands in — the model should know a post is from Astral
            // Codex Ten, not just that it exists.
            let feedTitles = Dictionary(feeds.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
            let batchCandidates = batch.map { item in
                JournalMatchingCandidate(
                    id: item.itemURL,
                    title: item.title,
                    summary: item.summary,
                    source: item.journal ?? feedTitles[item.feedID],
                    authors: item.authors
                )
            }
            do {
                let verdicts = try await service.matchJournalArticles(
                    notebooks: matchingNotebooks,
                    candidates: batchCandidates,
                    config: config
                )
                let recorded = try await storage.recordJournalMatches(verdicts)
                try await storage.markJournalItemsJudged(batch.map(\.itemURL))
                newMatches += recorded
                lastMatchingError = nil
            } catch {
                logger.error("Journal matching failed: \(error.localizedDescription, privacy: .public)")
                lastMatchingError = error.localizedDescription
                break
            }
        }
        return newMatches
    }

    /// A dozen titles from the pool, spread across it, so the model sees the
    /// Notebook's range rather than its most recent corner.
    private func sampleSourceTitles(for goal: LearningGoalRecord) async -> [String] {
        let ids = goal.approvedSourceIDs
        guard !ids.isEmpty else { return [] }
        let limit = 12
        let sampled: [String]
        if ids.count <= limit {
            sampled = ids
        } else {
            let stride = Double(ids.count) / Double(limit)
            sampled = (0..<limit).map { ids[min(ids.count - 1, Int(Double($0) * stride))] }
        }
        let sources = (try? await storage.loadPersistedSources(ids: sampled)) ?? []
        return sources.map(\.title).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // MARK: - Announcing

    private func announce(_ matches: [JournalArticleMatch]) {
        var countsByNotebook: [String: Int] = [:]
        for match in matches { countsByNotebook[match.notebookID, default: 0] += 1 }
        NotificationCenter.default.post(
            name: .journalWatchDidFindMatches,
            object: nil,
            userInfo: [
                JournalWatchNotificationInfo.notebookIDsKey: Array(countsByNotebook.keys),
                JournalWatchNotificationInfo.matchCountKey: matches.count,
            ]
        )
        guard JournalWatch.notifiesOnMatch else { return }
        let titles = notebookTitles
        Task {
            for (notebookID, count) in countsByNotebook {
                await JournalWatchNotifications.deliver(
                    notebookID: notebookID,
                    notebookTitle: titles[notebookID] ?? "a notebook",
                    count: count
                )
            }
        }
    }

    /// Titles of the Notebooks the last matching pass saw, so a banner can
    /// name the Notebook without another read.
    private var notebookTitles: [String: String] = [:]
}

/// The banner a check with new matches raises. Off until the learner turns it
/// on in Settings → Journals; delivered at once rather than scheduled, so the
/// one-time `NotificationRetirement` sweep never finds one pending.
enum JournalWatchNotifications {
    static let identifierPrefix = "com.foreverlm.journals.match."
    static let notebookIDKey = "notebookID"

    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    static func deliver(notebookID: String, notebookTitle: String, count: Int) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = "New from your feeds"
        content.body = count == 1
            ? "An article matches \(notebookTitle). Click to decide whether to add it."
            : "\(count) articles match \(notebookTitle). Click to decide which to add."
        content.sound = .default
        content.userInfo = [notebookIDKey: notebookID]

        // One banner per Notebook; a later check replaces it rather than stacking.
        let request = UNNotificationRequest(
            identifier: identifierPrefix + notebookID,
            content: content,
            trigger: nil
        )
        center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
        try? await center.add(request)
    }

    static func clear(notebookID: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifierPrefix + notebookID])
    }
}
