import Combine
import Foundation
import OSLog
import WatchConnectivity

// The phone's half of the Apple Watch app (Watch/). The watch holds no library:
// this deals it today's cards as the phone's card review deals them, the
// narrated sources it can start, what is playing, and the bout's clock, and
// writes back what the watch answers.
//
// - Today's cards: `MobileCardReviewSession.Backend.live()`, over every
//   notebook, as the phone's own review opens. Each grade is decided and
//   written exactly as the phone's sitting writes a self-graded answer
//   (`MobileSelfGradedAnswer`, `MobileMemoryAttemptRecorder.recordSelfGraded`),
//   under one sitting key per day, so a grade delivered twice is written once.
// - Listen: a play, pause, resume or stop from the watch is the same command
//   Siri queues (`MobileSiriCommand`), handled by the same code.
// - The bout: the widget's snapshot (`MobileTodayWidgetSnapshotStore`), which
//   `MobileLearningBoutTimer` writes; End Break is the timer's own.

@MainActor
final class MobileWatchBridge: NSObject {
    static let shared = MobileWatchBridge()

    nonisolated private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "WatchBridge")
    /// More than a day's deal ever holds; the application context has a size
    /// limit, and a wrist does not get through more in one go.
    private static let cardLimit = 60
    private static let listenLimit = 25

    private var started = false
    private var cancellables = Set<AnyCancellable>()
    private var pushWork: Task<Void, Never>?
    /// Grades are written one after another, in the order they arrived.
    private var gradeWrites: Task<Void, Never>?
    private var sittingDay = ""
    private var sittingKey = ""

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    /// At launch, also a launch in the background that the watch woke.
    func start() {
        guard !started, let session else { return }
        started = true
        session.delegate = self
        session.activate()

        let vm = MobileAudioReviewViewModel.shared
        // What the watch draws changes when today's cards are dealt again, a
        // source starts or stops, or narration or the Schedule changes. The
        // elapsed time is not watched: the watch runs that clock by itself.
        Publishers.MergeMany(
            vm.$todayMemoryCards.map { _ in () }.eraseToAnyPublisher(),
            vm.$isPlaying.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            vm.$currentItem.map { $0?.id }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            vm.$items.map(\.count).removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            vm.$scheduleItems.map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in self?.scheduleRefresh() }
        .store(in: &cancellables)
    }

    /// A fresh day for the watch, soon: several changes in a row send one.
    func scheduleRefresh() {
        guard started else { return }
        pushWork?.cancel()
        pushWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            await self?.push()
        }
    }

    private func push() async {
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        let day = await makeDay()
        guard let data = WatchBridge.encode(day) else { return }
        do {
            try session.updateApplicationContext([WatchBridge.dayKey: data])
        } catch {
            Self.logger.error("The watch's day was not sent: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: The day

    private func makeDay() async -> WatchDay {
        let vm = MobileAudioReviewViewModel.shared
        // Woken by the watch with nothing read yet: read the library first, as
        // a Siri command does.
        if vm.allSources.isEmpty && vm.items.isEmpty {
            await vm.load()
        }
        let now = Date()
        let dayKey = MemoryReviewGoal.dayKey(for: now)
        if dayKey != sittingDay {
            sittingDay = dayKey
            sittingKey = MemoryCardSitting.newKey(day: dayKey)
        }

        let deal = await MobileCardReviewSession.Backend.live().deal(.today(.allNotebooks), .today, now)
        let cards = deal.cards.prefix(Self.cardLimit).map { card in
            WatchCard(
                itemID: card.itemID,
                prompt: CardVisualization.words(card.prompt),
                back: CardVisualization.words(card.back),
                why: card.why,
                sourceTitle: card.sourceID.flatMap { deal.sourceTitles[$0] },
                isNew: card.isNew
            )
        }

        let widget = MobileTodayWidgetSnapshotStore.load()
        let bout = widget.boutTitle.map {
            WatchBout(title: $0, endsAt: widget.boutEndsAt, isOnBreak: widget.isOnBreak, needsAttention: widget.boutNeedsAttention)
        }

        let calendar = Calendar.autoupdatingCurrent
        let todayIDs = Set(vm.scheduleItems
            .filter { !$0.isAutomatic && !$0.isCompleted && calendar.isDateInToday($0.plannedAt) }
            .map(\.source.id))
        let narrated = vm.items.sorted { lhs, rhs in
            let lhsToday = todayIDs.contains(lhs.id), rhsToday = todayIDs.contains(rhs.id)
            if lhsToday != rhsToday { return lhsToday }
            return lhs.createdAt > rhs.createdAt
        }
        let listen = narrated.prefix(Self.listenLimit).map {
            WatchListenItem(sourceID: $0.id, title: $0.title, subtitle: $0.subtitle, isToday: todayIDs.contains($0.id))
        }

        let nowPlaying = vm.currentItem.map {
            WatchNowPlaying(
                sourceID: $0.id,
                title: $0.title,
                isPlaying: vm.isPlaying,
                elapsed: vm.currentTime,
                duration: vm.duration,
                readAt: now
            )
        }

        return WatchDay(
            dayKey: dayKey,
            sittingKey: sittingKey,
            cards: Array(cards),
            bout: bout,
            listen: Array(listen),
            nowPlaying: nowPlaying,
            updatedAt: now
        )
    }

    // MARK: Grades

    /// One grade from the watch, after those before it, decided from the
    /// card's history as this phone holds it and written only when it counts.
    private func record(_ grade: WatchGrade) {
        let previous = gradeWrites
        let backend = MobileCardReviewSession.Backend.live()
        let letGo = backend.keepAwake()
        gradeWrites = Task { [weak self] in
            await previous?.value
            defer { letGo() }
            do {
                guard let context = await backend.answerContext(grade.itemID) else {
                    throw MobileCardReviewError.cardGone
                }
                let decision = try MobileSelfGradedAnswer.decide(
                    item: context.item,
                    history: context.history,
                    prompt: grade.prompt,
                    remembered: grade.remembered,
                    sessionKey: grade.sittingKey,
                    practice: false,
                    at: grade.answeredAt
                )
                switch decision {
                case .write(let attempt):
                    _ = try await backend.write(attempt, MemoryTutorIdentity.immutableCurriculumFingerprint(context.item))
                    await backend.noteRecorded(attempt)
                case .skip(let outcome):
                    Self.logger.info("A watch card answer was not written: \(outcome.rawValue, privacy: .public)")
                }
            } catch {
                Self.logger.error("A watch card answer was not saved: \(error.localizedDescription, privacy: .public)")
            }
            self?.scheduleRefresh()
        }
    }

    // MARK: Commands

    private func perform(_ command: WatchCommand) async {
        let vm = MobileAudioReviewViewModel.shared
        switch command {
        case .refresh:
            return
        case .play(let sourceID, let title):
            MobileSiriCommandCenter.shared.enqueue(.playSource(title, sourceID: sourceID))
        case .pause:
            MobileSiriCommandCenter.shared.enqueue(MobileSiriCommand(action: .pausePlayback))
        case .resume:
            MobileSiriCommandCenter.shared.enqueue(MobileSiriCommand(action: .resumePlayback))
        case .stop:
            MobileSiriCommandCenter.shared.enqueue(MobileSiriCommand(action: .stopPlayback))
        case .endBreak:
            await MobileLearningBoutTimer.shared.endBreak()
            return
        }
        // The app's window takes a queued command too; whichever comes first
        // takes it, and the other finds nothing waiting. Woken in the
        // background there may be no window, so the bridge does not wait.
        await vm.handlePendingSiriCommandIfNeeded()
    }
}

extension MobileWatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            Self.logger.error("The watch session did not activate: \(error.localizedDescription, privacy: .public)")
        }
        Task { @MainActor in self.scheduleRefresh() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// A switch to another watch: activate again for the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.scheduleRefresh() }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let grade = WatchBridge.decode(WatchGrade.self, from: userInfo[WatchBridge.gradeKey]) else { return }
        Task { @MainActor in self.record(grade) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let command = WatchBridge.decode(WatchCommand.self, from: message[WatchBridge.commandKey]) else {
            replyHandler([:])
            return
        }
        Task { @MainActor in
            await self.perform(command)
            // Let a play or pause land before the day is read back.
            if command != .refresh {
                try? await Task.sleep(for: .milliseconds(400))
            }
            let day = await self.makeDay()
            replyHandler(WatchBridge.encode(day).map { [WatchBridge.dayKey: $0] } ?? [:])
        }
    }
}
