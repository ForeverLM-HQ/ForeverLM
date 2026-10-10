import Foundation

/// Off-main access to the time-block planner.
///
/// Thin pass-throughs to `KnowledgeStore` plus the sync urgency: every planner
/// write is the learner's own hand on today's plan, and the other Mac should
/// show the redraw before they walk over to it, so all of them push at once.
extension StorageService {

    func loadDayPlan(_ date: String) throws -> DayPlanDetail? {
        try notebookFilesKnowledgeStore().loadDayPlan(date)
    }

    func loadDayPlans(from: String, to: String) throws -> [DayPlanDetail] {
        try notebookFilesKnowledgeStore().loadDayPlans(from: from, to: to)
    }

    func dayPlanDatesHoldingCalendarSeries(_ prefix: String, after date: String) throws -> [String] {
        try notebookFilesKnowledgeStore().dayPlanDatesHoldingCalendarSeries(prefix, after: date)
    }

    @discardableResult
    func addTimeBlock(_ block: TimeBlock) throws -> TimeBlock {
        let saved = try notebookFilesKnowledgeStore().addTimeBlock(block)
        dayPlansDidChange()
        return saved
    }

    @discardableResult
    func updateTimeBlock(_ block: TimeBlock) throws -> TimeBlock {
        let saved = try notebookFilesKnowledgeStore().updateTimeBlock(block)
        dayPlansDidChange()
        return saved
    }

    func deleteTimeBlock(_ blockID: String) throws {
        try notebookFilesKnowledgeStore().deleteTimeBlock(blockID)
        dayPlansDidChange()
    }

    @discardableResult
    func attachSourceToTimeBlock(_ sourceID: String, blockID: String, completing: Bool = false) throws -> TimeBlock? {
        let saved = try notebookFilesKnowledgeStore().attachSourceToTimeBlock(sourceID, blockID: blockID, completing: completing)
        if saved != nil { dayPlansDidChange() }
        return saved
    }

    @discardableResult
    func reviseDayPlan(_ date: String, replacing blockIDs: [String], replacements: [TimeBlock]) throws -> DayPlanDetail {
        let detail = try notebookFilesKnowledgeStore().reviseDayPlan(date, replacing: blockIDs, replacements: replacements)
        dayPlansDidChange()
        return detail
    }

    @discardableResult
    func setDayPlanNotes(_ date: String, notes: String?) throws -> DayPlan {
        let plan = try notebookFilesKnowledgeStore().setDayPlanNotes(date, notes: notes)
        dayPlansDidChange()
        return plan
    }

    @discardableResult
    func setDayPlanShutdown(_ date: String, at shutdownAt: Date?) throws -> DayPlan {
        let plan = try notebookFilesKnowledgeStore().setDayPlanShutdown(date, at: shutdownAt)
        dayPlansDidChange()
        return plan
    }

    func deleteDayPlan(_ date: String) throws {
        try notebookFilesKnowledgeStore().deleteDayPlan(date)
        dayPlansDidChange()
    }

    /// The Planner's log: the learner was seen doing `kind` on `targetID` at
    /// `moment`. Recorded a minute at a time by the reader heartbeat, the chat
    /// and the Doc editor, so the write is cheap and quiet: the record is
    /// queued for the regular sync rather than pushed at once, and the pane is
    /// told only when a span actually moved.
    @discardableResult
    func recordDayActivity(kind: DayActivityKind, targetID: String, title: String, at moment: Date = Date()) throws -> DayActivity? {
        let span = try notebookFilesKnowledgeStore().recordDayActivity(kind: kind, targetID: targetID, title: title, at: moment)
        if span != nil {
            NotificationCenter.default.post(name: .dayPlansDidChange, object: nil)
        }
        return span
    }

    /// Puts a stretch of work on the clock at the hours it ran, for work
    /// ForeverLM did not watch — an imported ChatGPT or Claude conversation.
    /// See `KnowledgeStore.recordDayActivitySpan`.
    @discardableResult
    func recordDayActivitySpan(
        kind: DayActivityKind,
        targetID: String,
        title: String,
        from start: Date,
        to end: Date
    ) throws -> DayActivity? {
        let span = try notebookFilesKnowledgeStore().recordDayActivitySpan(
            kind: kind, targetID: targetID, title: title, from: start, to: end
        )
        if span != nil {
            NotificationCenter.default.post(name: .dayPlansDidChange, object: nil)
        }
        return span
    }

    /// Takes spans off the day's log. See `KnowledgeStore.deleteDayActivities`.
    func deleteDayActivities(_ ids: [String]) throws {
        try notebookFilesKnowledgeStore().deleteDayActivities(ids)
        dayPlansDidChange()
    }

    // MARK: - Learning bouts

    func loadLearningBout(_ id: String) throws -> LearningBout? {
        try notebookFilesKnowledgeStore().loadLearningBout(id)
    }

    func loadLearningBouts(dayPlanID: String) throws -> [LearningBout] {
        try notebookFilesKnowledgeStore().loadLearningBouts(dayPlanID: dayPlanID)
    }

    /// The running, unwritten or resting bout, wherever it started. What the
    /// menu bar, the phone's snapshot and every pane ask for.
    func loadLiveLearningBout() throws -> LearningBout? {
        try notebookFilesKnowledgeStore().loadLiveLearningBout()
    }

    @discardableResult
    func startLearningBout(_ bout: LearningBout) throws -> LearningBout {
        let saved = try notebookFilesKnowledgeStore().startLearningBout(bout)
        boutDidChange()
        return saved
    }

    @discardableResult
    func endLearningBout(_ id: String) throws -> LearningBout {
        let saved = try notebookFilesKnowledgeStore().endLearningBout(id)
        boutDidChange()
        return saved
    }

    @discardableResult
    func writeUpLearningBout(_ id: String, learned: String, unclear: String?, breakMinutes: Int? = nil) throws -> LearningBout {
        let saved = try notebookFilesKnowledgeStore().writeUpLearningBout(
            id,
            learned: learned,
            unclear: unclear,
            breakMinutes: breakMinutes
        )
        boutDidChange()
        return saved
    }

    @discardableResult
    func setLearningBoutBreakMinutes(_ id: String, minutes: Int) throws -> LearningBout {
        let saved = try notebookFilesKnowledgeStore().setLearningBoutBreakMinutes(id, minutes: minutes)
        boutDidChange()
        return saved
    }

    @discardableResult
    func startLearningBoutBreak(_ id: String, minutes: Int? = nil) throws -> LearningBout {
        let saved = try notebookFilesKnowledgeStore().startLearningBoutBreak(id, minutes: minutes)
        boutDidChange()
        return saved
    }

    @discardableResult
    func endLearningBoutBreak(_ id: String) throws -> LearningBout {
        let saved = try notebookFilesKnowledgeStore().endLearningBoutBreak(id)
        boutDidChange()
        return saved
    }

    @discardableResult
    func abandonLearningBout(_ id: String) throws -> LearningBout {
        let saved = try notebookFilesKnowledgeStore().abandonLearningBout(id)
        boutDidChange()
        return saved
    }

    func deleteLearningBout(_ id: String) throws {
        try notebookFilesKnowledgeStore().deleteLearningBout(id)
        boutDidChange()
    }

    /// A bout changed: the day republishes as any planner write does, and the
    /// clock the other devices are watching is pushed at once rather than
    /// waiting for the regular sync — a break that starts here has to be
    /// counting down on the phone, not in ten minutes' time.
    private func boutDidChange() {
        scheduleImmediateCloudKitSyncForDayPlans()
        NotificationCenter.default.post(name: .dayPlansDidChange, object: nil)
        NotificationCenter.default.post(name: .learningBoutDidChange, object: nil)
    }

    private func dayPlansDidChange() {
        scheduleImmediateCloudKitSyncForDayPlans()
        NotificationCenter.default.post(name: .dayPlansDidChange, object: nil)
    }
}
