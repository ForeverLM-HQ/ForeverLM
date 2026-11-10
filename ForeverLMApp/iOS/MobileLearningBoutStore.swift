import Foundation

/// The phone's half of the Planner's timer.
///
/// The phone has no Planner and is not getting one — a plan is made at a desk.
/// What it has is the **clock**, because the break a write-up earns is taken
/// away from the desk, and a ten-minute rest you have to walk back to a Mac to
/// read is not a rest (product owner, 2026-09-18: "ideally I want a timer also on my
/// phone ForeverLM app").
///
/// A bout is the Mac's `Sitting(kind bout)`, read from the replica, and the one
/// field the phone writes is its `breakEndsAt` (§3.5.23): ending the break now
/// moves the break's end to now. When a break was ended stays each device's own
/// (the Mac keeps `break_ended_at` local), so the phone remembers the breaks it
/// ended itself.
actor MobileLearningBoutStore {
    static let shared = MobileLearningBoutStore()

    private let recordWriter: @Sendable () async -> MobileRecordWriter?
    private let defaults: UserDefaults

    init(writer: @escaping @Sendable () async -> MobileRecordWriter? = { await MobileRecordWriter.current() },
         defaults: UserDefaults = .standard) {
        recordWriter = writer
        self.defaults = defaults
    }

    /// The breaks this phone ended, by bout id; kept two days, as long as a bout is read.
    static let endedBreaksKey = "ios.learningBout.endedBreaks.v1"

    private func endedBreaks(now: Date) -> [String: Date] {
        let stored = defaults.dictionary(forKey: Self.endedBreaksKey) as? [String: Double] ?? [:]
        return stored.compactMapValues { seconds in
            let date = Date(timeIntervalSince1970: seconds)
            return now.timeIntervalSince(date) < 2 * MemoryTutorScheduler.secondsPerDay ? date : nil
        }
    }

    private func rememberEndedBreak(_ boutID: String, at date: Date) {
        var kept = endedBreaks(now: date).mapValues(\.timeIntervalSince1970)
        kept[boutID] = date.timeIntervalSince1970
        defaults.set(kept, forKey: Self.endedBreaksKey)
    }

    private func requiredWriter() async throws -> MobileRecordWriter {
        try await MobileRecordWriter.required(from: recordWriter)
    }

    // MARK: - Reads

    /// The bout with a clock on it — learning, owing its write-up, waiting on
    /// its break or resting — or nil when the learner is not in one. Today's
    /// and yesterday's bouts are read, from midnight yesterday on, because a
    /// bout begun before midnight is still the live one at ten past.
    func fetchLive(now: Date = Date()) async throws -> LearningBout? {
        let since = Calendar.current.startOfDay(for: now).addingTimeInterval(-MemoryTutorScheduler.secondsPerDay)
        let ended = endedBreaks(now: now)
        return LearningBout.live(in: try await requiredWriter().read { try $0.bouts(since: since, endedBreaks: ended) }, now: now)
    }

    // MARK: - Writes

    /// Ends the break from the phone — the learner is back, or the ten minutes
    /// are up and they acknowledged it where they were standing.
    @discardableResult
    func endBreak(_ bout: LearningBout, now: Date = Date()) async throws -> LearningBout {
        var updated = bout
        guard updated.breakEndedAt == nil else { return updated }
        updated.breakEndedAt = now
        updated.updatedAt = now
        try await requiredWriter().transaction { try $0.endBreak(boutID: bout.id, at: now) }
        rememberEndedBreak(bout.id, at: now)
        return updated
    }
}
