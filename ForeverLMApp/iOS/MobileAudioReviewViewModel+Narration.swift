// Narration download, automatic audio and reading a source aloud.

import Foundation
import MediaPlayer

extension MobileAudioReviewViewModel {
    /// Whether ready-to-play narration audio for this source is already on the
    /// phone (synced from the Mac or generated here earlier), i.e. text-to-speech
    /// can start without a TTS round trip.
    func hasSyncedTextToSpeechAudio(sourceID: String) -> Bool {
        items.contains { $0.id == sourceID }
    }

    /// The narration whose audio is being pulled down from iCloud right now,
    /// and how far along it is. Generation ("preparing") and download are
    /// different waits with different remedies, so the UI names them apart.
    func narrationDownloadFraction(sourceID: String) -> Double? {
        narrationDownloadProgress(sourceID: sourceID)?.fractionCompleted
    }

    func narrationDownloadProgress(sourceID: String) -> MobileNarrationDownloadProgress? {
        narrationDownloadSourceID == sourceID ? narrationDownloadProgress : nil
    }

    /// The title a banner shows for a download that has not produced a
    /// player item yet.
    var narrationDownloadTitle: String? {
        narrationDownloadProgress?.title
    }

    /// Audio the Mac has published but this phone has not pulled down yet is
    /// still audio: the library says so, and pressing play fetches it. Only the
    /// bytes are absent, and only until someone wants them — and playing
    /// starts before the download is over.
    ///
    /// A chapter is tens of megabytes and CloudDocs on a phone is bursty, so
    /// waiting for the last chunk before the first one played was a minute of
    /// spinner for audio the account already owned. Instead the download
    /// reports the contiguous prefix it has, and as soon as that prefix is
    /// playable — and reaches past the saved resume point — the opening starts
    /// through the same machinery fresh generation uses. Each further chunk
    /// extends it; `play` hands over to the whole composition at the end.
    func materializeNarrationIfNeeded(
        _ item: MobileAudioItem,
        startAt: TimeInterval?
    ) async throws {
        let manifest = item.manifest
        let alreadyLocal = await Task.detached(priority: .userInitiated) {
            SyncedArticleAudioStore.hasLocalChunks(for: manifest)
        }.value
        if alreadyLocal { return }

        let startedAt = Date()
        narrationDownloadSourceID = item.id
        narrationDownloadProgress = MobileNarrationDownloadProgress(
            title: item.title,
            readyChunks: 0,
            contiguousChunks: 0,
            totalChunks: manifest.chunks.count,
            startedAt: startedAt,
            isPlayingPrefix: false
        )
        isStartingDownloadedOpening = false
        defer {
            narrationDownloadSourceID = nil
            narrationDownloadProgress = nil
            isStartingDownloadedOpening = false
        }

        // Where the listener left off, resolved once: the opening may only
        // start when the downloaded prefix reaches past it, or it would start
        // the chapter from the top and jump later.
        let resumeTarget: TimeInterval
        if let startAt {
            resumeTarget = max(startAt, 0)
        } else {
            let saved = await Task.detached(priority: .userInitiated) {
                await SyncedArticleAudioStore.loadPlaybackPositionIncludingAccount(sourceID: manifest.sourceID)
            }.value
            resumeTarget = Self.resumeTime(from: saved, manifest: manifest, duration: .infinity)
        }

        // The weak capture belongs on the outer closure: `materializeChunks`
        // holds this progress handler for the whole iCloud download, so a strong
        // reference here would have outlived the screen no matter what the inner
        // task captured.
        try await SyncedArticleAudioStore.materializeChunks(for: manifest) { [weak self] progress in
            Task { @MainActor in
                guard let self, self.narrationDownloadSourceID == item.id else { return }
                await self.downloadedPrefixDidGrow(
                    progress,
                    for: item,
                    resumeTarget: resumeTarget,
                    startedAt: startedAt
                )
            }
        }
    }

    /// One CloudDocs update during a narration download: republish the count,
    /// and start or extend playback on the contiguous prefix.
    private func downloadedPrefixDidGrow(
        _ progress: SyncedArticleAudioDownloadProgress,
        for item: MobileAudioItem,
        resumeTarget: TimeInterval,
        startedAt: Date
    ) async {
        func publish() {
            guard narrationDownloadSourceID == item.id else { return }
            narrationDownloadProgress = MobileNarrationDownloadProgress(
                title: item.title,
                readyChunks: progress.readyChunks,
                contiguousChunks: progress.contiguousChunks,
                totalChunks: progress.totalChunks,
                startedAt: startedAt,
                isPlayingPrefix: openingPlaybackSourceID == item.id
            )
        }
        publish()

        // The last chunk is `play`'s to handle: it builds the whole
        // composition and hands over at the current second.
        guard progress.contiguousChunks > 0,
              !progress.isComplete,
              !MobileRealtimeVoice.controller.isActive else { return }

        let prefixItem = MobileAudioItem(manifest: item.manifest.prefix(chunkCount: progress.contiguousChunks))
        if openingPlaybackSourceID == item.id {
            _ = await extendOpeningPlayback(prefixItem)
            publish()
            return
        }
        guard !isStartingDownloadedOpening else { return }
        isStartingDownloadedOpening = true
        defer { isStartingDownloadedOpening = false }

        // The prefix has to reach past the resume point with some runway, or
        // the opening would begin at the wrong place and run dry at once.
        if resumeTarget > 0 {
            let prefixDuration = await prefixDurationIfPlayable(prefixItem)
            guard let prefixDuration, prefixDuration > resumeTarget + 5 else { return }
        }

        // Listen on this chapter is an explicit switch: whatever was playing
        // yields the moment this one can make sound, exactly as it would have
        // when the download finished.
        if currentItem?.id != item.id, isPlaying {
            player.pause()
            isPlaying = false
            persistPlaybackPosition(force: true)
        }
        let didStart = await startOpeningPlayback(prefixItem, startAt: resumeTarget)
        if didStart { publish() }
    }

    private func prefixDurationIfPlayable(_ item: MobileAudioItem) async -> TimeInterval? {
        do {
            let urls = try await Task.detached(priority: .userInitiated) {
                try SyncedArticleAudioStore.chunkURLs(for: item.manifest)
            }.value
            return try await audioComposition(for: urls).duration
        } catch {
            return nil
        }
    }

    func isPreparingAudio(sourceID: String) -> Bool {
        textToSpeechPreparingSourceID == sourceID
            || backgroundTextToSpeechPreparingTitles[sourceID] != nil
    }

    /// Stops the audio being generated for a source: no further speech requests
    /// are sent, so nothing more is billed. The pieces already generated stay
    /// on the phone, and asking for the source again carries on from them.
    /// The partial audio that was playing ahead of the rest is closed with it.
    func stopTextToSpeechGeneration(sourceID: String) {
        guard let cancel = stoppableTextToSpeechGenerations[sourceID] else { return }
        listenerStoppedTextToSpeechSourceIDs.insert(sourceID)
        pendingTextToSpeechResumes[sourceID] = nil
        textToSpeechStoppedWhilePreparingText.remove(sourceID)
        if pendingTextToSpeechAfterPreparationSourceID == sourceID {
            pendingTextToSpeechAfterPreparationSourceID = nil
        }
        cancel()

        guard openingPlaybackSourceID == sourceID, currentItem?.id == sourceID else { return }
        player.pause()
        isPlaying = false
        removeEndObserver()
        player.replaceCurrentItem(with: nil)
        openingPlaybackSourceID = nil
        isAwaitingRemainingNarration = false
        openingPlaybackRanDry = false
        deferredOpeningExtension = nil
        if backgroundOpeningPlaybackOwnerSourceID == sourceID {
            backgroundOpeningPlaybackOwnerSourceID = nil
        }
        currentItem = nil
        currentTime = 0
        duration = 0
        lastPlaybackPositionSaveAt = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        updateNowPlayingInfo()
    }

    /// What a generation that ended early says to the listener, or nil when
    /// it says nothing: their own Stop, and a cancellation from anywhere else.
    /// Neither is a fault in the request, and the text Swift gives a
    /// cancellation ("The operation couldn’t be completed.
    /// (Swift.CancellationError error 1.)") is not a sentence for a banner.
    /// Every caller that shows or speaks a generation's failure asks here.
    func textToSpeechFailureMessage(_ error: Error, sourceID: String) -> String? {
        Self.textToSpeechFailureMessage(
            error,
            listenerStopped: listenerStoppedTextToSpeechSourceIDs.contains(sourceID)
        )
    }

    nonisolated static func textToSpeechFailureMessage(_ error: Error, listenerStopped: Bool) -> String? {
        if listenerStopped || isCancelledTextToSpeechGeneration(error) { return nil }
        return error.localizedDescription
    }

    /// A generation whose task was cancelled, or whose speech request was
    /// cancelled under it.
    nonisolated static func isCancelledTextToSpeechGeneration(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let bridged = error as NSError
        return bridged.domain == NSURLErrorDomain && bridged.code == NSURLErrorCancelled
    }

    /// Runs one source's generation as a task the listener can stop. The task
    /// still ends when its caller is cancelled, as it did when it ran inline.
    private func runStoppableTextToSpeechGeneration<Output: Sendable>(
        sourceID: String,
        _ work: @escaping @MainActor () async throws -> Output
    ) async throws -> Output {
        listenerStoppedTextToSpeechSourceIDs.remove(sourceID)
        let task = Task { @MainActor in try await work() }
        stoppableTextToSpeechGenerations[sourceID] = { task.cancel() }
        defer { stoppableTextToSpeechGenerations[sourceID] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func textToSpeechGenerationProgress(sourceID: String) -> MobileTextToSpeechGenerationProgress? {
        if textToSpeechPreparingSourceID == sourceID {
            return textToSpeechGenerationProgress
        }
        return backgroundTextToSpeechGenerationProgress[sourceID]
    }

    /// The speech model narrating a source whose audio is being made: the one
    /// the generation reports once its chunks start, and before that the pick
    /// it started with.
    func textToSpeechModelName(sourceID: String) -> String? {
        textToSpeechGenerationProgress(sourceID: sourceID)?.modelName ?? textToSpeechModelNames[sourceID]
    }

    /// Reads one source aloud end to end — already-synced audio when it exists,
    /// freshly generated cloud narration otherwise.
    func readSourceAloud(sourceID: String) async {
        if allSources.isEmpty && items.isEmpty {
            await load()
        }
        // Already on its way down, and playing as soon as it can.
        if narrationDownloadSourceID == sourceID { return }
        if let item = itemForSourceID(sourceID) {
            // A conversation started in the meantime outranks this playback:
            // acquiring the audio session here would tear that session down.
            guard !MobileRealtimeVoice.controller.isActive else { return }
            await play(item)
            return
        }
        if backgroundTextToSpeechPreparingTitles[sourceID] != nil {
            // A prepare-only job can be promoted to playback without starting
            // duplicate network work. Its completion performs the cached play.
            pendingTextToSpeechAfterPreparationSourceID = sourceID
            return
        }
        if let preparingSourceID = textToSpeechPreparingSourceID {
            // The direct autoplay path already fulfills a repeated request for
            // this source. Background-only generation does not, so remember the
            // request and start playback as soon as that task publishes audio.
            if preparingSourceID != sourceID || textToSpeechAutoplaySourceID != sourceID {
                pendingTextToSpeechAfterPreparationSourceID = sourceID
            }
            return
        }
        guard let source = source(for: sourceID) else {
            let message = "I could not find that source on this phone anymore."
            errorMessage = message
            speakWithoutListening(message)
            return
        }
        await readCloudSourceAloud(source)
    }

    /// Generates and syncs narration without taking over the audio session,
    /// so the chunks become available to the iPhone, Mac, and CarPlay while
    /// the learner carries on.
    func prepareSourceAudio(
        sourceID: String,
        playsOpeningWhenReady: Bool = false
    ) async throws -> MobileAudioItem {
        if allSources.isEmpty && items.isEmpty {
            await load()
        }
        if let item = itemForSourceID(sourceID) {
            return item
        }
        guard !isPreparingAudio(sourceID: sourceID) else {
            let title = textToSpeechPreparingSourceID == sourceID
                ? textToSpeechPreparingTitle
                : backgroundTextToSpeechPreparingTitles[sourceID]
            throw MobileTextToSpeechPreparationError.alreadyPreparing(title)
        }
        guard let source = source(for: sourceID) else {
            throw MobileTextToSpeechPreparationError.sourceNotFound
        }
        return try await runStoppableTextToSpeechGeneration(sourceID: source.id) { [self] in
            try await generateBackgroundTextToSpeechAudio(
                for: source,
                playsOpeningWhenReady: playsOpeningWhenReady
            )
        }
    }

    /// Starts an event-driven pass over ready sources. The task is generate-only:
    /// it never claims the player, marks a source listened, or keeps a poller alive.
    ///
    /// `retryFailures` is the deliberate gesture — switching a type on — that
    /// clears sources this launch already failed on, so a fixed sync is picked
    /// up without relaunching the app.
    func scheduleAutomaticAudioGeneration(retryFailures: Bool = false) {
        if retryFailures {
            failedAutomaticSourceAudioIDs.removeAll()
        }
        guard automaticSourceAudioTask == nil else {
            automaticSourceAudioPassRequested = true
            return
        }
        automaticSourceAudioTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.automaticSourceAudioPassRequested = false
                await self.generateAutomaticSourceAudio()
            } while self.automaticSourceAudioPassRequested && !Task.isCancelled
            self.automaticSourceAudioTask = nil
        }
    }

    /// The candidate contract the execution pass hands to the filter,
    /// including the word-count fallback, so "keep it short" is judged
    /// against a length the model can see.
    private func automaticAudioFilterCandidate(
        for source: MobileCloudSource
    ) -> SourceAudioAutomation.FilterCandidate {
        SourceAudioAutomation.FilterCandidate(
            id: source.id,
            // The automation kind, as the Mac sends it: an explainer is judged
            // under the Explainers rule, never the Articles one.
            sourceType: source.audioAutomationKind,
            title: source.title,
            author: source.author,
            journal: source.journal,
            year: source.publishedYear,
            collection: source.parentGroup,
            url: source.url,
            description: source.sourceReviewGuide.map { String($0.guide.prefix(800)) },
            characterCount: source.listenableCharacterCount
                ?? SourceAudioAutomation.estimatedCharacters(
                    wordCount: source.wordCount,
                    contentCharacterCount: nil
                )
        )
    }

    private func generateAutomaticSourceAudio() async {
        // Read the synced consent before the gate. It starts false each launch,
        // and a stale false here would retire the learner's opt-ins rather than
        // honor a grant they already made.
        await refreshPaidAutomaticVoiceConsent()
        guard !paidAutomaticVoiceConsentIsUnverified else {
            // iCloud did not answer. Nothing generates without a verified
            // consent, and nothing is switched off on a guess; the next pass
            // reads it again.
            automaticAudioProgress = nil
            return
        }
        // The gate below prices the selected model from OpenRouter's speech
        // list, so read the list first: a model picked from it is not among
        // the ones this build records, and would read as unpriced.
        await OpenRouterAudioDirectory.prepare(.speech)
        // A pick the list dropped is repaired before it is priced; the
        // generation that uses it says so.
        ArticleSpeechSelection.repairAfterDirectoryRead()
        ArticleSpeechPreferences.shared.reloadFromStorage()
        let storedModel = Preferences.value(Prefs.Mobile.readAloudModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard ArticleSpeechCatalog.isDirectoryBacked
                || storedModel.isEmpty
                || ArticleSpeechCatalog.model(id: storedModel) != nil else {
            // The list could not be read and the pick is not in the recorded
            // one. Nothing is priced on a guess and nothing is switched off;
            // the next pass reads the list again.
            automaticAudioProgress = nil
            return
        }
        guard automaticAudioSelectionIsAllowed else {
            automaticAudioProgress = nil
            await disableAutomaticAudioPreferences()
            return
        }
        // One switch per source type, read from the synced preferences rather
        // than from a list held here, so a type added to
        // `SourceAudioAutomation` is picked up without a second place to edit.
        var enabledTypes: Set<String> = []
        do {
            for type in SourceAudioAutomation.automatable {
                let isEnabled = try await MobileModelPreferenceStore.shared
                    .bool(forKey: type.preferenceKey) ?? false
                if isEnabled { enabledTypes.insert(type.sourceType) }
            }
        } catch {
            // A background pass has no one to tell about a transient outage;
            // it re-runs on the next event. Anything else is still surfaced.
            if case .iCloudUnavailable? = error as? MobileModelRouteError {
                automaticAudioProgress = nil
                return
            }
            errorMessage = "Automatic audio settings could not be loaded: \(error.localizedDescription)"
            return
        }
        guard !enabledTypes.isEmpty else {
            automaticAudioProgress = nil
            return
        }

        var candidates = allSources.filter { source in
            guard !source.hasAudio, !source.isArchived, source.state == "ready" else { return false }
            guard !failedAutomaticSourceAudioIDs.contains(source.id) else { return false }
            guard !isPreparingAudio(sourceID: source.id) else { return false }
            // By automation kind, so an explainer follows the Explainers
            // switch and never the Articles one.
            return enabledTypes.contains(source.audioAutomationKind)
        }
        do {
            var constraints: [String: String] = [:]
            for sourceType in enabledTypes {
                guard let key = SourceAudioAutomation.constraintPreferenceKey(for: sourceType),
                      let constraint = try await MobileModelPreferenceStore.shared.string(forKey: key)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !constraint.isEmpty else { continue }
                constraints[sourceType] = constraint
            }
            guard !constraints.isEmpty else { throw AutomaticAudioConstraintControl.noConstraints }
            let route = try await MobileModelPreferenceStore.shared.resolve(.automaticAudioFiltering)
            var allowedIDs = Set(candidates.map(\.id))
            for (sourceType, constraint) in constraints.sorted(by: { $0.key < $1.key }) {
                let typed = candidates.filter { $0.audioAutomationKind == sourceType }
                let filterCandidates = typed.map { automaticAudioFilterCandidate(for: $0) }
                let matches = try await MobileAutomaticAudioConstraintMatcher.matchingIDs(
                    constraint: constraint,
                    candidates: filterCandidates,
                    route: route
                )
                allowedIDs.subtract(typed.map(\.id))
                allowedIDs.formUnion(matches)
            }
            candidates = candidates.filter { allowedIDs.contains($0.id) }
        } catch AutomaticAudioConstraintControl.noConstraints {
            // No semantic filter means the per-type opt-in retains its existing
            // all-sources behavior without making an AI call.
        } catch {
            errorMessage = "Automatic audio filter failed: \(error.localizedDescription)"
            automaticAudioProgress = nil
            return
        }
        guard !candidates.isEmpty else {
            automaticAudioProgress = nil
            return
        }
        var completedCount = 0
        defer { automaticAudioProgress = nil }
        for source in candidates {
            guard !Task.isCancelled else { return }
            // A model selection or the consent can change while a long source
            // is generating. Re-read both before each item so the next source
            // never inherits a route the learner has since withdrawn.
            await refreshPaidAutomaticVoiceConsent()
            guard !paidAutomaticVoiceConsentIsUnverified else { return }
            guard automaticAudioSelectionIsAllowed else {
                await disableAutomaticAudioPreferences()
                return
            }
            automaticAudioProgress = SourceAudioAutomation.GenerationProgress(
                completedCount: completedCount,
                totalCount: candidates.count,
                currentSourceType: source.audioAutomationKind,
                currentTitle: source.title
            )
            do {
                _ = try await prepareSourceAudio(sourceID: source.id)
                completedCount += 1
            } catch {
                // A source the listener stopped is still left alone for the
                // rest of this launch; it only has nothing to report.
                failedAutomaticSourceAudioIDs.insert(source.id)
                if let message = textToSpeechFailureMessage(error, sourceID: source.id) {
                    errorMessage = "Automatic audio for \(source.title) failed: \(message)"
                }
            }
        }
    }

    /// Whether the current selection may generate: free always, priced only
    /// behind the synced account consent, unpriced never. Re-read between every
    /// source, so a revoked consent or a changed model stops the next item.
    private var automaticAudioSelectionIsAllowed: Bool {
        SourceAudioAutomation.allowsAutomaticGeneration(
            provider: ArticleSpeechCatalog.provider,
            model: ArticleSpeechPreferences.shared.modelID,
            allowsPaidVoices: allowsPaidAutomaticVoices
        )
    }

    func refreshPaidAutomaticVoiceConsent() async {
        do {
            allowsPaidAutomaticVoices = try await MobileModelPreferenceStore.shared
                .valueOrDefault(for: Prefs.ReadAloud.autoGenerateAllowPaidVoices) ?? false
            paidAutomaticVoiceConsentIsKnown = true
        } catch {
            allowsPaidAutomaticVoices = false
            paidAutomaticVoiceConsentIsKnown = false
        }
    }

    /// True when the pass must stop without deciding anything: the selection
    /// is priced, so it runs only behind consent, and iCloud did not say
    /// whether that consent stands. An unpriced voice needs no consent and
    /// is not held up by the outage.
    private var paidAutomaticVoiceConsentIsUnverified: Bool {
        !paidAutomaticVoiceConsentIsKnown
            && SourceAudioAutomation.requiresPaidVoiceConsent(
                provider: ArticleSpeechCatalog.provider,
                model: ArticleSpeechPreferences.shared.modelID
            )
    }

    /// The store's read-side wording ("No request was sent") does not fit a
    /// failed write. Say what the failure means here: the switches stay on in
    /// iCloud while this phone refuses to generate.
    static func automaticAudioDisableFailureMessage(_ error: Error) -> String {
        if case .iCloudUnavailable? = error as? MobileModelRouteError {
            return "Automatic audio is paused but its switches could not be turned off because iCloud could not be reached. Nothing will generate in the meantime; they will be turned off once iCloud is back."
        }
        return "Automatic audio could not be turned off: \(error.localizedDescription)"
    }

    private func disableAutomaticAudioPreferences() async {
        do {
            for type in SourceAudioAutomation.automatable {
                let isEnabled = try await MobileModelPreferenceStore.shared
                    .bool(forKey: type.preferenceKey) ?? false
                if isEnabled {
                    try await MobileModelPreferenceStore.shared.setBool(
                        false,
                        forKey: type.preferenceKey
                    )
                }
            }
        } catch {
            // Execution is already blocked locally. Surface a sync failure so
            // the stale preference is not mistaken for an armed paid queue.
            errorMessage = Self.automaticAudioDisableFailureMessage(error)
        }
    }

    func readCloudSourceAloud(_ source: MobileCloudSource) async {
        do {
            try await runStoppableTextToSpeechGeneration(sourceID: source.id) { [self] in
                try await generateCloudTextToSpeechAudio(for: source, autoplay: true)
            }
            pendingTextToSpeechResumes[source.id] = nil
            automaticTextToSpeechResumeCounts[source.id] = nil
        } catch {
            // The listener's own Stop: nothing to resume and nothing to say.
            if listenerStoppedTextToSpeechSourceIDs.contains(source.id) {
                pendingTextToSpeechResumes[source.id] = nil
                return
            }
            recordInterruptedTextToSpeechGeneration(
                sourceID: source.id,
                playsOpeningWhenReady: true,
                error: error
            )
            // A cancellation that was not the listener's is resumed above, and
            // has no message either.
            guard let message = textToSpeechFailureMessage(error, sourceID: source.id) else { return }
            errorMessage = message
            if MobileRealtimeVoice.controller.isActive {
                return
            } else if voiceListen?.sourceID == source.id, MobileRealtimeVoice.isCarConnected {
                // Started by voice in the car: the assistant comes back and
                // says why (`startVoiceListen`), not the system voice.
                return
            } else {
                speakAndResumeListening(message, pausePlayback: true, resumePlaybackAfterSpeech: true)
            }
        }
    }
}

// MARK: - A whole book

extension MobileAudioReviewViewModel {
    /// The chapters still in a book, in reading order.
    func bookChapters(bookID: String) -> [MobileCloudSource] {
        allSources
            .filter { $0.sourceType == "book" && $0.parentGroup == bookID && !$0.isArchived }
            .sorted(by: MobileSourceGrouping.memberOrder)
    }

    /// How much of a book has audio: the chapters with it, and all of them.
    func audiobookCoverage(bookID: String) -> (ready: Int, total: Int) {
        let chapters = bookChapters(bookID: bookID)
        return (chapters.filter { hasSyncedTextToSpeechAudio(sourceID: $0.id) }.count, chapters.count)
    }

    private func pendingAudiobookChapters(bookID: String) -> [MobileCloudSource] {
        MobileAudiobookPlan.pendingChapters(
            bookChapters(bookID: bookID),
            hasAudio: { hasSyncedTextToSpeechAudio(sourceID: $0.id) },
            isPreparing: { isPreparingAudio(sourceID: $0.id) },
            listeningTo: currentItem?.id
        )
    }

    /// Generate Audiobook: prices every chapter of the book that has no audio
    /// yet and asks once for all of them (`audiobookConfirmation`); a voice
    /// that costs nothing starts without a question, as on the Mac.
    func requestAudiobook(bookID: String) async {
        errorMessage = nil
        if let running = audiobookGeneration {
            if running.bookID != bookID {
                errorMessage = "The audiobook for \(running.title) is still generating. Stop it, or wait for it to finish."
            }
            return
        }
        if allSources.isEmpty && items.isEmpty {
            await load()
        }
        if await offersVoiceChoice(before: .audiobook(bookID: bookID)) { return }
        // The quote prices the selected model from OpenRouter's speech list.
        await OpenRouterAudioDirectory.prepare(.speech)
        let modelID: String
        do {
            modelID = try CloudArticleTTS.currentSelection().model
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard audiobookGeneration == nil,
              let plan = MobileAudiobookPlan.plan(
                bookID: bookID,
                title: collections.booksByID[bookID]?.title ?? bookID,
                chapters: bookChapters(bookID: bookID),
                hasAudio: { hasSyncedTextToSpeechAudio(sourceID: $0.id) },
                isPreparing: { isPreparingAudio(sourceID: $0.id) },
                listeningTo: currentItem?.id,
                provider: ArticleSpeechCatalog.provider,
                modelID: modelID
              ) else { return }
        if plan.isBillable {
            audiobookConfirmation = plan
        } else {
            startAudiobookGeneration(plan)
        }
    }

    func resolveAudiobookConfirmation(_ plan: MobileAudiobookPlan, approved: Bool) {
        if audiobookConfirmation?.id == plan.id {
            audiobookConfirmation = nil
        }
        if approved {
            startAudiobookGeneration(plan)
        }
    }

    private func startAudiobookGeneration(_ plan: MobileAudiobookPlan) {
        guard audiobookGeneration == nil else { return }
        let coverage = audiobookCoverage(bookID: plan.bookID)
        let run = MobileAudiobookGeneration(
            runID: UUID(),
            bookID: plan.bookID,
            title: plan.title,
            readyChapters: coverage.ready,
            totalChapters: coverage.total
        )
        audiobookGeneration = run
        runAudiobookGeneration(runID: run.runID)
    }

    private func runAudiobookGeneration(runID: UUID) {
        audiobookGenerationTask = Task { [weak self] in
            await self?.generateAudiobookChapters(runID: runID)
        }
    }

    /// One chapter after another, generate-only: the player is never claimed,
    /// and each chapter's row and the book's own line show how far it is. The
    /// list of what is left is read again before every chapter, so a chapter
    /// the Mac narrated meanwhile, or one a Listen is already making, is not
    /// made twice.
    private func generateAudiobookChapters(runID: UUID) async {
        var failuresInARow = 0
        var lastFailure: (chapterTitle: String, message: String?)?
        while let run = audiobookGeneration, run.runID == runID, failuresInARow < 2 {
            let coverage = audiobookCoverage(bookID: run.bookID)
            audiobookGeneration?.readyChapters = coverage.ready
            audiobookGeneration?.totalChapters = coverage.total
            let pending = pendingAudiobookChapters(bookID: run.bookID)
                .filter { !run.setAsideChapterIDs.contains($0.id) }
            guard let chapter = pending.first else { break }
            audiobookGeneration?.currentChapterID = chapter.id
            audiobookGeneration?.currentChapterTitle = chapter.title
            do {
                _ = try await prepareSourceAudio(sourceID: chapter.id)
                failuresInARow = 0
            } catch {
                // Stopped from the book's own Stop: the run is gone.
                guard audiobookGeneration?.runID == runID else { return }
                // Stopped on the chapter's own button: that ends the book too,
                // or the next chapter would start under the finger.
                if listenerStoppedTextToSpeechSourceIDs.contains(chapter.id) {
                    audiobookGeneration = nil
                    return
                }
                // An interruption that mends itself. The chapter's own resume
                // finishes it and calls this run back.
                if pendingTextToSpeechResumes[chapter.id] != nil {
                    audiobookGeneration?.isWaitingToResume = true
                    return
                }
                audiobookGeneration?.setAsideChapterIDs.append(chapter.id)
                failuresInARow += 1
                lastFailure = (chapter.title, textToSpeechFailureMessage(error, sourceID: chapter.id))
            }
        }
        guard let run = audiobookGeneration, run.runID == runID else { return }
        audiobookGeneration = nil
        guard let lastFailure else { return }
        let reason = lastFailure.message.map { ": \($0)" } ?? "."
        if failuresInARow >= 2 {
            // Two chapters in a row is the account or the network, not the
            // chapters; the rest would only fail the same way.
            errorMessage = "The audiobook for \(run.title) stopped at \(lastFailure.chapterTitle)\(reason)"
        } else {
            let count = run.setAsideChapterIDs.count
            errorMessage = count == 1
                ? "\(lastFailure.chapterTitle) could not be narrated\(reason)"
                : "\(count) chapters of \(run.title) could not be narrated\(reason)"
        }
    }

    /// Called when the interrupted generations have had their resume: a book
    /// that was waiting on one of them picks up where it stopped.
    func resumeAudiobookGenerationIfWaiting() {
        guard let run = audiobookGeneration, run.isWaitingToResume else { return }
        if let chapterID = run.currentChapterID, pendingTextToSpeechResumes[chapterID] != nil { return }
        audiobookGeneration?.isWaitingToResume = false
        runAudiobookGeneration(runID: run.runID)
    }

    /// Stops the book where it is. Every finished chapter stays, and so do the
    /// pieces of the one in hand, so generating again costs nothing for them.
    func stopAudiobookGeneration() {
        guard let run = audiobookGeneration else { return }
        audiobookGeneration = nil
        if let chapterID = run.currentChapterID {
            pendingTextToSpeechResumes[chapterID] = nil
            stopTextToSpeechGeneration(sourceID: chapterID)
        }
        audiobookGenerationTask?.cancel()
        audiobookGenerationTask = nil
    }

    /// The chapter of a book the listener was last in: the one whose saved
    /// position is newest. A finished chapter keeps no position, so this is
    /// nil for a book never started and for one stopped exactly at a
    /// chapter's end.
    func lastListenedChapter(bookID: String) async -> MobileCloudSource? {
        let chapters = bookChapters(bookID: bookID).filter { hasSyncedTextToSpeechAudio(sourceID: $0.id) }
        let ids = chapters.map(\.id)
        let newestID = await Task.detached(priority: .userInitiated) { () -> String? in
            var newest: (id: String, updatedAt: Date)?
            for id in ids {
                guard let position = SyncedArticleAudioStore.loadLocalPlaybackPosition(sourceID: id),
                      position.globalTime > 0 else { continue }
                if newest.map({ position.updatedAt > $0.updatedAt }) ?? true {
                    newest = (id, position.updatedAt)
                }
            }
            return newest?.id
        }.value
        return chapters.first { $0.id == newestID }
    }
}
