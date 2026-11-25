import AppKit
import Foundation
import Observation
import OSLog

extension Notification.Name {
    /// Posted on the main thread once this Mac has selected a day's cards
    /// ahead of the click (the morning, Prepare now). Studio reads today's counts again off it.
    static let memoryReviewDidPrepare = Notification.Name("memoryReviewDidPrepare")
    /// Asks Studio to open the Memory pane in its active window, where Start
    /// Review is. Posted when the daily reminder is clicked, and by the Today
    /// menu's Today's Review….
    static let requestMemoryReview = Notification.Name("requestMemoryReview")
}

/// What shape a day's review was prepared in.
enum MemoryReviewDayKind: String, Codable, Sendable {
    /// Today's cards, selected without a model: the card review.
    case cards
    /// A review chat planned by topic and opened with its first question.
    case topics

    /// Whether a day prepared in this shape is today's review. Only cards
    /// are: a topic-shaped day — a recorded attempt, or the review chat it
    /// made — is never resumed, and the morning selects the
    /// day's cards anyway.
    var isResumable: Bool { self == .cards }
}

/// Selects today's cards before anyone clicks Memory.
///
/// Opt-in through `DailyReviewPreparation`. At the chosen hour, on a Mac that
/// is open, this reads today's cards across every notebook
/// (`MemoryCardQueue.today`), records the day as prepared in the card
/// review's shape (`Attempt.kind`), and re-asserts the daily reminder, which
/// says a review is ready only when a card is waiting. No model is called.
///
/// It does not prepare a topic review: no day close, no cohort, no planner
/// call and no review chat with an opening question (docs/memory-design.md,
/// "The card review").
///
/// **Timing is event-driven**, the way `ScheduledTaskRunner` is: one timer for
/// the next instant, re-armed on waking, activation, a clock change and a
/// settings change. A Mac that was closed at the hour selects on its first
/// activation after it. **One selection a day per device**, recorded; "Prepare
/// now" in MCP's `run_settings_action` selects again whatever the hour.
@MainActor
@Observable
final class MemoryReviewPreparationRunner {
    static let shared = MemoryReviewPreparationRunner()

    /// What this device did about a day's review, kept across launches.
    struct Attempt: Codable, Equatable, Sendable {
        /// `DailyReviewPreparation.dayKey(for:)` of the day attempted.
        var day: String
        var at: Date
        var succeeded: Bool
        /// The failure, in words.
        var message: String?
        /// The review chat prepared for the day, when it was a topic review;
        /// nil for a day prepared as cards.
        var sessionID: String?
        /// What shape the day was prepared in. A recorded attempt with no
        /// kind was the topic review's.
        var kind: MemoryReviewDayKind
        /// The day's cards when they were selected: due, and new.
        var dueCards: Int?
        var newCards: Int?

        init(
            day: String,
            at: Date,
            succeeded: Bool,
            message: String? = nil,
            sessionID: String? = nil,
            kind: MemoryReviewDayKind = .cards,
            dueCards: Int? = nil,
            newCards: Int? = nil
        ) {
            self.day = day
            self.at = at
            self.succeeded = succeeded
            self.message = message
            self.sessionID = sessionID
            self.kind = kind
            self.dueCards = dueCards
            self.newCards = newCards
        }

        private enum CodingKeys: String, CodingKey {
            case day, at, succeeded, message, sessionID, kind, dueCards, newCards
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            day = try container.decode(String.self, forKey: .day)
            at = try container.decode(Date.self, forKey: .at)
            succeeded = try container.decode(Bool.self, forKey: .succeeded)
            message = try container.decodeIfPresent(String.self, forKey: .message)
            sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            kind = (try? container.decodeIfPresent(MemoryReviewDayKind.self, forKey: .kind)) ?? .topics
            dueCards = try container.decodeIfPresent(Int.self, forKey: .dueCards)
            newCards = try container.decodeIfPresent(Int.self, forKey: .newCards)
        }

        /// "6 due · 4 new", for Settings and MCP; nil before cards.
        var cardsLine: String? {
            guard kind == .cards, let dueCards, let newCards else { return nil }
            return MemoryCardDayCounts(due: dueCards, new: newCards, practice: 0).line ?? "No cards due"
        }
    }

    /// The day this Mac last prepared in the card review's shape, for the
    /// one-selection-a-day rule. A topic-shaped attempt prepared a
    /// review chat, which is not today's review, so it does not count.
    static func preparedDay(of attempt: Attempt?) -> String? {
        guard let attempt, attempt.kind.isResumable else { return nil }
        return attempt.day
    }

    private(set) var lastAttempt: Attempt?
    private(set) var isPreparing = false
    /// When the armed timer fires next, for Settings to show.
    private(set) var nextInstant: Date?

    private let storage = StorageService()
    private let logger = Logger(subsystem: "ForeverLM", category: "MemoryReviewPreparation")
    private var timer: Timer?
    private var hasStarted = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        lastAttempt = Self.loadLastAttempt()
    }

    // MARK: - Lifecycle

    /// Called once from Studio's launch task.
    func start() {
        guard !hasStarted else { return }
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
            (center, NSNotification.Name.NSSystemTimeZoneDidChange),
            // The switch flipped on the other Mac.
            (center, PreferenceStore.didChangeRemotely),
        ] {
            observers.append(notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in MemoryReviewPreparationRunner.shared.scheduleRefresh() }
            })
        }
    }

    /// Re-evaluates now and re-arms. Settings calls this after any change.
    func scheduleRefresh() {
        Task { await refresh() }
    }

    func refresh() async {
        await prepareIfDue()
        armTimer()
    }

    // MARK: - Timer

    private func armTimer() {
        timer?.invalidate()
        timer = nil
        guard DailyReviewPreparation.isEnabled else {
            nextInstant = nil
            return
        }
        let next = DailyReviewPreparation.nextPreparationInstant(
            after: Date(),
            hour: DailyReviewPreparation.hour
        )
        nextInstant = next
        let interval = max(next.timeIntervalSinceNow, 1)
        let scheduled = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            Task { @MainActor in MemoryReviewPreparationRunner.shared.scheduleRefresh() }
        }
        RunLoop.main.add(scheduled, forMode: .common)
        scheduled.tolerance = 30
        timer = scheduled
    }

    // MARK: - Preparing

    private func prepareIfDue(now: Date = Date()) async {
        guard !isPreparing else { return }
        // A review chat for today — a topic review or the phone's — is not
        // today's review, so it does not stand in for a selection.
        let decision = DailyReviewPreparation.decide(
            now: now,
            isEnabled: DailyReviewPreparation.isEnabled,
            hour: DailyReviewPreparation.hour,
            todaysSessionExists: false,
            lastAttemptDay: Self.preparedDay(of: lastAttempt)
        )
        guard decision == .prepare else { return }
        await prepare(day: now, now: now)
    }

    /// "Prepare now" (`run_settings_action prepare_memory_review_now`):
    /// today's cards selected again, whatever the hour and the day's earlier
    /// selection.
    func prepareNow(now: Date = Date()) async {
        guard !isPreparing else { return }
        await prepare(day: now, now: now)
        armTimer()
    }

    /// Selects the cards of the day `day` falls in, as of that moment.
    private func prepare(day: Date, now: Date) async {
        // Signed out, the library is behind the Apple sign-in wall: there is
        // no review to select for, and the day is left unattempted so the
        // first activation after signing in selects it.
        guard ManagedAI.isSignedIn else { return }
        isPreparing = true
        defer { isPreparing = false }
        let dayKey = DailyReviewPreparation.dayKey(for: day)
        do {
            let snapshot = try await storage.memoryCardReviewSnapshot(
                now: day,
                budgetMinutes: MemoryReviewBudget.minutes,
                newPerDay: MemoryCardSettings.newCardsPerDay(),
                deadlines: [],
                scope: nil,
                includesListings: false,
                includesToCheck: false
            )
            let counts = snapshot.counts
            logger.notice("Selected \(counts.due) due and \(counts.new) new card(s) for \(dayKey, privacy: .public)")
            record(Attempt(day: dayKey, at: now, succeeded: true, kind: .cards, dueCards: counts.due, newCards: counts.new))
            await refreshReminder(now: now)
            NotificationCenter.default.post(name: .memoryReviewDidPrepare, object: nil)
        } catch {
            logger.error("Memory review preparation could not read the cards: \(error.localizedDescription)")
            record(Attempt(day: dayKey, at: now, succeeded: false, message: "The day's cards could not be read. \(error.localizedDescription)", kind: .cards))
        }
    }

    /// The daily reminder follows the cards: scheduled while the morning it
    /// next fires on holds a card, taken down otherwise. Read as of that
    /// morning, so a day finished tonight keeps tomorrow's reminder, and a
    /// card kept today counts as tomorrow's new card. A failed read leaves
    /// the schedule as it stands.
    func refreshReminder(now: Date = Date()) async {
        // The morning-after cards banner rides the same hour and the same
        // events, so it is re-asserted wherever the reminder is.
        defer { Task(priority: .utility) { await AppModelBridge.studio?.refreshCardsToCheckBanner() } }
        guard DailyReviewPreparation.isEnabled else {
            await CohortReviewNotifications.refresh(hasReviewReady: false)
            return
        }
        // Signed out, the library is behind the sign-in wall; the reminder
        // keeps whatever schedule it has until there is a library to read.
        guard ManagedAI.isSignedIn else { return }
        let next = DailyReviewPreparation.nextPreparationInstant(after: now, hour: DailyReviewPreparation.hour)
        do {
            let snapshot = try await storage.memoryCardReviewSnapshot(
                now: next,
                budgetMinutes: MemoryReviewBudget.minutes,
                newPerDay: MemoryCardSettings.newCardsPerDay(),
                deadlines: [],
                scope: nil,
                includesListings: false,
                includesToCheck: false
            )
            // The morning's pick, as things stand now, when the morning starts
            // with an explanation (docs/morning-routine-design.md).
            var explain: String?
            if MemoryCardSettings.startsMorningWithExplanation(), let studio = AppModelBridge.studio,
               let pick = await studio.morningPickQueue(now: next).first {
                explain = pick.sourceIDs
                    .compactMap { studio.articlesById[$0].map(studio.displayTitle(for:)) }
                    .joined(separator: " and ")
                if explain?.isEmpty == true { explain = nil }
            }
            await CohortReviewNotifications.refresh(
                hasReviewReady: snapshot.counts.today > 0 || explain != nil,
                explain: explain,
                cardCount: snapshot.counts.today
            )
        } catch {
            logger.error("The reminder could not read the next day's cards: \(error.localizedDescription)")
        }
    }

    // MARK: - Receipt

    private func record(_ attempt: Attempt) {
        lastAttempt = attempt
        if let data = try? JSONEncoder().encode(attempt) {
            Preferences.set(data, for: Prefs.Memory.dailyPreparationLastAttempt)
        }
    }

    private static func loadLastAttempt() -> Attempt? {
        guard let data = Preferences.value(Prefs.Memory.dailyPreparationLastAttempt) else { return nil }
        return try? JSONDecoder().decode(Attempt.self, from: data)
    }
}
