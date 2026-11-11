// Catalog loading, sync status, notebook reads and card review reads.

import Foundation
import OSLog
import WidgetKit

extension MobileAudioReviewViewModel {
    nonisolated private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "AudioReviewCatalog")

    /// Coalesce the three catalog projections into one widget write. Encoding,
    /// app-group UserDefaults, and WidgetCenter invalidation can all block, so
    /// the main actor only captures copy-on-write value snapshots here.
    func scheduleTodayWidgetSnapshotPublish() {
        widgetSnapshotPublishTask?.cancel()
        let scheduleSnapshot = scheduleItems
        let cardsSnapshot = todayMemoryCards
        widgetSnapshotPublishTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let calendar = Calendar.autoupdatingCurrent
            // Deliberate placements only: an anchor the app wrote to hold a
            // source's activity is history, not something the learner planned,
            // and the widget must never count it as work waiting today.
            let pending = scheduleSnapshot.filter {
                !$0.isAutomatic && calendar.isDateInToday($0.plannedAt) && !$0.isCompleted
            }
            // Only the day's half: the bout's clock is written by
            // MobileLearningBoutTimer into the same record, and neither writer
            // may blank the other's fields.
            MobileTodayWidgetSnapshotStore.saveDay(
                pendingCount: pending.count,
                nextTitle: pending.first?.source.title,
                // Counts only: a card's target is its answer. The review the
                // widget opens is the phone's card review, which deals these
                // due and new cards ("6 due · 4 new").
                memoryDueCount: cardsSnapshot.dueCount,
                memoryNewCount: cardsSnapshot.newCount
            )
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadTimelines(ofKind: "ForeverLMTodayWidget")
        }
    }

    /// Streams a sync into the UI: a two-step progress readout, and the list
    /// itself filling in batch by batch — "nothing until minute ten" is the
    /// exact first-run experience this replaces.
    func handleSyncProgress(
        pending: Int,
        walking: Bool,
        scanned: Int,
        fullPass: Bool,
        expectedScan: Int?,
        drainTotal: Int?
    ) async {
        if walking {
            // The scanned count is the line's spine: the zone is mostly record
            // types the walk skips (usage events, chat history), and on a
            // from-scratch pass whole minutes can go by before the first
            // source-type record appears. "Found" alone would sit at nothing.
            // The previous full walk's total turns the count into a real bar.
            let expected = fullPass ? expectedScan : nil
            let denominator = expected.map { " of ~\($0.formatted())" } ?? ""
            let found = pending > 0 ? " · \(pending.formatted()) to download" : ""
            publishSyncStatus(
                MobileCatalogSyncStatus(
                    phase: .scanning,
                    stepText: "Step 1 of 2 · Scanning your library",
                    detailText: "\(scanned.formatted())\(denominator) records\(found)",
                    fractionComplete: expected.map { min(Double(scanned) / Double(max($0, 1)), 0.98) }
                )
            )
        } else if pending > 0 {
            let total = max(drainTotal ?? pending, pending)
            let done = total - pending
            publishSyncStatus(
                MobileCatalogSyncStatus(
                    phase: .downloading,
                    stepText: "Step 2 of 2 · Downloading sources",
                    detailText: "\(done.formatted()) of \(total.formatted()) records",
                    fractionComplete: Double(done) / Double(max(total, 1))
                )
            )
        } else {
            publishSyncStatus(nil)
        }

        if pending > 0 || allSources.isEmpty {
            notebooks = await sourceCatalog.currentNotebooks()
            collections = await sourceCatalog.currentCollections()
            audioOverviewRecords = await sourceCatalog.currentAudioOverviews()
            await publishNotebookCatalog()
            publishCatalogSources(await sourceCatalog.currentSources())
            scheduledSources = await sourceCatalog.currentScheduledSources()
            scheduleItems = await sourceCatalog.currentScheduleItems()
            await refreshMemorySnapshot()
        }
    }

    func dismissInitialSyncScreen() {
        hasDismissedInitialSyncScreen = true
    }

    /// One writer for both projections of sync state, so the compact line and
    /// the structured status can never disagree about whether a sync is running.
    private func publishSyncStatus(_ status: MobileCatalogSyncStatus?) {
        catalogSyncStatus = status
        notebookSyncStatus()
    }

    private func publishNarrationScanStatus(_ status: MobileCatalogSyncStatus?) {
        narrationScanStatus = status
        notebookSyncStatus()
    }

    private func notebookSyncStatus() {
        let status = catalogSyncStatus ?? narrationScanStatus
        syncStatus = status
        syncProgressText = status.map { "\($0.stepText) · \($0.detailText)" }
    }

    /// Maps catalog rows into the published list (archived filter, audio badge
    /// from the synced manifests, newest first). The catalog already dropped
    /// hidden sources. Shared by the finished load and the progressive
    /// first-sync fill.
    func publishCatalogSources(_ catalog: [MobileCloudSource]) {
        let manifestIDs = Set(items.map { $0.id })
        allSources = catalog
            .filter { !$0.isArchived }
            .map { source in
                var row = source
                row.hasAudio = manifestIDs.contains(source.id)
                return row
            }
            .sorted { $0.dateAdded > $1.dateAdded }
        // Which sources have an explainer, read off the explainers' own URLs
        // (`foreverlm://explainer/<sourceID>`), so a row can answer without a
        // hash and without scanning the list.
        var explainers: [String: String] = [:]
        for source in allSources {
            if let explained = ExplainerScript.explainedSourceID(from: source.url ?? "") {
                explainers[explained] = source.id
            }
        }
        explainerIDsByExplainedSourceID = explainers
    }

    /// The id of the source's explainer when the library has one — an
    /// article-typed source whose URL names this source (explainer-design.md).
    func explainerID(explaining sourceID: String) -> String? {
        explainerIDsByExplainedSourceID[sourceID]
    }

    /// A notebook's audio overviews whose script source has reached this
    /// phone, newest first. An overview whose script has not synced yet is
    /// left out until it has. The phone does not make them yet; the Mac's
    /// Studio and `generate_audio_overview` do.
    func audioOverviews(inNotebook notebookID: String) -> [MobileAudioOverviewListing] {
        let records = audioOverviewRecords.filter { $0.notebookIDs.contains(notebookID) }
        guard !records.isEmpty else { return [] }
        let byID = sourcesByID
        return records
            .sorted { ($0.createdAt ?? .distantPast, $1.id) > ($1.createdAt ?? .distantPast, $0.id) }
            .compactMap { record in
                byID[record.carrierSourceID].map {
                    MobileAudioOverviewListing(id: record.id, title: record.title ?? $0.title, carrier: $0)
                }
            }
    }

    // MARK: - Notebooks

    /// The Docs and chats notebooks list, from the same checkpoint as the
    /// Notebooks published beside them.
    private func publishNotebookCatalog() async {
        notebookArtifacts = await sourceCatalog.currentNotebookArtifacts()
        notebookChatsByNotebookID = await sourceCatalog.currentNotebookChats()
        scheduleShareNotebookListPublish()
    }

    /// The share sheet's notebooks (`MobileShareNotebookStore`), since the
    /// extension cannot read the CloudKit catalog: Home's order, each
    /// notebook's id and title and nothing else, written into the app group
    /// whenever the catalog publishes its notebooks — coalesced, off the main
    /// actor, and only when the list changed.
    private func scheduleShareNotebookListPublish() {
        shareNotebookListPublishTask?.cancel()
        let notebooksSnapshot = notebooks
        let lastChatAt = lastNotebookChatAt
        shareNotebookListPublishTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let notebooks = Self.shareNotebooks(notebooksSnapshot, lastChatAt: lastChatAt)
            MobileShareNotebookStore.shared?.save(notebooks)
        }
    }

    /// Home's notebooks as the share sheet lists them (`MobileNotebookOrdering`).
    nonisolated static func shareNotebooks(
        _ notebooks: [MobileCloudNotebook],
        lastChatAt: [String: Date]
    ) -> [MobileShareNotebook] {
        MobileNotebookOrdering.sorted(notebooks, lastChatAt: lastChatAt)
            .map { MobileShareNotebook(id: $0.id, title: $0.title) }
    }

    /// The chats filed under a notebook, newest first.
    func notebookChats(in notebookID: String) -> [MobileNotebookChatSummary] {
        notebookChatsByNotebookID[notebookID] ?? []
    }

    /// One of the notebooks' chats by its session id; nil when no notebook
    /// on this phone lists it.
    func notebookChat(sessionID: String) -> MobileNotebookChatSummary? {
        for chats in notebookChatsByNotebookID.values {
            if let chat = chats.first(where: { $0.id == sessionID }) { return chat }
        }
        return nil
    }

    /// Whether the phone continues a notebook's saved chat, or shows it
    /// read-only and why (`MobileNotebookChatContinuation.verdict`).
    func continuation(of chat: MobileNotebookChatSummary) -> MobileNotebookChatContinuation.Verdict {
        MobileNotebookChatContinuation.verdict(shape: chat.shape, sourceIDs: chat.sourceIDs) {
            sourcesByID[$0] != nil
        }
    }

    /// When each notebook's latest chat happened, for Home's order (each list
    /// is newest first).
    var lastNotebookChatAt: [String: Date] {
        notebookChatsByNotebookID.compactMapValues { $0.first?.lastActivityAt }
    }

    /// The Docs a notebook holds — homed on it or linked to it — that the
    /// Mac's Studio lists (`NotebookOutputs.isListed`, `kind(of:)`): an audio
    /// overview is never one of them, even one an older build saved back
    /// without its kind, which its script's carrier source still names.
    func docs(in notebook: MobileCloudNotebook) -> [MobileCloudArtifact] {
        let overviewIDs = Set(audioOverviewRecords.map(\.id))
        return notebookArtifacts.filter { artifact in
            artifact.isListed
                && artifact.isDoc
                && artifact.belongs(toNotebookID: notebook.id)
                && !overviewIDs.contains(artifact.id)
                && sourcesByID[MobileCloudMutationService.audioOverviewSourceID(artifactID: artifact.id)] == nil
        }
    }

    /// The notebook's own sources as this phone has them — never a context
    /// notebook's — which the walkthroughs and spoken explainers in its
    /// Studio ride (the Mac's `notebookOutputMemberIDs`).
    func notebookOwnSources(in notebook: MobileCloudNotebook) -> [MobileCloudSource] {
        let own = Set(notebook.sourceIDs)
        return notebookSources(in: notebook).filter { own.contains($0.id) }
    }

    /// The notebook's context notebooks this phone has a record of, in link
    /// order, each with the sources its group lists under the notebook's own
    /// (the Sources tab, the iPad's column, the chat's Sources sheet).
    func contextNotebookGroups(in notebook: MobileCloudNotebook) -> [MobileNotebookContextGroup] {
        let byID = sourcesByID
        return notebook.contextNotebooks.map { contextNotebook in
            MobileNotebookContextGroup(
                notebook: contextNotebook,
                sources: contextNotebook.sourceIDs.compactMap { byID[$0] }.filter { !MobileSourceListing.isSpokenScript($0) }
            )
        }
    }

    /// The courses a notebook links, in the Mac's order, that this phone has.
    func linkedCourses(in notebook: MobileCloudNotebook) -> [MobileCloudCourse] {
        notebook.linkedCourseIDs.compactMap { collections.coursesByID[$0] }.filter { !$0.isHidden }
    }

    /// One saved chat as the read-only transcript shows it, the tutor's
    /// Markdown parsed once, off the main actor.
    func chatTranscript(sessionID: String) async -> MobileVoiceChatTranscript? {
        guard let turns = await sourceCatalog.currentChatTranscriptTurns(sessionID: sessionID) else { return nil }
        let messages = await Task.detached(priority: .userInitiated) {
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
            return turns.map { turn in
                MobileChatMessage(
                    id: UUID(),
                    role: turn.role == .user ? .user : .assistant,
                    content: turn.content,
                    isStreaming: false,
                    rendered: turn.role == .user ? nil : try? AttributedString(markdown: turn.content, options: options)
                )
            }
        }.value
        return MobileVoiceChatTranscript(messages: messages)
    }

    /// A notebook's Studio Cards row: "42 kept · 6 due", by the Mac's
    /// `notebookCardCounts`, with the day's minutes and new cards as last
    /// read; nil for a notebook not on this phone.
    func notebookCardCounts(in notebook: MobileCloudNotebook) async -> NotebookCardCounts? {
        await sourceCatalog.currentNotebookCardCounts(
            notebookID: notebook.id,
            budgetMinutes: memoryReviewPreferences.budgetMinutes,
            newPerDay: memoryReviewPreferences.newCardsPerDay
        )
    }

    // MARK: - The card review

    /// What a card sitting over `scope` deals (`MobileCardReviewSession`), with the
    /// day's minutes and new cards as last read. Local only.
    func cardReviewRead(scope: MemoryReviewScope, now: Date = Date()) async -> MobileCardReviewDealing.Read {
        await sourceCatalog.currentCardReviewRead(
            now: now,
            budgetMinutes: memoryReviewPreferences.budgetMinutes,
            newPerDay: memoryReviewPreferences.newCardsPerDay,
            scope: scope
        )
    }

    /// A notebook's Practice: its kept cards; nil for a notebook not on this
    /// phone.
    func notebookPractice(notebookID: String, now: Date = Date()) async -> MobileCardReviewDealing.NotebookPractice? {
        await sourceCatalog.currentNotebookPractice(notebookID: notebookID, now: now)
    }

    /// The notebooks a card review may be narrowed to, archived ones included.
    func cardReviewNotebookIDs() async -> Set<String> {
        await sourceCatalog.currentCardReviewNotebookIDs()
    }

    /// The notebooks holding at least one kept card.
    func cardReviewNotebookIDsWithCards() async -> Set<String> {
        await sourceCatalog.currentNotebookIDsWithCards()
    }

    func cardAnswerContext(memoryItemID: String) async -> (item: MemoryItem, history: [MemoryAttempt])? {
        await sourceCatalog.currentCardAnswerContext(memoryItemID: memoryItemID)
    }

    /// A mnemonic reading's questions' items and their attempts on this
    /// phone (`MobileMnemonicReadingModel`). Local only.
    func mnemonicReadingHeld(itemIDs: Set<String>) async -> (items: [MemoryItem], attempts: [MemoryAttempt]) {
        await sourceCatalog.currentMnemonicReadingHeld(itemIDs: itemIDs)
    }

    /// A card a mnemonic reading just kept, with its first attempt: both
    /// published in the catalog at once, under the record names CloudKit
    /// holds them by, and today's cards dealt again, so the notebook's Cards
    /// row and the card review see it.
    func noteKeptReadingCard(_ item: MemoryItem, firstAttempt attempt: MemoryAttempt) async {
        await sourceCatalog.noteRecordedMemoryItem(
            item,
            recordName: MobileReviewSessionRecorder.memoryItemRecordName(for: item.id)
        )
        await sourceCatalog.noteRecordedMemoryAttempt(
            attempt,
            recordName: MobileMemoryAttemptRecorder.recordName(for: attempt.id)
        )
        await refreshMemorySnapshot()
    }

    func dayReviewChatIsUnderway() async -> Bool {
        await sourceCatalog.currentDayReviewChatIsUnderway()
    }

    /// The Memory screen's All Cards: every kept card on this phone, oldest
    /// kept first. Local only.
    func keptCardListings() async -> [MemoryCardListing] {
        await sourceCatalog.currentKeptCardListings()
    }

    // MARK: - Going through cards

    /// The cards to check over `scope` (To Check), in their order; nil when
    /// the replica could not be read. Local only.
    func cardsToCheck(scope: MemoryReviewScope, now: Date = Date()) async -> [MemoryCardToCheck]? {
        await sourceCatalog.currentCardsToCheck(scope: scope, now: now)
    }

    /// The Cards of kept cards, by item id: what words them. Local only.
    func cardRecords(itemIDs: [String]) async -> [String: MobileCardRecord] {
        await sourceCatalog.currentCardRecords(itemIDs: itemIDs)
    }

    /// Writes what the learner decided in To Check — Keep, Edit then Keep,
    /// Skip, Keep All, Skip All — on each card's Card
    /// (`MobileCardTriageWriter`), then deals today's cards again, so a card
    /// kept here is a card of Memory at once. A card the phone could not
    /// keep stays to check, and the result says why.
    @discardableResult
    func triageCardsToCheck(_ decisions: [MemoryCardTriageDecision]) async -> MemoryCardTriageResult {
        guard !decisions.isEmpty else { return MemoryCardTriageResult() }
        let writer: MobileRecordWriter
        do {
            writer = try await MobileRecordWriter.required()
        } catch {
            var result = MemoryCardTriageResult()
            result.failed = decisions.map { MemoryCardTriageResult.Failure(cardID: $0.card.cardID, reason: error.localizedDescription) }
            return result
        }
        let textStore = sourceTextStore
        let outcome = await MobileCardTriageWriter.apply(decisions, writer: writer) { sourceID in
            do {
                return try await textStore.loadSourceText(sourceID: sourceID)
            } catch {
                Self.logger.error("Loading a source's text for the card change failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        await sourceCatalog.noteWrittenMemoryItems(outcome.kept)
        await refreshMemorySnapshot()
        return outcome.result
    }

    /// Edit Card on a kept card: a new front alone rewords it; a new back or
    /// why starts it over (`MobileCardEditWriter`), as the Mac's All Cards
    /// does. `wording` is the card's wording as asked now.
    func applyCardEdit(_ edit: MemoryCardEdit, to card: MemoryCardListing, wording: String) async throws {
        if MobileCardEditWriter.startsOver(card, edit) {
            try await startCardOver(card, edit: edit, wording: wording)
            return
        }
        let front = try MobileCardEditWriter.rewording(card, front: edit.front, wording: wording)
        try await MobileRecordWriter.required().transaction { try $0.rewordCard(card.itemID, front: front) }
        await refreshMemorySnapshot()
    }

    /// "Start this card over?": the card retired with its answers and its
    /// revision kept under a new card id on the passages its sources still
    /// print, in `edit`'s words or as it is asked now.
    func startCardOver(_ card: MemoryCardListing, edit: MemoryCardEdit?, wording: String) async throws {
        guard let old = await cardAnswerContext(memoryItemID: card.itemID)?.item else { throw MobileCardRecords.Refusal.gone }
        var texts: [String: String] = [:]
        for sourceID in Set(old.sources.map(\.sourceID)) {
            do {
                texts[sourceID] = try await sourceTextStore.loadSourceText(sourceID: sourceID)
            } catch {
                Self.logger.error("Loading a source's text to start a card over failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let face = MobileCardEditWriter.revisedFace(card, edit: edit, wording: wording, newID: UUID().uuidString.lowercased())
        let now = Date()
        let revision = try MobileCardRecords.revision(of: old, as: face, texts: texts, at: now)
        try await MobileRecordWriter.required().transaction { try $0.startCardOver(old.id, as: revision) }
        await sourceCatalog.noteWrittenMemoryItems([MobileCardRecords.retired(old, at: now), revision])
        await refreshMemorySnapshot()
    }

    /// Retire: the card is never asked again.
    func retireCard(_ card: MemoryCardListing) async throws {
        try await MobileRecordWriter.required().transaction { try $0.retireCard(card.itemID) }
        if let item = await cardAnswerContext(memoryItemID: card.itemID)?.item {
            await sourceCatalog.noteWrittenMemoryItems([MobileCardRecords.retired(item, at: Date())])
        }
        await refreshMemorySnapshot()
    }

    /// "Always Ask in Its Own Words", or "Let Its Wording Vary".
    func setCardAlwaysAsk(_ on: Bool, itemID: String) async throws {
        try await MobileRecordWriter.required().transaction { try $0.setCardAlwaysAsk(itemID, on) }
        await refreshMemorySnapshot()
    }

    /// "This asks something else" on a card asked in a rewording: the
    /// rewording taken out on its Card, and the failed attempt that says so
    /// in this device's Sitting, which moves no schedule. Once a sitting and
    /// wording.
    func reportCardAskedSomethingElse(itemID: String, prompt: String, variantIndex: Int, sessionKey: String, at now: Date = Date()) async throws {
        let fingerprint = await cardAnswerContext(memoryItemID: itemID).map { MemoryTutorIdentity.immutableCurriculumFingerprint($0.item) }
        let attempt = MemoryCardVariation.askedSomethingElseAttempt(
            id: MobileCardEditWriter.askedSomethingElseAttemptID(sessionKey: sessionKey, memoryItemID: itemID, prompt: prompt),
            memoryItemID: itemID,
            prompt: prompt,
            variantIndex: variantIndex,
            at: now
        )
        try await MobileRecordWriter.required().transaction { write in
            try write.retireCardVariant(itemID, text: prompt)
            _ = try write.recordAnswer(attempt, curriculumFingerprint: fingerprint, anyHeldCounts: true)
        }
        await sourceCatalog.noteRecordedMemoryAttempt(attempt, recordName: attempt.id)
        await refreshMemorySnapshot()
    }

    /// The Memory screen's history grid: the earlier days with a review chat
    /// to open, and the days the learner wrote in. Local only.
    func memoryReviewChatDays() async -> MobileMemoryHistoryDays.Days {
        await sourceCatalog.currentMemoryReviewChatDays()
    }

    /// A card answer the card review just saved: published in the catalog at
    /// once, under the record name CloudKit holds it by (the zone delta later
    /// replaces it rather than adding a second), and today's cards dealt
    /// again, so Home, the widget and the next round see it.
    func noteRecordedCardAnswer(_ attempt: MemoryAttempt) async {
        await sourceCatalog.noteRecordedMemoryAttempt(
            attempt,
            recordName: MobileMemoryAttemptRecorder.recordName(for: attempt.id)
        )
        await refreshMemorySnapshot()
    }

    /// The sources a notebook lists as rows: its own sources as synced here
    /// (on a value narrowed for a voice conversation, what that reads),
    /// without the spoken scripts (explainers, an audio overview's carrier),
    /// which belong under their source or the Studio. Its context notebooks'
    /// are their groups' (`contextNotebookGroups`).
    func notebookSources(in notebook: MobileCloudNotebook) -> [MobileCloudSource] {
        sources(in: notebook).filter { !MobileSourceListing.isSpokenScript($0) }
    }

    /// How many sources the notebook's card and list say it holds: a book's
    /// chapters count as the one book, as on the Mac (`NotebookSourceTally`).
    func notebookSourceCount(in notebook: MobileCloudNotebook) -> Int {
        NotebookSourceTally.count(notebookSources(in: notebook)) { source in
            source.sourceType == "book" ? source.parentGroup : nil
        }
    }

    /// Coalesces the phone window, CarPlay, and lifecycle triggers onto one
    /// publication pass. A launch can activate its scene while the root `.task`
    /// is still loading; allowing both callers through made Home return to the
    /// full-screen "Syncing your sources" state for a second, shorter pass.
    ///
    /// `scansNarrations` is false for a reload the replica asked for (a write or a sync round): the audio
    /// tree in iCloud Drive is walked at launch and when the app comes forward, not for each of those.
    @discardableResult
    func load(forceRefresh: Bool = true, scansNarrations: Bool = true) async -> Bool {
        if forceRefresh {
            forcedCatalogReloadRequested = true
        }
        if scansNarrations {
            narrationScanRequested = true
        }
        if let activeCatalogLoad {
            return await activeCatalogLoad.task.value
        }

        let id = UUID()
        let task: Task<Bool, Never> = Task { @MainActor [weak self] in
            guard let self else { return false }
            var succeeded = false
            repeat {
                let shouldForceRefresh = self.forcedCatalogReloadRequested
                self.forcedCatalogReloadRequested = false
                let shouldScanNarrations = self.narrationScanRequested
                self.narrationScanRequested = false
                succeeded = await self.performLoad(forceRefresh: shouldForceRefresh, scansNarrations: shouldScanNarrations)
            } while self.forcedCatalogReloadRequested
            if self.activeCatalogLoad?.id == id {
                self.activeCatalogLoad = nil
            }
            return succeeded
        }
        activeCatalogLoad = (id, task)
        return await task.value
    }

    /// True while a first sync is running and the full-screen readout is not:
    /// either sources are already on screen behind it, or the learner left it.
    /// Ordinary delta syncs stay silent — this is the multi-minute pass only.
    var showsShellSyncStatus: Bool {
        (isInitialCatalogSync || isInitialNarrationScan)
            && (!allSources.isEmpty || hasDismissedInitialSyncScreen)
    }

    /// Deals today's cards again from the catalog. Local only: it runs before
    /// a recorded voice answer returns to the tutor and on the load's
    /// checkpoint, so it never waits on CloudKit. The minutes and new cards a
    /// day are the account's as last read (`memoryReviewPreferences`); the
    /// new cards are set on the Mac or over MCP, the phone having no control
    /// of its own for them.
    func refreshMemorySnapshot() async {
        todayMemoryCards = await sourceCatalog.currentTodayMemoryCards(
            budgetMinutes: memoryReviewPreferences.budgetMinutes,
            newPerDay: memoryReviewPreferences.newCardsPerDay
        )
        cardsToCheckTotal = await sourceCatalog.currentCardsToCheck(scope: .allNotebooks)?.count ?? cardsToCheckTotal
        memoryCardsRevision &+= 1
    }

    /// The learner changed the day's minutes in the phone's Settings, which
    /// wrote the synced row: today's cards are cut to the new budget now,
    /// rather than at the next load (which re-reads the row, on every
    /// foreground as well).
    func memoryReviewBudgetDidChange(to minutes: Int) async {
        let minutes = MemoryReviewBudget.clamp(minutes)
        guard minutes != memoryReviewPreferences.budgetMinutes else { return }
        memoryReviewPreferences.budgetMinutes = minutes
        await refreshMemorySnapshot()
    }

    /// Re-reads the day's minutes and new cards, two CloudKit fetches side by
    /// side, and deals today's cards again when either changed. A failed read
    /// keeps the value last read; a learner who never set one has the
    /// product's default, the Mac's.
    private func refreshMemoryReviewPreferences() async {
        async let budgetRead = Self.syncedIntRead(Prefs.Memory.budgetMinutes)
        async let newCardsRead = Self.syncedIntRead(Prefs.Memory.newCardsPerDay)
        let budget = await budgetRead
        let newCards = await newCardsRead
        let refreshed = memoryReviewPreferences.refreshed(budgetRead: budget, newCardsRead: newCards)
        guard refreshed != memoryReviewPreferences else { return }
        memoryReviewPreferences = refreshed
        await refreshMemorySnapshot()
    }

    /// One synced whole number's read: nil when the learner never set it, a
    /// failure when iCloud did not answer.
    private nonisolated static func syncedIntRead(_ key: AccountKey<Int?>) async -> Result<Int?, Error> {
        do {
            return .success(try await MobileModelPreferenceStore.shared.valueOrDefault(for: key))
        } catch {
            return .failure(error)
        }
    }

    private func performLoad(forceRefresh: Bool, scansNarrations: Bool = true) async -> Bool {
        defer {
            publishSyncStatus(nil)
        }

        await refreshManagedSignInState()
        isLoading = true

        // Publish the durable checkpoint first — before the audio manifests and
        // before asking CloudKit for deltas. It is local SQLite and costs
        // nothing, so rebuilds open on the previously synced library.
        //
        // Order matters here, and it is not cosmetic. The manifest pass below
        // walks the shared iCloud audio tree, thousands of files: it asks
        // CloudDocs to materialize every manifest the Mac has published. Loading
        // it ahead of this publish, with `isLoading` gated behind it, would let
        // one slow or wedged CloudDocs hide a fully synced library behind the
        // spinner indefinitely. The manifest pass runs alongside the CloudKit
        // walk, see below.
        let checkpointSources = await sourceCatalog.currentSources()
        if !checkpointSources.isEmpty {
            notebooks = await sourceCatalog.currentNotebooks()
            collections = await sourceCatalog.currentCollections()
            audioOverviewRecords = await sourceCatalog.currentAudioOverviews()
            await publishNotebookCatalog()
            publishCatalogSources(checkpointSources)
            scheduledSources = await sourceCatalog.currentScheduledSources()
            scheduleItems = await sourceCatalog.currentScheduleItems()
            // The library is on screen. Everything after this point refines it.
            isLoading = false
        }
        await refreshMemorySnapshot()
        // The day's minutes cut today's cards and its new cards cap them;
        // their read waits on CloudKit, so it runs beside the load rather
        // than ahead of it.
        Task { [weak self] in await self?.refreshMemoryReviewPreferences() }

        // The manifest pass rides alongside the CloudKit sync, never ahead of
        // it. It walks the shared iCloud audio tree — hundreds of narrations,
        // gigabytes of chunks — and on a device that has not materialized those
        // files yet every manifest read blocks until CloudDocs delivers it. The
        // checkpoint publish above shields a rebuild from that, but a first
        // launch has no checkpoint: with the manifests awaited first, the zone
        // walk never started, no progress line ever fired, and the setup screen
        // sat on "Connecting to iCloud…" for as long as iCloud Drive took. Now
        // the walk starts immediately and the audio badges land whenever the
        // manifests do, re-stamping whichever rows are on screen by then.
        //
        // On a first launch the scan reports its own count, so that once the
        // CloudKit readout clears the shell row says how many source folders
        // are still to check rather than a bare "Syncing your library".
        let manifestLoad: Task<Void, Error>? = !scansNarrations ? nil : Task { [weak self] () throws -> Void in
            defer {
                Task { @MainActor [weak self] in
                    self?.isInitialNarrationScan = false
                    self?.publishNarrationScanStatus(nil)
                }
            }
            // The replica's narrations are laid into the working folder first, and one this phone made is
            // uploaded in the background (§3.5.30).
            await MobileNarrationLibrary.shared.refresh()
            let manifests = try await Task.detached(priority: .userInitiated) {
                try SyncedArticleAudioStore.loadAvailableManifests(onProgress: { _, _ in })
            }.value
            guard let self else { return }
            self.items = manifests.map(MobileAudioItem.init(manifest:))
            // `hasAudio` is read off `items`, so rows published before this
            // point — the checkpoint, or the walk's progressive fill — carried
            // none. Stamping the published rows again is idempotent.
            if !self.allSources.isEmpty {
                self.publishCatalogSources(self.allSources)
            }
            self.startObservingSyncedAudioManifests()
        }

        var catalogLoadSucceeded = false
        do {
            let catalog = try await sourceCatalog.loadSources(forceRefresh: forceRefresh)
            // Same zone pass as the sources — refreshing here keeps the Notebooks
            // list and the book/course metadata as fresh as the sources they shape.
            do {
                notebooks = try await sourceCatalog.loadNotebooks()
            } catch {
                Self.logger.error("Loading the notebooks failed: \(error.localizedDescription, privacy: .public)")
            }
            do {
                collections = try await sourceCatalog.loadCollections()
            } catch {
                Self.logger.error("Loading the collections failed: \(error.localizedDescription, privacy: .public)")
            }
            audioOverviewRecords = await sourceCatalog.currentAudioOverviews()
            await publishNotebookCatalog()
            publishCatalogSources(catalog)
            scheduledSources = await sourceCatalog.currentScheduledSources()
            scheduleItems = await sourceCatalog.currentScheduleItems()
            await refreshMemorySnapshot()
            // The library is on screen, and what is left (the narration scan beside this load) only refines it.
            // A phone that switched has no checkpoint to publish ahead of this, so the spinner it opened on
            // would otherwise wait for the walk of the iCloud Drive audio tree as well.
            if !allSources.isEmpty { isLoading = false }
            if allSources.isEmpty {
                sourceSyncDiagnostic = await sourceCatalog.diagnose()
            } else {
                sourceSyncDiagnostic = MobileSourceSyncDiagnostic(
                    accountStatus: "not checked",
                    knowledgeZoneStatus: "load succeeded",
                    sourceRecordCount: catalog.count,
                    decodedSourceCount: catalog.count,
                    zoneRecordCount: nil,
                    zoneRecordTypes: nil,
                    errorMessage: nil,
                    checkedAt: Date()
                )
            }
            catalogLoadSucceeded = true
            if errorMessage == lastSourceSyncErrorMessage {
                errorMessage = nil
            }
            lastSourceSyncErrorMessage = nil
        } catch {
            sourceSyncDiagnostic = await sourceCatalog.diagnose()
            let message = "Sources could not sync: \(MobileCloudKitRetry.describe(error))"
            lastSourceSyncErrorMessage = message
            errorMessage = message
        }

        // Home's collections are found through the notebooks just published
        // (`MobileNotebookCollectionsStore`); their reads wait on CloudKit,
        // so they run beside the rest of the load rather than ahead of it.
        Task { [weak self] in await self?.refreshNotebookCollections() }
        // Home's Pinned and the learner's notebook order, the same way.
        Task { [weak self] in await self?.refreshNotebookRail() }

        var manifestError: Error?
        do {
            try await manifestLoad?.value
        } catch {
            manifestError = error
            items = []
        }

        // A library that would not sync still lists the narrations this device
        // holds — decided once both passes have reported, so the fallback rows
        // reflect the manifests that actually arrived.
        if !catalogLoadSucceeded, allSources.isEmpty {
            allSources = items.map {
                MobileCloudSource(
                    id: $0.id,
                    title: $0.title,
                    subtitle: $0.subtitle,
                    sourceType: $0.manifest.sourceType,
                    dateAdded: $0.createdAt,
                    hasAudio: true,
                    isArchived: false
                )
            }
        }

        if allSources.isEmpty,
           lastSourceSyncErrorMessage == nil,
           let error = manifestError {
            errorMessage = error.localizedDescription
        }

        // Source/manifest loading is done; clear the loading overlay before the
        // hands-free voice session starts. Voice startup (mic/speech authorization,
        // continuous listening) must never keep the "Loading Audio" spinner up.
        isLoading = false
        scheduleAutomaticAudioGeneration()

        // Refresh Spotlight's semantic index so Siri AI / Apple Intelligence can resolve
        // "quiz me on <source>" by meaning. Off the main actor, never blocks the UI.
        if #available(iOS 18.0, *) {
            let snapshot = allSources
            Task.detached(priority: .utility) {
                await SourceSpotlightIndexer.index(snapshot)
            }
        }
        return catalogLoadSucceeded
    }

    /// What a session on the Notebook reads (`contextSourceIDs`: its own
    /// approved pool, or what a voice conversation was narrowed to) narrowed
    /// to what has actually synced to this phone, in pool order. Sources
    /// archived on the Mac (or not yet delivered) drop out here, so the count
    /// shown on a Notebook is what a session can really reach.
    func sources(in notebook: MobileCloudNotebook) -> [MobileCloudSource] {
        let byID = sourcesByID
        let ids = notebook.contextSourceIDs.isEmpty ? notebook.sourceIDs : notebook.contextSourceIDs
        return ids.compactMap { byID[$0] }
    }
}
