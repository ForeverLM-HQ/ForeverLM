// Review session links, learning goals, schedule days and group titles.

import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif

extension StudioViewModel {

    func loadReviewSessionLinks() async {
        do {
            reviewSessionLinks = try await storage.loadReviewSessionLinks()
            sourceReviewedAt = try await storage.sourceReviewDates()
            learningGoalLinkedSourceIds = try await storage.sourceIdsWithReviewSession()
            learningGoalEligibleSourceIds = try await storage.sourceIdsWithLinkedChatSession()
        } catch {
            logger.error("Failed to load review session links: \(error.localizedDescription)")
        }
    }

    func saveReviewSessionLink(
        title: String,
        url: String,
        sourceIDs: [String]? = nil,
        showSessionsPanel: Bool = true,
        mergeWithExistingSources: Bool = false
    ) async {
        do {
            let resolvedSourceIDs = try await reviewSessionSourceIDsForSave(
                url: url,
                sourceIDs: sourceIDs ?? contextSourceIds,
                mergeWithExistingSources: mergeWithExistingSources
            )
            _ = try await storage.saveReviewSessionLink(
                title: title,
                url: url,
                sourceIDs: resolvedSourceIDs
            )
            reviewSessionLinks = try await storage.loadReviewSessionLinks()
            sourceReviewedAt = try await storage.sourceReviewDates()
            learningGoalLinkedSourceIds = try await storage.sourceIdsWithReviewSession()
            learningGoalEligibleSourceIds = try await storage.sourceIdsWithLinkedChatSession()
            if showSessionsPanel {
                isChatTabActive = true
                revealReviewSessionSidebar()
                searchText = ""
            }
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to save review session link: \(error.localizedDescription)")
        }
    }

    func reviewSessionSourceIDsForSave(url: String, sourceIDs: [String], mergeWithExistingSources: Bool) async throws -> [String] {
        guard mergeWithExistingSources else { return sourceIDs }
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let links = try await storage.loadReviewSessionLinks()
        guard let existing = links.first(where: { ($0.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == trimmedURL }) else {
            return sourceIDs
        }

        var merged = existing.sourceIDs
        for sourceID in sourceIDs where !merged.contains(sourceID) {
            merged.append(sourceID)
        }
        return merged
    }

    func loadReviewSessionExchanges(_ sessionID: String) async {
        do {
            reviewSessionExchanges[sessionID] = try await storage.loadReviewSessionExchanges(sessionID: sessionID)
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to load review session transcript: \(error.localizedDescription)")
        }
    }

    func linkedSources(for session: ReviewSessionRecord) -> [StudioArticle] {
        // By id, not a scan: the sessions list calls this per visible row, and
        // a linear search of the library per source id made every list render
        // O(rows × sources).
        let byID = articlesById
        return session.sourceIDs.compactMap { byID[$0] }
    }

    var activeLearningGoal: LearningGoalRecord? {
        let now = Date()
        return learningGoals.first { goal in
            goal.lifecycleStatus == .active && goal.startAt <= now && goal.endAt >= now
        } ?? learningGoals.first { $0.lifecycleStatus == .active }
            ?? learningGoals.first
    }

    func learningGoalSource(for sourceID: String) -> StudioArticle? {
        articles.first { $0.id == sourceID }
    }

    func scheduleDays(for goal: LearningGoalRecord, containing date: Date) -> [ScheduleDay] {
        // The schedule reads the shared-placement model (`scheduled_sources`), filtered
        // to the placements tagged with this goal — the same model every schedule write
        // (add, move, mark-done, clear) mutates. `goal.items` (`learning_goal_items`)
        // remains the Notebook's source pool / companion-quiz state, not the schedule.
        unifiedScheduleDays(containing: date, goalID: goal.id)
    }

    /// The planned week containing `date`: every shared placement, tagged or
    /// not, bucketed by its planned day, each item carrying the Goals it serves.
    /// Pure/in-memory — safe to call from view bodies.
    ///
    /// **Only deliberate placements appear here.** A placement the app created
    /// by itself to anchor activity (`isAutomatic`) is consumption history, not
    /// a plan: it belongs to the History pane in Settings, and surfacing it here
    /// once made opening a source for two seconds read as a completed day.
    func unifiedScheduleDays(
        containing date: Date,
        goalID: String? = nil,
        includesFollowingDay: Bool = false
    ) -> [ScheduleDay] {
        // Memoized: the reader's idle view, the chat panel's welcome and the
        // planner all ask for the same week from their bodies, in every open
        // window, whenever any source changes — and opening a video changes a
        // source. Walking the whole schedule for each of those asks was most of
        // a click's main-thread cost. Every input the walk reads is in the key,
        // and reading the key's observable inputs here is what keeps a caller's
        // body subscribed to them on a cache hit.
        let calendar = Calendar.current
        let key = ScheduleDaysCacheKey(
            dayStart: calendar.startOfDay(for: date),
            goalID: goalID,
            includesFollowingDay: includesFollowingDay,
            today: calendar.startOfDay(for: Date()),
            inputsRevision: scheduleInputsRevision,
            articlesRevision: articlesRevision,
            linkedSourceIDs: learningGoalLinkedSourceIds,
            courseMetadataCount: courseMetadata.count,
            bookTitleCount: bookTitles.count,
            videoPlaylistCount: videoPlaylistMetadata.count,
            meetingMetadataCount: meetingMetadata.count
        )
        if let cached = unifiedScheduleDaysCache, cached.key == key {
            return cached.days
        }
        let days = computeUnifiedScheduleDays(
            containing: date,
            goalID: goalID,
            includesFollowingDay: includesFollowingDay,
            calendar: calendar
        )
        unifiedScheduleDaysCache = (key, days)
        return days
    }

    struct ScheduleDaysCacheKey: Equatable {
        let dayStart: Date
        let goalID: String?
        let includesFollowingDay: Bool
        let today: Date
        let inputsRevision: Int
        let articlesRevision: Int
        let linkedSourceIDs: Set<String>
        let courseMetadataCount: Int
        let bookTitleCount: Int
        let videoPlaylistCount: Int
        let meetingMetadataCount: Int
    }

    private func computeUnifiedScheduleDays(
        containing date: Date,
        goalID: String?,
        includesFollowingDay: Bool,
        calendar: Calendar
    ) -> [ScheduleDay] {
        let today = calendar.startOfDay(for: Date())
        let reviewDays = scheduleWeekDayStarts(
            containing: date,
            calendar: calendar,
            includesFollowingDay: includesFollowingDay
        )
        let articlesByID = articlesById
        var entriesByDay: [Date: [(order: Date, item: SchedulePlanItem)]] = [:]
        let goalsByID = Dictionary(uniqueKeysWithValues: learningGoals.map { ($0.id, $0) })
        for entry in scheduledSources {
            // Activity anchors are not plans. See the note above.
            if entry.isAutomatic { continue }
            // When scoped to a goal, only its tagged placements appear.
            if let goalID, !entry.goalIDs.contains(goalID) { continue }
            // Completing or archiving a Goal should stop its unfinished future
            // work from cluttering the active Schedule. Completed history remains,
            // as do placements shared with any active goal or with no known goal.
            if !entry.placement.isCompleted {
                let knownMemberships = entry.goalIDs.compactMap { goalsByID[$0] }
                if !knownMemberships.isEmpty,
                   knownMemberships.allSatisfy({ $0.lifecycleStatus != .active }) {
                    continue
                }
            }
            let plannedDay = calendar.startOfDay(for: entry.placement.plannedAt)
            guard reviewDays.contains(plannedDay) else { continue }
            // A placement whose source is archived or deleted resolves to nil here
            // (only active sources live in `articlesByID`). Such orphans must never
            // surface on the schedule, so drop them rather than render a "Missing
            // source" ghost row.
            guard let article = articlesByID[entry.placement.sourceID] else { continue }
            let groupTitle = sourceGroupTitle(for: article)
            let subtitle: String = {
                if article.sourceType == .book { return "Book chapter" }
                if let groupTitle, !groupTitle.isEmpty { return groupTitle }
                return article.domain
            }()
            // Kept for the "already opened this" hint on a pending row. It is a
            // hint only: completion never follows from it.
            let plannedActivityKinds = entry.activityDays
                .filter { calendar.isDate($0.dayStart, inSameDayAs: plannedDay) }
                .reduce(into: Set<SourceActivityKind>()) { $0.formUnion($1.kinds) }
            let item = SchedulePlanItem(
                id: entry.placement.id,
                sourceID: entry.placement.sourceID,
                title: playlistAwareTitle(for: article),
                subtitle: subtitle,
                groupTitle: groupTitle,
                plannedDate: plannedDay,
                // Completion is a fact the learner or a graded review produced.
                isCompleted: entry.placement.isCompleted,
                canMarkDone: true,
                hasLinkedChat: learningGoalLinkedSourceIds.contains(entry.placement.sourceID),
                isMissingSource: false,
                activityKinds: plannedActivityKinds,
                goalTags: entry.goalTags
            )
            entriesByDay[plannedDay, default: []].append((entry.placement.plannedAt, item))
        }
        return reviewDays.map { day in
            let items = (entriesByDay[day] ?? [])
                .sorted { $0.order < $1.order }
                .map(\.item)
            return ScheduleDay(
                date: day,
                items: items,
                isToday: calendar.isDate(day, inSameDayAs: today),
                isPast: day < today
            )
        }
    }

    /// A human-readable name for a source group, resolved from the group key
    /// alone — for callers that hold a group without holding one of its
    /// sources, such as a drag payload.
    ///
    /// Books, courses, meetings, and video playlists are all keyed by an opaque
    /// ID with the title kept in metadata, so the key itself must never reach
    /// the UI. Nil rather than the raw key when nothing readable resolves: a
    /// caller that has no name to show should say so, not show an identifier.
    ///
    /// Dictionary lookups only, in the order the group kinds are keyed. This is
    /// read during a drag, where a scan of every group per render would show up.
    func groupDisplayTitle(_ groupName: String) -> String? {
        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let bookTitle = storedBookDisplayTitle(for: trimmed) {
            return bookTitle
        }
        if let courseTitle = courseMetadata[trimmed]?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !courseTitle.isEmpty {
            return courseTitle
        }
        if let meetingTitle = meetingMetadata[canonicalMeetingGroupID(trimmed)]?.title?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !meetingTitle.isEmpty {
            return meetingTitle
        }
        if let playlistTitle = videoPlaylistMetadata[trimmed]?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !playlistTitle.isEmpty {
            return playlistTitle
        }
        return Self.humanVisibleGroupTitle(trimmed)
    }

    func sourceGroupTitle(for article: StudioArticle) -> String? {
        guard let groupName = article.parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines),
              !groupName.isEmpty else { return nil }

        if article.sourceType == .book {
            return storedBookDisplayTitle(for: groupName) ?? Self.humanVisibleGroupTitle(groupName)
        }

        if allCourseGroupNames.contains(groupName) {
            return courseDisplayName(groupName)
        }

        if article.sourceType == .video,
           let playlistTitle = videoPlaylistMetadata[groupName]?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !playlistTitle.isEmpty {
            return playlistTitle
        }
        return Self.humanVisibleGroupTitle(groupName)
    }

    nonisolated static func humanVisibleGroupTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !looksLikeOpaqueIdentifier(trimmed) else { return nil }
        return trimmed
    }

    nonisolated static func looksLikeOpaqueIdentifier(_ value: String) -> Bool {
        if UUID(uuidString: value) != nil {
            return true
        }
        return value.range(of: #"^(src_)?[A-Fa-f0-9]{24,}$"#, options: .regularExpression) != nil
    }

    /// A source's title as a list shows it: a playlist video carries its place
    /// in the playlist, everything else its stored title.
    func playlistAwareTitle(for article: StudioArticle) -> String {
        guard article.sourceType == .video,
              let groupName = article.parentGroup,
              let playlistTitle = videoPlaylistMetadata[groupName]?.title else {
            return article.title
        }
        return Self.videoPlaylistDisplayTitle(
            storedTitle: article.title,
            playlistTitle: playlistTitle,
            sortIndex: article.courseSortIndex
        )
    }

    func scheduleAssignableDays(goalID: String, containing date: Date = Date()) -> [Date] {
        guard learningGoals.contains(where: { $0.id == goalID }) else { return [] }
        return scheduleWeekDayStarts(containing: date, calendar: Calendar.current)
    }

    func startScheduleItem(_ item: SchedulePlanItem) async {
        guard !item.isMissingSource else { return }
        setContextSources([item.sourceID])
        showReaderPanel = true
        isChatTabActive = true
        readerPoppedOut = false
        clearReaderSurfaces()
        await selectArticle(item.sourceID)
    }

    func openSourceInReader(_ sourceID: String) async {
        let shouldRefreshVisibleChat = isChatTabActive
        setContextSources([sourceID])
        showReaderPanel = true
        readerPoppedOut = false
        clearReaderSurfaces()
        if shouldRefreshVisibleChat {
            requestResetReviewChat()
        }
        await selectArticle(sourceID)
    }

    /// Opens a source from a planner surface that is itself sitting in the reader
    /// column — a Notebook's source pool. Releasing the surface is the whole point:
    /// `selectArticle` alone moves the selection while Notebooks keeps the column,
    /// so the click looks dead. `workbenchNotebookID` is untouched, so the rail
    /// keeps the notebook active and its chats scoped while you read.
    ///
    /// Unlike `openSourceInReader`, this leaves chat context and the open chat
    /// alone: clicking a source in the pool is reader navigation, not a request to
    /// re-aim the chat at it. Dragging to chat and "Start review" still do that.
    func revealSourceInReader(_ sourceID: String) async {
        showReaderPanel = true
        readerPoppedOut = false
        clearReaderSurfaces()
        await selectArticle(sourceID)
    }

    func readerBestSearchMatch(for sourceId: String) -> SourceSearchBestMatch? {
        readerSearchBestMatches[sourceId]
            ?? sourceSearchResults.first { $0.article.id == sourceId }?.bestMatch
    }

    func scheduleWeekDayStarts(
        containing date: Date,
        calendar: Calendar,
        includesFollowingDay: Bool = false
    ) -> [Date] {
        let weekStart = mondayWeekStart(containing: date, calendar: calendar)
        let dayCount = includesFollowingDay ? 8 : 7
        return (0..<dayCount).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: weekStart)
        }
    }

    func mondayWeekStart(containing date: Date, calendar: Calendar) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: dayStart)
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: dayStart) ?? dayStart
    }

    func loadLearningGoals() async {
        do {
            learningGoals = try await storage.loadLearningGoals()
            // Which notebooks follow which course moves with the notebooks.
            if let followers = try? await storage.loadCourseFollowers(), followers != courseFollowerNotebookIDs {
                courseFollowerNotebookIDs = followers
            }
            if !hasLoadedLearningGoalsOnce { hasLoadedLearningGoalsOnce = true }
            if notebookSyncBaseline == nil { notebookSyncBaseline = learningGoals }
            if activeNotebookId == nil || !notebooks.contains(where: { $0.id == activeNotebookId }) {
                activeNotebookId = notebooks.first?.id
            }
            // A notebook deleted on another device, or one a relaunch brought
            // back whose record is gone, is open nowhere.
            closeNotebooksMissingFromLibrary()
            // What a notebook holds may have changed: one made without a name
            // may be ready to be named (`NotebookNaming`).
            nameReadyNotebooks()
            scheduledSources = try await storage.loadScheduledSources()
            learningGoalLinkedSourceIds = try await storage.sourceIdsWithReviewSession()
            learningGoalEligibleSourceIds = try await storage.sourceIdsWithLinkedChatSession()
        } catch {
            logger.error("Failed to load schedule: \(error.localizedDescription)")
        }
    }

    /// Approve or reject discovered sources on a Learning Companion goal, then
    /// refresh so the card reflects the new state. Approved sources enter the daily
    /// quiz rotation; rejected ones are tombstoned and never re-proposed.
    func setCompanionReviewState(goalID: String, sourceIDs: [String], approved: Bool) async {
        guard !sourceIDs.isEmpty else { return }
        do {
            try await storage.setCompanionItemReviewState(
                goalID: goalID,
                sourceIDs: sourceIDs,
                state: approved ? .approved : .rejected
            )
            learningGoals = try await storage.loadLearningGoals()
        } catch {
            logger.error("Failed to update suggestion: \(error.localizedDescription)")
        }
    }

    /// Start an in-app review for a Learning Companion goal: open the Chat
    /// panel and hand it a goal-linked review seeded with the goal's sources and topic,
    /// so completing it links to the goal.
    func startCompanionReview(
        goalID: String?,
        sourceIDs: [String],
        topic: String,
        rationale: String? = nil,
        memoryPlan: MemoryCompanionPlan? = nil
    ) {
        guard !sourceIDs.isEmpty else { return }
        pendingCompanionReview = MemoryCompanionRequest(
            goalID: goalID,
            sourceIDs: sourceIDs,
            topic: topic,
            rationale: rationale,
            memoryPlan: memoryPlan
        )
        reviewChatPanelMode = .chat
        isChatTabActive = true
        reviewChatAutoStartRequestID = UUID()
    }

    /// Create a Learning Companion goal from the in-app editor — the app-side twin of
    /// the create_learning_goal MCP tool. Seeds are approved immediately; when
    /// discovery is enabled, related sources are searched right away and inserted as
    /// pending suggestions. Throws if the goal itself cannot be created. Returns a
    /// human-readable note when discovery could not run (the goal still exists), or
    /// nil on a clean run.
    /// Most recent completed reviews for a goal, for the goal dashboard's history list.
    func companionRecentSessions(goalID: String, limit: Int = 4) async -> [CompanionSessionSummary] {
        (try? await storage.companionRecentSessions(goalID: goalID, limit: limit)) ?? []
    }

}
