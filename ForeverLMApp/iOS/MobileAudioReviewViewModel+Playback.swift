// Audio playback, the player, opening playback, now playing and remote commands.

import AVFoundation
import Foundation
import MediaPlayer
import OSLog

extension MobileAudioReviewViewModel {
    nonisolated private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "AudioReviewPlayback")

    var canSeek: Bool {
        duration > 0
    }

    /// The direct autoplay flow used by voice commands keeps its opening until
    /// the whole narration arrives. UI-started background generation is keyed
    /// separately and may be dismissed without cancelling or reopening it.
    var canDismissPlayback: Bool {
        guard let currentItem else { return false }
        return textToSpeechPreparingSourceID != currentItem.id
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    var playerDetailText: String {
        let elapsed = Self.formatTime(currentTime)
        let total = duration > 0 ? Self.formatTime(duration) : "--:--"
        return "\(elapsed) / \(total) - \(MobileAudioPlaybackSpeed.label(for: speed))"
    }

    /// `startAt` overrides the stored resume point. The opening-section handover
    /// uses it to continue at the exact second the listener had reached, which
    /// the saved position cannot express: that position is cleared near the end
    /// of a source, and the opening ending *is* near its own end.
    ///
    /// `inPlace` says this audio replaces audio of the same source that is
    /// playing now (a longer prefix, or the whole narration taking over from
    /// its opening). The listener keeps listening while the new audio is
    /// assembled, which takes seconds for a long source, so the second they
    /// are at is read when the new audio goes in (`handoverSecond`), never
    /// before: a second noted earlier puts them back by as long as the
    /// assembly took, twice that at 2x.
    func play(_ item: MobileAudioItem, startAt: TimeInterval? = nil, inPlace: Bool = false) async {
        // Deliberately ahead of `isLoading`: a first-time download is a wait
        // with a length and a progress bar, not the library's loading spinner.
        // The download starts the opening itself as soon as the first chunks
        // are here, so by the time it returns the listener may already be
        // some way into the chapter.
        do {
            try await materializeNarrationIfNeeded(item, startAt: startAt)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Narration could not download: \(error.localizedDescription)"
            return
        }

        // Hand over from the streamed opening to the whole composition without
        // moving the listener: same second, and still paused if they paused it.
        var startAt = startAt
        var continuesInPlace = inPlace
        var keepPausedAfterHandover = false
        if openingPlaybackSourceID == item.id, currentItem?.id == item.id {
            startAt = currentTime
            continuesInPlace = true
            keepPausedAfterHandover = !isPlaying && !openingPlaybackRanDry
            openingPlaybackSourceID = nil
            isAwaitingRemainingNarration = false
            openingPlaybackRanDry = false
        }

        isLoading = true
        defer { isLoading = false }

        do {
            if let openingPlaybackSourceID, openingPlaybackSourceID != item.id {
                self.openingPlaybackSourceID = nil
                isAwaitingRemainingNarration = false
                openingPlaybackRanDry = false
            }
            persistPlaybackPosition(force: true)
            try await configureAudioSession()
            let urls = try await Task.detached(priority: .userInitiated) {
                try SyncedArticleAudioStore.chunkURLs(for: item.manifest)
            }.value
            async let compositionLoad = audioComposition(for: urls)
            // The account copy is what the other device most recently wrote;
            // the file is what CloudDocs happens to have delivered. Newer wins.
            async let savedPositionLoad = Task.detached(priority: .utility) {
                await SyncedArticleAudioStore.loadPlaybackPositionIncludingAccount(sourceID: item.id)
            }.value
            let composition = try await compositionLoad
            let savedPosition = await savedPositionLoad
            var playerItem = await MobileLoudnessAudioMix.playerItem(for: composition.asset)

            // Audio that replaces what is sounding takes over in step with it,
            // so the listener hears no break. Anything else (paused, run dry,
            // the listener moved meanwhile) takes the ordinary swap below.
            var tookOverInStep = false
            if continuesInPlace, currentItem?.id == item.id, isPlaying {
                tookOverInStep = await handOverInStep(to: playerItem) { [weak self] in
                    self?.currentItem?.id == item.id
                }
                if !tookOverInStep {
                    // Closed, or another source started, while it was tried.
                    guard currentItem?.id == item.id else { return }
                    if !isPlaying, !openingPlaybackRanDry {
                        keepPausedAfterHandover = true
                    }
                    // The first item belonged to the player that was given up.
                    playerItem = await MobileLoudnessAudioMix.playerItem(for: composition.asset)
                }
            }

            removeEndObserver()
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: playerItem,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.finishFullPlaybackIfNeeded(
                        playerItem: playerItem,
                        sourceID: item.id
                    )
                }
            }

            // Nothing awaits between here and the swap below.
            let resumeTime: TimeInterval
            if continuesInPlace, currentItem?.id == item.id {
                resumeTime = handoverSecond(into: composition.duration)
            } else {
                resumeTime = startAt.map { min(max($0, 0), composition.duration) }
                    ?? Self.resumeTime(
                        from: savedPosition,
                        manifest: item.manifest,
                        duration: composition.duration
                    )
            }
            currentItem = item
            Task { [weak self] in await self?.loadNowPlayingArtwork(for: item) }
            if bookContinuationOffer?.completedSourceID != item.id {
                bookContinuationOffer = nil
            }
            if pendingAutomaticBookContinuation?.completedSourceID != item.id {
                pendingAutomaticBookContinuation = nil
            }
            activeVoiceSourceID = item.id
            activeVoiceSourceTitle = item.title
            duration = composition.duration
            currentTime = resumeTime
            lastPlaybackPositionSaveAt = nil
            if !tookOverInStep {
                player.replaceCurrentItem(with: playerItem)
                if resumeTime > 0 {
                    await player.seek(
                        to: CMTime(seconds: resumeTime, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                }
                player.playImmediately(atRate: speed)
            }
            isPlaying = true
            if keepPausedAfterHandover {
                togglePlayback()
            }
            updateNowPlayingInfo()
            Task { [weak self] in
                await self?.recordSourceActivity(sourceID: item.id, kind: .listening)
            }
            prefetchNextBookChapterAudio(after: item.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Pulls the next chapter's chunks down while this one plays, so the book
    /// carries on without the download gap this chapter may just have had.
    /// Nothing is generated and nothing is shown: the chunks simply arrive,
    /// and the next `play` finds them local. A chapter without synced audio is
    /// left to the continuation code, which owns the decision to spend money.
    private func prefetchNextBookChapterAudio(after sourceID: String) {
        nextChapterPrefetchTask?.cancel()
        nextChapterPrefetchTask = nil
        guard let nextChapter = nextBookChapter(after: sourceID),
              let nextItem = itemForSourceID(nextChapter.id) else { return }
        let manifest = nextItem.manifest
        nextChapterPrefetchTask = Task.detached(priority: .utility) {
            guard !SyncedArticleAudioStore.hasLocalChunks(for: manifest) else { return }
            do {
                try await SyncedArticleAudioStore.materializeChunks(for: manifest) { _ in }
            } catch is CancellationError {
            } catch {
                Self.logger.error("Fetching the next chapter's audio ahead failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func togglePlayback() {
        guard currentItem != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            if openingPlaybackSourceID != nil {
                openingPlaybackRanDry = false
            }
            persistPlaybackPosition(force: true)
        } else {
            // A timer that ran out while playback was paused has nothing left
            // to pause; pressing play is the listener awake again.
            if sleepTimer?.isDue(at: Date()) == true {
                sleepTimer = nil
            }
            // An opening section that has run out is not a finished source, so
            // resuming must not replay it from the top while the rest arrives.
            if duration > 0, currentTime >= duration, !isAwaitingRemainingNarration {
                completedPlayerItemIdentity = nil
                seek(to: 0)
            }
            player.playImmediately(atRate: speed)
            isPlaying = true
        }
        updateNowPlayingInfo()
    }

    /// Removes the app-shell player without deleting generated audio. This is
    /// intentionally distinct from pause: a paused or completed item remains
    /// resumable in the mini-player until the learner explicitly closes it.
    func dismissPlayback() {
        guard canDismissPlayback, let dismissedItem = currentItem else { return }
        player.pause()
        isPlaying = false
        if duration - currentTime > 1 {
            persistPlaybackPosition(force: true)
        } else {
            clearPlaybackPosition(for: dismissedItem.id)
        }
        removeEndObserver()
        player.replaceCurrentItem(with: nil)
        if openingPlaybackSourceID == dismissedItem.id {
            openingPlaybackSourceID = nil
            isAwaitingRemainingNarration = false
            openingPlaybackRanDry = false
        }
        currentItem = nil
        sleepTimer = nil
        bookContinuationOffer = nil
        pendingAutomaticBookContinuation = nil
        nextChapterPrefetchTask?.cancel()
        nextChapterPrefetchTask = nil
        currentTime = 0
        duration = 0
        lastPlaybackPositionSaveAt = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        updateNowPlayingInfo()
    }

    // MARK: - Sleep timer

    func setSleepTimer(minutes: Int) {
        sleepTimer = .minutes(minutes, from: Date())
    }

    func setSleepTimerToEndOfSource() {
        sleepTimer = .endOfSource
    }

    func cancelSleepTimer() {
        sleepTimer = nil
    }

    /// Checked on the player's clock, which ticks twice a second while sound
    /// is playing, in the background and on the Lock Screen too.
    private func pauseForSleepTimerIfDue() {
        guard let sleepTimer, sleepTimer.isDue(at: Date()) else { return }
        self.sleepTimer = nil
        if isPlaying {
            togglePlayback()
        }
    }

    func nextBookChapter(after sourceID: String) -> MobileCloudSource? {
        guard let source = source(for: sourceID),
              source.sourceType == "book",
              let parentGroup = source.parentGroup,
              !parentGroup.isEmpty else { return nil }
        let chapters = allSources
            .filter { $0.sourceType == "book" && $0.parentGroup == parentGroup }
            .sorted(by: MobileSourceGrouping.memberOrder)
        guard let index = chapters.firstIndex(where: { $0.id == sourceID }),
              chapters.indices.contains(index + 1) else { return nil }
        return chapters[index + 1]
    }

    func prepareNextBookChapter(after sourceID: String) async {
        guard let nextChapter = nextBookChapter(after: sourceID),
              !hasSyncedTextToSpeechAudio(sourceID: nextChapter.id),
              !isPreparingAudio(sourceID: nextChapter.id) else { return }
        do {
            _ = try await prepareSourceAudio(sourceID: nextChapter.id)
        } catch {
            if let message = textToSpeechFailureMessage(error, sourceID: nextChapter.id) {
                errorMessage = "The next chapter could not be generated: \(message)"
            }
        }
    }

    func playNextBookChapter(after sourceID: String) async {
        guard let nextChapter = nextBookChapter(after: sourceID) else { return }
        await readSourceAloud(sourceID: nextChapter.id)
    }

    func respondToBookContinuationOffer(
        _ offer: MobileBookContinuationOffer,
        enable: Bool
    ) async {
        if bookContinuationOffer == offer {
            bookContinuationOffer = nil
        }
        MobileBookPlaybackPreferences.hasAskedToAutomaticallyContinue = true
        MobileBookPlaybackPreferences.automaticallyContinues = enable
        guard enable else { return }
        await automaticallyContinueBook(
            from: offer.completedSourceID,
            to: offer.nextSourceID
        )
    }

    func dismissBookContinuationOffer() {
        guard bookContinuationOffer != nil else { return }
        bookContinuationOffer = nil
        MobileBookPlaybackPreferences.hasAskedToAutomaticallyContinue = true
    }

    func setSpeed(_ newSpeed: Float) {
        speed = MobileAudioPlaybackSpeed.clamped(newSpeed)
        Preferences.set(speed, for: Prefs.Mobile.playbackSpeed)
        if isPlaying {
            player.rate = speed
        }
        updateNowPlayingInfo()
    }

    func seek(toFraction fraction: Double) {
        guard duration > 0 else { return }
        seek(to: duration * min(max(fraction, 0), 1))
    }

    func skip(seconds: TimeInterval) {
        guard duration > 0 else { return }
        seek(to: min(max(currentTime + seconds, 0), duration))
        persistPlaybackPosition(force: true)
    }

    /// The direct UI action used by source rows and the reader. Cached audio
    /// starts immediately. Uncached audio uses the source-keyed concurrent path;
    /// the first ready opening claims playback while every requested source
    /// continues generating in the background.
    func toggleTextToSpeech(sourceID: String) async {
        errorMessage = nil
        // The narration is still coming down and its opening is already the
        // player: a tap means pause or resume, not a second download of the
        // same chapter racing the first.
        if narrationDownloadSourceID == sourceID {
            if currentItem?.id == sourceID { togglePlayback() }
            return
        }
        if currentItem?.id == sourceID {
            // The player can still be holding a truncated prefix from a
            // generation that was interrupted, while the finished audio has
            // since landed in the catalog. Listen means the whole source, not a
            // replay of the fragment — so take the longer composition, at the
            // second the listener is already on.
            if let complete = itemForSourceID(sourceID),
               complete.manifest.chunks.count > (currentItem?.manifest.chunks.count ?? 0) {
                await play(complete, startAt: currentTime, inPlace: true)
                return
            }
            togglePlayback()
            return
        }
        guard !isPreparingAudio(sourceID: sourceID) else { return }

        if let item = itemForSourceID(sourceID) {
            await play(item)
            return
        }

        do {
            _ = try await prepareSourceAudio(
                sourceID: sourceID,
                playsOpeningWhenReady: true
            )
        } catch {
            if let message = textToSpeechFailureMessage(error, sourceID: sourceID) {
                errorMessage = message
            }
        }
    }

    func flushPlaybackProgress() {
        persistPlaybackPosition(force: true)
    }

    func playLatestSource(sourceType: String? = nil) async {
        let source = MobileLatestSourceSelector.latest(
            in: allSources,
            sourceType: sourceType
        )
        guard let source else {
            let missingKind = sourceType.map { " synced \($0)s" } ?? " synced sources"
            speakAndResumeListening("I do not have any\(missingKind) to play yet.")
            return
        }

        await playVoiceAgentSource(source.id, utterance: "read me the latest source from ForeverLM")
    }

    func itemForSourceID(_ sourceID: String?) -> MobileAudioItem? {
        guard let sourceID else { return nil }
        return items.first { $0.id == sourceID }
    }

    func source(for sourceID: String?) -> MobileCloudSource? {
        guard let sourceID else { return nil }
        return allSources.first { $0.id == sourceID }
    }

    private func handleCompletedBookChapter(sourceID: String) async {
        guard let nextChapter = nextBookChapter(after: sourceID) else { return }
        if MobileBookPlaybackPreferences.automaticallyContinues {
            await automaticallyContinueBook(from: sourceID, to: nextChapter.id)
        } else if !MobileBookPlaybackPreferences.hasAskedToAutomaticallyContinue {
            bookContinuationOffer = MobileBookContinuationOffer(
                completedSourceID: sourceID,
                nextSourceID: nextChapter.id,
                nextTitle: nextChapter.title
            )
        }
    }

    func automaticallyContinueBook(
        from completedSourceID: String,
        to nextSourceID: String
    ) async {
        guard MobileBookPlaybackPreferences.automaticallyContinues,
              currentItem?.id == completedSourceID,
              !isPlaying,
              duration > 0,
              currentTime >= duration - 1 else { return }

        if !hasSyncedTextToSpeechAudio(sourceID: nextSourceID),
           !isPreparingAudio(sourceID: nextSourceID) {
            do {
                _ = try await prepareSourceAudio(sourceID: nextSourceID)
            } catch {
                if let message = textToSpeechFailureMessage(error, sourceID: nextSourceID) {
                    errorMessage = "The next chapter could not be generated: \(message)"
                }
                return
            }
        } else if isPreparingAudio(sourceID: nextSourceID) {
            pendingAutomaticBookContinuation = (completedSourceID, nextSourceID)
            return
        }

        // Closing the player, replaying the completed chapter, or starting any
        // other source while generation ran cancels the delayed handoff. Turning
        // the setting off while generation runs leaves the audio prepared but
        // does not start it.
        guard MobileBookPlaybackPreferences.automaticallyContinues,
              currentItem?.id == completedSourceID,
              !isPlaying,
              duration > 0,
              currentTime >= duration - 1 else { return }
        await readSourceAloud(sourceID: nextSourceID)
    }

    /// The earliest ready opening among concurrent UI Listen requests owns the
    /// empty player. Ownership lasts until that job completes even if the
    /// listener closes it, so another already-requested source cannot pop up
    /// immediately afterward.
    func startBackgroundOpeningPlaybackIfAvailable(
        _ item: MobileAudioItem
    ) async -> Bool {
        guard currentItem == nil,
              backgroundOpeningPlaybackOwnerSourceID == nil,
              !MobileRealtimeVoice.controller.isActive else { return false }

        backgroundOpeningPlaybackOwnerSourceID = item.id
        let didStart = await startOpeningPlayback(item)
        if !didStart, backgroundOpeningPlaybackOwnerSourceID == item.id {
            backgroundOpeningPlaybackOwnerSourceID = nil
        }
        return didStart
    }

    /// Replaces a progressively growing opening with the final durable
    /// manifest without moving the playback cursor. A dismissed opening has
    /// already cleared `openingPlaybackSourceID`, so completion stays silent.
    func finishBackgroundOpeningPlaybackIfNeeded(
        _ item: MobileAudioItem
    ) async {
        guard openingPlaybackSourceID == item.id,
              currentItem?.id == item.id,
              !MobileRealtimeVoice.controller.isActive else { return }

        let startAt = currentTime
        let keepPaused = !isPlaying && !openingPlaybackRanDry
        openingPlaybackSourceID = nil
        isAwaitingRemainingNarration = false
        openingPlaybackRanDry = false

        await play(item, startAt: startAt, inPlace: true)
        if keepPaused, isPlaying {
            togglePlayback()
        }
    }

    /// Starts `playerItem` on a second player in step with the one that is
    /// sounding and makes it the player, so audio that replaces what is
    /// playing goes in without a break. False when it did not take over: the
    /// player is as it was, and `playerItem` must not be used again.
    private func handOverInStep(
        to playerItem: AVPlayerItem,
        stillWanted: @MainActor () -> Bool
    ) async -> Bool {
        await MobileGaplessPlayerHandover.run(
            from: player,
            to: playerItem,
            rate: speed,
            stillWanted: stillWanted,
            adopt: { incoming in self.adoptPlayer(incoming) }
        )
    }

    /// The second the listener is at, for audio about to replace what is
    /// playing: the player's own clock, clamped to the new audio. `currentTime`
    /// is only the periodic observer's last tick, up to half a second old.
    /// With nothing in the player (a prefix that was closed) the last tick is
    /// all there is.
    func handoverSecond(into newDuration: TimeInterval) -> TimeInterval {
        Self.handoverSecond(
            playerSecond: player.currentItem == nil ? nil : player.currentTime().seconds,
            lastTick: currentTime,
            newDuration: newDuration
        )
    }

    nonisolated static func handoverSecond(
        playerSecond: Double?,
        lastTick: TimeInterval,
        newDuration: TimeInterval
    ) -> TimeInterval {
        let second = playerSecond.flatMap { $0.isFinite ? $0 : nil } ?? lastTick
        return min(max(second, 0), max(newDuration, 0))
    }

    /// Plays the opening section the moment its audio lands, so tapping Listen
    /// makes sound in a couple of seconds instead of holding a spinner for as
    /// long as a whole paper takes to narrate.
    ///
    /// The manifest here describes only the opening and is never saved — it
    /// exists so playback, Now Playing, and the transport controls have the
    /// same shape they always do. `generateCloudTextToSpeechAudio` replaces it
    /// with the whole composition as soon as the rest is generated.
    func startOpeningPlayback(
        _ item: MobileAudioItem,
        startAt: TimeInterval = 0
    ) async -> Bool {
        guard !MobileRealtimeVoice.controller.isActive else { return false }
        // A listener who started something else during generation keeps it.
        guard currentItem == nil || currentItem?.id == item.id || !isPlaying else { return false }

        do {
            try await configureAudioSession()
            let urls = try await Task.detached(priority: .userInitiated) {
                try SyncedArticleAudioStore.chunkURLs(for: item.manifest)
            }.value
            let composition = try await audioComposition(for: urls)
            let playerItem = await MobileLoudnessAudioMix.playerItem(for: composition.asset)

            installOpeningEndObserver(for: playerItem)

            let resumeTime = min(max(startAt, 0), composition.duration)
            openingPlaybackSourceID = item.id
            isAwaitingRemainingNarration = true
            openingPlaybackRanDry = false
            currentItem = item
            activeVoiceSourceID = item.id
            activeVoiceSourceTitle = item.title
            duration = composition.duration
            currentTime = resumeTime
            lastPlaybackPositionSaveAt = nil
            player.replaceCurrentItem(with: playerItem)
            if resumeTime > 0 {
                await player.seek(
                    to: CMTime(seconds: resumeTime, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }
            player.playImmediately(atRate: speed)
            isPlaying = true
            isLoading = false
            updateNowPlayingInfo()
            Task { [weak self] in
                await self?.recordSourceActivity(sourceID: item.id, kind: .listening)
            }
            return true
        } catch {
            // Nothing is lost: generation continues, and the whole source plays
            // through the ordinary path when it finishes. Returning the result
            // lets the progress surface explain why playback has not started yet.
            openingPlaybackSourceID = nil
            isAwaitingRemainingNarration = false
            openingPlaybackRanDry = false
            return false
        }
    }

    /// Replaces the temporary composition with its longer contiguous prefix.
    /// Requests may finish out of order, but `CloudArticleTTS` only calls this
    /// with gap-free audio, so the current global playback second is stable.
    /// If the old prefix ran dry, the new audio resumes automatically; an
    /// intentional pause inside the prefix remains paused.
    func extendOpeningPlayback(_ item: MobileAudioItem) async -> Bool {
        guard openingPlaybackSourceID == item.id,
              currentItem?.id == item.id,
              !MobileRealtimeVoice.controller.isActive else { return false }

        // Sound is playing and there is plenty of it left: keep this prefix for
        // later instead of interrupting the listener once per generated piece.
        // A paused or dried-up player is silent, so it takes the swap at once.
        if isPlaying, !openingPlaybackRanDry, !openingPrefixIsRunningLow {
            deferredOpeningExtension = item
            return true
        }
        deferredOpeningExtension = nil

        do {
            let urls = try await Task.detached(priority: .userInitiated) {
                try SyncedArticleAudioStore.chunkURLs(for: item.manifest)
            }.value
            let composition = try await audioComposition(for: urls)
            // The whole composition may have taken over while this prefix was
            // being assembled; installing the shorter one now would move the
            // listener backwards.
            guard openingPlaybackSourceID == item.id, currentItem?.id == item.id else { return false }
            guard composition.duration > duration + 0.05 else { return true }

            var playerItem = await MobileLoudnessAudioMix.playerItem(for: composition.asset)
            // The same two questions again: the listener kept listening while
            // the item was made, and something longer may have gone in.
            guard openingPlaybackSourceID == item.id, currentItem?.id == item.id else { return false }
            guard composition.duration > duration + 0.05 else { return true }

            // While the prefix is sounding, the longer one takes over in step
            // with it, so the listener hears no break.
            var tookOverInStep = false
            if isPlaying, !openingPlaybackRanDry {
                let longerDuration = composition.duration
                tookOverInStep = await handOverInStep(to: playerItem) { [weak self] in
                    guard let self else { return false }
                    return self.openingPlaybackSourceID == item.id
                        && self.currentItem?.id == item.id
                        && longerDuration > self.duration + 0.05
                }
                if !tookOverInStep {
                    // The first item belonged to the player that was given up.
                    playerItem = await MobileLoudnessAudioMix.playerItem(for: composition.asset)
                    guard openingPlaybackSourceID == item.id, currentItem?.id == item.id else { return false }
                    guard composition.duration > duration + 0.05 else { return true }
                }
            }
            // Read at the swap, not before the item was made: a second noted
            // earlier moves the listener back by as long as that took.
            let resumeTime = handoverSecond(into: composition.duration)
            let shouldPlay = isPlaying || openingPlaybackRanDry

            installOpeningEndObserver(for: playerItem)
            currentItem = item
            duration = composition.duration
            currentTime = resumeTime
            if !tookOverInStep {
                player.replaceCurrentItem(with: playerItem)
                if resumeTime > 0 {
                    await player.seek(
                        to: CMTime(seconds: resumeTime, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                }
            }
            if shouldPlay {
                if !tookOverInStep {
                    player.playImmediately(atRate: speed)
                }
                isPlaying = true
                if openingPlaybackRanDry {
                    textToSpeechPreparationDetail = "Playing · generating remaining audio…"
                }
                openingPlaybackRanDry = false
            } else {
                isPlaying = false
            }
            updateNowPlayingInfo()
            return true
        } catch {
            // Keep the shorter prefix playing. Final generation still performs
            // the ordinary whole-source handoff and surfaces any real failure.
            return false
        }
    }

    /// True when the playing prefix has less than the lead left at the current
    /// speed, so a longer one should go in now.
    private var openingPrefixIsRunningLow: Bool {
        duration - currentTime <= Self.openingExtensionLeadSeconds * Double(max(speed, 0.5))
    }

    /// Installs the waiting longer prefix once the playhead nears the end of
    /// the playing one, or the moment the player stops making sound.
    private func installDeferredOpeningExtensionIfDue() {
        guard let waiting = deferredOpeningExtension else { return }
        guard openingPlaybackSourceID == waiting.id, currentItem?.id == waiting.id else {
            deferredOpeningExtension = nil
            return
        }
        guard !isPlaying || openingPlaybackRanDry || openingPrefixIsRunningLow else { return }
        deferredOpeningExtension = nil
        Task { [weak self] in
            _ = await self?.extendOpeningPlayback(waiting)
        }
    }

    private func installOpeningEndObserver(for playerItem: AVPlayerItem) {
        removeEndObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Running out of the generated prefix is buffering, not source
                // completion. Hold the global second so the next prefix resumes.
                self.isPlaying = false
                self.currentTime = self.duration
                self.openingPlaybackRanDry = true
                self.installDeferredOpeningExtensionIfDue()
                // The bar was saying "Playing"; it is not. Say what it is
                // waiting for, so the silence reads as a gap, not a stop. A
                // download's banner reads its own counts and needs no text.
                if self.narrationDownloadSourceID == nil {
                    self.textToSpeechPreparationDetail = "Waiting for the next section…"
                }
                self.updateNowPlayingInfo()
            }
        }
    }

    func configureAudioSession() async throws {
        try await MobileAudioSessionArbiter.shared.acquire(.voiceTab, for: .playback)
    }

    func registerAudioSessionPreemptionIfNeeded() {
        guard !didRegisterAudioSessionPreemption else { return }
        didRegisterAudioSessionPreemption = true
        Task { [weak self] in
            await MobileAudioSessionArbiter.shared.register(.voiceTab) { [weak self] in
                await self?.yieldAudioSession()
            }
        }
    }

    /// Driven by the arbiter when another surface takes the audio session. Half-duplex
    /// is the invariant, so the mic tap and any in-flight speech must be gone before
    /// the session is reconfigured underneath us.
    private func yieldAudioSession() async {
        // The cheap main-actor state settles first; the mic teardown is awaited last
        // so a tab switch landing mid-handoff cannot clobber it on resume. The
        // arbiter awaits this whole handler, so half-duplex still holds.
        speech.stop(owner: .voiceTab)
        shouldResumePlaybackAfterSpeech = false
        if isPlaying {
            player.pause()
            isPlaying = false
            persistPlaybackPosition(force: true)
            updateNowPlayingInfo()
        }
        await voice.stop()
    }

    nonisolated func audioComposition(
        for urls: [URL]
    ) async throws -> (asset: AVMutableComposition, duration: TimeInterval) {
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MobileAudioPlayerError.couldNotBuildComposition
        }

        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let sourceTrack = tracks.first else {
                throw MobileAudioPlayerError.missingAudioTrack(url.lastPathComponent)
            }
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: cursor
            )
            cursor = cursor + duration
        }

        return (composition, cursor.seconds.isFinite ? cursor.seconds : 0)
    }

    private func seek(to seconds: TimeInterval) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
        updateNowPlayingInfo()
    }

    static func resumeTime(
        from position: ArticleSpeechPlaybackPosition?,
        manifest: SyncedArticleAudioManifest,
        duration: TimeInterval
    ) -> TimeInterval {
        guard let position,
              position.globalTime.isFinite,
              position.globalTime > 0,
              position.contentSignature == nil || position.contentSignature == manifest.contentSignature else {
            return 0
        }
        let clamped = min(position.globalTime, duration)
        return duration - clamped > 5 ? clamped : 0
    }

    func persistPlaybackPosition(force: Bool) {
        guard let currentItem, duration > 0, currentTime.isFinite else { return }
        let now = Date()
        if !force,
           let lastPlaybackPositionSaveAt,
           now.timeIntervalSince(lastPlaybackPositionSaveAt) < 5 {
            return
        }
        lastPlaybackPositionSaveAt = now

        let sourceID = currentItem.id
        let signature = currentItem.manifest.contentSignature
        let elapsed = min(max(currentTime, 0), duration)

        // Depth rides the same throttle as the position save, exactly as it does
        // on the Mac. A prefix-only opening plays against the prefix's duration
        // rather than the whole source's, so its inflated fraction must never
        // reach the MAX merge that can only ever move forward.
        let fraction = elapsed / duration
        if openingPlaybackSourceID == nil,
           !isAwaitingRemainingNarration,
           shouldRecordDepth(sourceID: sourceID, fraction: fraction) {
            Task { @MainActor [weak self] in
                await self?.recordSourceDepth(
                    sourceID: sourceID,
                    kind: .listening,
                    fraction: fraction
                )
            }
        }

        if duration - elapsed <= 1 {
            clearPlaybackPosition(for: sourceID)
            return
        }
        let position = ArticleSpeechPlaybackPosition(
            globalTime: elapsed,
            appleCharacterOffset: nil,
            contentSignature: signature,
            updatedAt: now
        )
        // A forced save is a pause, a skip, a dismissal, or the app leaving the
        // screen — each the moment a listener is likeliest to pick up the Mac —
        // so it reaches the account at once. Steady playback republishes on
        // the account interval so the other device is never far behind.
        let publishesToAccount = force
            || lastAccountPositionSaveAt.map {
                now.timeIntervalSince($0) >= ListeningPositionSync.accountSaveInterval
            } ?? true
        if publishesToAccount {
            lastAccountPositionSaveAt = now
        }
        Task.detached(priority: .utility) {
            try? SyncedArticleAudioStore.savePlaybackPosition(position, sourceID: sourceID)
            if publishesToAccount {
                await SyncedArticleAudioStore.publishPlaybackPositionToAccount(position, sourceID: sourceID)
            }
        }
    }

    private func clearPlaybackPosition(for sourceID: String) {
        Task.detached(priority: .utility) {
            SyncedArticleAudioStore.clearPlaybackPosition(sourceID: sourceID)
        }
    }

    func installTimeObserver(for player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                self.installDeferredOpeningExtensionIfDue()
                self.pauseForSleepTimerIfDue()
                if self.isPlaying {
                    self.persistPlaybackPosition(force: false)
                    if self.openingPlaybackSourceID == nil,
                       let playerItem = player.currentItem,
                       let sourceID = self.currentItem?.id,
                       MobileAudioPlaybackCompletion.reachedEnd(
                           elapsed: self.currentTime,
                           duration: self.duration
                       ) {
                        self.finishFullPlaybackIfNeeded(
                            playerItem: playerItem,
                            sourceID: sourceID
                        )
                    }
                }
                self.updateNowPlayingInfo()
            }
        }
    }

    /// One idempotent completion boundary shared by AVPlayer's end notification
    /// and the final periodic clock tick. Temporary opening prefixes never reach
    /// this path: exhausting one means buffering, not finishing the source.
    private func finishFullPlaybackIfNeeded(
        playerItem: AVPlayerItem,
        sourceID: String
    ) {
        let identity = ObjectIdentifier(playerItem)
        guard openingPlaybackSourceID == nil,
              player.currentItem === playerItem,
              currentItem?.id == sourceID,
              completedPlayerItemIdentity != identity else { return }

        completedPlayerItemIdentity = identity
        isPlaying = false
        currentTime = duration
        clearPlaybackPosition(for: sourceID)
        updateNowPlayingInfo()
        noteVoiceListenFinished(sourceID: sourceID)
        // A sleep timer set to the end of this source stops here: the book
        // does not carry on into its next chapter, and nothing is offered.
        let sleepsHere = sleepTimer == .endOfSource
        if sleepsHere {
            sleepTimer = nil
        }
        Task { @MainActor [weak self] in
            guard !sleepsHere else { return }
            await self?.handleCompletedBookChapter(sourceID: sourceID)
        }
        Task { @MainActor [weak self] in
            await self?.recordSourceConsumption(sourceID: sourceID, kind: .listening)
        }
    }

    func installRemoteCommandHandlers() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // AirPods and other headset controls can deliver the combined command
        // instead of the discrete play/pause commands. Register all three so a
        // stem press always reaches the text-to-speech transport.
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentItem != nil else { return }
                self.togglePlayback()
            }
            return .success
        }

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                if self?.isPlaying == false {
                    self?.togglePlayback()
                }
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                if self?.isPlaying == true {
                    self?.togglePlayback()
                }
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in
                self?.seek(to: event.positionTime)
            }
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.skip(seconds: 15) }
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.skip(seconds: -15) }
            return .success
        }
    }

    func updateNowPlayingInfo() {
        guard let currentItem else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentItem.title,
            MPMediaItemPropertyArtist: currentItem.subtitle ?? "ForeverLM",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0
        ]
        if let subtitle = currentItem.subtitle, !subtitle.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = subtitle
        }
        if let nowPlayingArtwork, nowPlayingArtworkSourceID == currentItem.id {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// The picture CarPlay, the lock screen and Control Center show beside the
    /// narration: a chapter's book cover or a paper's first page from the
    /// synced assets the rows already use, an article's artwork, and the
    /// ForeverLM mark when the source has no image. Loaded once per source and
    /// applied only while that source is still the one playing.
    private func loadNowPlayingArtwork(for item: MobileAudioItem) async {
        if nowPlayingArtworkSourceID != item.id {
            nowPlayingArtwork = nil
        }
        nowPlayingArtworkSourceID = item.id
        var image: UIImage?
        if let source = source(for: item.id) {
            image = await MobileSourceArtworkLoader.localArtwork(for: source, collections: collections)
            if image == nil, let artworkURL = source.artworkURL, let url = URL(string: artworkURL),
               url.scheme?.hasPrefix("http") == true {
                let key = "now-playing-artwork:\(url.absoluteString)"
                if let cached = ImageCache.shared.image(for: key) {
                    image = cached
                } else if let (data, _) = try? await URLSession.shared.data(from: url),
                          let downloaded = UIImage(data: data) {
                    ImageCache.shared.set(downloaded, for: key)
                    image = downloaded
                }
            }
        }
        guard let final = image ?? UIImage(named: "BrandMark") else { return }
        guard nowPlayingArtworkSourceID == item.id else { return }
        nowPlayingArtwork = MPMediaItemArtwork(boundsSize: final.size) { _ in final }
        if currentItem?.id == item.id {
            updateNowPlayingInfo()
        }
    }

    func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    /// A playback time as `m:ss`, or `h:mm:ss` from an hour up; `--:--` when it is unknown.
    static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        return MediaClock.reading(seconds)
    }
}

// MARK: - Gapless handover

/// Hands playback from the player that is sounding to a second player that
/// holds longer audio of the same narration, with no break in the sound.
///
/// Replacing a player's item is a dropout: the player stops, loads the new
/// item, seeks and starts again. Here the new item is loaded, sought and
/// prerolled on its own silent player while the first keeps playing, and is
/// then started on the host clock at the exact instant the first reaches the
/// chosen second (`setRate(_:time:atHostTime:)`).
///
/// That start is exact at 1x only. At any other speed the player lands ahead
/// or behind by a share of the lead it was given (measured on a Mac: a third
/// of a second ahead at 2x with a 0.4 s lead). So the two clocks are compared
/// while the new player is still silent, and it is anchored again to the
/// first player's timebase, with the error that anchoring itself leaves taken
/// off, until they agree. Both then play the same words in step, the volume
/// moves from one to the other mid-word, and the first is let go.
@MainActor
enum MobileGaplessPlayerHandover {
    nonisolated private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "AudioHandover")

    /// Wall-clock seconds the incoming player is given to seek and preroll
    /// before the outgoing one reaches the handover second. The second try is
    /// for a phone too busy to make the first.
    nonisolated static let leadSeconds: [Double] = [0.4, 1.0]
    /// The incoming player must be started at least this far ahead of the
    /// handover instant.
    nonisolated static let minimumStartMargin = 0.05
    /// The two players are in step when their clocks differ by less than this
    /// many wall-clock seconds: too short to hear as a repeat or a skip.
    nonisolated static let inStepTolerance = 0.006
    /// Further apart than this (wall-clock seconds) is not a start error: the
    /// listener moved the outgoing player meanwhile.
    nonisolated static let movedApart = 1.0
    /// How far ahead a silent, running player is anchored again, and how many
    /// times before the handover is given up.
    nonisolated static let correctionLead = 0.1
    nonisolated static let maximumCorrections = 4
    /// Wall-clock seconds the outgoing audio must still have after the
    /// handover second: the corrections and the volume move happen in it.
    nonisolated static let settleSeconds = 1.5

    /// True when `incoming` took over and `adopt` was called with its player.
    /// False leaves `outgoing` exactly as it was; `item` was then given to a
    /// player that is discarded and must not be played again.
    ///
    /// `stillWanted` is asked once, at the handover instant, with nothing
    /// awaited between its answer and `adopt`.
    static func run(
        from outgoing: AVPlayer,
        to item: AVPlayerItem,
        rate: Float,
        stillWanted: @MainActor () -> Bool,
        adopt: @MainActor (AVPlayer) -> Void
    ) async -> Bool {
        guard rate > 0, isSounding(outgoing, at: rate),
              let outgoingItem = outgoing.currentItem else { return false }
        let volume = outgoing.volume

        let incoming = AVPlayer(playerItem: item)
        // Required by `setRate(_:time:atHostTime:)`. The audio is local files.
        incoming.automaticallyWaitsToMinimizeStalling = false
        incoming.volume = 0
        var handedOver = false
        defer {
            if !handedOver {
                incoming.pause()
                incoming.replaceCurrentItem(with: nil)
            }
        }
        guard await becomesReady(item) else { return false }

        for lead in leadSeconds {
            guard isSounding(outgoing, at: rate), outgoing.currentItem === outgoingItem,
                  let timebase = outgoingItem.timebase,
                  let target = handoverSecond(
                      outgoingSecond: outgoing.currentTime().seconds,
                      lead: lead,
                      rate: Double(rate),
                      outgoingDuration: outgoingItem.duration.seconds,
                      incomingDuration: item.duration.seconds
                  ) else { return false }
            let targetTime = CMTime(seconds: target, preferredTimescale: 48_000)
            guard await incoming.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero),
                  await incoming.preroll(atRate: rate) else { return false }
            guard isSounding(outgoing, at: rate), outgoing.currentItem === outgoingItem else { return false }

            // The host-clock instant at which the outgoing audio reaches the
            // target, from its own timebase rather than from arithmetic here.
            let hostClock = CMClockGetHostTimeClock()
            let hostTime = CMSyncConvertTime(targetTime, from: timebase, to: hostClock)
            let wait = CMTimeSubtract(hostTime, CMClockGetTime(hostClock)).seconds
            guard wait.isFinite else { return false }
            // Seeking took longer than the lead: try once more, further ahead.
            guard wait > minimumStartMargin else { continue }

            incoming.setRate(rate, time: targetTime, atHostTime: hostTime)
            try? await Task.sleep(nanoseconds: UInt64((wait + 0.05) * 1_000_000_000))
            var incomingTimebase: CMTimebase?
            for _ in 0..<40 {
                if isSounding(incoming, at: rate), let running = item.timebase, CMTimebaseGetRate(running) > 0 {
                    incomingTimebase = running
                    break
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            guard let incomingTimebase else { return false }

            // Bring the silent player in step. `bias` is the error an anchor
            // of this lead leaves at this speed, learned from the last one.
            var apart = secondsApart(incomingTimebase, timebase, on: hostClock)
            var bias = 0.0
            var corrections = 0
            while abs(apart) > inStepTolerance * Double(rate) {
                guard apart.isFinite, abs(apart) < movedApart * Double(rate),
                      corrections < maximumCorrections,
                      isSounding(outgoing, at: rate), outgoing.currentItem === outgoingItem else {
                    logger.notice("Handover given up: \(apart * 1000, privacy: .public) ms apart after \(corrections, privacy: .public) corrections")
                    return false
                }
                if corrections > 0 {
                    bias += apart
                }
                corrections += 1
                let anchorHost = CMTimeAdd(
                    CMClockGetTime(hostClock),
                    CMTime(seconds: correctionLead, preferredTimescale: 1_000_000_000)
                )
                let anchorTime = CMTimeSubtract(
                    CMSyncConvertTime(anchorHost, from: hostClock, to: timebase),
                    CMTime(seconds: bias, preferredTimescale: 1_000_000_000)
                )
                incoming.setRate(rate, time: anchorTime, atHostTime: anchorHost)
                try? await Task.sleep(nanoseconds: UInt64((correctionLead + 0.1) * 1_000_000_000))
                apart = secondsApart(incomingTimebase, timebase, on: hostClock)
            }

            // Nothing awaits from here to the end of the handover.
            guard isSounding(incoming, at: rate), isSounding(outgoing, at: rate),
                  outgoing.currentItem === outgoingItem, stillWanted() else { return false }

            incoming.volume = volume
            outgoing.volume = 0
            handedOver = true
            adopt(incoming)
            outgoing.pause()
            outgoing.replaceCurrentItem(with: nil)
            outgoing.volume = volume
            logger.info("Handed over near \(target, privacy: .public) s, \(apart * 1000, privacy: .public) ms apart after \(corrections, privacy: .public) corrections")
            return true
        }
        return false
    }

    /// The second at which the incoming audio starts in step, or nil when
    /// there is no room for it: the outgoing audio must still be sounding for
    /// `settleSeconds` past that second, and the incoming audio must hold it.
    nonisolated static func handoverSecond(
        outgoingSecond: Double,
        lead: Double,
        rate: Double,
        outgoingDuration: Double,
        incomingDuration: Double
    ) -> Double? {
        guard outgoingSecond.isFinite, outgoingDuration.isFinite, incomingDuration.isFinite,
              outgoingSecond >= 0, lead > 0, rate > 0 else { return nil }
        let target = outgoingSecond + lead * rate
        guard target + settleSeconds * rate < outgoingDuration, target < incomingDuration else { return nil }
        return target
    }

    /// How far `first` is ahead of `second`, in their own (media) seconds,
    /// read off both timebases at one host-clock instant.
    private static func secondsApart(_ first: CMTimebase, _ second: CMTimebase, on hostClock: CMClock) -> Double {
        let now = CMClockGetTime(hostClock)
        return CMSyncConvertTime(now, from: hostClock, to: first).seconds
            - CMSyncConvertTime(now, from: hostClock, to: second).seconds
    }

    private static func isSounding(_ player: AVPlayer, at rate: Float) -> Bool {
        player.rate == rate && player.timeControlStatus == .playing
    }

    /// A composition of local files is ready within a few run-loop turns.
    private static func becomesReady(_ item: AVPlayerItem) async -> Bool {
        for _ in 0..<200 {
            switch item.status {
            case .readyToPlay: return true
            case .failed: return false
            default: try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        return false
    }
}
