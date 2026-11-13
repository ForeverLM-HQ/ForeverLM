// Text-to-speech preparation and generation.

import Foundation
import MediaPlayer
import OSLog

extension MobileAudioReviewViewModel {
    nonisolated private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "AudioReviewSpeech")

    func resolveTextToSpeechCostConfirmation(approved: Bool) {
        guard let continuation = textToSpeechCostConfirmationContinuation else { return }
        textToSpeechCostConfirmationContinuation = nil
        textToSpeechCostConfirmation = nil
        continuation.resume(returning: approved)
    }

    /// The rest of the book behind a chapter about to be generated. Playback
    /// carries on into the next chapter and generates it in the background
    /// without a second prompt, so this chapter's confirmation is the only
    /// place the book's real cost can be stated.
    ///
    /// Nil when the source is not a book chapter, or when every other chapter
    /// already has audio on the phone — the chapter's own price is then the
    /// whole charge. Sizing comes from each chapter's synced word count, scaled
    /// by the ratio this chapter's prepared narration actually measured; a
    /// chapter with no word count is counted but not priced, which understates
    /// the book rather than inventing a number for it.
    func textToSpeechBookScope(
        for source: MobileCloudSource,
        narrationCharacters: Int
    ) -> MobileTextToSpeechCostConfirmation.BookScope? {
        guard source.sourceType == "book",
              let parentGroup = source.parentGroup,
              !parentGroup.isEmpty else { return nil }
        let remaining = allSources.filter {
            $0.sourceType == "book"
                && $0.parentGroup == parentGroup
                && $0.id != source.id
                && !$0.isArchived
                && !hasSyncedTextToSpeechAudio(sourceID: $0.id)
        }
        guard !remaining.isEmpty else { return nil }

        let charactersPerWord = ArticleSpeechCostEstimate.charactersPerWord(
            narrationCharacters: narrationCharacters,
            wordCount: source.wordCount
        )
        let characters = remaining.reduce(0) { total, chapter in
            guard let words = chapter.wordCount, words > 0 else { return total }
            return total + Int((Double(words) * charactersPerWord).rounded())
        }
        guard characters > 0 else { return nil }

        return MobileTextToSpeechCostConfirmation.BookScope(
            title: collections.booksByID[parentGroup]?.title ?? "Whole book",
            remainingChapters: remaining.count,
            remainingCharacters: characters
        )
    }

    private func confirmTextToSpeechCost(
        source: MobileCloudSource,
        characterCount: Int,
        modelID: String,
        languageNotice: String? = nil
    ) async -> Bool {
        if let pending = textToSpeechCostConfirmationContinuation {
            textToSpeechCostConfirmationContinuation = nil
            textToSpeechCostConfirmation = nil
            pending.resume(returning: false)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                textToSpeechCostConfirmationContinuation = continuation
                textToSpeechCostConfirmation = MobileTextToSpeechCostConfirmation(
                    sourceID: source.id,
                    sourceTitle: source.title,
                    characterCount: characterCount,
                    modelID: modelID,
                    languageNotice: languageNotice,
                    book: textToSpeechBookScope(for: source, narrationCharacters: characterCount)
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveTextToSpeechCostConfirmation(approved: false)
            }
        }
    }

    /// Held for as long as any text-to-speech generation is running. It keeps the
    /// screen awake and, more importantly, keeps the app out of suspension the
    /// moment it stops being frontmost.
    ///
    /// The `audio` background mode only covers an app that is actually playing
    /// something, and generation runs before there is anything to play — and
    /// again whenever the generated prefix runs dry mid-source. Without the
    /// background task assertion, leaving the reader for the home screen or
    /// another app suspended the process within seconds and froze every
    /// in-flight speech request until the user came back, by which point they
    /// had failed.
    private func acquireTextToSpeechGenerationLease() {
        if textToSpeechIdleTimerLeaseCount == 0 {
            wasIdleTimerDisabledBeforeTextToSpeechGeneration = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
        textToSpeechIdleTimerLeaseCount += 1
        // Outside the count check on purpose: an expired assertion has already
        // cleared itself, and the next job deserves a fresh runway even though
        // the lease never dropped to zero.
        beginTextToSpeechBackgroundTask()
    }

    private func releaseTextToSpeechGenerationLease() {
        guard textToSpeechIdleTimerLeaseCount > 0 else { return }
        textToSpeechIdleTimerLeaseCount -= 1
        if textToSpeechIdleTimerLeaseCount == 0 {
            UIApplication.shared.isIdleTimerDisabled = wasIdleTimerDisabledBeforeTextToSpeechGeneration
            endTextToSpeechBackgroundTask()
        }
    }

    private func beginTextToSpeechBackgroundTask() {
        guard textToSpeechBackgroundTaskID == .invalid else { return }
        textToSpeechBackgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "text-to-speech-generation"
        ) { [weak self] in
            // iOS calls this synchronously on the main thread when the runway
            // is gone. End the assertion here rather than hopping to a task the
            // system may never schedule: an assertion left open is a kill, and
            // the journaled chunks mean a suspension only costs the requests
            // that were still in flight.
            MainActor.assumeIsolated {
                self?.endTextToSpeechBackgroundTask()
            }
        }
    }

    private func endTextToSpeechBackgroundTask() {
        guard textToSpeechBackgroundTaskID != .invalid else { return }
        let identifier = textToSpeechBackgroundTaskID
        textToSpeechBackgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }

    /// Resolves the source's durable listen-ready text without touching player
    /// state. Both autoplay and concurrent background jobs use this path so a
    /// second article can prepare while the first keeps its audio session.
    private func prepareTextToSpeechNarration(
        for source: MobileCloudSource,
        onDetail: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> MobilePreparedTextToSpeechNarration {
        // The phone uses what the Mac prepared and synced when there is one.
        // The Mac prepares Listen only when someone listens
        // there, or at once for the kinds automatic audio covers, so a paper or
        // article nobody has played yet has no synced narration: the phone then
        // runs the same preparation itself, on the same prompt, route and
        // ledger task, because the learner has just asked to listen. A book chapter the Mac prepared because it
        // carries equations or tables uses that narration too; otherwise the
        // chapter's own text is read, as before. An explainer's script is the
        // one article read as it stands: it was written for the ear, and the
        // pass is never run on it anywhere (`MobileTextToSpeechNarrationPolicy`).
        textToSpeechStoppedWhilePreparingText.remove(source.id)
        let requiresPreparedNarration = MobileTextToSpeechNarrationPolicy.requiresMacPreparedNarration(
            sourceType: source.sourceType,
            url: source.url
        )
        let mayHavePreparedNarration = MobileTextToSpeechNarrationPolicy.mayHaveMacPreparedNarration(
            sourceType: source.sourceType,
            url: source.url
        )
        if mayHavePreparedNarration {
            onDetail("Loading prepared narration…")
            let savedListenable = try await sourceTextStore.loadSourceListenableContent(
                sourceID: source.id
            )
            if let savedListenable,
               savedListenable.metadata.preparationSignature?
                    .hasPrefix(PaperNarrationFilter.preparationContractPrefix) == true {
                return MobilePreparedTextToSpeechNarration(
                    text: savedListenable.text,
                    sourceContentSignature: savedListenable.metadata.sourceSHA256,
                    preparationSignature: savedListenable.metadata.preparationSignature
                )
            }
            if requiresPreparedNarration {
                onDetail("Loading source…")
                let canonicalText = try await sourceTextStore.loadSourceText(sourceID: source.id)
                let prepared: PreparedMobilePaperNarration
                do {
                    prepared = try await MobilePaperTextToSpeechPreparation.prepare(
                        sourceID: source.id,
                        sourceType: source.sourceType,
                        title: source.title,
                        canonicalText: canonicalText,
                        onProgress: { completed, total in
                            onDetail(completed == 0
                                ? "Preparing text…"
                                : "Preparing text \(completed) of \(total)…")
                        }
                    )
                } catch {
                    textToSpeechStoppedWhilePreparingText.insert(source.id)
                    throw error
                }
                return MobilePreparedTextToSpeechNarration(
                    text: prepared.text,
                    sourceContentSignature: prepared.sourceContentSignature,
                    preparationSignature: prepared.preparationSignature
                )
            }
        }

        onDetail("Loading source…")
        let rawText = try await sourceTextStore.loadSourceText(sourceID: source.id)
        let narrationText = await Task.detached(priority: .userInitiated) {
            MobileReviewSpeechService.narrationText(from: rawText)
        }.value
        return MobilePreparedTextToSpeechNarration(
            text: narrationText,
            sourceContentSignature: nil,
            preparationSignature: nil
        )
    }

    /// The account's text-to-speech selection, refreshed from iCloud immediately
    /// before a billable request, so a model picked on the Mac is the one that
    /// narrates here. iCloud not answering stops the request: never spend on
    /// a selection another device may have replaced.
    ///
    /// A pick OpenRouter stopped offering is repaired first, by the Mac's
    /// rule, and the repair becomes the account's pick; `repairNotice` says
    /// so once ("<old> is no longer offered; using <new>."). A pick applied
    /// while its test could not finish, or whose pass has run out, is tested
    /// beside this request.
    private func refreshedTextToSpeechSelection() async throws -> (
        selection: CloudArticleTTS.Selection,
        repairNotice: String?
    ) {
        try await ArticleSpeechPreferences.shared.refreshFromAccount()
        let repair = ArticleSpeechSelection.repairSelectionForUse()
        if repair != nil {
            ArticleSpeechPreferences.shared.reloadFromStorage()
            // Best effort: the account row still names a model no device can
            // use, and every device repairs that on its own the same way.
            do {
                try await ArticleSpeechPreferences.shared.pushToAccount()
            } catch {
                Self.logger.error("Pushing the repaired speech model to the account failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let selection = try CloudArticleTTS.currentSelection()
        CloudArticleTTS.testPickWhenDue(model: selection.model, voice: selection.voice ?? "")
        return (selection, repair?.message)
    }

    /// Names the speech model on the rows of a generation that is about to
    /// make audio: the device's pick when it starts, then the one the request
    /// goes out on (the account's pick read again, or a language's own voice).
    /// Audio another device already made names none, since nothing is made.
    private func noteTextToSpeechModel(_ modelID: String?, sourceID: String) {
        textToSpeechModelNames[sourceID] = modelID.map { ArticleSpeechCatalog.model(id: $0)?.name ?? $0 }
    }

    private func generateTextToSpeechManifest(
        for source: MobileCloudSource,
        narration: MobilePreparedTextToSpeechNarration,
        selection: CloudArticleTTS.Selection? = nil,
        onOpeningReady: (@Sendable (SyncedArticleAudioManifest) async -> Void)?,
        onMoreAudioReady: (@Sendable (SyncedArticleAudioManifest) async -> Void)?,
        onProgress: @escaping @Sendable (_ completedChunks: Int, _ totalChunks: Int) async -> Void
    ) async throws -> SyncedArticleAudioManifest {
        let manifest = try await AIUsageAttribution.withSource(
            AIUsageSource(id: source.id, type: source.sourceType, title: source.title)
        ) {
            try await CloudArticleTTS.generate(
                sourceID: source.id,
                title: source.title,
                subtitle: source.subtitle,
                sourceType: source.sourceType,
                sourceURL: source.url ?? "",
                text: narration.text,
                sourceContentSignature: narration.sourceContentSignature,
                narrationPreparationSignature: narration.preparationSignature,
                createdAt: Date(),
                selection: selection,
                onOpeningReady: onOpeningReady,
                onMoreAudioReady: onMoreAudioReady,
                onProgress: onProgress
            )
        }
        // The finished narration goes up as the source's `audio.*` satellites.
        let sourceID = source.id
        Task { await MobileNarrationLibrary.shared.refresh(only: sourceID) }
        return manifest
    }

    /// Audio another device has published for this source, waited for briefly
    /// when CloudDocs has announced it but not delivered it yet, and entered
    /// into the library exactly as a generation here would be. nil means the
    /// account has no narration for this source and generating is the only way.
    private func adoptPublishedSyncedAudioIfAvailable(
        for source: MobileCloudSource
    ) async -> MobileAudioItem? {
        let sourceID = source.id
        let manifest = await Task.detached(priority: .userInitiated) {
            await SyncedArticleAudioStore.awaitPublishedManifest(sourceID: sourceID)
        }.value
        guard let manifest else { return nil }
        return publishGeneratedTextToSpeechManifest(manifest, sourceID: sourceID)
    }

    /// Starts following CloudDocs' view of the audio tree so a narration the
    /// Mac finishes while this app is open shows up here within seconds, rather
    /// than at whatever later reload happens to run after its manifest landed.
    func startObservingSyncedAudioManifests() {
        guard syncedAudioManifestObserver == nil,
              SyncedArticleAudioStore.isUbiquitousAudioRootAvailable else { return }
        let observer = SyncedAudioManifestObserver(
            audioRoot: SyncedArticleAudioStore.audioRootURL()
        )
        syncedAudioManifestObserver = observer
        syncedAudioObservationTask = Task { @MainActor [weak self] in
            for await _ in observer.changes {
                guard let self else { return }
                await self.refreshSyncedAudioCatalog()
            }
        }
    }

    /// Re-reads the manifests after CloudDocs reported that the readable set
    /// changed, and republishes the rows' audio badges when it really did.
    private func refreshSyncedAudioCatalog() async {
        let manifests = await Task.detached(priority: .utility) {
            try? SyncedArticleAudioStore.loadAvailableManifests()
        }.value
        guard let manifests, manifests != items.map(\.manifest) else { return }
        items = manifests.map(MobileAudioItem.init(manifest:))
        if !allSources.isEmpty {
            publishCatalogSources(allSources)
        }
        NotificationCenter.default.post(name: .mobileListeningCatalogDidChange, object: nil)
    }

    @discardableResult
    private func publishGeneratedTextToSpeechManifest(
        _ manifest: SyncedArticleAudioManifest,
        sourceID: String
    ) -> MobileAudioItem {
        let generatedItem = MobileAudioItem(manifest: manifest)
        items.removeAll { $0.id == generatedItem.id }
        items.insert(generatedItem, at: 0)
        if let index = allSources.firstIndex(where: { $0.id == sourceID }) {
            allSources[index].hasAudio = true
        }
        NotificationCenter.default.post(name: .mobileListeningCatalogDidChange, object: sourceID)
        return generatedItem
    }

    /// A prepare-only job never claims or modifies the player. Several source
    /// IDs can run together, and each row observes its own keyed progress. UI
    /// Listen requests opt into an opening callback; MCP and automatic cache
    /// preparation keep the default generate-only behavior.
    func generateBackgroundTextToSpeechAudio(
        for source: MobileCloudSource,
        playsOpeningWhenReady: Bool
    ) async throws -> MobileAudioItem {
        backgroundTextToSpeechPreparingTitles[source.id] = source.title
        backgroundTextToSpeechGenerationProgress[source.id] = nil
        acquireTextToSpeechGenerationLease()
        defer {
            backgroundTextToSpeechPreparingTitles[source.id] = nil
            backgroundTextToSpeechGenerationProgress[source.id] = nil
            textToSpeechModelNames[source.id] = nil
            releaseTextToSpeechGenerationLease()
        }

        do {
            let item: MobileAudioItem
            if let published = await adoptPublishedSyncedAudioIfAvailable(for: source) {
                // Another device already narrated this source; the list was
                // behind. A Listen tap plays it the way a cache hit would, and
                // a prepare-only request simply has its answer.
                item = published
                if playsOpeningWhenReady, !MobileRealtimeVoice.controller.isActive {
                    await play(item)
                }
            } else {
                noteTextToSpeechModel((try? CloudArticleTTS.currentSelection())?.model, sourceID: source.id)
                let narration = try await prepareTextToSpeechNarration(for: source) { _ in }
                let isSignedIn = await Task.detached(priority: .userInitiated) {
                    ManagedAI.isSignedIn
                }.value
                guard isSignedIn else {
                    throw CloudArticleTTS.GenerationError.missingAPIKey
                }
                let (selection, repairNotice) = try await refreshedTextToSpeechSelection()
                noteTextToSpeechModel(selection.model, sourceID: source.id)
                if let repairNotice { errorMessage = repairNotice }
                let generationStartedAt = Date()
                let onOpeningReady: (@Sendable (SyncedArticleAudioManifest) async -> Void)?
                let onMoreAudioReady: (@Sendable (SyncedArticleAudioManifest) async -> Void)?
                if playsOpeningWhenReady {
                    onOpeningReady = { [weak self] opening in
                        guard let self else { return }
                        _ = await self.startBackgroundOpeningPlaybackIfAvailable(
                            MobileAudioItem(manifest: opening)
                        )
                    }
                    onMoreAudioReady = { [weak self] partial in
                        guard let self else { return }
                        _ = await self.extendOpeningPlayback(MobileAudioItem(manifest: partial))
                    }
                } else {
                    onOpeningReady = nil
                    onMoreAudioReady = nil
                }
                let manifest = try await generateTextToSpeechManifest(
                    for: source,
                    narration: narration,
                    selection: selection,
                    onOpeningReady: onOpeningReady,
                    onMoreAudioReady: onMoreAudioReady,
                    onProgress: { [weak self] completedChunks, totalChunks in
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            // Requests finish in any order and report from two
                            // places; the ring never steps backwards.
                            if let current = self.backgroundTextToSpeechGenerationProgress[source.id],
                               current.totalChunks == totalChunks,
                               current.completedChunks > completedChunks { return }
                            self.backgroundTextToSpeechGenerationProgress[source.id] =
                                MobileTextToSpeechGenerationProgress(
                                    completedChunks: completedChunks,
                                    totalChunks: totalChunks,
                                    startedAt: generationStartedAt,
                                    model: selection.model
                                )
                        }
                    }
                )
                item = publishGeneratedTextToSpeechManifest(manifest, sourceID: source.id)
                if playsOpeningWhenReady {
                    await finishBackgroundOpeningPlaybackIfNeeded(item)
                    if backgroundOpeningPlaybackOwnerSourceID == source.id {
                        backgroundOpeningPlaybackOwnerSourceID = nil
                    }
                }
            }

            if let continuation = pendingAutomaticBookContinuation,
               continuation.nextSourceID == source.id {
                pendingAutomaticBookContinuation = nil
                Task { @MainActor [weak self] in
                    await self?.automaticallyContinueBook(
                        from: continuation.completedSourceID,
                        to: continuation.nextSourceID
                    )
                }
            }

            if pendingTextToSpeechAfterPreparationSourceID == source.id {
                pendingTextToSpeechAfterPreparationSourceID = nil
                Task { @MainActor [weak self] in
                    await self?.readSourceAloud(sourceID: source.id)
                }
            }
            pendingTextToSpeechResumes[source.id] = nil
            automaticTextToSpeechResumeCounts[source.id] = nil
            return item
        } catch {
            // A resume that is still coming keeps the listener's prefix and the
            // player state that lets the rest be appended to it: the second half
            // really is on its way, so this is buffering rather than the end of
            // the source. Only a generation that is over for good hands it back.
            if !recordInterruptedTextToSpeechGeneration(
                sourceID: source.id,
                playsOpeningWhenReady: playsOpeningWhenReady,
                error: error
            ) {
                releaseInterruptedOpeningPlayback(sourceID: source.id)
            }
            if pendingTextToSpeechAfterPreparationSourceID == source.id {
                pendingTextToSpeechAfterPreparationSourceID = nil
                if let message = textToSpeechFailureMessage(error, sourceID: source.id) {
                    errorMessage = message
                    if !MobileRealtimeVoice.controller.isActive {
                        speakWithoutListening(message)
                    }
                }
            }
            throw error
        }
    }

    /// Whether a failed generation is one worth restarting on its own.
    ///
    /// Only the failures that say nothing about the request survive here: the
    /// network went away, or the work was cancelled. A model that refused the
    /// text, an empty balance, an expired session, or an invalid voice all fail
    /// again identically, and retrying them silently would spend the listener's
    /// credits on the same refusal.
    private static func isResumableTextToSpeechFailure(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if error is URLError { return true }
        if let generation = error as? CloudArticleTTS.GenerationError {
            switch generation {
            case .failedAfterRetries, .networkUnavailable:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// A failure that means the device has nowhere to send the next request.
    /// Worth separating from the rest: retrying one of these immediately only
    /// spends the resume budget against an outage that has not ended.
    private static func isOfflineTextToSpeechFailure(_ error: Error) -> Bool {
        if let generation = error as? CloudArticleTTS.GenerationError,
           case .networkUnavailable = generation {
            return true
        }
        return CloudArticleTTS.isOfflineError(error)
    }

    /// Remembers a generation that stopped for a reason worth retrying, and
    /// restarts it right away when the app is on screen to run it. Returns
    /// whether a resume is now pending for this source.
    ///
    /// Suspension is what makes this necessary: iOS freezes the process, the
    /// speech requests that were in flight fail the moment it thaws, and the
    /// generation ends holding a journal of everything already paid for. The
    /// resume picks up from that journal, so a restart costs only the chunks
    /// that never arrived.
    @discardableResult
    func recordInterruptedTextToSpeechGeneration(
        sourceID: String,
        playsOpeningWhenReady: Bool,
        error: Error
    ) -> Bool {
        // A cancellation is normally worth resuming, but not the one the
        // listener asked for.
        guard !listenerStoppedTextToSpeechSourceIDs.contains(sourceID) else {
            pendingTextToSpeechResumes[sourceID] = nil
            textToSpeechStoppedWhilePreparingText.remove(sourceID)
            return false
        }
        guard Self.isResumableTextToSpeechFailure(error) else {
            pendingTextToSpeechResumes[sourceID] = nil
            return false
        }
        guard automaticTextToSpeechResumeCounts[sourceID, default: 0]
                < Self.maximumAutomaticTextToSpeechResumes else {
            pendingTextToSpeechResumes[sourceID] = nil
            return false
        }
        pendingTextToSpeechResumes[sourceID] =
            playsOpeningWhenReady || (pendingTextToSpeechResumes[sourceID] ?? false)
        let waitsForNetwork = Self.isOfflineTextToSpeechFailure(error)
        if UIApplication.shared.applicationState == .active {
            Task { @MainActor [weak self] in
                // A generation the radio ended resumes when the radio is back,
                // not a second later: the tunnel, the lift and the cell
                // handover all end on their own, and an attempt spent before
                // then is one the listener does not get back. The foreground
                // pass still covers a wait that runs out.
                if waitsForNetwork {
                    guard await NetworkPathAvailability.shared.waitForPath(
                        timeout: Self.offlineResumeNetworkWait
                    ) else { return }
                }
                await self?.resumeInterruptedTextToSpeechGeneration()
            }
        }
        return true
    }

    /// Hands the player back after a generation that is not coming back.
    ///
    /// While a resume is pending the listener stays on the prefix they are
    /// hearing, still marked as awaiting the rest, so the resumed tail is
    /// appended to it in place. Once there is no resume left to wait for, that
    /// prefix is ordinary playback again — otherwise the transport would sit in
    /// a buffering state that never resolves, and finishing it would never
    /// count as finishing the source.
    private func releaseInterruptedOpeningPlayback(sourceID: String) {
        if backgroundOpeningPlaybackOwnerSourceID == sourceID {
            backgroundOpeningPlaybackOwnerSourceID = nil
        }
        if openingPlaybackSourceID == sourceID {
            openingPlaybackSourceID = nil
            isAwaitingRemainingNarration = false
            openingPlaybackRanDry = false
        }
    }

    /// Restarts every generation that an interruption left unfinished. Called
    /// when the app comes back to the foreground and immediately after a
    /// resumable failure, so returning to the app is enough to finish a source
    /// the phone suspended part-way through.
    func resumeInterruptedTextToSpeechGeneration() async {
        guard !isResumingTextToSpeechGeneration else { return }
        isResumingTextToSpeechGeneration = true
        defer { isResumingTextToSpeechGeneration = false }

        // Generations fail independently, and one can fail while this pass is
        // awaiting another's resume. The task that failure spawns finds this
        // pass already running and returns, so without draining, the second
        // source would wait for the next foreground to be picked up.
        while await resumeOnePassOfInterruptedTextToSpeechGeneration() {}
        // A whole book that was waiting on one of those chapters carries on.
        resumeAudiobookGenerationIfWaiting()
    }

    /// One pass over the pending set. Returns whether it consumed anything —
    /// false means every remaining entry is blocked on a generation that is
    /// still running, which is the signal to stop rather than spin.
    private func resumeOnePassOfInterruptedTextToSpeechGeneration() async -> Bool {
        let pending = pendingTextToSpeechResumes
        guard !pending.isEmpty else { return false }

        for (sourceID, playsOpeningWhenReady) in pending {
            if hasSyncedTextToSpeechAudio(sourceID: sourceID) {
                pendingTextToSpeechResumes[sourceID] = nil
                releaseInterruptedOpeningPlayback(sourceID: sourceID)
                continue
            }
            guard !isPreparingAudio(sourceID: sourceID) else { continue }
            // Only resumable work is restarted automatically. Without a journal
            // the retry would re-narrate — and re-bill — the whole source, which
            // is the listener's call to make, not this pass's. A Listen that
            // stopped while its text was being prepared has narrated nothing
            // yet, and the windows it did finish are kept, so it restarts too:
            // a stop would otherwise end the Listen for good, which on a phone that
            // was locked or between cells was nearly every time.
            let stoppedWhilePreparingText = textToSpeechStoppedWhilePreparingText.remove(sourceID) != nil
            let hasJournal = await Task.detached(priority: .utility) {
                SyncedArticleAudioStore.hasGenerationProgress(sourceID: sourceID)
            }.value
            let hasProgress = hasJournal || stoppedWhilePreparingText
            guard hasProgress else {
                pendingTextToSpeechResumes[sourceID] = nil
                releaseInterruptedOpeningPlayback(sourceID: sourceID)
                continue
            }

            pendingTextToSpeechResumes[sourceID] = nil
            automaticTextToSpeechResumeCounts[sourceID, default: 0] += 1
            // A failure re-records itself through the ordinary catch path, and
            // the listener already saw the message that stopped it.
            _ = try? await prepareSourceAudio(
                sourceID: sourceID,
                playsOpeningWhenReady: playsOpeningWhenReady
            )
        }

        // Unchanged means every entry was blocked on a running generation, and
        // another identical pass would do nothing but spin. Any other outcome —
        // an entry consumed, a new failure recorded — earns another look.
        return pendingTextToSpeechResumes != pending
    }

    func generateCloudTextToSpeechAudio(
        for source: MobileCloudSource,
        autoplay: Bool
    ) async throws {
        var generationSucceeded = false
        if autoplay { isLoading = true }
        acquireTextToSpeechGenerationLease()
        textToSpeechPreparingTitle = source.title
        textToSpeechPreparingSourceID = source.id
        textToSpeechAutoplaySourceID = autoplay ? source.id : nil
        textToSpeechPreparationDetail = "Loading source…"
        textToSpeechGenerationProgress = nil
        defer {
            if autoplay { isLoading = false }
            releaseTextToSpeechGenerationLease()
            textToSpeechPreparingTitle = nil
            textToSpeechPreparingSourceID = nil
            textToSpeechAutoplaySourceID = nil
            textToSpeechPreparationDetail = nil
            textToSpeechGenerationProgress = nil
            textToSpeechModelNames[source.id] = nil
            // A generation that failed after its opening started leaves no
            // second half coming; the opening is ordinary playback again.
            if openingPlaybackSourceID == source.id {
                openingPlaybackSourceID = nil
                isAwaitingRemainingNarration = false
                openingPlaybackRanDry = false
            }
            if autoplay { updateNowPlayingInfo() }
            if let pendingSourceID = pendingTextToSpeechAfterPreparationSourceID {
                if generationSucceeded {
                    pendingTextToSpeechAfterPreparationSourceID = nil
                    // Run after this method releases its preparation state. The
                    // generated source takes the cached fast path; a different
                    // source starts its own TTS job serially.
                    Task { @MainActor [weak self] in
                        await self?.readSourceAloud(sourceID: pendingSourceID)
                    }
                } else if autoplay {
                    // The direct text-to-speech caller owns failure presentation.
                    pendingTextToSpeechAfterPreparationSourceID = nil
                }
            }
        }

        // Audio another device already published for this source outranks any
        // generation: the library's manifest walk may simply not have caught
        // up with it. Waiting here is only ever spent on audio CloudDocs has
        // announced, and it is what stands between a stale list and paying for
        // the same narration twice.
        textToSpeechPreparationDetail = "Checking iCloud for existing audio…"
        if let published = await adoptPublishedSyncedAudioIfAvailable(for: source) {
            generationSucceeded = true
            guard autoplay, !MobileRealtimeVoice.controller.isActive else { return }
            await play(published)
            return
        }

        noteTextToSpeechModel((try? CloudArticleTTS.currentSelection())?.model, sourceID: source.id)
        let narration = try await prepareTextToSpeechNarration(for: source) { [weak self] detail in
            self?.textToSpeechPreparationDetail = detail
        }
        let isSignedIn = await Task.detached(priority: .userInitiated) {
            ManagedAI.isSignedIn
        }.value
        guard isSignedIn else {
            throw CloudArticleTTS.GenerationError.missingAPIKey
        }

        let (selection, repairNotice) = try await refreshedTextToSpeechSelection()
        let narrationText = narration.text
        let narrationPricing = await Task.detached(priority: .userInitiated) {
            let signature = SyncedArticleAudioStore.contentSignature(for: narrationText)
            let hasCachedAudio = CloudArticleTTS.cachedManifest(
                sourceID: source.id,
                signature: signature
            ) != nil
            return (characterCount: narrationText.count, hasCachedAudio: hasCachedAudio)
        }.value
        // Almost every catalog voice is English-only, and handed German text
        // it returns fluent-sounding nonsense — and bills for it. Recognize the
        // narration's own language first: if another catalog voice speaks it,
        // this source gets that voice; if none does, say so before the money
        // goes out, whether or not price confirmation is switched on.
        let language: ArticleSpeechLanguageResolution? = narrationPricing.hasCachedAudio
            ? nil
            : await Task.detached(priority: .userInitiated) {
                ArticleSpeechLanguageResolution.resolve(
                    text: narrationText,
                    model: selection.model,
                    voice: selection.voice ?? ""
                )
            }.value
        // Only a substitution replaces the selection; a language the chosen
        // voice already speaks leaves the validated selection exactly as it is.
        let resolvedSelection: CloudArticleTTS.Selection
        if let language, language.changesSelection {
            resolvedSelection = CloudArticleTTS.Selection(model: language.model, voice: language.voice)
        } else {
            resolvedSelection = selection
        }
        noteTextToSpeechModel(resolvedSelection.model, sourceID: source.id)
        let unnarratableLanguage = language?.outcome == .unsupported

        // Confirmation suppression follows the account. Refresh immediately
        // before a potentially billable request; a CloudKit failure fails safe
        // by asking rather than silently spending.
        var suppressedCostModels: [String] = []
        do {
            suppressedCostModels = try await MobileModelPreferenceStore.shared.valueOrDefault(
                for: Prefs.ReadAloud.costConfirmationSuppressedModels
            ) ?? []
        } catch {
            Self.logger.error("Reading the suppressed cost confirmations failed: \(error.localizedDescription, privacy: .public)")
        }
        let confirmsSelectedModelCost = MobileTextToSpeechPricingPreferences.confirmsEstimatedCost
            && !suppressedCostModels.contains(resolvedSelection.model)
        // Asked for by voice (`listen_to_source`): the price was said and
        // agreed to out loud, and the phone may be in a pocket or a car. A
        // language the voice cannot read is then a failure the assistant
        // says, never a question left waiting on the screen.
        let approvedByVoice = voiceApprovedTextToSpeechSourceIDs.remove(source.id) != nil
        if approvedByVoice, unnarratableLanguage, !narrationPricing.hasCachedAudio {
            throw MobileTextToSpeechPreparationError.unnarratableLanguage(
                language?.message ?? "The selected voice does not read this source's language."
            )
        }
        let asksToConfirmCost = autoplay
            && !approvedByVoice
            && !narrationPricing.hasCachedAudio
            && (confirmsSelectedModelCost || unnarratableLanguage)
        // A repaired pick is said once: in the price question when there is
        // one, else in the bar's message row.
        if let repairNotice, !asksToConfirmCost {
            errorMessage = repairNotice
        }
        if asksToConfirmCost {
            textToSpeechPreparationDetail = "Waiting for cost confirmation…"
            let notice = [repairNotice, language?.message].compactMap { $0 }.joined(separator: " ")
            guard await confirmTextToSpeechCost(
                source: source,
                characterCount: narrationPricing.characterCount,
                modelID: resolvedSelection.model,
                languageNotice: notice.isEmpty ? nil : notice
            ) else { return }
        }

        textToSpeechPreparationDetail = "Generating first audio chunk…"
        if autoplay {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: source.title,
                MPMediaItemPropertyArtist: "Preparing audio · \(ArticleSpeechCatalog.model(id: resolvedSelection.model)?.name ?? resolvedSelection.model)…",
                MPMediaItemPropertyAlbumTitle: "ForeverLM Listen",
                MPNowPlayingInfoPropertyIsLiveStream: true,
                MPNowPlayingInfoPropertyPlaybackRate: 0,
            ]
            MPNowPlayingInfoCenter.default().playbackState = .paused
        }

        if autoplay, isPlaying {
            player.pause()
            isPlaying = false
            persistPlaybackPosition(force: true)
            updateNowPlayingInfo()
        }
        if autoplay {
            await voice.stop()
            speech.stop(owner: .voiceTab)
            isSourceChatActive = false
            activeChatTitle = nil
            shouldResumePlaybackAfterSpeech = false
        }

        // Generate cloud audio and save it through the synced-audio pipeline.
        // Listen does not wait for the whole source: the opening section starts
        // playing as soon as it exists, and the whole composition takes over at
        // the same second once the rest is generated.
        let onOpeningReady: (@Sendable (SyncedArticleAudioManifest) async -> Void)?
        let onMoreAudioReady: (@Sendable (SyncedArticleAudioManifest) async -> Void)?
        if autoplay {
            onOpeningReady = { [weak self] opening in
                guard let self else { return }
                await MainActor.run {
                    self.textToSpeechPreparationDetail = "First chunk ready · starting playback…"
                }
                let didStart = await self.startOpeningPlayback(MobileAudioItem(manifest: opening))
                await MainActor.run {
                    self.textToSpeechPreparationDetail = didStart
                        ? "Playing · generating remaining audio…"
                        : "First chunk ready · finishing audio…"
                }
            }
            onMoreAudioReady = { [weak self] partial in
                guard let self else { return }
                _ = await self.extendOpeningPlayback(MobileAudioItem(manifest: partial))
            }
        } else {
            onOpeningReady = nil
            onMoreAudioReady = nil
        }
        let generationStartedAt = Date()

        let manifest = try await generateTextToSpeechManifest(
            for: source,
            narration: narration,
            selection: resolvedSelection,
            onOpeningReady: onOpeningReady,
            onMoreAudioReady: onMoreAudioReady,
            onProgress: { [weak self] completedChunks, totalChunks in
                await MainActor.run { [weak self] in
                    if completedChunks == 0 {
                        self?.textToSpeechPreparationDetail = "Generating first audio chunk…"
                    } else if completedChunks < totalChunks,
                              self?.openingPlaybackSourceID != source.id {
                        self?.textToSpeechPreparationDetail = "Generating remaining audio…"
                    } else if completedChunks == totalChunks {
                        self?.textToSpeechPreparationDetail = "Audio ready · starting playback…"
                    }
                    if let current = self?.textToSpeechGenerationProgress,
                       current.totalChunks == totalChunks,
                       current.completedChunks > completedChunks { return }
                    self?.textToSpeechGenerationProgress = MobileTextToSpeechGenerationProgress(
                        completedChunks: completedChunks,
                        totalChunks: totalChunks,
                        startedAt: generationStartedAt,
                        model: resolvedSelection.model
                    )
                }
            }
        )
        let generatedItem = publishGeneratedTextToSpeechManifest(manifest, sourceID: source.id)
        generationSucceeded = true

        guard autoplay, !MobileRealtimeVoice.controller.isActive else { return }

        // Hand the listener over from the opening to the whole source without
        // moving them: same second, and still paused if they paused it.
        var startAt: TimeInterval?
        var keepPaused = false
        if openingPlaybackSourceID == source.id {
            startAt = currentTime
            keepPaused = !isPlaying && !openingPlaybackRanDry
            openingPlaybackSourceID = nil
            isAwaitingRemainingNarration = false
            openingPlaybackRanDry = false
        }

        await play(generatedItem, startAt: startAt, inPlace: startAt != nil)
        if keepPaused, isPlaying {
            togglePlayback()
        }
    }
}
