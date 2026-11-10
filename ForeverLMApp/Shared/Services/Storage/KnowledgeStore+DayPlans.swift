import Foundation
import SQLite3

/// Storage for the time-block planner: one `day_plans` row per local date and
/// its `time_blocks`.
///
/// The day and its blocks sync as one `DayPlan` record, keyed by the date, so
/// two devices that plan the same day offline produce one record and merge
/// block by block rather than duplicating the day. A day has one plan: an edit
/// lands on the block's own row, and a block deleted or replaced by a redraw
/// is tombstoned rather than removed, a fact that survives a merge because it
/// only ever gets set.
extension KnowledgeStore {

    // MARK: - Reads

    /// The day as it reads now: its blocks, and its log under the names the
    /// things it names carry today rather than the ones they were saved
    /// under. Every reader gets the current names this way — the pane, the
    /// side panel and `get_day_plan` alike.
    func loadDayPlan(_ date: String) throws -> DayPlanDetail? {
        try loadDayPlanDetail(date, resolvingTitles: true)
    }

    private func loadDayPlanDetail(_ date: String, resolvingTitles: Bool) throws -> DayPlanDetail? {
        guard let plan = try loadDayPlanRow(date) else { return nil }
        let activities = try loadDayActivities(dayPlanID: plan.id)
        return DayPlanDetail(
            plan: plan,
            blocks: try loadTimeBlocks(dayPlanID: plan.id),
            activities: resolvingTitles ? try currentlyTitled(activities) : activities,
            bouts: try loadLearningBouts(dayPlanID: plan.id)
        )
    }

    /// Every plan whose date falls in `from...to` (both `YYYY-MM-DD`,
    /// inclusive), oldest first, with all of its rows.
    func loadDayPlans(from: String, to: String) throws -> [DayPlanDetail] {
        var plans: [DayPlan] = []
        try queryBind("\(Self.dayPlanColumns) WHERE plan_date >= ? AND plan_date <= ? ORDER BY plan_date ASC", bind: { stmt in
            self.bind(stmt, 1, from)
            self.bind(stmt, 2, to)
        }) { stmt in
            if let plan = self.dayPlan(from: stmt) { plans.append(plan) }
        }
        return try plans.map {
            DayPlanDetail(
                plan: $0,
                blocks: try loadTimeBlocks(dayPlanID: $0.id),
                activities: try currentlyTitled(loadDayActivities(dayPlanID: $0.id)),
                bouts: try loadLearningBouts(dayPlanID: $0.id)
            )
        }
    }

    func loadTimeBlock(_ blockID: String) throws -> TimeBlock? {
        var block: TimeBlock?
        try queryBind("\(Self.timeBlockColumns) WHERE id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, blockID)
        }) { stmt in
            block = self.timeBlock(from: stmt)
        }
        return block
    }

    /// The days after `date` whose plans still hold an untouched occurrence of
    /// the calendar series `prefix` begins. Matched with `instr(… ) = 1` rather
    /// than `LIKE`: a Google series prefix ends in `_`, which `LIKE` would read
    /// as a wildcard and quietly match its neighbours.
    func dayPlanDatesHoldingCalendarSeries(_ prefix: String, after date: String, limit: Int = 60) throws -> [String] {
        guard !prefix.isEmpty else { return [] }
        var dates: [String] = []
        try queryBind("""
            SELECT DISTINCT day_plan_id FROM time_blocks
             WHERE day_plan_id > ?
               AND calendar_event_id IS NOT NULL AND instr(calendar_event_id, ?) = 1
               AND deleted_at IS NULL AND superseded_in_revision IS NULL
               AND status = 'planned'
             ORDER BY day_plan_id ASC LIMIT ?
            """, bind: { stmt in
            self.bind(stmt, 1, date)
            self.bind(stmt, 2, prefix)
            self.bind(stmt, 3, limit)
        }) { stmt in
            if let day = self.string(stmt, 0) { dates.append(day) }
        }
        return dates
    }

    // MARK: - Writes

    /// Adds a block to a day, creating the day's plan when it is the first.
    @discardableResult
    func addTimeBlock(_ block: TimeBlock, now: Date = Date()) throws -> TimeBlock {
        var saved = block.normalized(now: now)
        guard !saved.title.isEmpty else {
            throw KnowledgeStoreError.invalidData("A time block needs a title.")
        }
        guard DayPlan.isValidDateString(saved.dayPlanID) else {
            throw KnowledgeStoreError.invalidData("A time block needs a day, formatted YYYY-MM-DD.")
        }
        try exec("BEGIN IMMEDIATE")
        do {
            let plan = try ensureDayPlanRow(saved.dayPlanID, now: now)
            saved.revision = plan.revision
            saved.supersededInRevision = nil
            saved.deletedAt = nil
            saved.createdAt = now
            try refuseOverlaps(of: saved, among: try loadTimeBlocks(dayPlanID: saved.dayPlanID))
            try writeTimeBlockRow(saved)
            try touchDayPlan(plan.id, at: now)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return saved
    }

    /// Changes a block in place — its time, what it is, or how it went — and
    /// returns the row as written. The block keeps its id.
    @discardableResult
    func updateTimeBlock(_ block: TimeBlock, now: Date = Date()) throws -> TimeBlock {
        let incoming = block.normalized(now: now)
        guard !incoming.title.isEmpty else {
            throw KnowledgeStoreError.invalidData("A time block needs a title.")
        }
        try exec("BEGIN IMMEDIATE")
        do {
            guard let existing = try loadTimeBlock(incoming.id), existing.isCurrent else {
                try exec("ROLLBACK")
                throw KnowledgeStoreError.invalidData("No current time block with id \(incoming.id).")
            }
            guard let plan = try loadDayPlanRow(existing.dayPlanID) else {
                try exec("ROLLBACK")
                throw KnowledgeStoreError.invalidData("Time block \(incoming.id) has no day plan.")
            }
            var result = existing
            result.startMinute = incoming.startMinute
            result.endMinute = incoming.endMinute
            result.title = incoming.title
            result.notes = incoming.notes
            result.location = incoming.location
            result.notebookID = incoming.notebookID
            result.goalID = incoming.goalID
            result.sourceIDs = incoming.sourceIDs
            result.purpose = incoming.purpose
            result.calendarEventID = incoming.calendarEventID
            result.calendarEventURL = incoming.calendarEventURL
            result.status = incoming.status
            result.updatedAt = now

            // A block moved or resized onto another is refused; an edit that
            // leaves the time alone never fails on an overlap it did not make
            // (a calendar block laid over it, a row from before the rule).
            if result.startMinute != existing.startMinute || result.endMinute != existing.endMinute {
                try refuseOverlaps(of: result, among: try loadTimeBlocks(dayPlanID: existing.dayPlanID))
            }

            try writeTimeBlockRow(result)
            try touchDayPlan(plan.id, at: now)
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Adds a source to a block in place: what was said in a meeting the
    /// block already stands for.
    ///
    /// With `completing`, the source is the proof the block happened — a
    /// meeting's transcript — and a block still planned is marked done in the
    /// same write. This is the one way a block is completed without the
    /// learner's hand, and it is not the clock: a transcript exists because
    /// the meeting took place. A block the learner already marked done or
    /// skipped keeps that verdict.
    ///
    /// Returns the row as written, or nil when the block already carried the
    /// source and needed no status change.
    @discardableResult
    func attachSourceToTimeBlock(_ sourceID: String, blockID: String, completing: Bool = false, now: Date = Date()) throws -> TimeBlock? {
        try exec("BEGIN IMMEDIATE")
        do {
            guard var block = try loadTimeBlock(blockID), block.isCurrent,
                  let plan = try loadDayPlanRow(block.dayPlanID) else {
                try exec("ROLLBACK")
                throw KnowledgeStoreError.invalidData("No current time block with id \(blockID).")
            }
            let attaches = !sourceID.isEmpty && !block.sourceIDs.contains(sourceID)
            let completes = completing && block.status == .planned
            guard attaches || completes else {
                try exec("ROLLBACK")
                return nil
            }
            if attaches { block.sourceIDs.append(sourceID) }
            if completes { block.status = .done }
            block.updatedAt = now
            try writeTimeBlockRow(block)
            try touchDayPlan(plan.id, at: now)
            try exec("COMMIT")
            return block
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Removes a block from the day. The row is tombstoned, so a merge with a
    /// device that still has it never brings it back.
    func deleteTimeBlock(_ blockID: String, now: Date = Date()) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            guard var block = try loadTimeBlock(blockID), block.isCurrent,
                  let plan = try loadDayPlanRow(block.dayPlanID) else {
                try exec("ROLLBACK")
                throw KnowledgeStoreError.invalidData("No current time block with id \(blockID).")
            }
            block.deletedAt = now
            block.updatedAt = now
            try writeTimeBlockRow(block)
            try touchDayPlan(plan.id, at: now)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Redraws part of a day in one step, on the day's one plan: the named
    /// current blocks leave it and `replacements` are drawn in their place.
    /// The first replacement carrying the id of a named block rewrites that
    /// block in place, keeping its row and id — that is how Extend moves the
    /// blocks it pushes back. Any other replacement is a new row, and a named
    /// block no replacement carries is tombstoned. This is the shape of the
    /// assistant's redraw, the in-app one and Extend.
    @discardableResult
    func reviseDayPlan(
        _ date: String,
        replacing blockIDs: [String],
        replacements: [TimeBlock],
        now: Date = Date()
    ) throws -> DayPlanDetail {
        let drafts = replacements.map { $0.normalized(now: now) }
        if let blank = drafts.first(where: { $0.title.isEmpty }) {
            throw KnowledgeStoreError.invalidData("A time block needs a title (\(DayPlan.clockString(minute: blank.startMinute))).")
        }
        try exec("BEGIN IMMEDIATE")
        do {
            let plan = try ensureDayPlanRow(date, now: now)
            let current = try loadTimeBlocks(dayPlanID: plan.id).filter(\.isCurrent)
            let currentByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let named = Set(blockIDs)
            if let missing = named.first(where: { currentByID[$0] == nil }) {
                try exec("ROLLBACK")
                throw KnowledgeStoreError.invalidData("No current time block with id \(missing) on \(date).")
            }
            let rewritten = Set(drafts.map(\.id)).intersection(named)
            for blockID in named.subtracting(rewritten) {
                guard var block = currentByID[blockID] else { continue }
                block.deletedAt = now
                block.updatedAt = now
                try writeTimeBlockRow(block)
            }
            // Each block drawn is checked against what the day keeps and
            // against the blocks drawn before it, so two drafts over one hour
            // are refused as surely as a draft over a kept block. A block
            // rewritten in place is checked at its new hours only.
            var placed = current.filter { !named.contains($0.id) }
            var rewrote: Set<String> = []
            for draft in drafts {
                let block: TimeBlock
                if rewritten.contains(draft.id), rewrote.insert(draft.id).inserted, var existing = currentByID[draft.id] {
                    existing.startMinute = draft.startMinute
                    existing.endMinute = draft.endMinute
                    existing.title = draft.title
                    existing.notes = draft.notes
                    existing.location = draft.location
                    existing.notebookID = draft.notebookID
                    existing.goalID = draft.goalID
                    existing.sourceIDs = draft.sourceIDs
                    existing.purpose = draft.purpose
                    existing.calendarEventID = draft.calendarEventID
                    existing.calendarEventURL = draft.calendarEventURL
                    existing.status = draft.status
                    existing.updatedAt = now
                    block = existing
                } else {
                    block = TimeBlock(
                        dayPlanID: plan.id,
                        startMinute: draft.startMinute,
                        endMinute: draft.endMinute,
                        title: draft.title,
                        notes: draft.notes,
                        location: draft.location,
                        notebookID: draft.notebookID,
                        goalID: draft.goalID,
                        sourceIDs: draft.sourceIDs,
                        purpose: draft.purpose,
                        calendarEventID: draft.calendarEventID,
                        calendarEventURL: draft.calendarEventURL,
                        status: draft.status,
                        revision: plan.revision,
                        createdAt: now,
                        updatedAt: now
                    )
                }
                try refuseOverlaps(of: block, among: placed)
                try writeTimeBlockRow(block)
                placed.append(block)
            }
            try touchDayPlan(plan.id, at: now)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        guard let detail = try loadDayPlan(date) else {
            throw KnowledgeStoreError.invalidData("Day plan \(date) vanished while being revised.")
        }
        return detail
    }

    /// The day's free text: the task list, ideas, the shutdown note.
    @discardableResult
    func setDayPlanNotes(_ date: String, notes: String?, now: Date = Date()) throws -> DayPlan {
        try exec("BEGIN IMMEDIATE")
        do {
            var plan = try ensureDayPlanRow(date, now: now)
            let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
            plan.notes = (trimmed?.isEmpty ?? true) ? nil : trimmed
            plan.updatedAt = now
            try writeDayPlanRow(plan)
            try exec("COMMIT")
            return plan
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Marks the shutdown ritual done (`at` a moment) or reopens the day (`nil`).
    @discardableResult
    func setDayPlanShutdown(_ date: String, at shutdownAt: Date?, now: Date = Date()) throws -> DayPlan {
        try exec("BEGIN IMMEDIATE")
        do {
            var plan = try ensureDayPlanRow(date, now: now)
            plan.shutdownAt = shutdownAt
            plan.updatedAt = now
            try writeDayPlanRow(plan)
            try exec("COMMIT")
            return plan
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - The log

    /// Records that the learner was seen doing `kind` on `targetID` at
    /// `moment`. An observation within `DayPlan.activityMergeGapMinutes` of the
    /// latest span for the same thing extends that span to cover the minute;
    /// otherwise a new one-minute span starts. The day's row is created when
    /// this is the first thing recorded on it. Nothing here touches a block.
    ///
    /// Returns the span the observation landed in, or nil when it changed
    /// nothing (a second observation inside the same minute), so a caller can
    /// skip the notification and the sync queue stays quiet.
    @discardableResult
    func recordDayActivity(
        kind: DayActivityKind,
        targetID: String,
        title: String,
        at moment: Date,
        now: Date = Date()
    ) throws -> DayActivity? {
        let target = targetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            throw KnowledgeStoreError.invalidData("A day activity needs the id of what was being done.")
        }
        let date = DayPlan.dateString(for: moment)
        guard let minute = DayPlan.minuteOfDay(for: moment, on: date) else { return nil }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Most observations fall in a minute the span already covers — a page
        // saved at each pause in typing, a chat's every turn — and change
        // nothing. They are answered from the thing's own spans before the
        // write lock, so they cost neither a transaction nor a read of the
        // day's whole log.
        if let latest = try latestDayActivity(dayPlanID: date, kind: kind, targetID: target),
           latest.absorbs(minute: minute, named: name) {
            return nil
        }
        try exec("BEGIN IMMEDIATE")
        do {
            let plan = try ensureDayPlanRow(date, now: now)
            let latest = try latestDayActivity(dayPlanID: plan.id, kind: kind, targetID: target)
            var span: DayActivity
            if let latest, latest.continues(atMinute: minute) {
                // Another writer may have extended it since the look above.
                guard !latest.absorbs(minute: minute, named: name) else {
                    try exec("COMMIT")
                    return nil
                }
                span = latest
                span.endMinute = max(span.endMinute, min(DayPlan.minutesPerDay, minute + 1))
                if !name.isEmpty, name != span.title { span.title = name }
                span.updatedAt = now
            } else {
                span = DayActivity(
                    dayPlanID: plan.id,
                    startMinute: minute,
                    endMinute: min(DayPlan.minutesPerDay, minute + 1),
                    kind: kind,
                    targetID: target,
                    title: name,
                    createdAt: now,
                    updatedAt: now
                )
            }
            try writeDayActivityRow(span)
            try touchDayPlan(plan.id, at: now)
            try exec("COMMIT")
            return span
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Puts a stretch of work on the clock at the hours it actually ran.
    ///
    /// The sibling of `recordDayActivity`, for work ForeverLM did not watch:
    /// a conversation had in ChatGPT or Claude and imported afterwards, which
    /// otherwise lands as nothing at all, or — worse — at the minute it was
    /// pasted in rather than the afternoon it happened
    /// (docs/tethered-workday-design.md; the product owner, 2026-09-18: "it should also
    /// save the times when I worked on that and the sources used").
    ///
    /// Unlike the heartbeat this asserts a whole range rather than a minute.
    /// The range joins the thing's spans it overlaps or continues within
    /// `DayPlan.activityMergeGapMinutes` — re-importing the same chat widens
    /// that chat's own span instead of drawing a second one beside it — and a
    /// range further off is a sitting of its own. Widening whatever span the
    /// thing already had drew a chat's later exchange and its first as one
    /// span, with the afternoon between them (2026-09-28). A range that
    /// crosses midnight is cut at the end of the day it began in, as a block
    /// is; the day's id is the start's.
    @discardableResult
    func recordDayActivitySpan(
        kind: DayActivityKind,
        targetID: String,
        title: String,
        from start: Date,
        to end: Date,
        now: Date = Date()
    ) throws -> DayActivity? {
        try exec("BEGIN IMMEDIATE")
        do {
            let span = try recordDayActivitySpanRows(
                kind: kind, targetID: targetID, title: title, from: start, to: end, now: now
            )
            try exec("COMMIT")
            return span
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Transaction-free form of `recordDayActivitySpan`, for a caller whose
    /// span must commit or roll back with its other rows: a play heard in
    /// Apple Podcasts lands on the day's log together with its activity day.
    @discardableResult
    func recordDayActivitySpanRows(
        kind: DayActivityKind,
        targetID: String,
        title: String,
        from start: Date,
        to end: Date,
        now: Date
    ) throws -> DayActivity? {
        let target = targetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            throw KnowledgeStoreError.invalidData("A day activity needs the id of what was being done.")
        }
        guard end > start else {
            throw KnowledgeStoreError.invalidData("A stretch of work has to end after it started.")
        }
        let date = DayPlan.dateString(for: start)
        guard let startMinute = DayPlan.minuteOfDay(for: start, on: date) else { return nil }
        // An end on a later day is the end of this one: the span belongs to the
        // day it began in, and a day never runs past its own midnight.
        let rawEnd = DayPlan.minuteOfDay(for: end, on: date) ?? DayPlan.minutesPerDay
        let endMinute = min(DayPlan.minutesPerDay, max(startMinute + 1, rawEnd))
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)

        let plan = try ensureDayPlanRow(date, now: now)
        let gap = DayPlan.activityMergeGapMinutes
        let touching = try loadDayActivities(dayPlanID: plan.id).filter {
            $0.kind == kind && $0.targetID == target
                && startMinute - $0.endMinute <= gap && $0.startMinute - endMinute <= gap
        }
        var span: DayActivity
        if var found = touching.first {
            found.startMinute = touching.map(\.startMinute).reduce(startMinute, min)
            found.endMinute = touching.map(\.endMinute).reduce(endMinute, max)
            if !name.isEmpty { found.title = name }
            found.updatedAt = now
            span = found
            // A range that bridges two of the thing's spans makes them one.
            for joined in touching.dropFirst() {
                try execBind("DELETE FROM day_activities WHERE id = ?") { stmt in
                    self.bind(stmt, 1, joined.id)
                }
            }
        } else {
            span = DayActivity(
                dayPlanID: plan.id,
                startMinute: startMinute,
                endMinute: endMinute,
                kind: kind,
                targetID: target,
                title: name,
                createdAt: now,
                updatedAt: now
            )
        }
        try writeDayActivityRow(span)
        try touchDayPlan(plan.id, at: now)
        return span
    }

    /// Puts work ForeverLM did not watch on the clock from the moments its own
    /// record says it happened: a conversation read from its client's session
    /// file, every message stamped. Each moment is an observation, as a turn
    /// of an in-app chat is, and the moments are joined by the heartbeat's
    /// rule (`DayActivity.observedRuns`), so time the learner was away between
    /// two messages stays off the clock. Drawn as one span from its first
    /// message to its last, a chat imported on 2026-09-28 covered 14:26–19:04,
    /// 278 minutes, most of an afternoon spent elsewhere.
    ///
    /// The record is read whole on every import, so on each day it touches
    /// the thing's spans inside the record's hours are redrawn from it rather
    /// than widened: a repeat call draws the same spans under the same ids, a
    /// record that grew lengthens its last span or adds one, and a span an
    /// older build drew across the whole chat becomes its first sitting. That
    /// span keeps its id, so the other Macs, which keep the newest copy of
    /// each span, shorten it too. A span of the thing outside the record's
    /// hours — the chat continued in ForeverLM — is kept, and one that crosses
    /// the record's edge is joined to the run it overlaps. Returns the
    /// record's spans, by day and start.
    @discardableResult
    func recordDayActivityObservations(
        kind: DayActivityKind,
        targetID: String,
        title: String,
        at moments: [Date],
        now: Date = Date()
    ) throws -> [DayActivity] {
        let target = targetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            throw KnowledgeStoreError.invalidData("A day activity needs the id of what was being done.")
        }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var minutesByDay: [String: [Int]] = [:]
        for moment in moments {
            let date = DayPlan.dateString(for: moment)
            guard let minute = DayPlan.minuteOfDay(for: moment, on: date) else { continue }
            minutesByDay[date, default: []].append(minute)
        }
        guard !minutesByDay.isEmpty else { return [] }

        try exec("BEGIN IMMEDIATE")
        do {
            var drawn: [DayActivity] = []
            for date in minutesByDay.keys.sorted() {
                let runs = DayActivity.observedRuns(atMinutes: minutesByDay[date] ?? [])
                guard let windowStart = runs.first?.start, let windowEnd = runs.last?.end else { continue }
                let plan = try ensureDayPlanRow(date, now: now)
                let existing = try loadDayActivities(dayPlanID: plan.id)
                    .filter { $0.kind == kind && $0.targetID == target }
                func isInsideRecord(_ span: DayActivity) -> Bool {
                    span.startMinute >= windowStart && span.endMinute <= windowEnd
                }
                // Drawn from this record before: redrawn, their ids reused in order.
                var recycled = existing.filter(isInsideRecord)
                // Recorded some other way and crossing the record's edge: joined.
                let crossing = existing.filter {
                    !isInsideRecord($0) && $0.startMinute < windowEnd && windowStart < $0.endMinute
                }
                var pieces: [(start: Int, end: Int, span: DayActivity?)] = []
                for run in runs {
                    pieces.append((start: run.start, end: run.end, span: nil))
                }
                for span in crossing {
                    pieces.append((start: span.startMinute, end: span.endMinute, span: span))
                }
                pieces.sort { $0.start < $1.start }
                var joined: [(start: Int, end: Int, span: DayActivity?)] = []
                var surplus: [DayActivity] = []
                for piece in pieces {
                    guard var last = joined.last, piece.start < last.end else {
                        joined.append(piece)
                        continue
                    }
                    last.end = max(last.end, piece.end)
                    if let span = piece.span {
                        if last.span == nil { last.span = span } else { surplus.append(span) }
                    }
                    joined[joined.count - 1] = last
                }

                var changed = false
                for piece in joined {
                    let reused: DayActivity?
                    if let kept = piece.span {
                        reused = kept
                    } else if !recycled.isEmpty {
                        reused = recycled.removeFirst()
                    } else {
                        reused = nil
                    }
                    guard var span = reused else {
                        let span = DayActivity(
                            dayPlanID: plan.id,
                            startMinute: piece.start,
                            endMinute: piece.end,
                            kind: kind,
                            targetID: target,
                            title: name,
                            createdAt: now,
                            updatedAt: now
                        )
                        try writeDayActivityRow(span)
                        changed = true
                        drawn.append(span)
                        continue
                    }
                    let renamed = !name.isEmpty && span.title != name
                    if span.startMinute != piece.start || span.endMinute != piece.end || renamed {
                        span.startMinute = piece.start
                        span.endMinute = piece.end
                        if renamed { span.title = name }
                        span.updatedAt = now
                        try writeDayActivityRow(span)
                        changed = true
                    }
                    drawn.append(span)
                }
                for stale in recycled + surplus {
                    try execBind("DELETE FROM day_activities WHERE id = ?") { stmt in
                        self.bind(stmt, 1, stale.id)
                    }
                    changed = true
                }
                if changed {
                    try touchDayPlan(plan.id, at: now)
                }
            }
            try exec("COMMIT")
            return drawn
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Takes spans off the day's log for good. The Planner's **Delete** on a
    /// sitting (product owner, 2026-09-20: "please let me delete things here too")
    /// passes every span the sitting was built from; `delete_day_activity`
    /// passes one. The log is this Mac's observation and rides in the day's
    /// record rather than as rows of its own, so the rows go rather than being
    /// tombstoned; the day stays, touched so an open Planner reads it again.
    /// An id the log does not hold deletes nothing and is not an error.
    func deleteDayActivities(_ ids: [String], now: Date = Date()) throws {
        let unique = Array(Set(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            var days = Set<String>()
            for id in unique {
                guard let activity = try loadDayActivity(id) else { continue }
                days.insert(activity.dayPlanID)
                try execBind("DELETE FROM day_activities WHERE id = ?") { stmt in
                    self.bind(stmt, 1, id)
                }
            }
            for day in days {
                try touchDayPlan(day, at: now)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Removes a day and every row it held, on every device.
    func deleteDayPlan(_ date: String, now: Date = Date()) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM learning_bouts WHERE day_plan_id = ?") { stmt in
                self.bind(stmt, 1, date)
            }
            try execBind("DELETE FROM day_activities WHERE day_plan_id = ?") { stmt in
                self.bind(stmt, 1, date)
            }
            try execBind("DELETE FROM time_blocks WHERE day_plan_id = ?") { stmt in
                self.bind(stmt, 1, date)
            }
            try execBind("DELETE FROM day_plans WHERE id = ?") { stmt in
                self.bind(stmt, 1, date)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - CloudKit

    // MARK: - Row plumbing

    private func loadDayPlanRow(_ date: String) throws -> DayPlan? {
        var plan: DayPlan?
        try queryBind("\(Self.dayPlanColumns) WHERE id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, date)
        }) { stmt in
            plan = self.dayPlan(from: stmt)
        }
        return plan
    }

    /// The day's rule: no two blocks at one hour. Throws for a block drawn
    /// over a current block of its day, naming what is in the way, so the
    /// caller's transaction rolls back with nothing written. A calendar
    /// block is never refused (`TimeBlock.keepsClearOfOtherBlocks`).
    private func refuseOverlaps(of block: TimeBlock, among others: [TimeBlock]) throws {
        let inTheWay = DayPlan.blocksOverlapping(block, among: others)
        guard inTheWay.isEmpty else {
            // Screen record mode (admin only): a block the take may not show —
            // a calendar event, the learner's own plan — is refused by its
            // hours alone. The message reaches the filmed chat, which read
            // "Alan <> Zara (existing calendar event)" back to the camera
            // (build 144, 2026-09-25).
            if let scope = screenRecordScope(), inTheWay.contains(where: { !scope.allowsBlock($0) }) {
                let hours = inTheWay
                    .map { "\(DayPlan.clockString(minute: $0.startMinute))–\(DayPlan.clockString(minute: $0.endMinute))" }
                    .joined(separator: ", ")
                throw KnowledgeStoreError.invalidData("That time is taken: \(hours) already holds a block. Choose free hours and name no block you cannot see.")
            }
            throw KnowledgeStoreError.invalidData(DayPlan.overlapMessage(for: block, overlapping: inTheWay))
        }
    }

    private func loadTimeBlocks(dayPlanID: String) throws -> [TimeBlock] {
        var blocks: [TimeBlock] = []
        try queryBind("\(Self.timeBlockColumns) WHERE day_plan_id = ? ORDER BY start_minute ASC, end_minute ASC, created_at ASC", bind: { stmt in
            self.bind(stmt, 1, dayPlanID)
        }) { stmt in
            if let block = self.timeBlock(from: stmt) { blocks.append(block) }
        }
        return blocks
    }

    /// The day's row, created at revision 1 when the day has none yet. Runs
    /// inside the caller's transaction.
    /// Not private: `KnowledgeStore+LearningBouts` starts a bout on a day
    /// that may have no plan row yet, and must create it the same way.
    func ensureDayPlanRow(_ date: String, now: Date) throws -> DayPlan {
        guard DayPlan.isValidDateString(date) else {
            throw KnowledgeStoreError.invalidData("A day plan needs a date formatted YYYY-MM-DD, not \"\(date)\".")
        }
        if let existing = try loadDayPlanRow(date) { return existing }
        let plan = DayPlan(date: date, createdAt: now, updatedAt: now)
        try writeDayPlanRow(plan)
        return plan
    }

    /// Stamps the day and queues the record after one of its blocks changed.
    /// Not private, for the same reason as `ensureDayPlanRow`: a bout's write
    /// queues the day for CloudKit through this one place.
    func touchDayPlan(_ date: String, at now: Date) throws {
        try execBind("UPDATE day_plans SET updated_at = ? WHERE id = ?") { stmt in
            self.bind(stmt, 1, now.timeIntervalSinceReferenceDate)
            self.bind(stmt, 2, date)
        }
    }

    /// The log, read back under the names its things carry now: a source
    /// renamed after it was read, a chat whose topic changed, a Doc retitled.
    /// The row keeps the name it was seen under, which is what a span whose
    /// thing has been deleted still reads by.
    private func currentlyTitled(_ activities: [DayActivity]) throws -> [DayActivity] {
        DayPlanDetail.resolvingCurrentTitles(activities, currentTitles: try currentDayActivityTitles(for: activities))
    }

    /// What the things a day's log names are called now — sources by their
    /// projected title, chats by their topic, Docs by their title — keyed the
    /// way a span links: `source/<id>`, `chat/<id>`, `doc/<id>`. Things that
    /// are gone are simply absent.
    private func currentDayActivityTitles(for activities: [DayActivity]) throws -> [String: String] {
        var idsByKind: [String: Set<String>] = [:]
        for activity in activities where !activity.targetID.isEmpty {
            idsByKind[activity.kind.targetKind, default: []].insert(activity.targetID)
        }
        guard !idsByKind.isEmpty else { return [:] }
        var titles: [String: String] = [:]
        for (kind, ids) in idsByKind {
            let table: String
            let column: String
            switch kind {
            case "source": table = "source_projection"; column = "title"
            case "chat": table = "review_sessions"; column = "topic"
            case "doc": table = "global_artifacts"; column = "title"
            default: continue
            }
            var remaining = Array(ids)
            while !remaining.isEmpty {
                let chunk = Array(remaining.prefix(400))
                remaining.removeFirst(chunk.count)
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                try queryBind("SELECT id, \(column) FROM \(table) WHERE id IN (\(placeholders))", bind: { stmt in
                    for (index, id) in chunk.enumerated() { self.bind(stmt, index + 1, id) }
                }) { stmt in
                    guard let id = self.string(stmt, 0), let title = self.string(stmt, 1) else { return }
                    titles["\(kind)/\(id)"] = title
                }
            }
        }
        return titles
    }

    private func loadDayActivities(dayPlanID: String) throws -> [DayActivity] {
        var activities: [DayActivity] = []
        try queryBind("\(Self.dayActivityColumns) WHERE day_plan_id = ? ORDER BY start_minute ASC, end_minute ASC, created_at ASC", bind: { stmt in
            self.bind(stmt, 1, dayPlanID)
        }) { stmt in
            if let activity = self.dayActivity(from: stmt) { activities.append(activity) }
        }
        return activities
    }

    /// The span `recordDayActivity` extends: of the day's spans about
    /// `targetID` doing `kind`, the one that ends latest (the earliest begun
    /// of those). Reads only the thing's own spans.
    private func latestDayActivity(dayPlanID: String, kind: DayActivityKind, targetID: String) throws -> DayActivity? {
        var spans: [DayActivity] = []
        try queryBind("\(Self.dayActivityColumns) WHERE day_plan_id = ? AND target_id = ? ORDER BY start_minute ASC, end_minute ASC, created_at ASC", bind: { stmt in
            self.bind(stmt, 1, dayPlanID)
            self.bind(stmt, 2, targetID)
        }) { stmt in
            if let span = self.dayActivity(from: stmt) { spans.append(span) }
        }
        return spans.filter { $0.kind == kind }.max { $0.endMinute < $1.endMinute }
    }

    /// One span of the log by id. Not private: `delete_day_activity` names the
    /// span it is about before it goes.
    func loadDayActivity(_ id: String) throws -> DayActivity? {
        var activity: DayActivity?
        try queryBind("\(Self.dayActivityColumns) WHERE id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, id)
        }) { stmt in
            activity = self.dayActivity(from: stmt)
        }
        return activity
    }

    private static let dayActivityColumns = """
        SELECT id, day_plan_id, start_minute, end_minute, kind, target_id, title, created_at, updated_at
        FROM day_activities
    """

    private func writeDayActivityRow(_ activity: DayActivity) throws {
        try execBind("""
            INSERT INTO day_activities (id, day_plan_id, start_minute, end_minute, kind, target_id, title, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                day_plan_id = excluded.day_plan_id,
                start_minute = excluded.start_minute,
                end_minute = excluded.end_minute,
                kind = excluded.kind,
                target_id = excluded.target_id,
                title = excluded.title,
                updated_at = excluded.updated_at
        """) { stmt in
            self.bind(stmt, 1, activity.id)
            self.bind(stmt, 2, activity.dayPlanID)
            self.bind(stmt, 3, activity.startMinute)
            self.bind(stmt, 4, activity.endMinute)
            self.bind(stmt, 5, activity.kind.rawValue)
            self.bind(stmt, 6, activity.targetID)
            self.bind(stmt, 7, activity.title)
            self.bind(stmt, 8, activity.createdAt.timeIntervalSinceReferenceDate)
            self.bind(stmt, 9, activity.updatedAt.timeIntervalSinceReferenceDate)
        }
    }

    private func dayActivity(from stmt: OpaquePointer?) -> DayActivity? {
        guard let id = string(stmt, 0), let dayPlanID = string(stmt, 1), let targetID = string(stmt, 5) else { return nil }
        let start = Int(sqlite3_column_int(stmt, 2))
        return DayActivity(
            id: id,
            dayPlanID: dayPlanID,
            startMinute: start,
            endMinute: max(start + 1, Int(sqlite3_column_int(stmt, 3))),
            kind: DayActivityKind(rawValue: string(stmt, 4) ?? "") ?? .reading,
            targetID: targetID,
            title: string(stmt, 6) ?? "",
            createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 7)),
            updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 8))
        )
    }

    private static let dayPlanColumns = """
        SELECT id, plan_date, revision, notes, shutdown_at, created_at, updated_at
        FROM day_plans
    """

    private static let timeBlockColumns = """
        SELECT id, day_plan_id, start_minute, end_minute, title, notes, notebook_id, status,
               revision, superseded_in_revision, deleted_at, created_at, updated_at, source_id, source_ids,
               calendar_event_id, calendar_event_url, goal_id, purpose, location
        FROM time_blocks
    """

    private func writeDayPlanRow(_ plan: DayPlan) throws {
        try execBind("""
            INSERT INTO day_plans (id, plan_date, revision, notes, shutdown_at, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                plan_date = excluded.plan_date,
                revision = excluded.revision,
                notes = excluded.notes,
                shutdown_at = excluded.shutdown_at,
                updated_at = excluded.updated_at
        """) { stmt in
            self.bind(stmt, 1, plan.id)
            self.bind(stmt, 2, plan.date)
            self.bind(stmt, 3, plan.revision)
            self.bind(stmt, 4, plan.notes)
            self.bind(stmt, 5, plan.shutdownAt?.timeIntervalSinceReferenceDate)
            self.bind(stmt, 6, plan.createdAt.timeIntervalSinceReferenceDate)
            self.bind(stmt, 7, plan.updatedAt.timeIntervalSinceReferenceDate)
        }
    }

    /// Not private: a bout's write-up marks its block done in the same
    /// transaction, and a status change is never a redraw, so the row is
    /// written in place through here.
    func writeTimeBlockRow(_ block: TimeBlock) throws {
        try execBind("""
            INSERT INTO time_blocks (
                id, day_plan_id, start_minute, end_minute, title, notes, notebook_id, status,
                revision, superseded_in_revision, deleted_at, created_at, updated_at, source_id, source_ids,
                calendar_event_id, calendar_event_url, goal_id, purpose, location
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                day_plan_id = excluded.day_plan_id,
                start_minute = excluded.start_minute,
                end_minute = excluded.end_minute,
                title = excluded.title,
                notes = excluded.notes,
                notebook_id = excluded.notebook_id,
                status = excluded.status,
                revision = excluded.revision,
                superseded_in_revision = excluded.superseded_in_revision,
                deleted_at = excluded.deleted_at,
                updated_at = excluded.updated_at,
                source_id = excluded.source_id,
                source_ids = excluded.source_ids,
                calendar_event_id = excluded.calendar_event_id,
                calendar_event_url = excluded.calendar_event_url,
                goal_id = excluded.goal_id,
                purpose = excluded.purpose,
                location = excluded.location
        """) { stmt in
            self.bind(stmt, 1, block.id)
            self.bind(stmt, 2, block.dayPlanID)
            self.bind(stmt, 3, block.startMinute)
            self.bind(stmt, 4, block.endMinute)
            self.bind(stmt, 5, block.title)
            self.bind(stmt, 6, block.notes)
            self.bind(stmt, 7, block.notebookID)
            self.bind(stmt, 8, block.status.rawValue)
            self.bind(stmt, 9, block.revision)
            self.bind(stmt, 10, block.supersededInRevision)
            self.bind(stmt, 11, block.deletedAt?.timeIntervalSinceReferenceDate)
            self.bind(stmt, 12, block.createdAt.timeIntervalSinceReferenceDate)
            self.bind(stmt, 13, block.updatedAt.timeIntervalSinceReferenceDate)
            // The first source doubles as the one-source column older clients read.
            self.bind(stmt, 14, block.sourceIDs.first)
            self.bind(stmt, 15, block.sourceIDsJSON)
            self.bind(stmt, 16, block.calendarEventID)
            self.bind(stmt, 17, block.calendarEventURL)
            self.bind(stmt, 18, block.goalID)
            self.bind(stmt, 19, block.purpose.rawValue)
            self.bind(stmt, 20, block.location)
        }
    }

    private func dayPlan(from stmt: OpaquePointer?) -> DayPlan? {
        guard let date = string(stmt, 1) ?? string(stmt, 0) else { return nil }
        return DayPlan(
            date: date,
            revision: max(1, Int(sqlite3_column_int(stmt, 2))),
            notes: string(stmt, 3),
            shutdownAt: optionalDouble(stmt, 4).map { Date(timeIntervalSinceReferenceDate: $0) },
            createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 5)),
            updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 6))
        )
    }

    private func timeBlock(from stmt: OpaquePointer?) -> TimeBlock? {
        guard let id = string(stmt, 0), let dayPlanID = string(stmt, 1), let title = string(stmt, 4) else { return nil }
        return TimeBlock(
            id: id,
            dayPlanID: dayPlanID,
            startMinute: Int(sqlite3_column_int(stmt, 2)),
            endMinute: Int(sqlite3_column_int(stmt, 3)),
            title: title,
            notes: string(stmt, 5),
            location: string(stmt, 19),
            notebookID: string(stmt, 6),
            goalID: string(stmt, 17),
            sourceIDs: TimeBlock.sourceIDs(fromJSON: string(stmt, 14)),
            purpose: TimeBlockPurpose.parse(string(stmt, 18)),
            calendarEventID: string(stmt, 15),
            calendarEventURL: string(stmt, 16),
            status: TimeBlockStatus(rawValue: string(stmt, 7) ?? "") ?? .planned,
            revision: max(1, Int(sqlite3_column_int(stmt, 8))),
            supersededInRevision: optionalInt(stmt, 9),
            deletedAt: optionalDouble(stmt, 10).map { Date(timeIntervalSinceReferenceDate: $0) },
            createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 11)),
            updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 12))
        )
    }
}
