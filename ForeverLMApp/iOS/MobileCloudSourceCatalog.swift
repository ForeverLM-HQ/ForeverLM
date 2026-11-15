// The actor that reads and caches the synced source catalog on the phone.

import CloudKit
import Foundation
import OSLog

actor MobileCloudSourceCatalog {
    static let shared = MobileCloudSourceCatalog()

    private static let syncLogger = Logger(subsystem: "com.foreverlm.mobile", category: "SourceCatalogSync")
    private static let cacheTTL: TimeInterval = 90

    private var cachedSources: [MobileCloudSource] = []
    private var cachedNotebooks: [MobileCloudNotebook] = []
    private var cachedCollections: MobileCatalogCollections = .empty
    private var cachedAt: Date?
    private var activeLoad: (id: UUID, task: Task<[MobileCloudSource], Error>)?
    /// A forced refresh is a freshness contract, not merely permission to skip
    /// the short-lived cache. If it arrives while a zone delta is already in
    /// flight, remember it and run one more delta before releasing waiters.
    private var forcedRefreshRequested = false
    private var lastDecodedSourceCount: Int?
    /// What the replica's index gave on the last load (`MobileReadModels`): the phone's library.
    private var replicaSnapshot: MobileReadModels.Snapshot?
    /// The member's cards and the answers about them, decoded from the Card and Sitting
    /// payloads on first use and kept until the replica next loads. A write this phone makes adds to it
    /// (`noteRecordedMemoryAttempt`) instead of decoding the library again.
    private var replicaMemory: MobileReadModels.MemoryState?
    /// The replica `replicaMemory` was read from, whose revision says whether it still holds.
    private var replicaMemoryHandle: MobileReplica?
    /// Moves with every replica load, so a decode that began before one never outlives it.
    private var replicaMemoryEpoch = 0

    /// The replica's query layer once the session runs (`MobileSyncSession`); nil when it cannot start.
    private let replicaProjection: @Sendable () async -> MobileProjection?
    private let ideaStore: MobileSourceIdeaStore

    init(projection: @escaping @Sendable () async -> MobileProjection? = MobileCloudSourceCatalog.sessionProjection,
         ideas: MobileSourceIdeaStore = .shared) {
        replicaProjection = projection
        ideaStore = ideas
    }

    /// The running session's replica; under the DEBUG whole-app preview, its sample library's.
    static let sessionProjection: @Sendable () async -> MobileProjection? = {
#if DEBUG
        if let preview = MobileAppHarness.backend { return preview.projection }
#endif
        return await MobileSyncSession.startIfEnabled()?.projection
    }

    func loadSources(forceRefresh: Bool = false) async throws -> [MobileCloudSource] {
        if forceRefresh {
            forcedRefreshRequested = true
        }

        // Join an in-flight delta before considering the cache. Otherwise an
        // ordinary reader can publish the old snapshot while a refresh is
        // already bringing newer records onto the phone.
        if let activeLoad {
            return try await activeLoad.task.value
        }

        if !forcedRefreshRequested,
           let cachedAt,
           Date().timeIntervalSince(cachedAt) < Self.cacheTTL,
           !cachedSources.isEmpty {
            return cachedSources
        }

        // Launch fires several consumers at once (library, audio review, Siri);
        // one zone pass serves them all. A force request that arrives during
        // that pass is drained as a second delta so it cannot be swallowed.
        let id = UUID()
        let load = Task { [weak self] () throws -> [MobileCloudSource] in
            guard let self else { return [] }
            return try await self.runCoalescedLoad(id: id)
        }
        activeLoad = (id, load)
        return try await load.value
    }

    private func runCoalescedLoad(id: UUID) async throws -> [MobileCloudSource] {
        do {
            var sources: [MobileCloudSource] = []
            repeat {
                forcedRefreshRequested = false
                sources = try await performReplicaLoad()
            } while forcedRefreshRequested
            if activeLoad?.id == id {
                activeLoad = nil
            }
            return sources
        } catch {
            if activeLoad?.id == id {
                activeLoad = nil
            }
            throw error
        }
    }

    /// The Notebooks synced from the Mac (top-level companion goals), newest
    /// activity first, archived ones dropped — the same set the Mac's own
    /// selectors offer. Rides the exact same zone pass as `loadSources`, so
    /// calling both costs one round trip.
    func loadNotebooks(forceRefresh: Bool = false) async throws -> [MobileCloudNotebook] {
        _ = try await loadSources(forceRefresh: forceRefresh)
        return cachedNotebooks
    }

    /// Book/course display metadata and the hidden sets, from the same zone
    /// pass as `loadSources` — the grouped lists and the visibility rule read
    /// these together with the sources they shape.
    func loadCollections(forceRefresh: Bool = false) async throws -> MobileCatalogCollections {
        _ = try await loadSources(forceRefresh: forceRefresh)
        return cachedCollections
    }

    func loadSourceHighlights(sourceID: String, forceRefresh: Bool = false) async throws -> [SourceHighlight] {
        _ = try await loadSources(forceRefresh: forceRefresh)
        return currentSourceHighlights(sourceID: sourceID)
    }

    func currentSourceHighlights(sourceID: String) -> [SourceHighlight] {
        return replicaSnapshot?.highlights.filter { $0.sourceID == sourceID } ?? []
    }

    /// Every mark the learner set aside to follow up or doubt (blue, pink),
    /// across the library, as the Follow up screen reads them: the replica's
    /// highlights are already keyed by the source's id on this phone.
    func loadOpenSourceHighlights(forceRefresh: Bool = false) async throws -> [FollowUpMark] {
        _ = try await loadSources(forceRefresh: forceRefresh)
        return currentOpenSourceHighlights()
    }

    func currentOpenSourceHighlights() -> [FollowUpMark] {
        (replicaSnapshot?.highlights ?? [])
            .filter { $0.color.isOpenItem }
            .map { FollowUpMark(highlight: $0, sourceID: $0.sourceID) }
    }

    /// The load (§13.6): the replica's index, read through `MobileReadModels` into the rows the
    /// screens already take; the session's rounds keep the replica current.
    private func performReplicaLoad() async throws -> [MobileCloudSource] {
        guard let projection = await replicaProjection() else {
            throw MobileCloudSourceCatalogError.replicaUnavailable
        }
        let snapshot = try await MobileReadModels.snapshot(projection)
        replicaSnapshot = snapshot
        replicaMemoryHandle = projection.replica
        // The cards and answers stay while no Card or Sitting arrived or went: a library read again for a
        // rename or a sync round does not decode every answer the learner ever gave.
        if let held = replicaMemory {
            let rows = try await projection.replica.read { try MobileReadModels.memoryRowCounts(in: $0.connection) }
            if rows.cards != held.cardRows || rows.sittings != held.sittingRows {
                replicaMemory = nil
                replicaMemoryEpoch &+= 1
            }
        }
        let sources = Self.available(snapshot, includingArchived: true)
        lastDecodedSourceCount = sources.count
        cachedSources = sources
        cachedCollections = snapshot.collections
        cachedNotebooks = snapshot.notebooks
        cachedAt = Date()
        return sources
    }

    /// The replica's sources the phone serves: courses once ready, nothing hidden on a Mac, newest
    /// first.
    private static func available(_ snapshot: MobileReadModels.Snapshot, includingArchived: Bool) -> [MobileCloudSource] {
        snapshot.sources
            .filter(isAvailableInMobileLibrary)
            .filter { includingArchived || !$0.isArchived }
            .filter { !MobileSourceVisibility.isHidden($0, collections: snapshot.collections) }
    }

    /// The decoded sources exactly as far as the current (possibly still
    /// running) sync has gotten — served from the last checkpoint, no fetch.
    /// Lets the list fill in progressively during the long first pass. Applies
    /// the same visibility rule as the finished load.
    func currentSources() -> [MobileCloudSource] {
        return replicaSnapshot.map { Self.available($0, includingArchived: false) } ?? []
    }

    /// Course imports are the one mobile grouping whose incomplete rows have
    /// no useful phone action: they have no synced text to read, discuss, or
    /// quiz. Keep them out until the Mac publishes `ready` rather than showing
    /// a tappable row that can only fail. Other source types retain their
    /// existing error/queued presentation semantics.
    private static func isAvailableInMobileLibrary(_ source: MobileCloudSource) -> Bool {
        source.sourceType != "course" || source.state == "ready"
    }

    /// Collections as far as the current sync has gotten, for the progressive
    /// first-pass fill — same checkpoint `currentSources()` reads.
    func currentCollections() -> MobileCatalogCollections {
        return replicaSnapshot?.collections ?? .empty
    }

    /// Notebooks from the same disk checkpoint as `currentSources()`. Publishing
    /// this snapshot before CloudKit refresh means a rebuild opens the previous
    /// library immediately instead of presenting sync as an empty first load.
    func currentNotebooks() -> [MobileCloudNotebook] {
        return replicaSnapshot?.notebooks ?? []
    }

    /// Every Goal in the Library, from the replica: the voice assistant's
    /// brief of what the learner is working toward.
    func currentGoals() -> [MobileCloudGoal] {
        replicaSnapshot?.goals ?? []
    }

    /// Sources a finished review covered, resolved to this phone's source ids:
    /// the Mac's `sourceReviewDates`, which a course's path counts as done for
    /// a lesson sheet or course PDF that can never be watched or marked read.
    func currentReviewedSourceIDs() -> Set<String> {
        return replicaSnapshot?.reviewedSourceIDs ?? []
    }

    /// Phone-side mirror of the Mac's bounded recent-chat preference. Memory
    /// sessions are excluded because their source list is the launch queue;
    /// ordinary chat/review relationships describe what the learner has chosen
    /// to discuss lately.
    func currentRecentReviewSourceActivity(
        now: Date = Date(),
        sessionLimit: Int = 12,
        maximumAgeDays: Int = 14
    ) -> [MemoryTutorRecentSourceActivity] {
        let availableSourceIDs = Set((replicaSnapshot?.sources ?? []).map(\.id))
        let cutoff = now.addingTimeInterval(
            -Double(max(1, min(maximumAgeDays, 90))) * MemoryTutorScheduler.secondsPerDay
        )
        // Already newest first (`MobileReadModels.chats`).
        let discussions = (replicaSnapshot?.chatDiscussions ?? [])
            .filter { $0.at >= cutoff }
            .prefix(max(0, min(sessionLimit, 50)))
        var latestBySourceID: [String: Date] = [:]
        for discussion in discussions {
            for sourceID in discussion.sourceIDs where availableSourceIDs.contains(sourceID) {
                latestBySourceID[sourceID] = max(latestBySourceID[sourceID] ?? .distantPast, discussion.at)
            }
        }
        return latestBySourceID.map {
            MemoryTutorRecentSourceActivity(sourceID: $0.key, discussedAt: $0.value)
        }.sorted {
            if $0.discussedAt != $1.discussedAt { return $0.discussedAt > $1.discussedAt }
            return $0.sourceID < $1.sourceID
        }
    }

    /// What the learner actually read, listened to, or watched lately, from the
    /// same synced Schedule activity the Mac writes.
    ///
    /// Discussion recency alone answers "what have we been talking about"; it
    /// says nothing about the podcast played on a walk this morning or the paper
    /// read last night. Both are attention signals of the same kind, so they
    /// merge into one recency input to the daily queue — which reorders an
    /// already-due queue and never invents a due date.
    func currentRecentSourceConsumptionActivity(
        now: Date = Date(),
        maximumAgeDays: Int = 14
    ) -> [MemoryTutorRecentSourceActivity] {
        let availableSourceIDs = Set((replicaSnapshot?.sources ?? []).map(\.id))
        let activityDays = replicaSnapshot?.activityDays ?? [:]
        let cutoff = now.addingTimeInterval(
            -Double(max(1, min(maximumAgeDays, 90))) * MemoryTutorScheduler.secondsPerDay
        )
        return activityDays
            .compactMap { sourceID, days -> MemoryTutorRecentSourceActivity? in
                guard availableSourceIDs.contains(sourceID),
                      let consumedAt = SourceActivityDay.lastConsumedAt(in: days),
                      consumedAt >= cutoff else { return nil }
                return MemoryTutorRecentSourceActivity(
                    sourceID: sourceID,
                    discussedAt: consumedAt
                )
            }
            .sorted {
                if $0.discussedAt != $1.discussedAt { return $0.discussedAt > $1.discussedAt }
                return $0.sourceID < $1.sourceID
            }
    }

    /// Everything the learner has attended to lately, from both halves of
    /// "recently": what was discussed, and what was read, listened to, or
    /// watched. Callers fold duplicates by keeping the later timestamp.
    func currentRecentSourceAttention(
        now: Date = Date()
    ) -> [MemoryTutorRecentSourceActivity] {
        currentRecentReviewSourceActivity(now: now)
            + currentRecentSourceConsumptionActivity(now: now)
    }

    /// Every audio overview the Mac saved, as the phone lists them under
    /// their notebooks (`MobileAudioReviewViewModel.audioOverviews(inNotebook:)`):
    /// archived and hidden ones left out, as the Mac's notebook leaves them.
    func currentAudioOverviews() -> [MobileAudioOverviewRecord] {
        return replicaSnapshot?.audioOverviews ?? []
    }

    /// Every current Artifact the learner has not hidden: what a notebook's
    /// Studio filters to its Docs (`MobileAudioReviewViewModel.docs(in:)`)
    /// and orders by when each was made (`MobileNotebookOutputOrder`).
    func currentNotebookArtifacts() -> [MobileCloudArtifact] {
        return replicaSnapshot?.artifacts ?? []
    }

    /// The chats filed under each notebook (`goalID`), newest first, as its
    /// Chat tab lists them: a chat hidden on a Mac and one nobody said
    /// anything in are left out. A chat filed on a Goal nested in a notebook
    /// is the notebook's too (homing's filed rule, `MobileNotebookMembership`).
    /// Each carries the sources it read, by this phone's ids, and what it is,
    /// which decide whether the phone continues it
    /// (`MobileNotebookChatContinuation`).
    func currentNotebookChats() -> [String: [MobileNotebookChatSummary]] {
        return replicaSnapshot?.notebookChats ?? [:]
    }

    /// One saved chat's turns for its read-only transcript; nil when the
    /// session is not on this phone.
    func currentChatTranscriptTurns(sessionID: String) async -> [MobileChatTranscriptTurns.Turn]? {
        // Only this chat's exchanges are decoded, a page at a time.
        guard let zoneKey = replicaSnapshot?.chatZones[sessionID], let projection = await replicaProjection() else { return nil }
        do {
            return try await MobileReadModels.transcript(chatID: sessionID, zoneKey: zoneKey, projection: projection)
        } catch {
            Self.syncLogger.error("Reading a saved chat's transcript failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Canonical concept-level memory state from the same durable zone mirror as
    /// Sources and Schedule. The phone derives due state from immutable attempts;
    /// it never keeps a second JSON persistence rail or guesses from sessions.
    /// The active ideas of the given sources, in their stored order — what a
    /// memory review's contour is graded against.
    func currentSourceIdeas(sourceIDs: [String]) async -> [String: [SourceIdea]] {
        // A source's ideas live in its `ideas` satellite (§10), not in records the catalog holds.
        return await ideaStore.ideas(sourceIDs: sourceIDs)
    }

    /// Every source with real consumption evidence and its review history, the
    /// phone's twin of the Mac's `cohortCandidates` query, from the records
    /// already synced here. Feeds `CohortSelector` unchanged.
    func currentMemoryReviewCandidates(
        now: Date = Date(),
        minimumConfidence: SourceConsumptionConfidence = CohortSelector.selectableConfidence
    ) -> [CohortCandidate] {
        let inputs = memoryReviewInputs()
        return MemoryReviewCandidates.candidates(
            sources: inputs.sources,
            activityDays: inputs.activityDays,
            sessions: inputs.sessions,
            now: now,
            minimumConfidence: minimumConfidence
        )
    }

    /// The day as the ledger recorded it, from the same synced records: totals
    /// since the start of yesterday and what was opened but is not in the
    /// review (`excluding`). The phone's twin of `StorageService.memoryReviewDay`.
    func currentMemoryReviewDay(
        now: Date = Date(),
        excluding: Set<String>
    ) -> (ledger: MemoryReviewLedger, touched: [CohortTouchedSource]) {
        let inputs = memoryReviewInputs()
        let since = MemoryReviewLedger.windowStart(now: now)
        return (
            MemoryReviewCandidates.ledger(
                sources: inputs.sources,
                activityDays: inputs.activityDays,
                sessions: inputs.sessions,
                since: since,
                now: now
            ),
            MemoryReviewCandidates.touched(
                sources: inputs.sources,
                activityDays: inputs.activityDays,
                since: since,
                now: now,
                excluding: excluding
            )
        )
    }

    /// The portable candidate inputs, built once per call: from the replica's index once this install
    /// switched, else from the catalog.
    private func memoryReviewInputs(
    ) -> (sources: [MemoryReviewCandidates.SourceInput], activityDays: [String: [SourceActivityDay]], sessions: [MemoryReviewCandidates.SessionInput]) {
        return Self.memoryReviewInputs(replicaSnapshot ?? MobileReadModels.Snapshot())
    }

    /// The candidate inputs, from the replica's index: its sources, the member's highlights
    /// and every source's activity days folded from the ActivityLogs. Its chats' exchanges are not in
    /// the index, so no review session counts yet.
    static func memoryReviewInputs(
        _ snapshot: MobileReadModels.Snapshot
    ) -> (sources: [MemoryReviewCandidates.SourceInput], activityDays: [String: [SourceActivityDay]], sessions: [MemoryReviewCandidates.SessionInput]) {
        (memoryReviewSources(snapshot.sources, collections: snapshot.collections, highlights: snapshot.highlights), snapshot.activityDays, [])
    }

    /// The sources a memory review may pick from, with their highlights counted as annotation evidence.
    private static func memoryReviewSources(
        _ sources: [MobileCloudSource],
        collections: MobileCatalogCollections,
        highlights: some Sequence<SourceHighlight>
    ) -> [MemoryReviewCandidates.SourceInput] {
        // Highlights are the ledger's annotation evidence; the phone syncs them
        // and counts them here the way the Mac counts `source_highlights`.
        let annotationCounts = highlights.reduce(into: [String: Int]()) { counts, highlight in
            // A talk's slide the canvas set down, unwritten on, is no annotation.
            guard !highlight.isBareSlideMark else { return }
            counts[highlight.sourceID, default: 0] += 1
        }
        return sources.map { source in
            MemoryReviewCandidates.SourceInput(
                id: source.id,
                title: source.title,
                sourceType: source.sourceType,
                dateAdded: source.dateAdded,
                readAt: source.readAt,
                // Hiding one source is a list state, not a knowledge state, so
                // it stays reviewable; a hidden show or channel mutes its
                // episodes for the review as well.
                // An audio overview's script retells its notebook's sources,
                // which are what is reviewed (the Mac's `cohortCandidates`).
                isAvailable: !source.isArchived
                    && !MobileSourceVisibility.isCollectionHidden(source, collections: collections)
                    && source.state == "ready"
                    && !TextToSpeechPreparationPolicy.isAudioOverviewScript(url: source.url ?? ""),
                wordCount: source.wordCount,
                annotationCount: annotationCounts[source.id] ?? 0
            )
        }
    }

    /// What the Memory feature reads: the member's items and answers, and the sources and notebooks that
    /// decide which of them the phone may ask, from the replica's Card and Sitting payloads and its
    /// snapshot.
    private struct MemoryInputs {
        var items: [MemoryItem] = []
        var attempts: [MemoryAttempt] = []
        var sources: [MobileCloudSource] = []
        var collections: MobileCatalogCollections = .empty
        /// A notebook's approved sources by its id, archived notebooks too: what a card's notebook is
        /// derived from (`MobileNotebookCards`).
        var notebookMembers: [String: [String]] = [:]
        var goalParents: [String: String] = [:]
    }

    private func memoryInputs() async -> MemoryInputs {
        let memory = await replicaMemoryState()
        let snapshot = replicaSnapshot ?? MobileReadModels.Snapshot()
        return MemoryInputs(items: memory.items, attempts: memory.attempts, sources: snapshot.sources, collections: snapshot.collections,
                            notebookMembers: snapshot.notebookPools, goalParents: snapshot.goalParents)
    }

    /// The cards and answers, decoded once per replica load. A read that fails answers what the
    /// phone could not read as nothing held, and says so in the log; the next call tries again.
    /// Adds what the phone just wrote to the cards and answers it holds. With none held yet, the next
    /// read decodes them from the replica, which has the write already; a decode under way began before
    /// it, so it is not kept.
    private func noteReplicaMemory(_ change: (inout MobileReadModels.MemoryState) -> Void) {
        guard replicaMemory != nil else {
            replicaMemoryEpoch &+= 1
            return
        }
        change(&replicaMemory!)
    }

    private func replicaMemoryState() async -> MobileReadModels.MemoryState {
        if let held = replicaMemory {
            if replicaMemoryHandle?.memoryRevision == held.revision { return held }
            replicaMemory = nil
            replicaMemoryEpoch &+= 1
        }
        let epoch = replicaMemoryEpoch
        guard let projection = await replicaProjection() else { return MobileReadModels.MemoryState() }
        do {
            let state = try await MobileReadModels.memory(projection)
            // A load that finished meanwhile read a newer replica; this one is for this call only.
            if epoch == replicaMemoryEpoch {
                replicaMemory = state
                replicaMemoryHandle = projection.replica
            }
            return state
        } catch {
            Self.syncLogger.error("The cards and answers could not be read from the replica: \(error.localizedDescription, privacy: .public)")
            return MobileReadModels.MemoryState()
        }
    }

    /// The synced items the phone may ask: active, and anchored only on library
    /// sources it has (`MobileMemoryReviewScope.eligibleItems`).
    private func reviewableMemoryItems(
        in inputs: MemoryInputs,
        restrictToSourceIDs: Set<String>?
    ) -> [MemoryItem] {
        MobileMemoryReviewScope.eligibleItems(
            inputs.items,
            availableSourceIDs: Self.availableSourceIDs(in: inputs),
            restrictToSourceIDs: restrictToSourceIDs
        )
    }

    /// The library sources a card may stand on here: listed, not archived,
    /// and not an episode of a hidden show or channel. A source hidden by
    /// itself stays reviewable.
    private static func availableSourceIDs(in inputs: MemoryInputs) -> Set<String> {
        Set(
            inputs.sources
                .filter(Self.isAvailableInMobileLibrary)
                .filter { !$0.isArchived && !MobileSourceVisibility.isCollectionHidden($0, collections: inputs.collections) }
                .map(\.id)
        )
    }

    /// Today's card review over the synced items: the one queue every surface
    /// deals and counts from (`MemoryCardQueue.today`, over the items with a
    /// face, as the Mac's card review reads them), so the phone's card
    /// review, its Memory screen, Home's strip, its widget and the Mac agree
    /// on what today holds. The phone receives no calendar blocks or Goal end
    /// dates, so it passes no deadlines: its order skips (a), and a deadline
    /// notebook's new cards wait for the daily allowance.
    func currentTodayMemoryCards(
        now: Date = Date(),
        budgetMinutes: Int?,
        newPerDay: Int
    ) async -> MemoryCardQueue.Today {
        await currentCardReviewRead(now: now, budgetMinutes: budgetMinutes, newPerDay: newPerDay, scope: .allNotebooks).today
    }

    /// What a card sitting reads over `scope` (docs/memory-design.md, "The
    /// card review on the iPhone"): today's cards, the new cards practice
    /// would take, and each one's history, the Mac's
    /// `memoryCardReviewSnapshot` over the synced items the phone may show.
    /// A notebook this phone does not hold narrows to no card. Local only:
    /// it never waits on CloudKit.
    func currentCardReviewRead(
        now: Date = Date(),
        budgetMinutes: Int?,
        newPerDay: Int,
        scope: MemoryReviewScope
    ) async -> MobileCardReviewDealing.Read {
        let inputs = await memoryInputs()
        let cardScope: MemoryCardScope?
        switch scope {
        case .allNotebooks:
            cardScope = nil
        case .notebook(let notebookID):
            guard let found = Self.notebookCardScope(notebookID: notebookID, in: inputs) else { return .empty }
            cardScope = found
        }
        return MobileCardReviewDealing.read(
            items: reviewableMemoryItems(in: inputs, restrictToSourceIDs: nil),
            attempts: inputs.attempts,
            now: now,
            budgetMinutes: budgetMinutes,
            newPerDay: newPerDay,
            scope: cardScope
        )
    }

    /// A notebook's Practice: its kept cards, due, then new, then not yet
    /// due (`MemoryCardDeal.notebookPractice`); nil for a notebook this phone
    /// does not hold.
    func currentNotebookPractice(notebookID: String, now: Date = Date()) async -> MobileCardReviewDealing.NotebookPractice? {
        let inputs = await memoryInputs()
        guard let scope = Self.notebookCardScope(notebookID: notebookID, in: inputs) else { return nil }
        return MobileCardReviewDealing.notebookPractice(
            items: reviewableMemoryItems(in: inputs, restrictToSourceIDs: nil),
            attempts: inputs.attempts,
            scope: scope,
            now: now
        )
    }

    /// A notebook's Studio Cards row: "42 kept · 6 due", by the Mac's
    /// `notebookCardCounts`; nil for a notebook this phone does not hold.
    func currentNotebookCardCounts(
        notebookID: String,
        now: Date = Date(),
        budgetMinutes: Int?,
        newPerDay: Int
    ) async -> NotebookCardCounts? {
        let inputs = await memoryInputs()
        guard let scope = Self.notebookCardScope(notebookID: notebookID, in: inputs) else { return nil }
        let counts = MobileCardReviewDealing.notebookCounts(
            items: reviewableMemoryItems(in: inputs, restrictToSourceIDs: nil),
            attempts: inputs.attempts,
            scope: scope,
            now: now,
            budgetMinutes: budgetMinutes,
            newPerDay: newPerDay
        )
        let toCheck = await cardsToCheck(in: inputs, scope: scope, now: now)?.count ?? 0
        return NotebookCardCounts(kept: counts.kept, due: counts.due, toCheck: toCheck)
    }

    // MARK: Cards to check and a kept card's Card

    /// The cards to check over `scope` (docs/memory-design.md, "Cards to
    /// check on the iPhone"): the drafts in the replica's Cards whose source
    /// this phone lists, in To Check's order (`MobileCardRecords.toCheck`),
    /// narrowed to a notebook's by the Mac's `MemoryCardScope`. Empty for a
    /// notebook this phone does not hold; nil when the replica could not be
    /// read. Local only.
    func currentCardsToCheck(scope: MemoryReviewScope, now: Date = Date()) async -> [MemoryCardToCheck]? {
        let inputs = await memoryInputs()
        switch scope {
        case .allNotebooks:
            return await cardsToCheck(in: inputs, scope: nil, now: now)
        case .notebook(let notebookID):
            guard let cardScope = Self.notebookCardScope(notebookID: notebookID, in: inputs) else { return [] }
            return await cardsToCheck(in: inputs, scope: cardScope, now: now)
        }
    }

    private func cardsToCheck(in inputs: MemoryInputs, scope: MemoryCardScope?, now: Date) async -> [MemoryCardToCheck]? {
        guard let projection = await replicaProjection() else { return nil }
        do {
            let records = try await projection.replica.read { try MobileReadModels.draftDecks(in: $0) }
            let cards = MobileCardRecords.toCheck(records, availableSourceIDs: Self.availableSourceIDs(in: inputs), now: now)
            guard let scope else { return cards }
            return cards.filter { scope.contains(anchorSourceIDs: [$0.sourceID], goalID: nil) }
        } catch {
            Self.syncLogger.error("The cards to check could not be read from the replica: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The Cards of the kept cards `itemIDs` names, by id: what a card is
    /// worded by (its rewording, rewordings, "always ask it this way").
    /// Empty when the replica could not be read: a card is then asked in its
    /// own words. Local only.
    func currentCardRecords(itemIDs: [String]) async -> [String: MobileCardRecord] {
        guard !itemIDs.isEmpty, let projection = await replicaProjection() else { return [:] }
        do {
            return try await projection.replica.read { try MobileReadModels.cards(itemIDs, in: $0) }
        } catch {
            Self.syncLogger.error("The cards' records could not be read from the replica: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    /// Items this phone just kept, retired or started over: held at once,
    /// so the next read needs no second decode of the library.
    func noteWrittenMemoryItems(_ items: [MemoryItem]) {
        noteReplicaMemory { memory in
            for item in items { memory.note(item) }
        }
    }

    /// The notebooks a card review may be narrowed to: every notebook this
    /// phone holds, archived ones included (their cards are still asked).
    func currentCardReviewNotebookIDs() async -> Set<String> {
        Set(await memoryInputs().notebookMembers.keys)
    }

    /// The notebooks this phone holds with at least one kept card, the ones
    /// a card review's scope menu offers.
    func currentNotebookIDsWithCards() async -> Set<String> {
        let inputs = await memoryInputs()
        let scopes = inputs.notebookMembers.keys.compactMap { Self.notebookCardScope(notebookID: $0, in: inputs) }
        return MobileCardReviewDealing.notebookIDsWithCards(
            items: reviewableMemoryItems(in: inputs, restrictToSourceIDs: nil),
            attempts: inputs.attempts,
            scopes: scopes
        )
    }

    /// One card's item, whatever its status, and its whole history as this
    /// phone holds it: what a self-graded answer is decided from
    /// (`MobileSelfGradedAnswer`). Nil once the item is gone from the phone.
    func currentCardAnswerContext(memoryItemID: String) async -> (item: MemoryItem, history: [MemoryAttempt])? {
        let inputs = await memoryInputs()
        guard let item = inputs.items.first(where: { $0.id == memoryItemID }) else { return nil }
        return (item, inputs.attempts.filter { $0.memoryItemID == memoryItemID })
    }

    /// The items a mnemonic reading's questions kept (`itemIDs`, each
    /// question's `memoryItemID`) and their attempts, as the phone holds them:
    /// where the reading reads each question's standing and decides an
    /// answer. Local only.
    func currentMnemonicReadingHeld(itemIDs: Set<String>) async -> (items: [MemoryItem], attempts: [MemoryAttempt]) {
        guard !itemIDs.isEmpty else { return ([], []) }
        let inputs = await memoryInputs()
        var seen = Set<String>()
        let items = inputs.items.filter { itemIDs.contains($0.id) && seen.insert($0.id).inserted }
        return (items, inputs.attempts.filter { itemIDs.contains($0.memoryItemID) })
    }

    /// Whether today's review chat — made before cards, by the phone's daily
    /// preparation or by voice — holds an answer of the learner's: the one
    /// case the card review offers to continue it (docs/memory-design.md,
    /// "The card review on the iPhone"). A chat no one has answered in is not
    /// being resumed, and nothing prepares one from here.
    func currentDayReviewChatIsUnderway(now: Date = Date()) -> Bool {
        let sessionID = MemoryReviewSession.sessionID(for: now)
        // A chat the learner has answered in is one whose exchanges hold an answer.
        return replicaSnapshot?.memoryChats.contains { $0.id == sessionID && $0.isAnswered } ?? false
    }

    /// Every kept card the phone may show, oldest kept first: the Memory
    /// screen's All Cards (`MobileCardReviewDealing.listings`). Local only.
    func currentKeptCardListings() async -> [MemoryCardListing] {
        let inputs = await memoryInputs()
        return MobileCardReviewDealing.listings(
            items: reviewableMemoryItems(in: inputs, restrictToSourceIDs: nil),
            attempts: inputs.attempts
        )
    }

    func currentMemoryReviewChatDays(now: Date = Date()) -> MobileMemoryHistoryDays.Days {
        return MobileMemoryHistoryDays.days(of: replicaSnapshot?.memoryChats ?? [], now: now)
    }

    /// The notebook `notebookID` as a card scope (`MobileNotebookCards`): its
    /// approved pool by this phone's ids and the ids its record names, and
    /// every Goal's notebook.
    private static func notebookCardScope(notebookID: String, in inputs: MemoryInputs) -> MemoryCardScope? {
        guard let members = inputs.notebookMembers[notebookID] else { return nil }
        return MobileNotebookCards.scope(
            notebookID: notebookID,
            memberSourceIDs: members,
            goalParents: inputs.goalParents
        )
    }

    private func dueMemoryItems(
        _ items: [MemoryItem],
        attempts: [MemoryAttempt],
        now: Date,
        limit: Int
    ) -> [DueMemoryItem] {
        let attemptsByItemID = Dictionary(grouping: attempts) {
            $0.memoryItemID
        }
        let schedules = Dictionary(uniqueKeysWithValues: items.map { item in
            (
                item.id,
                MemoryTutorScheduler.schedule(
                    item: item,
                    attempts: attemptsByItemID[item.id] ?? []
                )
            )
        })
        // Recency is supplied here, where the pool is bounded, and not only to
        // the downstream selection: a pool capped by "most overdue" alone cannot
        // be reordered into containing this week's material afterwards.
        return MemoryTutorScheduler.dueItems(
            items: Array(items),
            schedules: schedules,
            now: now,
            limit: limit,
            recentSourceActivity: currentRecentSourceAttention(now: now)
        )
    }

    /// Resolve a bounded set of already-synced source identities without a
    /// network refresh. MemoryItem anchors remain authoritative; this supplies
    /// portable URL metadata for an atomic phone-authored session payload.
    /// One chat as review material — its title and the transcript its ideas
    /// are extracted from, built exactly as the Mac builds it so the two agree
    /// on the ideas' content hash. nil when the session is not a reviewable
    /// chat.
    func currentReviewableChatTranscript(sessionID: String) async throws -> (title: String, text: String)? {
        guard let zoneKey = replicaSnapshot?.chatZones[sessionID], let projection = await replicaProjection() else { return nil }
        return try await MobileReadModels.reviewableChat(chatID: sessionID, zoneKey: zoneKey, projection: projection)
    }

    func currentSources(ids: [String]) -> [MobileCloudSource] {
        let held = replicaSnapshot?.sources ?? []
        let byID = Dictionary(
            held.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return ids.compactMap { byID[$0] }
    }

    func memoryStruggleProjection(
        for item: MemoryItem,
        limit: Int = 3
    ) async -> MemoryStruggleProjection {
        let attempts = await memoryInputs().attempts.filter {
            $0.memoryItemID == item.id
        }
        return MemoryTutorStruggleProjector.project(
            item: item,
            attempts: attempts,
            limit: limit
        )
    }

    /// Publish a successful phone-authored attempt immediately. The key is the
    /// exact CloudKit record name, so the later zone delta replaces this row
    /// rather than duplicating it. CloudKit remains the durable source of truth.
    func noteRecordedMemoryAttempt(_ attempt: MemoryAttempt, recordName: String) {
        noteReplicaMemory { $0.note(attempt) }
    }

    func noteRecordedMemoryItem(_ item: MemoryItem, recordName: String) {
        noteReplicaMemory { $0.note(item) }
    }

    /// Raw Schedule placements for conflict-aware mobile mutations. Display rows
    /// intentionally omit persistence details, while writes need the stable
    /// placement id and complete goal membership.
    func currentScheduledSources() -> [MobileCloudScheduledSource] {
        return replicaSnapshot?.placements ?? []
    }

    /// Resolves every Schedule relationship on the catalog actor so the main
    /// actor only publishes a finished array. Missing/hidden/archived sources
    /// stay out, and unfinished work whose known goals are all inactive follows
    /// the same visibility rule as the Mac Schedule.
    func currentScheduleItems() -> [MobileScheduledCatalogItem] {
        guard let snapshot = replicaSnapshot else { return [] }
        return Self.scheduleItems(placements: snapshot.placements, sources: snapshot.sources, collections: snapshot.collections,
                                  goals: snapshot.scheduleGoals)
    }

    /// The Schedule's rows from its placements, whichever generation fed them.
    static func scheduleItems(placements: [MobileCloudScheduledSource], sources: [MobileCloudSource], collections: MobileCatalogCollections,
                              goals: [MobileCloudGoal]) -> [MobileScheduledCatalogItem] {
        let sourcesByID = Dictionary(
            sources
                .filter { !$0.isArchived && !MobileSourceVisibility.isHidden($0, collections: collections) }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let goalsByID = Dictionary(
            goals.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return placements.compactMap { placement in
            guard let source = sourcesByID[placement.sourceID] else { return nil }
            let knownGoals = placement.goalIDs.compactMap { goalsByID[$0] }
            if !placement.isCompleted,
               !knownGoals.isEmpty,
               knownGoals.allSatisfy({ !$0.isActive }) {
                return nil
            }

            var seenTitles = Set<String>()
            let goalTitles = placement.goalIDs
                .compactMap { goalsByID[$0]?.title }
                .filter { !$0.isEmpty && seenTitles.insert($0).inserted }
            let groupTitle = source.parentGroup.flatMap { groupID in
                collections.booksByID[groupID]?.title ?? collections.coursesByID[groupID]?.title
            }
            return MobileScheduledCatalogItem(
                id: placement.id,
                source: source,
                plannedAt: placement.plannedAt,
                isCompleted: placement.isCompleted,
                completedAt: placement.completedAt,
                groupTitle: groupTitle,
                goalTitles: goalTitles,
                goalIDs: placement.goalIDs,
                activityDays: placement.activityDays,
                isAutomatic: placement.isAutomatic
            )
        }
        .sorted { $0.plannedAt < $1.plannedAt }
    }

    func diagnose() async -> MobileSourceSyncDiagnostic {
        let checkedAt = Date()
        // The replica is the library, and the session reports its rounds.
        return MobileSourceSyncDiagnostic(
            accountStatus: "not checked", knowledgeZoneStatus: "moved to the new iCloud store",
            sourceRecordCount: replicaSnapshot?.sources.count, decodedSourceCount: lastDecodedSourceCount,
            zoneRecordCount: nil, zoneRecordTypes: nil, errorMessage: nil, checkedAt: checkedAt
        )
    }
}

/// An audio overview the Mac saved for a notebook (docs/explainer-design.md,
/// "Audio overviews"): its Artifact, read from the synced record, and the id
/// of the carrier source its script and audio live on.
struct MobileAudioOverviewRecord: Identifiable, Equatable, Sendable {
    /// `ArtifactKind.audioOverview`'s raw value. The Mac's `Artifacts.swift`
    /// is not compiled here; `MobileCloudMutationServiceTests` pins the word.
    static let artifactKind = "audio_overview"

    let id: String
    let title: String?
    let notebookIDs: Set<String>
    let createdAt: Date?
    let carrierSourceID: String
}

/// One audio overview as a notebook's page lists it: its title and the
/// carrier source it plays through, the way any source plays here.
struct MobileAudioOverviewListing: Identifiable, Equatable {
    let id: String
    let title: String
    let carrier: MobileCloudSource
}

private enum MobileCloudSourceCatalogError: LocalizedError {
    case missingKnowledgeZone
    case replicaUnavailable

    var errorDescription: String? {
        switch self {
        case .missingKnowledgeZone:
            return "CloudKit returned no Knowledge zone."
        case .replicaUnavailable:
            return "This iPhone's copy of your library could not be opened."
        }
    }
}
