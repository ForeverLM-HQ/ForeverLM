import Foundation

// MARK: - Learning bouts (MCP tools)
//
// The learner's timer: a stretch of learning with a clock on it, ending in a
// write-up of what was learned and what is still unclear, which earns the break
// that follows. See docs/planner-design.md, "A bout on the clock".
//
// An assistant gets exactly what the pane gets, because the write-up is a
// conversation as often as it is a form: a learner who has just spent ninety
// minutes on a paper is more likely to *say* what they got out of it than to
// type it into a box, and the assistant that heard it should be able to file it.
// So `write_up_learning_bout` is the tool that matters here, and the assistant
// is expected to ask both questions — what landed, and what did not — before
// calling it.
//
// Everything goes through StorageService so every client republishes at once.
// Desktop-only
// in the public allowlist, as the calendar tools are: the clock is the Mac's
// own record.

extension MCPDataStore {

    // MARK: Reads

    /// The bout with a clock on it, and the day's finished ones.
    func getLearningBout(date rawDate: String?) async throws -> String {
        let date = try boutDate(rawDate)
        let live = try await notebookFileStorage.loadLiveLearningBout()
        let bouts = try await notebookFileStorage.loadLearningBouts(dayPlanID: date)
            .sorted(by: LearningBout.byRecency)
        var payload: [String: Any] = [
            "date": date,
            "bouts": bouts.map { learningBoutPayload($0) },
            "minutes_learned": bouts.filter { $0.abandonedAt == nil }.reduce(0) { $0 + $1.minutesLearned() },
        ]
        if let live {
            payload["live_bout"] = learningBoutPayload(live)
            payload["guidance"] = Self.boutGuidance(for: live)
        } else {
            payload["live_bout"] = NSNull()
            payload["guidance"] = "No bout is running. start_learning_bout puts a clock on a stretch of learning; pass event_id to run one of the day's calendar events."
        }
        return try jsonString(payload)
    }

    // MARK: Writes

    func startLearningBout(
        eventID rawEventID: String?,
        occurrenceDate rawOccurrence: String?,
        title rawTitle: String?,
        minutes: Int?,
        notebookID: String?,
        sourceIDs rawSourceIDs: [String]?
    ) async throws -> String {
        let eventID = (rawEventID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var title = (rawTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let notebookID = try validatedBoutNotebookID(notebookID)
        let sourceIDs = try validatedBoutSourceIDs(rawSourceIDs)
        var length = minutes ?? LearningBout.defaultMinutes

        if !eventID.isEmpty {
            // An event the day holds: the bout takes its title, and its length
            // from what is left of it (all of it, when it is still ahead).
            let event = try await calendarEvent(eventID: eventID, occurrenceDate: rawOccurrence)
            if title.isEmpty { title = DayNow.displayTitle(event) }
            if minutes == nil {
                let from = max(Date(), event.start)
                length = Int((event.end.timeIntervalSince(from) / 60).rounded(.down))
            }
        }
        guard !title.isEmpty else {
            throw MCPError.invalidInput("A bout needs a title, or an event_id to take one from.")
        }
        do {
            let bout = try await notebookFileStorage.startLearningBout(LearningBout(
                dayPlanID: DayPlan.dateString(for: Date()),
                blockID: nil,
                title: title,
                notebookID: notebookID,
                sourceIDs: sourceIDs,
                plannedMinutes: LearningBout.clampedMinutes(length)
            ))
            let payload: [String: Any] = [
                "bout": learningBoutPayload(bout),
                "message": "Started ‘\(bout.title)’ for \(bout.plannedMinutes) minutes.",
                "guidance": Self.boutGuidance(for: bout),
            ]
            return try jsonString(payload)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
    }

    func endLearningBout(boutID: String?) async throws -> String {
        let id = try boutIdentifier(boutID)
        do {
            let bout = try await notebookFileStorage.endLearningBout(id)
            return try jsonString([
                "bout": learningBoutPayload(bout),
                "message": "Stopped the clock after \(bout.minutesLearned()) minutes.",
                "guidance": Self.boutGuidance(for: bout),
            ])
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
    }

    /// The write-up: what the bout produced, and what it left open. This is
    /// what earns the break.
    func writeUpLearningBout(
        boutID: String?,
        learned rawLearned: String?,
        unclear rawUnclear: String?,
        breakMinutes: Int?
    ) async throws -> String {
        let id = try boutIdentifier(boutID)
        let learned = (rawLearned ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !learned.isEmpty else {
            throw MCPError.invalidInput("learned is required: the write-up is what earns the break. Ask the learner what they got out of the bout, in their own words, before calling this.")
        }
        let unclear = (rawUnclear ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let bout = try await notebookFileStorage.writeUpLearningBout(
                id,
                learned: learned,
                unclear: unclear.isEmpty ? nil : unclear,
                breakMinutes: breakMinutes
            )
            var payload: [String: Any] = [
                "bout": learningBoutPayload(bout),
                "message": "Wrote up ‘\(bout.title)’. A \(bout.breakMinutes)-minute break is earned.",
                "guidance": Self.boutGuidance(for: bout),
            ]
            if unclear.isEmpty {
                payload["note"] = "Nothing was recorded as still unclear. If the learner did name something they do not understand yet, call this again with `unclear` — it is the more useful half of the write-up and what the next bout is for."
            }
            return try jsonString(payload)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
    }

    /// Starts or ends the earned break. Ending one that never started is the
    /// learner declining it and going straight back to work.
    func setLearningBoutBreak(boutID: String?, running: Bool, minutes: Int?) async throws -> String {
        let id = try boutIdentifier(boutID)
        do {
            let bout = running
                ? try await notebookFileStorage.startLearningBoutBreak(id, minutes: minutes)
                : try await notebookFileStorage.endLearningBoutBreak(id)
            let message: String
            if running, let endsAt = bout.breakEndsAt {
                message = "Break started: \(bout.breakMinutes) minutes, until \(Self.clock.string(from: endsAt))."
            } else if bout.breakStartedAt == nil {
                message = "Break declined; the bout is finished."
            } else {
                message = "Break over."
            }
            return try jsonString([
                "bout": learningBoutPayload(bout),
                "message": message,
                "guidance": Self.boutGuidance(for: bout),
            ])
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
    }

    /// Lets a bout go without a write-up. Recorded rather than deleted: an hour
    /// that went nowhere is part of the honest record of the day.
    func abandonLearningBout(boutID: String?) async throws -> String {
        let id = try boutIdentifier(boutID)
        do {
            let bout = try await notebookFileStorage.abandonLearningBout(id)
            return try jsonString([
                "bout": learningBoutPayload(bout),
                "message": "Let ‘\(bout.title)’ go without a write-up. No break is earned.",
            ])
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
    }

    // MARK: Payloads

    func learningBoutPayload(_ bout: LearningBout, now: Date = Date()) -> [String: Any] {
        let phase = bout.phase(now: now)
        var payload: [String: Any] = [
            "bout_id": bout.id,
            "date": bout.dayPlanID,
            "title": bout.title,
            "phase": phase.rawValue,
            "planned_minutes": bout.plannedMinutes,
            "minutes_learned": bout.minutesLearned(now: now),
            "started_at": Self.iso.string(from: bout.startedAt),
            "timer_ends_at": Self.iso.string(from: bout.timerEndsAt),
            "break_minutes": bout.breakMinutes,
            "break_earned": bout.canStartBreak,
        ]
        if let notebookID = bout.notebookID { payload["notebook_id"] = notebookID }
        if !bout.sourceIDs.isEmpty {
            payload["source_ids"] = bout.sourceIDs
            payload["source_links"] = bout.sourceIDs.map {
                "\(StudioEntityLink.productScheme)://source/\(StudioEntityLink.encode($0))"
            }
        }
        if let endedAt = bout.endedAt { payload["ended_at"] = Self.iso.string(from: endedAt) }
        if let learned = bout.learned { payload["learned"] = learned }
        if let unclear = bout.unclear { payload["unclear"] = unclear }
        if let writtenAt = bout.writtenAt { payload["written_at"] = Self.iso.string(from: writtenAt) }
        if let breakStartedAt = bout.breakStartedAt {
            payload["break_started_at"] = Self.iso.string(from: breakStartedAt)
            if let endsAt = bout.breakEndsAt { payload["break_ends_at"] = Self.iso.string(from: endsAt) }
        }
        if let breakEndedAt = bout.breakEndedAt { payload["break_ended_at"] = Self.iso.string(from: breakEndedAt) }
        if let abandonedAt = bout.abandonedAt { payload["abandoned_at"] = Self.iso.string(from: abandonedAt) }
        if phase == .learning {
            payload["remaining_minutes"] = Int((Double(bout.remainingSeconds(now: now)) / 60).rounded(.towardZero))
        }
        return payload
    }

    /// What an assistant should do next about this bout. The rules the tool
    /// schema cannot carry: never write the learner's write-up for them, and
    /// never hand out a break that has not been earned.
    nonisolated static func boutGuidance(for bout: LearningBout, now: Date = Date()) -> String {
        switch bout.phase(now: now) {
        case .learning:
            let remaining = max(0, bout.remainingSeconds(now: now) / 60)
            return bout.isOverrunning(now: now)
                ? "The clock ran out \(-bout.remainingSeconds(now: now) / 60) minutes ago and the bout is still open — it stays open until the learner says otherwise. When they stop, ask what they learned and what they still don't understand, then call write_up_learning_bout with their words."
                : "\(remaining) minutes left. When the bout ends, ask what they learned and what they still don't understand, then call write_up_learning_bout with their own words — not a summary you wrote."
        case .writing:
            return "The clock has stopped and the write-up is owed. Ask two questions — what did you learn, and what don't you understand yet — and file the answers with write_up_learning_bout. The break is not earned until you do."
        case .earned:
            return "Written up. A \(bout.breakMinutes)-minute break is earned: start it with set_learning_bout_break running=true, or end it unstarted if the learner would rather carry on."
        case .resting:
            let left = bout.breakRemainingSeconds(now: now) ?? 0
            return left > 0
                ? "On a break, \(max(0, left / 60)) minutes left. Leave them alone until it ends."
                : "The break has run out. set_learning_bout_break running=false when the learner is back."
        case .complete:
            return "Finished. start_learning_bout begins the next one."
        case .abandoned:
            return "Let go without a write-up, so no break was earned."
        }
    }

    // MARK: Input

    private func boutIdentifier(_ raw: String?) throws -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPError.invalidInput("bout_id is required. get_learning_bout returns the live one.")
        }
        return trimmed
    }

    private func boutDate(_ raw: String?) throws -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "today" {
            return DayPlan.dateString(for: Date())
        }
        guard DayPlan.isValidDateString(trimmed) else {
            throw MCPError.invalidInput("date must be YYYY-MM-DD or \"today\", not \"\(trimmed)\".")
        }
        return trimmed
    }

    private func validatedBoutNotebookID(_ raw: String?) throws -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard try knowledgeStore().loadLearningGoal(trimmed) != nil else {
            throw MCPError.notFound("No Notebook with id \(trimmed).")
        }
        return trimmed
    }

    private func validatedBoutSourceIDs(_ raw: [String]?) throws -> [String] {
        let ids = SourceIDList.normalized(raw ?? [])
        for id in ids {
            guard try knowledgeStore().sourceExists(id) else {
                throw MCPError.notFound("No source with id \(id).")
            }
        }
        return ids
    }

    /// The sources named by a tool call: `source_ids` (a list), with the
    /// one-source `source_id` of builds up to 99 still accepted and folded
    /// in. Nil when neither was passed.
    static func sourceIDArguments(_ arguments: [String: Any]) -> [String]? {
        let list = arguments["source_ids"] as? [String]
        let single = arguments["source_id"] as? String
        guard list != nil || single != nil else { return nil }
        return (list ?? []) + [single].compactMap { $0 }
    }

    private static let iso = ISO8601DateFormatter()

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
