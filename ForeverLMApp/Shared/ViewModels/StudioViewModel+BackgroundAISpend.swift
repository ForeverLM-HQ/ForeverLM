import Foundation

// MARK: - Spend control for background AI
//
// The drains in `runCanonicalContentCleanup` ask two things before they spend:
// whether a bulk re-queue is waiting for the learner (its sources are passed
// over in the candidate queries, and the sidebar asks), and whether today's
// background cap is reached. See `BackgroundAISpend.swift`.

extension StudioViewModel {
    /// Re-reads the bulk re-queues waiting for a decision. Publishes only a
    /// change, so the sidebar row does not redraw on every drain.
    func refreshPendingBackgroundAIBulkJobs() async {
        do {
            let jobs = try await storage.pendingBackgroundAIBulkJobs()
            if jobs != pendingBackgroundAIBulkJobs {
                pendingBackgroundAIBulkJobs = jobs
            }
        } catch {
            logger.error("Could not read held bulk re-queues: \(error.localizedDescription)")
        }
    }

    /// The learner's choice for one held re-queue, from the sidebar row.
    func decideBackgroundAIBulkJob(_ job: BackgroundAIBulkJob, _ decision: BackgroundAIBulkDecision) async {
        do {
            let outcome = try await storage.decideBackgroundAIBulkJob(id: job.id, decision: decision)
            await refreshPendingBackgroundAIBulkJobs()
            switch decision {
            case .runAll, .runAffected:
                let noun = outcome.releasedCount == 1 ? "source" : "sources"
                showToast("\(job.queue.displayName): running \(outcome.releasedCount.formatted()) \(noun)")
            case .skip:
                showToast("\(job.queue.displayName): skipped")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Whether the background drains may spend now. Says once per local day,
    /// on this Mac, when the cap stops them, and wakes the drains at the next
    /// local midnight.
    func backgroundAISpendAllowed() async -> Bool {
        let check = await backgroundAIBudget.check()
        if case .reached(_, let cap) = check.status {
            if check.isFirstNoticeToday {
                let amount = cap.formatted(.currency(code: "USD").precision(.fractionLength(2)))
                showToast("Background AI reached today's \(amount) limit and resumes tomorrow")
            }
            scheduleBackgroundAIDayRollover(at: check.day.end)
        }
        if let message = check.errorMessage {
            logger.error("Background AI paused: the daily cap could not be checked (\(message))")
        }
        return check.allowsBackgroundSpend
    }

    /// One wake-up at the day boundary, not a poll: the next local day is the
    /// event that lets the paused drains continue.
    func scheduleBackgroundAIDayRollover(at dayEnd: Date) {
        guard backgroundAIDayRolloverTask == nil else { return }
        backgroundAIDayRolloverTask = Task(priority: .utility) { [weak self] in
            let delay = max(0, dayEnd.timeIntervalSinceNow) + 1
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.backgroundAIDayRolloverTask = nil
            NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
        }
    }

    /// A decision taken over MCP, or a cap the learner raised or turned off,
    /// is a next-work event for the drains.
    func startObservingBackgroundAISpendControls() {
        backgroundAISpendObserverTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .backgroundAIBulkJobsDidChange) {
                guard let self else { return }
                await self.refreshPendingBackgroundAIBulkJobs()
            }
        }
        backgroundAICapObserverTask = Task {
            for await _ in NotificationCenter.default.notifications(named: BackgroundAIDailyCap.didChange) {
                NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
            }
        }
    }
}
