import AppKit
import Foundation
import Observation
import OSLog

extension Notification.Name {
    /// Posted on the main thread when a day close finishes, with the receipt
    /// as `object`. Settings re-reads its status line off it.
    static let dayCloseDidRun = Notification.Name("dayCloseDidRun")
}

/// Closes the day: folds what was read and discussed into what the tutor
/// knows, extracts the ideas of what was read, drafts cards from what was
/// finished, rewords the cards that earned it, then counts the next
/// morning's cards.
///
/// The evening half of `MemoryReviewPreparationRunner`, and the answer to
/// "when I do shutdown complete, it should start thinking" (product owner,
/// 2026-09-20). The Planner's shutdown ritual was its first trigger until the
/// Planner went on 2026-09-30; the evening hour (Settings → General, "Close
/// the day each evening at") remains, beside `close_day`. Since 2026-10-01 it
/// has its own synced switch (`DayClosePreferences.isEnabled`), no longer the
/// morning's: the morning calls no model, and turning it off must not stop
/// the evening's drafting. A one-run-a-day lock like the morning's.
///
/// Every run is the same watermark-driven `DayClosePass`, so a run at six
/// followed by the hour at ten folds in the two hours between and nothing
/// twice. Until the card review (2026-10-01) the run then prepared
/// tomorrow's topic review — a planner call and the chat's opening question
/// — and the morning ran the pass first on a night the Mac was closed; the
/// card review retired that chat, and the morning calls no model, so a night
/// the Mac was closed is folded in by the next evening's run.
@MainActor
@Observable
final class DayCloseRunner {
    static let shared = DayCloseRunner()

    enum Reason: String, Codable, Sendable {
        case shutdown
        case evening
        case manual
    }

    /// What this device last did about closing the day, kept across launches.
    struct Receipt: Codable, Equatable, Sendable {
        var day: String
        var at: Date
        var reason: Reason
        var consolidatedChats: Int
        var updatedUnderstandingDocuments: Int
        var warmedSources: Int
        /// The next morning's cards, counted when the day closed: "6 due ·
        /// 4 new". Nil when they were not counted.
        var nextDayCards: String?
        /// Why the next morning's cards could not be counted, when they
        /// could not.
        var preparationMessage: String?
        var failures: [String]
        /// Cards reworded at this close with a rewording kept
        /// (`CardVariationPass`). Nil in a receipt an older build wrote.
        var variedCards: Int? = nil
        /// What waits for the next close, not failed: work the daily
        /// background AI limit stopped. Nil in an older receipt.
        var notes: [String]? = nil
        /// Cards drafted in the background at this close, the sources they
        /// came from, and the candidates the day's limit left for another
        /// day. Nil in an older receipt.
        var draftedCards: Int? = nil
        var draftedSources: Int? = nil
        var draftsWaiting: Int? = nil
        /// Kept cards whose question the wording repair reworded at this
        /// close (`CardWordingRepairPass`). Nil in an older receipt.
        var standaloneRewordedCards: Int? = nil

        var succeeded: Bool { failures.isEmpty && preparationMessage == nil }

        /// The day close's status line, under its switch in Settings:
        /// "Closed today at 22:03 · 12 cards drafted from 3 sources", then
        /// what failed, by source, and what waits.
        func statusLine(now: Date = Date(), calendar: Calendar = .current) -> String {
            let time = at.formatted(date: .omitted, time: .shortened)
            var parts = [calendar.isDate(at, inSameDayAs: now) ? "Closed today at \(time)" : "Closed \(at.formatted(date: .abbreviated, time: .omitted)) at \(time)"]
            if let drafted = draftedCards, drafted > 0 {
                let cards = drafted == 1 ? "1 card" : "\(drafted) cards"
                let sources = (draftedSources ?? 0) == 1 ? "1 source" : "\(draftedSources ?? 0) sources"
                parts.append("\(cards) drafted from \(sources)")
            }
            var line = parts.joined(separator: " · ")
            let more = failures + (notes ?? [])
            if !more.isEmpty { line += ". " + more.joined(separator: " ") }
            return line
        }
    }

    private(set) var lastRun: Receipt?
    private(set) var isRunning = false
    /// When the armed timer fires next, for Settings to show.
    private(set) var nextInstant: Date?

    private let logger = Logger(subsystem: "ForeverLM", category: "DayClose")
    private var timer: Timer?
    private var hasStarted = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        lastRun = Self.loadLastRun()
    }

    // MARK: - Lifecycle

    /// Called once from Studio's launch task, after the morning runner.
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
            (center, PreferenceStore.didChangeRemotely),
        ] {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in DayCloseRunner.shared.scheduleRefresh() }
            })
        }
    }

    /// Re-evaluates now and re-arms. Settings calls this after any change.
    func scheduleRefresh() {
        Task { await refresh() }
    }

    func refresh() async {
        await runIfDue()
        armTimer()
    }

    // MARK: - Timer

    private func armTimer() {
        timer?.invalidate()
        timer = nil
        guard DayClosePreferences.isEnabled else {
            nextInstant = nil
            return
        }
        let next = DayCloseTiming.nextCloseInstant(after: Date(), hour: DayClosePreferences.hour)
        nextInstant = next
        let scheduled = Timer.scheduledTimer(withTimeInterval: max(next.timeIntervalSinceNow, 1), repeats: false) { _ in
            Task { @MainActor in DayCloseRunner.shared.scheduleRefresh() }
        }
        RunLoop.main.add(scheduled, forMode: .common)
        scheduled.tolerance = 30
        timer = scheduled
    }

    // MARK: - Running

    private func runIfDue(now: Date = Date()) async {
        guard !isRunning else { return }
        let decision = DayCloseTiming.decide(
            now: now,
            isEnabled: DayClosePreferences.isEnabled,
            hour: DayClosePreferences.hour,
            lastRunDay: lastRun?.day
        )
        guard decision == .run else { return }
        await closeDay(reason: .evening, now: now)
    }

    /// The whole ritual: the pass, then the next morning's cards counted
    /// (`prepareTomorrow`; no model, nothing made). Returns the receipt it
    /// recorded, or nil when a run was already under way or nobody is signed
    /// in (Managed AI needs the Apple identity; without it every step would
    /// fail the same way, so the day is left for the next trigger).
    @discardableResult
    func closeDay(reason: Reason, prepareTomorrow: Bool = true, now: Date = Date()) async -> Receipt? {
        guard !isRunning else { return nil }
        guard ManagedAI.isSignedIn else { return nil }
        isRunning = true
        defer { isRunning = false }

        let storage = StorageService()
        // Idea extraction, drafting and rewording are background spend: they
        // stop at the learner's daily cap, which the open window says once a
        // day.
        let spendAllowed: @Sendable () async -> Bool = {
            if let studio = await MainActor.run(body: { AppModelBridge.studio }) {
                return await studio.backgroundAISpendAllowed()
            }
            return await BackgroundAIBudget(storage: storage).check().allowsBackgroundSpend
        }
        let pass = DayClosePass(
            storage: storage,
            aiService: AIService(),
            // The window's own extraction service: a source it is extracting
            // for a finish is not extracted twice.
            ideaExtraction: AppModelBridge.studio?.sourceIdeaExtractionService,
            spendAllowed: spendAllowed,
            drafting: .live(
                storage: storage,
                spendAllowed: spendAllowed,
                neededSoonSourceIDs: {
                    await MainActor.run { AppModelBridge.studio?.automaticCardDraftingNeededSoonSourceIDs() ?? [] }
                },
                // A source a Make Cards run holds is left to that run.
                isBeingMade: { sourceID in
                    await MainActor.run { CardDraftingCoordinator.shared.isDrafting(sourceID) }
                }
            ),
            wordingRepair: .live(storage: storage, spendAllowed: spendAllowed),
            variations: .live(storage: storage, spendAllowed: spendAllowed)
        )
        let report = await pass.consolidate(
            now: now,
            closeConfig: KeychainService.resolveConfig(for: .cohortSessionClose)
        )

        var receipt = Receipt(
            day: DailyReviewPreparation.dayKey(for: now),
            at: now,
            reason: reason,
            consolidatedChats: report.consolidatedChats,
            updatedUnderstandingDocuments: report.updatedUnderstandingDocuments,
            warmedSources: report.warmedSources,
            nextDayCards: nil,
            preparationMessage: nil,
            failures: report.failures,
            variedCards: report.variedCards,
            notes: report.notes,
            draftedCards: report.draftedCards,
            draftedSources: report.draftedSources,
            draftsWaiting: report.draftsWaiting,
            standaloneRewordedCards: report.standaloneRewordedCards
        )
        if prepareTomorrow {
            let attempt = await MemoryReviewPreparationRunner.shared.prepareNextReview(now: now)
            receipt.nextDayCards = attempt?.cardsLine
            if let attempt, !attempt.succeeded { receipt.preparationMessage = attempt.message }
        }
        record(receipt)
        if report.draftedCards > 0 {
            // The drafts wait in To Check: the counts, the Reader's toolbar
            // and the corner card read them again.
            await AppModelBridge.studio?.automaticDraftsDidChange()
        }
        logger.notice("Closed the day (\(reason.rawValue, privacy: .public)): \(report.consolidatedChats) chat(s), \(report.updatedUnderstandingDocuments) document(s), \(report.warmedSources) source(s) warmed, next day \(receipt.nextDayCards ?? "not counted", privacy: .public)")
        NotificationCenter.default.post(name: .dayCloseDidRun, object: receipt)
        return receipt
    }

    // MARK: - Receipt

    private func record(_ receipt: Receipt) {
        lastRun = receipt
        if let data = try? JSONEncoder().encode(receipt) {
            UserDefaults.standard.set(data, forKey: DayClosePreferences.lastRunKey)
        }
    }

    private static func loadLastRun() -> Receipt? {
        guard let data = UserDefaults.standard.data(forKey: DayClosePreferences.lastRunKey) else { return nil }
        return try? JSONDecoder().decode(Receipt.self, from: data)
    }
}
