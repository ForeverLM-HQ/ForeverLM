// Reacting to CloudKit changes and resuming source work.

import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import Darwin

extension StudioViewModel {

    func startObservingCloudKitRemoteChanges() {
        // A Doc shared or unshared on this Mac (`SharedDocs.share`, `stopSharingDoc`, `leaveSharedDoc`).
        sharedDocsObservationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .cloudKitSyncStoreDidChange) {
                await self?.refreshSharedDocs()
            }
        }
        cloudKitRemoteChangeTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .cloudKitSyncRemoteStoreDidChange) {
                let entityRawValues = notification.userInfo?[CloudKitSyncNotificationInfo.affectedEntitiesKey] as? [String]
                let affectedEntities = Set((entityRawValues ?? []).compactMap(CloudKitSyncEntity.init(rawValue:)))
                let requiresFullRefresh = notification.userInfo?[CloudKitSyncNotificationInfo.requiresFullRefreshKey] as? Bool ?? false
                // A Doc someone shared with this account arrives, or one is no longer shared.
                await self?.refreshSharedDocs()
                if let removedTeamID = notification.userInfo?[CloudKitSyncNotificationInfo.removedTeamKey] as? String {
                    await self?.teamWasRemoved(removedTeamID)
                }
                if affectedEntities.contains(.team) || requiresFullRefresh {
                    await self?.loadTeams()
                }
                if affectedEntities.contains(.shareRequest) || affectedEntities.contains(.source) || requiresFullRefresh {
                    await self?.refreshShareRequests()
                }
                // Nothing reloaded a board when its tasks arrived from
                // another Mac; now an open board and the Assigned list do.
                if affectedEntities.contains(.notebookTask) || requiresFullRefresh {
                    await self?.notebookTasksDidChangeRemotely()
                }
                await self?.scheduleCloudKitRemoteRefresh(
                    affectedEntities: affectedEntities,
                    requiresFullRefresh: requiresFullRefresh
                )
            }
        }
    }

    static let iCloudFullToast = "Your iCloud storage is full, so sync has paused. \(ICloudStorage.fullConsequence) Free up space or upgrade your iCloud+ plan (we recommend \(ICloudStorage.recommendedPlan))."

    /// A full iCloud stops uploads without a word: sync retries it like a
    /// network blip. Say so, once per filling.
    func startObservingICloudStorageFull() {
        iCloudFullObservationTask?.cancel()
        iCloudFullObservationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .cloudKitICloudStorageDidFill) {
                guard !Task.isCancelled else { return }
                self?.showToast(Self.iCloudFullToast)
            }
        }
    }

    func startObservingDerivedSourceWork() {
        derivedSourceWorkTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: .derivedSourceWorkNeeded
            ) {
                guard let self else { return }
                // Coalesce a burst of events into one start. Only the waiting is
                // cancelled here — never a drain that has already begun.
                self.derivedSourceWorkDebounceTask?.cancel()
                self.derivedSourceWorkDebounceTask = Task(priority: .utility) { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self else { return }
                    self.startDerivedSourceWork()
                }
            }
        }
    }

    /// Start a drain, or note that another event arrived while one is running.
    ///
    /// The drain lives in a task of its own, outside the debounce, because this
    /// event is posted by every `saveSource` — including the saves the drain
    /// itself makes, and those made concurrently by metadata extraction, artwork
    /// backfill, and incoming sync. Were it inside the debounce task, cancelling that
    /// task would cancel the drain with it, and every source still mid-flight in
    /// that batch would throw a cancellation that the queue records as the
    /// source's own failure, parking a batch of imported papers wholesale.
    ///
    /// Coalescing is kept: a second call while a drain runs sets a flag instead
    /// of starting a rival batch, and the drain starts again when it finishes.
    func startDerivedSourceWork() {
        guard !isRunningDerivedSourceWork else {
            hasPendingDerivedSourceWork = true
            return
        }
        isRunningDerivedSourceWork = true
        derivedSourceWorkRunTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runCanonicalContentCleanup()
            self.isRunningDerivedSourceWork = false
            guard self.hasPendingDerivedSourceWork else { return }
            self.hasPendingDerivedSourceWork = false
            self.startDerivedSourceWork()
        }
    }

    /// The account being able to pay again is the event that finishes work an
    /// empty balance stopped. Without this the learner adds a key and the
    /// paused source keeps offering them the same Add Key button.
    func startObservingManagedAICreditsRestored() {
        managedAICreditsRestoredTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: .managedAICreditsRestored
            ) {
                guard let self else { return }
                // Work that was still `ready` when the balance emptied kept its
                // durable queue row and simply stopped draining. That queue
                // needs no repair, only another drain.
                NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
                await self.resumeSourcesPausedByEmptyAIBalance()
            }
        }
    }

    /// Pick every parked source back up from where the empty balance stopped
    /// it. Nothing failed in these sources — the account simply could not pay —
    /// so this resumes the same work rather than retrying anything. A no-op
    /// when nothing is parked, which is the common case.
    @discardableResult
    func resumeSourcesPausedByEmptyAIBalance(
        creditsAreEmpty: Bool = AICreditEntitlement.isOutOfCredits
    ) async -> Int {
        guard !creditsAreEmpty else { return 0 }
        let pausedIDs = articles.filter(\.isPausedByEmptyAIBalance).map(\.id)
        guard !pausedIDs.isEmpty else { return 0 }

        var resumedCount = 0
        for id in pausedIDs {
            if await resumeSourcePausedByEmptyAIBalance(id) { resumedCount += 1 }
        }
        guard resumedCount > 0 else { return 0 }
        NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
        showToast(
            resumedCount == 1
                ? "AI is available again — finishing the paused source"
                : "AI is available again — finishing \(resumedCount) paused sources"
        )
        return resumedCount
    }

    /// Moves cleanup timeouts written by older builds back into durable pending
    /// work. The preserved raw extraction is authoritative; no refetch and no
    /// user action is needed. Saving `.queued` plus the staged preparation
    /// atomically creates the cleanup queue row.
    @discardableResult
    func resumeSourcesAfterTransientCleanupFailures() async -> Int {
        let affectedIDs = articles.filter {
            PaperContentPreparationService.isTransientIngestionFailure($0.errorMessage)
        }.map(\.id)
        guard !affectedIDs.isEmpty else { return 0 }

        var resumedCount = 0
        for id in affectedIDs {
            guard let index = articles.firstIndex(where: { $0.id == id }) else { continue }
            var resumed = articles[index]
            if resumed.state == .ready {
                let cleared = (try? await storage.clearCompletedCanonicalContentCleanupFailure(
                    sourceID: id
                )) ?? false
                if cleared, let currentIndex = articles.firstIndex(where: { $0.id == id }) {
                    articles[currentIndex].errorMessage = nil
                    resumedCount += 1
                }
                continue
            }
            guard resumed.state == .error else { continue }
            guard resumed.sourceType != .paper || resumed.hasPaperIngestionAttestation,
                  let raw = await storage.loadStagedRawContent(id),
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let rawSHA256 = await Self.contentSHA256OffMain(raw)
            if resumed.sourceType == .paper {
                resumed.stagePaperContentCleanup(raw: raw, rawSHA256: rawSHA256)
            } else {
                resumed.stageArticleContentCleanup(raw: raw, rawSHA256: rawSHA256)
            }
            resumed.state = .queued
            resumed.errorMessage = nil
            guard await persistSource(
                resumed,
                context: "Resume transient source cleanup",
                showErrorToast: false
            ) else { continue }

            if resumed.sourceType == .paper {
                resumed.discardPersistedPaperContentFromMemory()
            } else {
                resumed.discardPersistedArticleContentHandoff()
            }
            if let currentIndex = articles.firstIndex(where: { $0.id == id }) {
                articles[currentIndex] = resumed
            }
            resumedCount += 1
        }
        return resumedCount
    }

    private func resumeSourcePausedByEmptyAIBalance(_ articleId: String) async -> Bool {
        guard let index = articles.firstIndex(where: { $0.id == articleId }) else { return false }
        let article = articles[index]
        guard article.isPausedByEmptyAIBalance else { return false }

        // A paper stopped before its metadata stage resumes there; that stage
        // owns the cleanup that follows it.
        if article.sourceType == .paper, !article.hasPaperIngestionAttestation {
            return await extractPaperMetadataWithAI(id: articleId, showToasts: false)
        }

        // Everything else stopped at Source Content Cleanup with its extraction
        // already staged and no queue row: the save path deliberately declines
        // to enqueue work nothing can pay for. Restore the ordinary
        // cleanup-pending state so the durable drain finishes the ingestion.
        guard article.sourceType == .paper
                || article.sourceType == .article
                || article.sourceType == .manual
                || article.sourceType == .unclassified else { return false }
        guard let raw = await storage.loadStagedRawContent(articleId),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        var resumed = article
        resumed.content = raw
        resumed.state = .ready
        resumed.errorMessage = nil
        guard await persistSource(
            resumed,
            context: "Resume paused source cleanup",
            showErrorToast: false
        ) else { return false }
        // The staged extraction belongs to storage now; library rows hydrate
        // their text lazily and must not retain megabytes of it.
        resumed.content = nil
        if let currentIndex = articles.firstIndex(where: { $0.id == articleId }) {
            articles[currentIndex] = resumed
        }
        return true
    }

    func scheduleCloudKitRemoteRefresh(
        affectedEntities: Set<CloudKitSyncEntity>,
        requiresFullRefresh: Bool
    ) async {
        if requiresFullRefresh {
            cloudKitRemoteRefreshRequiresFullReload = true
            pendingCloudKitRefreshEntities = Set(CloudKitSyncEntity.allCases)
        } else if affectedEntities.isEmpty {
            pendingCloudKitRefreshEntities.formUnion([
                .source, .hiddenSource, .dismissedSource, .learningGoal, .scheduledSource, .reviewSession,
                .memoryItem, .memoryAttempt, .videoCitedPaper,
            ])
        } else {
            pendingCloudKitRefreshEntities.formUnion(affectedEntities)
        }

        cloudKitRemoteRefreshDebounceTask?.cancel()
        cloudKitRemoteRefreshDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            // Defer off any in-flight SwiftUI observation pass (e.g. text-to-speech
            // toolbar updates) before touching @Observable state.
            DispatchQueue.main.async { [weak self] in
                Task { @MainActor [weak self] in
                    self?.startCloudKitRemoteRefreshIfNeeded()
                }
            }
        }
    }

    /// CloudKit may deliver another event while a large-library refresh is still
    /// reading SQLite. Keep exactly one refresh in flight and fold later events
    /// into its next pass; overlapping refresh tasks multiplied identity scans
    /// and repeatedly invalidated the same SwiftUI list during a sync storm.
    private func startCloudKitRemoteRefreshIfNeeded() {
        guard cloudKitRemoteRefreshTask == nil else { return }
        cloudKitRemoteRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.cloudKitRemoteRefreshTask = nil }

            while self.cloudKitRemoteRefreshRequiresFullReload
                || !self.pendingCloudKitRefreshEntities.isEmpty {
                guard !Task.isCancelled else { return }
                let entities = self.pendingCloudKitRefreshEntities
                let requiresFull = self.cloudKitRemoteRefreshRequiresFullReload
                self.pendingCloudKitRefreshEntities = []
                self.cloudKitRemoteRefreshRequiresFullReload = false
                await Task.yield()
                await self.refreshAfterCloudKitRemoteChange(
                    affectedEntities: entities,
                    requiresFullRefresh: requiresFull
                )
            }
        }
    }

    /// Measure a synchronous main-actor publish step inside the CloudKit remote
    /// refresh and log any step slow enough to threaten a beachball. UI-stall
    /// samples attach ~1s after a stall begins and routinely miss the blocking
    /// step, so this names the culprit directly in the unified log.
    @discardableResult
    private func measureRefreshPublishStep<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        defer {
            let elapsed = ContinuousClock.now - start
            if elapsed > .milliseconds(100) {
                let ms = Double(elapsed.components.seconds) * 1_000
                    + Double(elapsed.components.attoseconds) / 1e15
                logger.warning("CloudKit remote refresh step '\(name, privacy: .public)' held the main actor for \(ms, format: .fixed(precision: 0))ms")
            }
        }
        return try body()
    }

    /// Re-seed the preference-backed stored properties from `UserDefaults`.
    ///
    /// These are assigned once from their property initializers and observe
    /// nothing, so a preference that arrives from another Mac is invisible until
    /// the next launch unless it is pushed back in here. Computed-property readers
    /// (`MacArticleSpeechSettings`, `AIModelDefaults`, `KeychainService`) read
    /// `UserDefaults` live and need no equivalent.
    ///
    /// Assigning fires each `didSet`, which calls back into `PreferenceStore.set`.
    /// That does not loop: `set` drops writes whose value already matches what is
    /// in `UserDefaults`, and these values came from `UserDefaults` a line earlier.
    func reloadSyncedPreferences() {
        let defaults = UserDefaults.standard

        if let raw = defaults.string(forKey: "podcastSortMode"),
           let mode = PodcastSortMode(rawValue: raw), mode != podcastSortMode {
            podcastSortMode = mode
        }
        if let raw = defaults.string(forKey: "videoSortMode"),
           let mode = VideoSortMode(rawValue: raw), mode != videoSortMode {
            videoSortMode = mode
        }
        if let raw = defaults.string(forKey: "meetingListOrder"),
           let order = MeetingListOrder(rawValue: raw), order != meetingListOrder {
            meetingListOrder = order
        }
        let youtubeFallbackShows = Set(
            defaults.stringArray(forKey: Self.podcastYouTubeFallbackShowsKey) ?? []
        )
        if youtubeFallbackShows != podcastYouTubeFallbackShows {
            podcastYouTubeFallbackShows = youtubeFallbackShows
        }
        let meetingFolderImages = Self.meetingFolderImageURLsFromDefaults()
        if meetingFolderImages != meetingFolderImageURLs {
            meetingFolderImageURLs = meetingFolderImages
        }
        let storedQuizScores = LectureQuizScore.scoresFromDefaults(prefix: LectureQuizScore.courseQuizPreferenceKeyPrefix)
        if storedQuizScores != courseQuizScores {
            courseQuizScores = storedQuizScores
        }
        // Boxes unticked, and context notebooks put in, on another Mac or by
        // set_notebook_source_selection.
        let notebookExclusions = NotebookChatSelection.exclusionsFromDefaults()
        if notebookExclusions != notebookChatExclusions {
            notebookChatExclusions = notebookExclusions
        }
        let notebookContexts = NotebookChatSelection.contextNotebooksFromDefaults()
        if notebookContexts != notebookChatContextNotebooks {
            notebookChatContextNotebooks = notebookContexts
        }
        // Collections made, renamed or filled on another device, or by
        // update_notebook_collection.
        let collections = NotebookCollectionRows.read()
        if collections != notebookCollections {
            notebookCollections = collections
        }
        // Spaces made, renamed or deleted on another device or by
        // update_space, and pages moved between them there.
        let spaces = PageSpaceRows.read()
        if spaces != pageSpaces {
            pageSpaces = spaces
        }
        // Pages pinned or unpinned on another device.
        let pins = PagePinRows.read()
        if pins != pagePins {
            pagePins = pins
        }
        // Chats pinned, unpinned or reordered on another device.
        refreshChatPinsFromRows()
        // Lists of goals and ideas made, renamed or trashed on another
        // device, and goals and ideas filed in them there.
        refreshSpaceListsFromRows()
        // Canvases made, renamed or trashed on another Mac.
        refreshCanvasesFromRows()
        // Pages nested or moved out from under a page on another device.
        let parents = PageParentRows.read()
        if parents != pageParents {
            pageParents = parents
        }
        // A notebook made unnamed on another device, or named there.
        let namingMarks = NotebookNamingRows.marks()
        if namingMarks != notebookNamingMarks {
            notebookNamingMarks = namingMarks
            nameReadyNotebooks()
        }
        // Machine-local, but written by resolve_unconverted_zoom_recording
        // too, and the Meetings tab's row has to go when an assistant ignores
        // the recording.
        let ignoredZoomRecordings = Self.zoomLocalRecordingIgnoredFoldersFromDefaults()
        if ignoredZoomRecordings != zoomLocalRecordingIgnoredFolders {
            zoomLocalRecordingIgnoredFolders = ignoredZoomRecordings
        }
        if let raw = defaults.stringArray(forKey: "studio.hiddenTabs") {
            let tabs = Set(raw.compactMap { StudioSidebarTab.fromPersistedRawValue($0) })
            if tabs != hiddenTabs { hiddenTabs = tabs }
        }
        // Reseeded alongside the pinned set, never after it: this is the record
        // of which of those unpins were Studio's own, and a stale copy lets
        // `pinIntegrationTabsInUse()` undo one the learner performed.
        if let raw = defaults.stringArray(
            forKey: StudioSidebarTab.autoUnpinnedIntegrationTabsPreferenceKey
        ) {
            let tabs = Set(raw.compactMap { StudioSidebarTab.fromPersistedRawValue($0) })
            if tabs != autoUnpinnedIntegrationTabs { autoUnpinnedIntegrationTabs = tabs }
        }
        if let raw = defaults.stringArray(forKey: StudioSidebarTab.knowledgeExclusionPreferenceKey) {
            let tabs = Set(raw.compactMap { StudioSidebarTab.fromPersistedRawValue($0) })
            if tabs != excludedKnowledgeTabs { excludedKnowledgeTabs = tabs }
        }
        if let raw = defaults.stringArray(forKey: "studio.tabOrder") {
            // Reconcile before comparing: a synced order that names only some of
            // the tabs is an arrangement, not a membership list, and adopting it
            // verbatim would drop the rest of the tab bar.
            let order = StudioSidebarTab.reconciledOrder(
                raw.compactMap { StudioSidebarTab.fromPersistedRawValue($0) }
            )
            if !order.isEmpty, order != tabOrder { tabOrder = order }
        }
        if let raw = defaults.stringArray(forKey: "studio.centerTabGroups.v1"),
           let groups = StudioCenterTabGroups.fromPersisted(raw) {
            applySyncedCenterTabGroupsDefault(groups)
        }
        if let order = defaults.stringArray(forKey: "studio.courseOrder"), order != courseOrder {
            courseOrder = order
        }
        if let order = defaults.stringArray(forKey: "studio.projectOrder"), order != notebookOrder {
            notebookOrder = order
        }
        let pinnedIDs = defaults.stringArray(forKey: NotebookPins.preferenceKey) ?? []
        if pinnedIDs != pinnedNotebookIDs {
            pinnedNotebookIDs = pinnedIDs
        }
        if let order = defaults.stringArray(forKey: StudioViewModel.chatOrderPreferenceKey),
           order != chatOrder {
            chatOrder = order
        }
        let expanded = defaults.string(forKey: "studio.expandedPanel").flatMap(StudioExpandedPanel.init(rawValue:))
        if expanded != expandedPanel { expandedPanel = expanded }
        if let value = defaults.object(forKey: "studio.showSearchPanel") as? Bool, value != showSearchPanel {
            showSearchPanel = value
        }

        invalidateFilteredSidebarCache()
    }

    func refreshAfterCloudKitRemoteChange(
        affectedEntities: Set<CloudKitSyncEntity> = Set(CloudKitSyncEntity.allCases),
        requiresFullRefresh: Bool = true
    ) async {
        let entities = requiresFullRefresh ? Set(CloudKitSyncEntity.allCases) : affectedEntities
        let needsBooks = entities.contains(.book)
        let needsCourses = entities.contains(.course) || entities.contains(.videoPlaylist)
        let needsMeetings = entities.contains(.meetingGroup)
        let needsSources = entities.contains(.source)
            || entities.contains(.hiddenSource)
            || entities.contains(.dismissedSource)
            || entities.contains(.hiddenPodcastShow)
            || entities.contains(.hiddenYouTubeChannel)
            // A cited-paper decision made on the other Mac either adds a paper source
            // (import) or changes what the video's reader should still offer.
            || entities.contains(.videoCitedPaper)
        let needsLearningGoals = entities.contains(.learningGoal) || entities.contains(.scheduledSource)
        let needsIdeas = entities.contains(.idea)
        let needsDirections = entities.contains(.researchDirection)
        let needsArtifacts = entities.contains(.artifact) || entities.contains(.hiddenArtifact)
        let needsReview = entities.contains(.reviewSession) || entities.contains(.hiddenReviewSession)
        let needsMemory = Self.cloudKitEntitiesRequireMemoryRefresh(entities)
        let needsHighlights = entities.contains(.sourceHighlight)
        let needsPodcastVisibility = entities.contains(.hiddenPodcastShow)
            || entities.contains(.source)
            || entities.contains(.hiddenSource)
        let needsYouTubeVisibility = entities.contains(.hiddenYouTubeChannel)
            || entities.contains(.source)
            || entities.contains(.hiddenSource)

        if entities.contains(.preference) {
            await PreferenceStore.hydrateFromStore()
            reloadSyncedPreferences()
        }
        // A walkthrough rides the Source record, so a source change from the
        // other Mac or an MCP write may have brought or replaced one; an open
        // panel reloads its steps.
        if needsSources {
            noteWalkthroughChanged()
        }

        if needsArtifacts {
            await loadArtifacts()
            // An animation's walkthrough rides its Artifact record the same
            // way; a chat walking through the animation reloads its steps.
            noteWalkthroughChanged()
        }

        if needsBooks {
            do {
                let books = try await storage.loadBooks()
                bookTitles = books.titles
                bookSubtitles = books.subtitles
                bookCoverPaths = books.coverPaths
                bookAuthors = books.authors
                bookEditions = books.editions
                bookKinds = books.kinds
                invalidateFilteredSidebarCache()
            } catch {
                logger.error("Failed to refresh synced books: \(error.localizedDescription)")
            }
        }
        if needsCourses {
            do {
                courseMetadata = try await storage.loadCourseMetadata()
                courseTeamIDs = try await storage.loadCourseTeamIDs()
                courseFollowerNotebookIDs = try await storage.loadCourseFollowers()
                invalidateFilteredSidebarCache()
            } catch {
                logger.error("Failed to refresh synced course metadata: \(error.localizedDescription)")
            }
            do {
                videoPlaylistMetadata = try await storage.loadVideoPlaylistMetadata()
            } catch {
                logger.error("Failed to refresh synced video playlist metadata: \(error.localizedDescription)")
            }
            do {
                async let loadedLectures = storage.loadCourseLectures()
                async let loadedItems = storage.loadCourseLectureItems()
                async let loadedArtworkURLs = storage.loadCourseArtworkURLs()
                let lectures = try await loadedLectures
                let items = try await loadedItems
                let artworkURLs = try await loadedArtworkURLs
                measureRefreshPublishStep("courses.outline") {
                    applyCourseOutline(lectures: lectures, items: items)
                    courseCoverArtworkURLs = artworkURLs
                    invalidateFilteredSidebarCache()
                }
            } catch {
                logger.error("Failed to refresh synced course lectures: \(error.localizedDescription)")
            }
            // Quizzes travel inside the Course record.
            await refreshCourseQuizzes()
            Task { [weak self] in
                await self?.drainPendingWebCourseImports()
            }
        }
        if needsMeetings {
            do {
                let metadata = try await storage.loadMeetingMetadata()
                let artifacts = try await storage.loadMeetingArtifacts()
                measureRefreshPublishStep("meetings.publish") {
                    meetingMetadata = metadata
                    applyMeetingArtifacts(artifacts)
                    invalidateFilteredSidebarCache()
                }
            } catch {
                logger.error("Failed to refresh synced meeting metadata: \(error.localizedDescription)")
            }
        }
        if needsSources {
            do {
                let reloaded = try await storage.loadLibrarySources().sources
                // Merge and diff off the main actor: with a large library, the
                // content-preserving merge plus the equality check are far too
                // much work for the main thread. Publishing only on a real change
                // also spares SwiftUI a full sidebar re-render when a sync cycle
                // fetched records that match what we already show.
                let current = articles
                let (merged, changed) = await Task.detached(priority: .userInitiated) {
                    let merged = StudioViewModel.preservingLoadedContent(
                        in: reloaded,
                        preservingFrom: current
                    )
                    return (merged, merged != current)
                }.value
                if changed {
                    await Task.yield()
                    measureRefreshPublishStep("sources.publish") {
                        articles = merged
                        seedReadingProgressFromArticles()
                    }
                    autoFetchNewlyAddedPapers()
                    autoExtractMissingPaperMetadata()
                    autoFetchUnfetchedSources()
                    // A source came in or became readable: the sources no
                    // card covers are counted again for the corner card.
                    Task(priority: .utility) { [weak self] in
                        await self?.refreshCardsToCheckAdditions()
                    }
                }
                await convergePaperIdentityDuplicates()
            } catch {
                logger.error("Failed to refresh synced sources: \(error.localizedDescription)")
            }
            Task { [weak self] in
                await self?.drainPendingWebBookImports()
            }
        }
        if needsIdeas {
            await loadIdeas()
        }
        if needsDirections {
            await loadResearchDirections()
        }
        if needsLearningGoals {
            do {
                let goalsInMemory = learningGoals
                let refreshedLearningGoals = try await storage.loadLearningGoals()
                // The Schedule panel renders from scheduledSources (shared placements),
                // so it must reload alongside the goals or the week stays stale.
                let refreshedScheduledSources = try await storage.loadScheduledSources()
                if refreshedLearningGoals != learningGoals {
                    learningGoals = refreshedLearningGoals
                }
                if refreshedScheduledSources != scheduledSources {
                    scheduledSources = refreshedScheduledSources
                }
                if let activeNotebookId,
                   !notebooks.contains(where: { $0.id == activeNotebookId }) {
                    self.activeNotebookId = notebooks.first?.id
                }
                // A source added to a notebook on the web, the iPhone or
                // another Mac arrives ticked here too.
                await noteInboundNotebooks(refreshedLearningGoals, inMemory: goalsInMemory)
            } catch {
                logger.error("Failed to refresh synced schedule: \(error.localizedDescription)")
            }
        }
        if needsReview {
            do {
                reviewSessionLinks = try await storage.loadReviewSessionLinks()
            } catch {
                logger.error("Failed to refresh synced review sessions: \(error.localizedDescription)")
            }
        }
        if needsReview || needsSources {
            do {
                sourceReviewedAt = try await storage.sourceReviewDates()
                invalidateFilteredSidebarCache()
            } catch {
                logger.error("Failed to refresh synced review dates: \(error.localizedDescription)")
            }
        }
        if needsMemory {
            await refreshMemoryCompanionPlan()
        }
        // Cards to check ride Artifact records (the sources' draft decks) and
        // preference rows (what was kept or skipped); a kept card is a Memory
        // item. A draft, a Keep or a Skip from another device or an assistant
        // reaches the Memory pane, a notebook's Cards row and the counts. A
        // source's own change (reading progress, mostly) does not read them
        // again.
        if needsArtifacts || !entities.isDisjoint(with: [.memoryItem, .memoryAttempt, .preference]) {
            memoryCardRevision &+= 1
            Task(priority: .utility) { [weak self] in
                await self?.refreshMemoryCardCounts()
            }
        }
        if needsLearningGoals || needsReview {
            do {
                learningGoalLinkedSourceIds = try await storage.sourceIdsWithReviewSession()
            } catch {
                logger.error("Failed to refresh synced schedule chat links: \(error.localizedDescription)")
            }
            do {
                learningGoalEligibleSourceIds = try await storage.sourceIdsWithLinkedChatSession()
            } catch {
                logger.error("Failed to refresh synced schedule eligibility: \(error.localizedDescription)")
            }
        }
        if needsPodcastVisibility {
            do {
                hiddenPodcastShows = try await storage.loadHiddenPodcastShows()
            } catch {
                logger.error("Failed to refresh synced hidden podcast shows: \(error.localizedDescription)")
            }
            do {
                hiddenPodcastEpisodeIDs = try await storage.loadHiddenPodcastEpisodeIDs()
            } catch {
                logger.error("Failed to refresh synced hidden podcast episodes: \(error.localizedDescription)")
            }
            do {
                visiblePodcastEpisodeOverrideIDs = try await storage.loadVisiblePodcastEpisodeOverrideIDs()
            } catch {
                logger.error("Failed to refresh synced visible podcast overrides: \(error.localizedDescription)")
            }
            invalidateFilteredSidebarCache()
            Task(priority: .utility) { [weak self] in
                await self?.processPendingPodcastTranscripts()
            }
        }
        if needsYouTubeVisibility {
            do {
                hiddenYouTubeChannels = try await storage.loadHiddenYouTubeChannels()
            } catch {
                logger.error("Failed to refresh synced hidden YouTube channels: \(error.localizedDescription)")
            }
            do {
                visibleYouTubeVideoOverrideIDs = try await storage.loadVisibleYouTubeVideoOverrideIDs()
            } catch {
                logger.error("Failed to refresh synced visible YouTube overrides: \(error.localizedDescription)")
            }
            invalidateFilteredSidebarCache()
        }

        // A mark made on another device — or by an assistant over MCP — has to
        // reach an open reader, which paints from this cache and otherwise only
        // fills it when a source is first opened. Only sources already loaded are
        // refreshed, so this costs one indexed query per open reader rather than a
        // sweep of the library.
        if needsHighlights {
            for sourceID in Array(readerHighlights.keys) {
                await reloadReaderHighlights(for: sourceID)
            }
            // A clip cut on another Mac belongs on this Canvas too.
            knowledgeMapClipRevision &+= 1
        }

        // Sources that arrived over CloudKit sync never passed through the ingest
        // embed path, and embeddings are local-only derived data that don't sync — so
        // the receiving device must build their vectors itself. Kick the indexer to
        // close that gap in the background.
        if needsSources {
            Task(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.runCanonicalContentCleanup()
                self.kickSourceEmbeddingIndexing()
            }
        }
    }

    /// Concept events directly change the due projection. Source events change
    /// which grounded targets are available, while a source's own review history can
    /// make an on-demand first-review candidate due.
    static func cloudKitEntitiesRequireMemoryRefresh(
        _ entities: Set<CloudKitSyncEntity>
    ) -> Bool {
        !entities.isDisjoint(with: [
            .memoryItem,
            .memoryAttempt,
            .source,
            .reviewSession,
        ])
    }

}
