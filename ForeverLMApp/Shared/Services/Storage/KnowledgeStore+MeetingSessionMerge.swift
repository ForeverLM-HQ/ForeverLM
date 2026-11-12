import Foundation

/// One sitting, one session.
///
/// A free Zoom account ends a call after forty minutes, the host starts a new
/// meeting, and the recording and transcript of each call reach the library
/// on their own: two sessions of the series for one standup (product owner,
/// 2026-09-19: "there should just be 1 a day since there is only 1 standup a
/// day. sometimes zoom kicks us out since it's the free version; so then i
/// start a new one. you should merge those transcripts").
///
/// The rule this holds: two sessions of one series are the same sitting when
/// they fall on the same local calendar day and the later one starts within
/// `window` of the first. Four hours, because a reconnect is minutes after the
/// call it continues and a standup that runs over into a second scheduled slot
/// is an hour or two, while a morning session and an afternoon one of the same
/// series are two meetings; the day boundary keeps a late evening call and the
/// next morning's apart even when they are closer than the window. Explicit
/// merges — the series' menu and `merge_meeting_sessions` — use the day alone,
/// because there the learner has said what the sessions are.
///
/// Deterministic on purpose: which rows are one meeting is identity, and no
/// model call decides it (AGENTS.md, "never let an LLM decide identity").
enum MeetingSessionContinuation {
    /// How long after the first call of a sitting a later call may start and
    /// still be the same meeting under the automatic rule.
    static let window: TimeInterval = 4 * 60 * 60

    struct Session: Equatable, Hashable, Sendable {
        let id: String
        let startedAt: Date
    }

    /// One session's stored document, as a part of the merged one.
    struct Part: Equatable, Sendable {
        var content: String?
        var startedAt: Date
        var title: String
    }

    /// The sessions grouped into sittings, each ordered by start, the first
    /// being the one that survives a merge. A session joins the open run when
    /// it is on the same local day as the run's first session and starts
    /// within `window` of it; a nil window is the whole day.
    static func runs(
        _ sessions: [Session],
        window: TimeInterval? = window,
        calendar: Calendar = .current
    ) -> [[Session]] {
        let ordered = sessions.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id < $1.id
        }
        var runs: [[Session]] = []
        for session in ordered {
            if let current = runs.last, let first = current.first,
               calendar.isDate(session.startedAt, inSameDayAs: first.startedAt),
               window.map({ session.startedAt.timeIntervalSince(first.startedAt) <= $0 }) ?? true {
                runs[runs.count - 1].append(session)
            } else {
                runs.append([session])
            }
        }
        return runs
    }

    /// The runs that hold more than one session: what a merge folds.
    static func mergeGroups(
        _ sessions: [Session],
        window: TimeInterval? = window,
        calendar: Calendar = .current
    ) -> [[Session]] {
        runs(sessions, window: window, calendar: calendar).filter { $0.count > 1 }
    }

    /// When a session's meeting started, if its row says so to the minute:
    /// the time in its session key (the Zoom watcher, the folder importers
    /// and `import_meeting_transcript_files` key a session that way), or, for
    /// a session not keyed as `meeting://` at all — a Zoom cloud recording
    /// filed from its share link, a notes page — the moment it is dated,
    /// which for a meeting is `occurred_at`. A `meeting://` session keyed by
    /// day alone (a Drive folder's date-led files) answers nil: two of those
    /// on one day are two files at no hour, and the automatic rule never
    /// folds them.
    static func knownStart(of article: StudioArticle, calendar: Calendar = .current) -> Date? {
        if let start = MeetingCalendarEvent.knownStart(of: article, calendar: calendar) {
            return start
        }
        // A `meeting://` session whose key spells no time. Checked on the
        // string, not through URLComponents, which refuses a group id with a
        // colon in it (`zoom:examplefellowship.zoom.us`).
        if article.url.hasPrefix("meeting://") {
            return nil
        }
        return article.dateAdded
    }

    /// The line written between two parts of one section: the moment the
    /// later call began, in the learner's clock.
    static func separator(reconnectedAt: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return "—— Reconnected at \(formatter.string(from: reconnectedAt)) ——"
    }

    /// The merged document: one `## Transcript`, `## Notes`, `## Chat` and
    /// `## Recording` section each, every part's text in start order with a
    /// reconnection line between parts, under the earliest part's title.
    /// Sections keep `MeetingContent`'s order, so a reader and the action-item
    /// extractor read the result exactly as they read a single session.
    static func mergedContent(_ parts: [Part], calendar: Calendar = .current) -> String {
        let ordered = parts.sorted { $0.startedAt < $1.startedAt }
        guard let first = ordered.first else { return "" }
        var content: String?
        for kind in MeetingArtifactKind.allCases.sorted(by: { $0.sortRank < $1.sortRank }) {
            var pieces: [String] = []
            for part in ordered {
                guard let text = sectionText(kind, in: part.content) else { continue }
                if !pieces.isEmpty {
                    pieces.append(separator(reconnectedAt: part.startedAt, calendar: calendar))
                }
                pieces.append(text)
            }
            guard !pieces.isEmpty else { continue }
            content = MeetingContent.inserting(
                section: kind,
                text: pieces.joined(separator: "\n\n"),
                into: content,
                title: first.title
            )
        }
        return content ?? "# \(first.title)"
    }

    /// One section of a stored session. A Zoom cloud session stores the bare
    /// transcript with no headings at all; that whole text is its transcript.
    static func sectionText(_ kind: MeetingArtifactKind, in content: String?) -> String? {
        if let text = MeetingContent.text(for: kind, in: content) { return text }
        guard kind == .transcript, let content else { return nil }
        let hasSections = MeetingArtifactKind.allCases.contains { MeetingContent.contains(section: $0, in: content) }
        guard !hasSections else { return nil }
        var lines = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if let firstLine = lines.first, firstLine.hasPrefix("# "), lines.count > 1 {
            lines.removeFirst()
        }
        let bare = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return bare.isEmpty ? nil : bare
    }
}

/// What one merge did, for the caller's sentence and its follow-up work.
struct MeetingSessionMergeOutcome: Equatable, Sendable {
    let groupID: String
    let survivorID: String
    let survivorTitle: String
    let absorbedIDs: [String]
    /// The local day the sitting fell on, `YYYY-MM-DD`.
    let date: String
}

extension KnowledgeStore {

    /// A session of a series and when it started, for the runs.
    struct MergeableMeetingSession {
        let article: StudioArticle
        let startedAt: Date
    }

    /// The series' id and every alias a merge pointed at it, so a session
    /// filed under a retired id is still the series' session.
    func meetingGroupIdentityIDs(of groupID: String) throws -> [String] {
        var ids: Set<String> = [groupID]
        for id in try loadMeetingGroups().keys {
            if try canonicalMeetingGroupID(id) == groupID { ids.insert(id) }
        }
        return ids.sorted()
    }

    /// The active sessions of a series, without content.
    func activeMeetingSessions(groupID: String) throws -> [StudioArticle] {
        let groupIDs = try meetingGroupIdentityIDs(of: groupID)
        let placeholders = groupIDs.map { _ in "?" }.joined(separator: ", ")
        var ids: [String] = []
        try queryBind("""
            SELECT DISTINCT id FROM source_projection
            WHERE source_type = 'meeting' AND status = 'active' AND parent_group IN (\(placeholders))
            ORDER BY date_added, id
        """, bind: { stmt in
            for (offset, id) in groupIDs.enumerated() { bind(stmt, offset + 1, id) }
        }) { stmt in
            if let id = string(stmt, 0) { ids.append(id) }
        }
        return try ids.compactMap { try loadSourceWithoutContent($0) }
    }

    /// The sitting `sourceID` belongs to under the automatic rule, survivor
    /// first, or nil when the session stands alone: it is not a ready, active
    /// meeting session with a start known to the minute, or no other such
    /// session of its series began on the same day within the window.
    func meetingSessionContinuationRun(
        for sourceID: String,
        window: TimeInterval = MeetingSessionContinuation.window,
        calendar: Calendar = .current
    ) throws -> [String]? {
        guard let article = try loadSourceWithoutContent(sourceID),
              article.sourceType == .meeting, article.status == .active, article.state == .ready,
              let rawGroupID = article.parentGroup,
              MeetingSessionContinuation.knownStart(of: article, calendar: calendar) != nil else { return nil }
        let groupID = try canonicalMeetingGroupID(rawGroupID)
        let candidates = try activeMeetingSessions(groupID: groupID)
            .filter { $0.state == .ready }
            .compactMap { session -> MeetingSessionContinuation.Session? in
                guard let start = MeetingSessionContinuation.knownStart(of: session, calendar: calendar) else { return nil }
                return .init(id: session.id, startedAt: start)
            }
        let runs = MeetingSessionContinuation.runs(candidates, window: window, calendar: calendar)
        guard let run = runs.first(where: { $0.contains { $0.id == sourceID } }), run.count > 1 else { return nil }
        return run.map(\.id)
    }

    /// Every day of a series that holds more than one session, each day's
    /// sessions survivor first — the explicit rule, the whole day and no
    /// window. `date` (`YYYY-MM-DD`) limits it to one day. A session still
    /// being transcribed is left out: its transcript is on its way, and
    /// folding the row before it lands would lose what lands.
    func sameDayMeetingSessionRuns(
        groupID: String,
        date: String? = nil,
        calendar: Calendar = .current
    ) throws -> [[String]] {
        let candidates = try activeMeetingSessions(groupID: groupID)
            .filter { $0.state == .ready || $0.state == .error }
            .map { session in
                MeetingSessionContinuation.Session(
                    id: session.id,
                    startedAt: MeetingSessionContinuation.knownStart(of: session, calendar: calendar) ?? session.dateAdded
                )
            }
        return MeetingSessionContinuation.mergeGroups(candidates, window: nil, calendar: calendar)
            .filter { run in
                guard let date, let first = run.first else { return true }
                return DayPlan.dateString(for: first.startedAt, calendar: calendar) == date
            }
            .map { $0.map(\.id) }
    }

    /// Fold the sessions into the one that started first, in one transaction.
    ///
    /// The survivor keeps its id, URL, title and date; its document becomes
    /// every part's sections in start order with a reconnection line between
    /// parts (`MeetingSessionContinuation.mergedContent`). Each other session
    /// hands over what `archiveMeetingSessionDuplicate` hands over — Notebook
    /// items, review sessions, schedule placements, highlights, memory items,
    /// group membership — and, unlike that fold of one file read twice, its
    /// artifacts move too: a second call is a second recording and a second
    /// transcript file, and the survivor lists them. The blocks the Planner
    /// drew for either call point at the survivor. Both sessions' action items
    /// are dropped, because the survivor's transcript is new and the extractor
    /// reads it again. The absorbed rows are archived rather than deleted and
    /// keep their URLs: that is what every ingest route checks before filing,
    /// so the same recording or caption file is never filed — or appended — a
    /// second time, on this Mac or on the other one the archived row syncs to.
    ///
    /// Throws when the ids are not all active meeting sessions of one series,
    /// or when one is still being transcribed. Nil when fewer than two
    /// distinct ids were named.
    func mergeMeetingSessions(
        _ ids: [String],
        calendar: Calendar = .current,
        now: Date = Date()
    ) throws -> MeetingSessionMergeOutcome? {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        guard unique.count >= 2 else { return nil }

        var sessions: [MergeableMeetingSession] = []
        var groupIDs = Set<String>()
        for id in unique {
            guard let article = try loadSourceWithoutContent(id) else {
                throw KnowledgeStoreError.invalidData("Meeting session not found: \(id)")
            }
            guard article.sourceType == .meeting else {
                throw KnowledgeStoreError.invalidData("'\(article.title)' (\(id)) is not a meeting session.")
            }
            guard article.status == .active else {
                throw KnowledgeStoreError.invalidData("'\(article.title)' (\(id)) is archived; only active sessions merge.")
            }
            guard article.state == .ready || article.state == .error else {
                throw KnowledgeStoreError.invalidData(
                    "'\(article.title)' (\(id)) is still being transcribed; merge it once its transcript is in."
                )
            }
            guard let rawGroupID = article.parentGroup else {
                throw KnowledgeStoreError.invalidData("'\(article.title)' (\(id)) belongs to no meeting series.")
            }
            groupIDs.insert(try canonicalMeetingGroupID(rawGroupID))
            sessions.append(MergeableMeetingSession(
                article: article,
                startedAt: MeetingSessionContinuation.knownStart(of: article, calendar: calendar) ?? article.dateAdded
            ))
        }
        guard groupIDs.count == 1, let groupID = groupIDs.first else {
            throw KnowledgeStoreError.invalidData("The sessions belong to different meeting series; merge one series' sessions at a time.")
        }
        sessions.sort {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.article.id < $1.article.id
        }

        var survivor = sessions[0].article
        var parts: [MeetingSessionContinuation.Part] = []
        for session in sessions {
            parts.append(MeetingSessionContinuation.Part(
                content: try loadSourceContent(session.article.id),
                startedAt: session.startedAt,
                title: session.article.title
            ))
        }
        let merged = MeetingSessionContinuation.mergedContent(parts, calendar: calendar)
        let absorbed = sessions.dropFirst().map(\.article.id)

        try exec("BEGIN IMMEDIATE")
        do {
            for id in absorbed {
                try archiveSourceIdentityDuplicateRows(
                    id, replacingWith: survivor.id, discardingMeetingArtifacts: false, at: now
                )
                try repointTimeBlockSources(from: id, to: survivor.id, now: now)
                try execBind("DELETE FROM meeting_action_items WHERE source_id = ?") { stmt in
                    bind(stmt, 1, id)
                }
                try clearSourceText(id)
            }
            // The sitting's series is the survivor's. A part moved into the
            // series by hand before its rows learnt to move with it still
            // names its old series on its recording and transcript rows,
            // which a listing by series would miss and a Delete Series of
            // the old folder would take.
            let identityIDs = try meetingGroupIdentityIDs(of: groupID)
            let placeholders = identityIDs.map { _ in "?" }.joined(separator: ", ")
            try execBind(
                "UPDATE meeting_artifacts SET group_id = ? WHERE source_id = ? AND group_id NOT IN (\(placeholders))"
            ) { stmt in
                bind(stmt, 1, groupID)
                bind(stmt, 2, survivor.id)
                for (offset, id) in identityIDs.enumerated() { bind(stmt, offset + 3, id) }
            }
            try execBind("DELETE FROM meeting_action_items WHERE source_id = ?") { stmt in
                bind(stmt, 1, survivor.id)
            }
            survivor.content = merged
            survivor.wordCount = merged.split(separator: " ").count
            survivor.state = .ready
            survivor.errorMessage = nil
            try persistSourceRows(survivor)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return MeetingSessionMergeOutcome(
            groupID: groupID,
            survivorID: survivor.id,
            survivorTitle: survivor.title,
            absorbedIDs: absorbed,
            date: DayPlan.dateString(for: sessions[0].startedAt, calendar: calendar)
        )
    }

    /// Every block, in any column, that names `oldID` names `newID` instead,
    /// once; each touched day is queued for sync. Inside the caller's
    /// transaction. Returns the day plans touched.
    @discardableResult
    func repointTimeBlockSources(from oldID: String, to newID: String, now: Date) throws -> Set<String> {
        var rows: [(id: String, planID: String, sourceIDs: [String])] = []
        try queryBind("""
            SELECT id, day_plan_id, source_id, source_ids FROM time_blocks
            WHERE source_id = ? OR EXISTS (
                SELECT 1 FROM json_each(
                    CASE WHEN json_valid(time_blocks.source_ids) THEN time_blocks.source_ids ELSE '[]' END
                ) WHERE value = ?
            )
        """, bind: { stmt in
            bind(stmt, 1, oldID)
            bind(stmt, 2, oldID)
        }) { stmt in
            guard let id = string(stmt, 0), let planID = string(stmt, 1) else { return }
            let single = string(stmt, 2)
            let raw = string(stmt, 3) ?? "[]"
            var ids = (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
            if ids.isEmpty, let single, !single.isEmpty { ids = [single] }
            rows.append((id, planID, ids))
        }
        var planIDs = Set<String>()
        for row in rows {
            var seen = Set<String>()
            let rewritten = row.sourceIDs.compactMap { id -> String? in
                let resolved = id == oldID ? newID : id
                return seen.insert(resolved).inserted ? resolved : nil
            }
            try execBind("UPDATE time_blocks SET source_id = ?, source_ids = ?, updated_at = ? WHERE id = ?") { stmt in
                bind(stmt, 1, rewritten.first)
                bind(stmt, 2, jsonString(from: rewritten))
                bind(stmt, 3, now.timeIntervalSinceReferenceDate)
                bind(stmt, 4, row.id)
            }
            planIDs.insert(row.planID)
        }
        for planID in planIDs.sorted() {
            try touchDayPlan(planID, at: now)
        }
        return planIDs
    }
}
