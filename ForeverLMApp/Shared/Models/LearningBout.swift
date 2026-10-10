import Foundation

/// The one rule for a list of source ids stored as JSON: trimmed, blanks
/// dropped, duplicates folded to their first place. It lives here rather than
/// on `TimeBlock` because the phone compiles this file and not the planner's
/// models, and a bout's sources have to read back identically on both.
enum SourceIDList {
    static func normalized(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Where a bout has got to. Derived from the stamps rather than stored, so two
/// devices can never disagree about a state while agreeing about the facts
/// underneath it: every stamp is written once and only ever kept, and the phase
/// is read back from them.
enum LearningBoutPhase: String, Codable, CaseIterable, Sendable {
    /// The timer is running. It keeps running past its end — the clock never
    /// stops a bout, any more than it marks a block done.
    case learning
    /// The learner stopped learning and owes the write-up. The break is not
    /// earned yet.
    case writing
    /// The write-up is saved and the break is earned, waiting to be taken.
    case earned
    /// The break is being taken.
    case resting
    /// The break was taken, or earned and declined. The bout is finished.
    case complete
    /// Given up on without a write-up.
    case abandoned

    var displayName: String {
        switch self {
        case .learning: return "Learning"
        case .writing: return "Write-up"
        case .earned: return "Break earned"
        case .resting: return "Break"
        case .complete: return "Done"
        case .abandoned: return "Abandoned"
        }
    }

    /// Whether the bout still wants the learner's attention: the Planner shows
    /// exactly one of these at a time and the phone's widget draws its clock.
    var isLive: Bool {
        switch self {
        case .learning, .writing, .earned, .resting: return true
        case .complete, .abandoned: return false
        }
    }
}

/// One timed stretch of learning and what came out of it.
///
/// The shape is the learner's, from *Protocols* (product owner, 2026-09-18): learning
/// happens in a bout with a clock on it; the bout ends in a write-up of what was
/// learned and what is still not understood; and the write-up — never the clock —
/// earns the break that follows. So the three facts this row exists to carry are
/// `endedAt` (the learning stopped), `writtenAt` (the write-up was saved, which
/// is when the break becomes available) and `breakStartedAt`.
///
/// A bout usually runs a block of the Planner's clock and takes its title,
/// Notebook and sources from it, but it does not need one: the timer is startable
/// on its own and draws its own block when it finishes, so a stretch of learning
/// is never lost because nobody planned it. Nothing here ever marks a block done
/// by itself — saving the write-up does, because that is the learner saying so,
/// and `blockID` carries no foreign key so the bout survives the block being
/// redrawn or deleted.
struct LearningBout: Identifiable, Codable, Equatable, Sendable {
    let id: String
    /// The `DayPlan.id` this bout belongs to, which is the plan's date. A bout
    /// that runs over midnight stays on the day it started.
    var dayPlanID: String
    /// The block this bout runs, when it was started from one. No foreign key:
    /// a redraw supersedes the block's row and the bout still reads.
    var blockID: String?
    var title: String
    var notebookID: String?
    /// The sources the bout is for, copied from the block at the start so the
    /// write-up still names them after the block is redrawn.
    var sourceIDs: [String]
    /// The clock the learner set: how long this bout was meant to run.
    var plannedMinutes: Int
    var startedAt: Date
    /// When the learner stopped learning. Nil while the bout is running — and
    /// the timer reaching zero does not set it.
    var endedAt: Date?
    /// The write-up. `learned` is what the bout produced; `unclear` is what it
    /// left open, which is the more valuable half and the reason the field
    /// exists separately.
    var learned: String?
    var unclear: String?
    /// When the write-up was saved. This is the moment the break is earned.
    var writtenAt: Date?
    /// How long the earned break is. Set when the bout is written up, from
    /// `earnedBreakMinutes`, and adjustable before the break starts.
    var breakMinutes: Int
    var breakStartedAt: Date?
    /// When the break was ended — by its own clock running out and being
    /// acknowledged, or by the learner going back to work early.
    var breakEndedAt: Date?
    /// Given up on: the learner stopped without writing anything up. Recorded
    /// rather than deleted, so a day's bouts are the honest record.
    var abandonedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString.lowercased(),
        dayPlanID: String,
        blockID: String? = nil,
        title: String,
        notebookID: String? = nil,
        sourceIDs: [String] = [],
        plannedMinutes: Int = LearningBout.defaultMinutes,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        learned: String? = nil,
        unclear: String? = nil,
        writtenAt: Date? = nil,
        breakMinutes: Int = 0,
        breakStartedAt: Date? = nil,
        breakEndedAt: Date? = nil,
        abandonedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.dayPlanID = dayPlanID
        self.blockID = blockID
        self.title = title
        self.notebookID = notebookID
        self.sourceIDs = sourceIDs
        self.plannedMinutes = plannedMinutes
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.learned = learned
        self.unclear = unclear
        self.writtenAt = writtenAt
        self.breakMinutes = breakMinutes
        self.breakStartedAt = breakStartedAt
        self.breakEndedAt = breakEndedAt
        self.abandonedAt = abandonedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, dayPlanID, blockID, title, notebookID, sourceIDs, plannedMinutes
        case startedAt, endedAt, learned, unclear, writtenAt
        case breakMinutes, breakStartedAt, breakEndedAt, abandonedAt
        case createdAt, updatedAt
    }

    /// Every field but `id`, `dayPlanID` and `startedAt` decodes optionally, so
    /// a record written by a later build that adds one is still read here.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        dayPlanID = try c.decode(String.self, forKey: .dayPlanID)
        blockID = try c.decodeIfPresent(String.self, forKey: .blockID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        notebookID = try c.decodeIfPresent(String.self, forKey: .notebookID)
        sourceIDs = SourceIDList.normalized(try c.decodeIfPresent([String].self, forKey: .sourceIDs) ?? [])
        plannedMinutes = try c.decodeIfPresent(Int.self, forKey: .plannedMinutes) ?? LearningBout.defaultMinutes
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        learned = try c.decodeIfPresent(String.self, forKey: .learned)
        unclear = try c.decodeIfPresent(String.self, forKey: .unclear)
        writtenAt = try c.decodeIfPresent(Date.self, forKey: .writtenAt)
        breakMinutes = try c.decodeIfPresent(Int.self, forKey: .breakMinutes) ?? 0
        breakStartedAt = try c.decodeIfPresent(Date.self, forKey: .breakStartedAt)
        breakEndedAt = try c.decodeIfPresent(Date.self, forKey: .breakEndedAt)
        abandonedAt = try c.decodeIfPresent(Date.self, forKey: .abandonedAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? startedAt
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    // MARK: - The clock

    /// The bout the Today menu and a bare Start draw when nothing says
    /// otherwise: the long block the method asks for.
    static let defaultMinutes = 90
    static let minimumMinutes = 5
    static let maximumMinutes = 8 * 60
    /// The rest a bout earns: a minute for every nine learned, never less than
    /// five and never more than twenty. Ninety minutes — the block the Planner
    /// draws by default — earns the ten the method asks for.
    static let minutesLearnedPerBreakMinute = 9
    static let minimumBreakMinutes = 5
    static let maximumBreakMinutes = 20

    /// What a bout of `minutes` earns. Pure, so it is pinned by a test and the
    /// browser's copy can be held to the same numbers.
    static func earnedBreakMinutes(forMinutesLearned minutes: Int) -> Int {
        let raw = Int((Double(max(0, minutes)) / Double(minutesLearnedPerBreakMinute)).rounded())
        return min(maximumBreakMinutes, max(minimumBreakMinutes, raw))
    }

    static func clampedMinutes(_ minutes: Int) -> Int {
        min(maximumMinutes, max(minimumMinutes, minutes))
    }

    static func clampedBreakMinutes(_ minutes: Int) -> Int {
        min(maximumBreakMinutes, max(minimumBreakMinutes, minutes))
    }

    /// When the timer the learner set runs out. The bout does not end here —
    /// it is where the app asks for the write-up.
    var timerEndsAt: Date {
        startedAt.addingTimeInterval(TimeInterval(plannedMinutes * 60))
    }

    /// Seconds left on the timer; negative once the bout is running over.
    func remainingSeconds(now: Date = Date()) -> Int {
        Int(timerEndsAt.timeIntervalSince(now).rounded())
    }

    func isOverrunning(now: Date = Date()) -> Bool {
        phase(now: now) == .learning && now >= timerEndsAt
    }

    /// How long the learner actually learned: to the stop, or to now while the
    /// bout is still running. This, not `plannedMinutes`, is what the break is
    /// earned from, so a bout cut short earns a shorter break.
    func minutesLearned(now: Date = Date()) -> Int {
        let end = endedAt ?? abandonedAt ?? now
        return max(0, Int(end.timeIntervalSince(startedAt) / 60))
    }

    /// What this bout has earned, had it been written up now.
    func earnedBreakMinutes(now: Date = Date()) -> Int {
        Self.earnedBreakMinutes(forMinutesLearned: minutesLearned(now: now))
    }

    var breakEndsAt: Date? {
        guard let breakStartedAt else { return nil }
        return breakStartedAt.addingTimeInterval(TimeInterval(breakMinutes * 60))
    }

    /// Seconds left of the break; negative once it has run over.
    func breakRemainingSeconds(now: Date = Date()) -> Int? {
        guard let breakEndsAt else { return nil }
        return Int(breakEndsAt.timeIntervalSince(now).rounded())
    }

    // MARK: - Phase

    /// Read from the stamps, in the order they can only ever be set. `now` is
    /// taken for symmetry with the rest of the clock arithmetic and because a
    /// caller reading it makes its view redraw on the tick; a break that has
    /// run out is still `resting` until somebody says it is over, exactly as a
    /// bout that has run out is still `learning`.
    func phase(now: Date = Date()) -> LearningBoutPhase {
        if abandonedAt != nil { return .abandoned }
        // Set without a start, this says the earned break was declined.
        if breakEndedAt != nil { return .complete }
        if breakStartedAt != nil { return .resting }
        if writtenAt != nil { return .earned }
        if endedAt != nil { return .writing }
        return .learning
    }

    /// Whether the write-up is enough to earn the break. What was learned has
    /// to be said; what is still unclear may honestly be nothing.
    static func isWriteUpComplete(learned: String?) -> Bool {
        !(learned ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasWriteUp: Bool { Self.isWriteUpComplete(learned: learned) }

    /// The break is available once the write-up is saved, and until it is
    /// taken or declined.
    var canStartBreak: Bool {
        writtenAt != nil && breakStartedAt == nil && breakEndedAt == nil && abandonedAt == nil
    }

    /// Trims the words, clamps the clocks, and keeps the stamps in the only
    /// order they can happen in.
    func normalized(now: Date = Date()) -> LearningBout {
        var copy = self
        copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.notebookID = notebookID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.notebookID?.isEmpty == true { copy.notebookID = nil }
        copy.sourceIDs = SourceIDList.normalized(sourceIDs)
        copy.blockID = blockID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.blockID?.isEmpty == true { copy.blockID = nil }
        copy.learned = learned?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.learned?.isEmpty == true { copy.learned = nil }
        copy.unclear = unclear?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.unclear?.isEmpty == true { copy.unclear = nil }
        copy.plannedMinutes = Self.clampedMinutes(plannedMinutes)
        copy.breakMinutes = breakMinutes <= 0 ? 0 : Self.clampedBreakMinutes(breakMinutes)
        if let ended = copy.endedAt, ended < copy.startedAt { copy.endedAt = copy.startedAt }
        if copy.writtenAt != nil && copy.endedAt == nil { copy.endedAt = copy.writtenAt }
        if copy.breakStartedAt != nil && copy.writtenAt == nil { copy.breakStartedAt = nil }
        // A `breakEndedAt` with no start is not nonsense: it is the earned
        // break being declined, which is the learner going straight back to
        // work and the only way a bout finishes without resting.
        if copy.breakEndedAt != nil && copy.writtenAt == nil { copy.breakEndedAt = nil }
        copy.updatedAt = now
        return copy
    }

    /// The JSON text `learning_bouts.source_ids` stores.
    var sourceIDsJSON: String {
        let data = (try? JSONEncoder().encode(sourceIDs)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The two devices' copies of one bout, folded into the truth about it.
    ///
    /// Words are newest-wins, because a later write-up is a real edit. Every
    /// *stamp* is kept once either side has it, at the earlier of the two: a
    /// bout that was ended, written up or rested on cannot become un-ended by
    /// a stale record arriving afterwards. This is the same rule a block's
    /// `deleted_at` follows, and it is what lets
    /// the phone end a break the Mac started.
    static func merged(local: LearningBout, remote: LearningBout) -> LearningBout {
        var merged = local.updatedAt >= remote.updatedAt ? local : remote
        merged.endedAt = [local.endedAt, remote.endedAt].compactMap { $0 }.min()
        merged.writtenAt = [local.writtenAt, remote.writtenAt].compactMap { $0 }.min()
        merged.breakStartedAt = [local.breakStartedAt, remote.breakStartedAt].compactMap { $0 }.min()
        merged.breakEndedAt = [local.breakEndedAt, remote.breakEndedAt].compactMap { $0 }.min()
        merged.abandonedAt = [local.abandonedAt, remote.abandonedAt].compactMap { $0 }.min()
        // The write-up itself is never dropped by a copy that has not seen it:
        // a phone ending the break writes no words, and its newer stamp must
        // not blank what the Mac wrote.
        if !LearningBout.isWriteUpComplete(learned: merged.learned) {
            merged.learned = [local, remote].first { LearningBout.isWriteUpComplete(learned: $0.learned) }?.learned
        }
        if (merged.unclear ?? "").isEmpty {
            merged.unclear = [local, remote].compactMap(\.unclear).first { !$0.isEmpty }
        }
        merged.createdAt = min(local.createdAt, remote.createdAt)
        merged.updatedAt = max(local.updatedAt, remote.updatedAt)
        return merged
    }

    /// The bout a client should be showing, out of everything the day holds:
    /// the most recently started one that is still learning, owing a write-up
    /// or resting. Two Macs that each started a bout leave two rows; the later
    /// one is the one in front of the learner. Pure; mirrored by
    /// `liveBout` on the web.
    static func live(in bouts: [LearningBout], now: Date = Date()) -> LearningBout? {
        bouts
            .filter { $0.phase(now: now).isLive }
            .max { lhs, rhs in
                if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
                return lhs.id < rhs.id
            }
    }

    /// The bouts of a day as the panes list them: newest first.
    static func byRecency(_ lhs: LearningBout, _ rhs: LearningBout) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
        return lhs.id > rhs.id
    }
}

extension Notification.Name {
    /// Posted after a bout is started, ended, written up, or its break begun
    /// or ended — in this process, from a pane or from MCP. The Planner
    /// already republishes on `dayPlansDidChange`; this is the narrower signal
    /// for the things that watch only the clock: the menu bar's Today titles
    /// and the bout's own alarms.
    static let learningBoutDidChange = Notification.Name("LearningBoutDidChange")
}
