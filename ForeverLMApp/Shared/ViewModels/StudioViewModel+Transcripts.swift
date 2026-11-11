import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import AppKit
import SQLite3
import Darwin

extension StudioViewModel {

    /// Whether a transcript may go through the billed formatting pass.
    ///
    /// Hidden sources — a hidden podcast show or YouTube channel, or an
    /// individually hidden episode or video — may retain a transcript fetched
    /// before they were hidden, but nobody is reading them, so formatting them
    /// is money spent on nothing. An explicit user request overrides that.
    ///
    /// A Dev or First Run build keeps a library of its own, which does not know
    /// what the learner hid in the installed app, yet it bills the same account.
    /// On 2026-09-25 a First Run import formatted TBPN, All-In and three other
    /// shows hidden in the real library. Those shows are treated as hidden here,
    /// for the billed pass only, so the Dev library still lists them as it would.
    func allowsTranscriptFormatting(
        for article: StudioArticle,
        userInitiated: Bool,
        automaticFormattingAllowed: Bool = true,
        installedLibraryHiddenShows: Set<String> = InstalledLibraryHiddenPodcastShows.names
    ) -> Bool {
        if userInitiated { return true }
        guard automaticFormattingAllowed, !isSourceHidden(article) else { return false }
        if article.sourceType == .podcast,
           installedLibraryHiddenShows.contains(article.domain),
           !visiblePodcastEpisodeOverrideIDs.contains(article.id) {
            return false
        }
        return true
    }

    /// Fetch a YouTube transcript directly without falling back to podcast search.
    ///
    /// - Parameters:
    ///   - userInitiated: `true` when the user asked for this specific video's
    ///     transcript, which permits the billed formatting pass even on a hidden
    ///     channel. Automatic fetches leave hidden videos as raw captions.
    ///   - forceRefresh: `true` re-downloads the captions instead of returning
    ///     the stored transcript, so a video that was fetched while its channel
    ///     was hidden can be formatted after the fact.
    ///   - allowsAutomaticFormatting: set to `false` for automatic Liked-video
    ///     imports until the learner explicitly opts into their potentially
    ///     large formatting cost. An explicit per-video request still formats.
    func fetchYouTubeTranscript(
        for articleId: String,
        userInitiated: Bool = false,
        forceRefresh: Bool = false,
        allowsAutomaticFormatting: Bool = true
    ) async {
        guard !youtubeTranscriptFetchInFlight.contains(articleId) else { return }
        youtubeTranscriptFetchInFlight.insert(articleId)
        defer { youtubeTranscriptFetchInFlight.remove(articleId) }

        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
        let urlString = articles[idx].url

        guard YouTubeTranscriptService.isYouTubeURL(urlString) else {
            articles[idx].state = .error
            articles[idx].errorMessage = "Not a YouTube URL."
            return
        }

        // Show the loading state immediately so the empty prompt never flashes while
        // the cache load and network fetch below run. The cache-hit path resets this
        // to .ready right after.
        articles[idx].state = .fetching
        articles[idx].errorMessage = nil

        if !forceRefresh,
           let cachedTranscript = await storage.loadSourceContent(articleId),
           !cachedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Re-resolve by id: the index captured before the cache-load await may
            // now point at a different source if a concurrent refresh reordered `articles`.
            guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
            articles[idx].content = cachedTranscript
            articles[idx].wordCount = cachedTranscript.split(separator: " ").count
            articles[idx].state = .ready
            articles[idx].errorMessage = nil

            // Title may still be the domain if the watch page was blocked on first fetch
            if Self.titleLooksBad(articles[idx].title, domain: articles[idx].domain, url: articles[idx].url),
               let videoId = YouTubeTranscriptService.extractVideoId(from: urlString),
               let title = await YouTubeTranscriptService.shared.fetchVideoTitle(videoId: videoId),
               let idx2 = articles.firstIndex(where: { $0.id == articleId }) {
                articles[idx2].title = title
            }
            if let idx2 = articles.firstIndex(where: { $0.id == articleId }) {
                do {
                    try await storage.saveSource(articles[idx2])
                } catch {
                    logger.error("saveSource failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }

        do {
            // Fetch the video's official chapters alongside formatting: it is a
            // separate WEB request (the caption client returns no markers) and
            // formatting a long lecture takes minutes, so overlap the two.
            async let officialChaptersTask = Self.fetchOfficialChapters(for: urlString)

            let (rawTranscript, videoTitle) = try await YouTubeTranscriptService.shared.fetchTranscript(from: urlString)
            guard let idx2 = articles.firstIndex(where: { $0.id == articleId }) else { return }
            if let videoTitle, !videoTitle.isEmpty,
               Self.titleLooksBad(articles[idx2].title, domain: articles[idx2].domain, url: articles[idx2].url) {
                articles[idx2].title = videoTitle
            }

            // Show the transcript the moment captions are in hand. Formatting can
            // take minutes on a long lecture, and gating readiness on it left the
            // reader stuck on "Fetching transcript…" long after the text itself was
            // ready. The raw caption stream already carries [m:ss] markers and reads
            // fine; it upgrades to the formatted version in place once formatting
            // finishes below.
            articles[idx2].content = rawTranscript
            articles[idx2].wordCount = rawTranscript.split(separator: " ").count
            articles[idx2].state = .ready
            articles[idx2].errorMessage = nil
            let interimTitle = videoTitle ?? articles[idx2].title
            let channelName = articles[idx2].domain
            // Videos on a hidden channel may retain raw captions for a future
            // unhide, but never pay for formatting nobody asked for.
            let hasLikedVideoFormattingConsent = Self.permitsAutomaticTranscriptFormatting(
                for: articles[idx2],
                likedFormattingEnabled: Self.isLikedYouTubeTranscriptFormattingEnabled
            )
            let allowsFormatting = allowsTranscriptFormatting(
                for: articles[idx2],
                userInitiated: userInitiated,
                automaticFormattingAllowed: allowsAutomaticFormatting
                    && hasLikedVideoFormattingConsent
            )
            do {
                try await storage.saveSource(articles[idx2])
            } catch {
                logger.error("saveSource failed: \(error.localizedDescription, privacy: .public)")
            }

            // YouTube caption streams often arrive as one unpunctuated block.
            // Use the transcript-formatting task to add punctuation, paragraphs,
            // and study-friendly section headings when the user has AI configured.
            let formattedTranscript: String?
            if allowsFormatting {
                formattedTranscript = await formatReadableYouTubeTranscriptWithLLM(
                    rawTranscript,
                    sourceID: articleId,
                    videoTitle: interimTitle,
                    channelName: channelName
                )
            } else {
                logger.info("Skipping automatic transcript formatting for YouTube video \(interimTitle)")
                formattedTranscript = nil
            }
            let baseTranscript = formattedTranscript.flatMap {
                Self.containsYouTubeTimingMarkers($0) ? $0 : nil
            } ?? rawTranscript
            // Replace the formatter's guessed section headings with the video's
            // real chapters when it has any; otherwise this is a no-op and the
            // AI headings stay as the fallback.
            let transcript = YouTubeChapterMarkup.applyingOfficialChapters(
                await officialChaptersTask,
                to: baseTranscript
            )
            // Slides are not captured at ingest. Capturing them streams the
            // video to grab full-resolution frames — minutes of work on a long
            // lecture — and most videos are never opened for their slides. It is
            // now opt-in per video: the reader's "Show slides" button calls
            // `extractSlideFrames`, which also unlocks the per-video "Extract
            // papers" scan. See StudioViewModel+SlideCitations.
            //
            // Re-resolve by id: the interim-ready save and the format await above
            // may have let a concurrent refresh reorder `articles`, leaving `idx2`
            // stale.
            guard let idx3 = articles.firstIndex(where: { $0.id == articleId }) else { return }
            articles[idx3].content = transcript
            articles[idx3].wordCount = transcript.split(separator: " ").count
            articles[idx3].state = .ready
            articles[idx3].errorMessage = nil
            do {
                try await storage.saveSource(articles[idx3])
            } catch {
                logger.error("saveSource failed: \(error.localizedDescription, privacy: .public)")
            }
            queueSourceEmbeddingRefreshIfReady(articleId)
        } catch {
            guard let idx2 = articles.firstIndex(where: { $0.id == articleId }) else { return }
            articles[idx2].state = .error
            articles[idx2].errorMessage = "YouTube transcript unavailable: \(error.localizedDescription)"
            logger.info("YouTube transcript failed: \(error.localizedDescription)")
            // Store the failure. Left in memory only, the next library reload
            // reverted the row to the stored `queued`, the once-per-session
            // sweep never touched it again, and a video with no captions sat
            // under "Waiting to process…" until the app was quit — with no
            // Retry, because nothing showed it had failed. A re-download of an
            // existing transcript is the exception: storage still holds the
            // text the learner had, and `reformatYouTubeTranscript` puts the
            // row back from it, so that failure stays in memory.
            if !forceRefresh {
                do {
                    try await storage.saveSource(articles[idx2])
                } catch {
                    logger.error("saveSource failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Re-download a YouTube video's captions and run them through the formatter
    /// again, replacing the stored transcript.
    ///
    /// The stored transcript is otherwise final: a video fetched while its
    /// channel was hidden keeps raw captions forever, because every other path
    /// short-circuits on the cached text. This is the way back.
    func reformatYouTubeTranscript(for articleId: String) async {
        guard let article = articles.first(where: { $0.id == articleId }),
              YouTubeTranscriptService.isYouTubeURL(article.url) else { return }
        let previousContent = article.content
        let previousState = article.state
        let previousWordCount = article.wordCount

        showToast("Reformatting transcript…")
        await fetchYouTubeTranscript(for: articleId, userInitiated: true, forceRefresh: true)

        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
        guard articles[idx].state == .error else {
            showToast("Reformatted transcript")
            return
        }

        // A failed re-download must not cost the user the transcript they had.
        // Only the in-memory row moved to .error — storage still holds the old
        // text — so putting the row back is enough. An unopened source carries
        // no in-memory content, so fall back to what storage kept.
        let restored: String?
        if let previousContent {
            restored = previousContent
        } else {
            restored = await storage.loadSourceContent(articleId)
        }
        guard let restored, !restored.isEmpty,
              let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
        articles[idx].content = restored
        articles[idx].wordCount = previousContent == nil
            ? restored.split(separator: " ").count
            : previousWordCount
        articles[idx].state = previousState
        articles[idx].errorMessage = nil
        showToast("Could not reformat transcript — kept the existing one")
    }

    /// Who asked for a Zoom transcript. Both routes ask Zoom and only Zoom;
    /// the difference is when to stop. The automatic route — a session that
    /// just arrived from the recordings mailbox or a pasted link, the
    /// quarter-hourly check, a reader opening it — gives up after two days,
    /// while the learner pressing Get Transcript is always worth one more
    /// ask (`ZoomTranscriptWait`).
    enum ZoomTranscriptRequest: Sendable {
        case automatic
        case userInitiated
    }

    /// The rule for a session whose transcript Zoom has not published: how
    /// long to keep asking before giving the session up as having none. Pure,
    /// so it can be pinned; the clock is the moment the session was added,
    /// which for a mailed notice is minutes after the meeting ended.
    ///
    /// Zoom writes the transcript after the recording, usually within the
    /// hour, so the "assets are ready" notice — and the fetch it triggers —
    /// comes first, and the answer is simply to ask again later. Waiting is
    /// the entire strategy: there is no longer a fallback that downloads the
    /// recording and transcribes it here. The product owner (2026-09-12): "zoom
    /// automatically transcribes our meetings already; can you just let me
    /// ingest those transcripts … no need to also have the recordings", and
    /// again (2026-09-15): "we never really need to upload the recording,
    /// just the transcript is ok".
    enum ZoomTranscriptWait {
        /// After this the session is marked as having no transcript.
        static let giveUpAfter: TimeInterval = 48 * 60 * 60
        /// How often the automatic check asks Zoom again.
        static let checkInterval: TimeInterval = 15 * 60

        enum Decision: Equatable {
            /// Ask Zoom for its transcript; keep waiting if it has none.
            case askZoom
            /// Stop waiting: the session has no transcript.
            case giveUp
        }

        /// A learner who presses Get Transcript is asking Zoom now, and is
        /// always worth one more ask — including past `giveUpAfter`, which
        /// only bounds the unattended check.
        static func decision(request: ZoomTranscriptRequest, addedAt: Date, now: Date = Date()) -> Decision {
            if request == .userInitiated { return .askZoom }
            return now.timeIntervalSince(addedAt) >= giveUpAfter ? .giveUp : .askZoom
        }

        /// The row's status line while it waits, e.g.
        /// "Waiting for Zoom's transcript · checked 10:42".
        static func waitingMessage(checkedAt: Date, detail: String?) -> String {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            var message = "Waiting for Zoom's transcript · checked \(formatter.string(from: checkedAt))"
            if let detail, !detail.isEmpty { message += " · \(detail)" }
            return message
        }

        static let waitingMarker = "Waiting for Zoom's transcript"

        /// Whether a stored row is one the automatic check should ask about
        /// again: a Zoom recording with no text that is waiting (or was left
        /// in the plain error the pre-wait builds wrote) and is not yet given
        /// up on. Terminal errors — a passcode, a removed recording — are not.
        static func isWaiting(state: StudioArticleState, errorMessage: String?, hasContent: Bool, addedAt: Date, now: Date = Date()) -> Bool {
            guard !hasContent, now.timeIntervalSince(addedAt) < giveUpAfter else { return false }
            switch state {
            case .queued:
                return true
            case .error:
                let message = errorMessage ?? ""
                return message.contains(waitingMarker) || message.contains("produced no text")
            case .fetching, .ready:
                return false
            }
        }
    }

    /// Fetch the transcript for a one-off Zoom cloud-recording link, preferring
    /// Zoom's own VTT transcript. When Zoom has none yet, an automatic request
    /// leaves the session waiting and the quarter-hourly check asks again; a
    /// learner's own request falls back to transcribing the recording media
    /// on the managed proxy. Passcode-protected recordings surface an error
    /// prompting for the passcode (context menu → "Enter Zoom Passcode…").
    /// Once Zoom accepts a supplied passcode, it is saved in the synchronized
    /// Keychain and reused for this source on later fetches.
    func fetchZoomTranscript(for articleId: String, passcode: String? = nil, request: ZoomTranscriptRequest = .userInitiated) async {
        guard !zoomTranscriptFetchInFlight.contains(articleId) else { return }
        zoomTranscriptFetchInFlight.insert(articleId)
        defer { zoomTranscriptFetchInFlight.remove(articleId) }

        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
        let urlString = articles[idx].url
        // A passcode typed in is the learner asking.
        let request: ZoomTranscriptRequest = passcode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? .userInitiated : request
        let decision = ZoomTranscriptWait.decision(request: request, addedAt: articles[idx].dateAdded)
        if decision == .giveUp {
            if articles[idx].state != .error || articles[idx].errorMessage?.contains(ZoomTranscriptWait.waitingMarker) == true {
                articles[idx].state = .error
                articles[idx].errorMessage = "Zoom never published a transcript for this recording. Right-click the session and choose Get Transcript to transcribe the recording itself."
                do {
                    try await storage.saveSource(articles[idx])
                } catch {
                    logger.error("saveSource failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }

        guard ZoomRecordingService.isZoomRecordingURL(urlString) else {
            articles[idx].state = .error
            articles[idx].errorMessage = "Not a Zoom recording URL."
            return
        }

        let trimmedPasscode = passcode?.trimmingCharacters(in: .whitespacesAndNewlines)
        let suppliedPasscode = trimmedPasscode.flatMap { $0.isEmpty ? nil : $0 }
        let savedPasscode: String?
        if suppliedPasscode == nil {
            savedPasscode = await Task.detached(priority: .userInitiated) {
                KeychainService.zoomRecordingPasscode(forSourceID: articleId)
            }.value
        } else {
            savedPasscode = nil
        }
        let effectivePasscode = suppliedPasscode ?? savedPasscode

        if let suppliedPasscode {
            let saved = await Task.detached(priority: .utility) {
                KeychainService.saveZoomRecordingPasscode(suppliedPasscode, forSourceID: articleId)
            }.value
            if !saved {
                showToast("Could not save the Zoom passcode to Keychain.")
            }
        }

        // The one place every Zoom recording passes through, whoever created
        // it: a link pasted here, a source captured in Web Studio (which can
        // only record the broad `video` type), or a row synced from a build
        // that still filed recordings under a Zoom tab. Adopting it as a meeting
        // session here means no ingest path can leave one in a family whose list
        // would never show it.
        if articles[idx].sourceType != .meeting || articles[idx].parentGroup == nil {
            var adopted = articles[idx]
            await assignZoomMeetingSeries(to: &adopted, explicit: false)
            if let current = articles.firstIndex(where: { $0.id == articleId }) {
                articles[current] = adopted
                do {
                    try await storage.saveSource(adopted)
                } catch {
                    logger.error("saveSource failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        articles[idx].state = .fetching
        articles[idx].errorMessage = nil

        if let cachedTranscript = await storage.loadSourceContent(articleId),
           !cachedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
            articles[idx].content = cachedTranscript
            articles[idx].wordCount = cachedTranscript.split(separator: " ").count
            articles[idx].state = .ready
            articles[idx].errorMessage = nil
            do {
                try await storage.saveSource(articles[idx])
            } catch {
                logger.error("saveSource failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        do {
            let result = try await ZoomRecordingService.shared.fetchTranscript(
                from: urlString, passcode: effectivePasscode
            )
            guard let idx2 = articles.firstIndex(where: { $0.id == articleId }) else { return }
            if let topic = result.topic, !topic.isEmpty,
               Self.titleLooksBad(articles[idx2].title, domain: articles[idx2].domain, url: articles[idx2].url) {
                articles[idx2].title = topic
            }
            articles[idx2].content = result.transcript
            articles[idx2].wordCount = result.transcript.split(separator: " ").count
            articles[idx2].state = .ready
            articles[idx2].errorMessage = nil
            do {
                try await storage.saveSource(articles[idx2])
            } catch {
                logger.error("saveSource failed: \(error.localizedDescription, privacy: .public)")
            }
            queueSourceEmbeddingRefreshIfReady(articleId)
            MeetingActionItemExtractor.shared.noteTranscriptReady(sourceID: articleId)
            logger.info("Zoom transcript stored for \(articleId, privacy: .public)")
        } catch {
            if effectivePasscode != nil,
               case ZoomRecordingService.ZoomRecordingError.wrongPasscode = error {
                _ = await Task.detached(priority: .utility) {
                    KeychainService.deleteZoomRecordingPasscode(forSourceID: articleId)
                }.value
            }
            guard let idx2 = articles.firstIndex(where: { $0.id == articleId }) else { return }
            let zoomError = error as? ZoomRecordingService.ZoomRecordingError
            if case .passcodeRequired? = zoomError {
                articles[idx2].state = .error
                articles[idx2].errorMessage =
                    "This Zoom recording requires a passcode. Right-click the source and choose “Enter Zoom Passcode…”."
            } else if zoomError?.isWorthRetrying ?? true {
                // Zoom has the recording and not yet its transcript, or could
                // not be reached: the session waits and the check asks again.
                // `.queued` rather than `.error`, so the row reads as pending
                // and the learner does not remove a session that is on its
                // way — which is what happened to the first three standups.
                // This covers Get Transcript too: with the media fallback
                // gone a manual press is just "ask Zoom now", so when Zoom
                // still has nothing the honest answer is the waiting line,
                // not an error the learner might act on by deleting the row.
                var detail: String?
                if case .transcriptNotReady(let assets)? = zoomError, !assets.isEmpty { detail = "Zoom offered \(assets)" }
                else if zoomError == nil || zoomError?.isWorthRetrying == false { detail = error.localizedDescription }
                else if case .transcriptNotReady? = zoomError {} else { detail = error.localizedDescription }
                articles[idx2].state = .queued
                articles[idx2].errorMessage = ZoomTranscriptWait.waitingMessage(checkedAt: Date(), detail: detail)
            } else {
                articles[idx2].state = .error
                articles[idx2].errorMessage = "Zoom transcript unavailable: \(error.localizedDescription)"
            }
            do {
                try await storage.saveSource(articles[idx2])
            } catch {
                logger.error("saveSource failed: \(error.localizedDescription, privacy: .public)")
            }
            logger.info("Zoom transcript not stored (\(request == .automatic ? "automatic" : "requested", privacy: .public)): \(error.localizedDescription)")
        }
    }

    /// The automatic check: every Zoom session still waiting for its
    /// transcript is asked about again, one at a time. Runs on a timer from
    /// launch (`startZoomTranscriptChecks`) and stops asking about a session
    /// once it has text, a terminal error, or has waited `giveUpAfter`.
    func checkWaitingZoomTranscripts(now: Date = Date()) async {
        // The state test is a few comparisons and the URL test parses the address, so the state
        // goes first: this runs on the main actor over the whole library, and parsing every
        // source's URL there once wedged the app for seconds (a stall sample, 2026-10-24).
        let waiting = articles.filter { article in
            article.status == .active
                && ZoomTranscriptWait.isWaiting(
                    state: article.state,
                    errorMessage: article.errorMessage,
                    hasContent: !(article.content ?? "").isEmpty,
                    addedAt: article.dateAdded,
                    now: now
                )
                && ZoomRecordingService.isZoomRecordingURL(article.url)
        }
        guard !waiting.isEmpty else { return }
        logger.info("Asking Zoom again for \(waiting.count) waiting transcript(s)")
        for article in waiting {
            await fetchZoomTranscript(for: article.id, request: .automatic)
        }
    }

    /// Starts the quarter-hourly check for the app's lifetime. Idempotent.
    func startZoomTranscriptChecks() {
        guard zoomTranscriptCheckTask == nil else { return }
        zoomTranscriptCheckTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.checkWaitingZoomTranscripts()
                try? await Task.sleep(for: .seconds(ZoomTranscriptWait.checkInterval))
            }
        }
    }

    func forgetZoomPasscode(for articleId: String) async {
        let deleted = await Task.detached(priority: .utility) {
            KeychainService.deleteZoomRecordingPasscode(forSourceID: articleId)
        }.value
        showToast(deleted ? "Forgot saved Zoom passcode" : "Could not remove the Zoom passcode from Keychain.")
    }

    static func containsYouTubeTimingMarkers(_ transcript: String) -> Bool {
        transcript.range(
            of: #"(?m)^\s*\[\d{1,2}:\d{2}(?::\d{2})?\]"#,
            options: .regularExpression
        ) != nil
    }

    /// Resolve a YouTube URL to its official chapter markers, or an empty array
    /// when the URL is not a video or the video has no chapters.
    static func fetchOfficialChapters(for urlString: String) async -> [YouTubeTranscriptService.VideoChapter] {
        guard let videoId = YouTubeTranscriptService.extractVideoId(from: urlString) else { return [] }
        return await YouTubeTranscriptService.shared.fetchChapters(videoId: videoId)
    }

    /// Migrate an already-stored YouTube transcript's section headings to the
    /// video's official chapters, if it has any. Runs once per source per app
    /// session when the reader opens, so videos imported before this existed
    /// pick up their real chapters without a manual reformat. A no-op — and no
    /// sync write — when the video has no official chapters (the AI headings
    /// stay) or the headings already match.
    func refreshOfficialYouTubeChaptersIfNeeded(for articleId: String) async {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
        let urlString = articles[idx].url
        guard YouTubeTranscriptService.isYouTubeURL(urlString),
              !youtubeChapterRefreshAttempted.contains(articleId) else { return }
        youtubeChapterRefreshAttempted.insert(articleId)

        guard let content = await currentTranscriptContent(for: articleId),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let officialChapters = await Self.fetchOfficialChapters(for: urlString)
        guard !officialChapters.isEmpty else { return }

        // Keep the opt-in slide section untouched; only the transcript's own
        // headings are rewritten.
        let parts = Self.splitYouTubeSlideSection(from: content)
        let updatedTranscript = YouTubeChapterMarkup.applyingOfficialChapters(officialChapters, to: parts.transcript)
        guard updatedTranscript != parts.transcript else { return }

        let newContent = [updatedTranscript, parts.slideSection]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        // Persist before mutating the in-memory copy: assigning `content`
        // restarts the reader's parse task, which can cancel this function
        // mid-flight, and the stored transcript must not be the casualty.
        do {
            try await storage.saveTranscript(articleId, newContent)
        } catch {
            logger.warning("Could not save official YouTube chapters for \(articleId): \(error.localizedDescription)")
            return
        }

        // Re-resolve by id after the awaits before mutating `articles`.
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
        articles[idx].content = newContent
        articles[idx].wordCount = newContent.split(separator: " ").count
        queueSourceEmbeddingRefreshIfReady(articleId)
    }

    /// Fetch a bounded number of YouTube transcripts in parallel. Running it serially
    /// would make large playlist/course sections painfully slow.
    func fetchYouTubeTranscriptsConcurrently(
        for articleIds: [String],
        allowsAutomaticFormatting: Bool = true
    ) async {
        guard !articleIds.isEmpty else { return }

        var nextIndex = 0
        let total = articleIds.count

        await withTaskGroup(of: Void.self) { group in
            let initialCount = min(Self.bulkYouTubeTranscriptFetchLimit, total)
            for _ in 0..<initialCount {
                let articleId = articleIds[nextIndex]
                nextIndex += 1
                group.addTask { @MainActor in
                    await self.fetchYouTubeTranscript(
                        for: articleId,
                        allowsAutomaticFormatting: allowsAutomaticFormatting
                    )
                }
            }

            while await group.next() != nil {
                guard nextIndex < total else { continue }
                let articleId = articleIds[nextIndex]
                nextIndex += 1
                group.addTask { @MainActor in
                    await self.fetchYouTubeTranscript(
                        for: articleId,
                        allowsAutomaticFormatting: allowsAutomaticFormatting
                    )
                }
            }
        }
    }

    /// Fetch podcast transcripts with a lower concurrency cap because the Apple
    /// transcript API is more sensitive to bursts than YouTube caption URLs.
    func fetchPodcastTranscriptsConcurrently(for articleIds: [String]) async {
        let candidates = podcastHydrationCandidates(for: articleIds).filter {
            !contentFetchInFlight.contains($0.id)
        }
        guard !candidates.isEmpty else { return }

        let candidateIDs = Set(candidates.map(\.id))
        for candidate in candidates {
            contentFetchInFlight.insert(candidate.id)
            if let idx = articles.firstIndex(where: { $0.id == candidate.id }) {
                // Every candidate is visible under Processing immediately. The
                // concurrency window promotes only active work to `.fetching`;
                // the remainder accurately stays queued.
                articles[idx].state = .queued
                articles[idx].errorMessage = nil
            }
        }
        defer { contentFetchInFlight.subtract(candidateIDs) }

        await hydratePodcastTranscripts(candidates)
    }

    func podcastHydrationCandidates(for articleIds: [String]) -> [PodcastTranscriptHydrationCandidate] {
        var seen = Set<String>()
        return articleIds.compactMap { articleId in
            guard seen.insert(articleId).inserted else { return nil }
            return podcastHydrationCandidate(for: articleId)
        }
    }

    /// - Parameter userInitiated: `true` when the user asked for this specific
    ///   episode's transcript (confirming a match), which permits formatting even
    ///   on a hidden show. Automatic hydration leaves hidden episodes unformatted.
    /// - Parameter honorYouTubePreference: `false` only for the explicit
    ///   Transcribe Audio action, where that one-off choice supersedes the
    ///   show's saved YouTube preference.
    func podcastHydrationCandidate(
        for articleId: String,
        userInitiated: Bool = false,
        honorYouTubePreference: Bool = true
    ) -> PodcastTranscriptHydrationCandidate? {
        guard let article = articles.first(where: { $0.id == articleId }),
              article.sourceType == .podcast,
              Self.podcastRowCanHydrate(url: article.url, showName: article.domain) else {
            return nil
        }
        return PodcastTranscriptHydrationCandidate(
            id: article.id,
            url: article.url,
            title: article.title,
            podcastName: article.domain,
            webPageURL: article.podcastWebPageURL ?? article.publicURL,
            prefersYouTube: honorYouTubePreference
                && prefersYouTubeTranscript(forPodcastShow: article.domain),
            allowsFormatting: allowsTranscriptFormatting(for: article, userInitiated: userInitiated),
            userInitiated: userInitiated
        )
    }

    func hydratePodcastTranscripts(_ candidates: [PodcastTranscriptHydrationCandidate]) async {
        guard !candidates.isEmpty else { return }

        let storage = self.storage
        let homeDir = realHomeDirectory
        let config = KeychainService.resolveConfig(for: .transcriptFormatting)
        var nextIndex = 0
        let total = candidates.count

        await withTaskGroup(of: PodcastTranscriptHydrationResult.self) { group in
            let initialCount = min(Self.bulkPodcastTranscriptFetchLimit, total)
            for _ in 0..<initialCount {
                let candidate = bulkHydrationCandidateAtDispatch(candidates[nextIndex])
                nextIndex += 1
                if let idx = articles.firstIndex(where: { $0.id == candidate.id }) {
                    articles[idx].state = .fetching
                }
                group.addTask {
                    await Self.hydratePodcastTranscript(
                        candidate,
                        storage: storage,
                        homeDir: homeDir,
                        config: config
                    )
                }
            }

            while let result = await group.next() {
                await applyPodcastHydrationResult(result)
                guard nextIndex < total else { continue }
                let candidate = bulkHydrationCandidateAtDispatch(candidates[nextIndex])
                nextIndex += 1
                if let idx = articles.firstIndex(where: { $0.id == candidate.id }) {
                    articles[idx].state = .fetching
                }
                group.addTask {
                    await Self.hydratePodcastTranscript(
                        candidate,
                        storage: storage,
                        homeDir: homeDir,
                        config: config
                    )
                }
            }
        }
    }

    /// The candidate as it stands when its turn in a bulk drain comes.
    ///
    /// A drain runs one episode at a time and a first import can hold hundreds,
    /// so the list is built long before most episodes start. A show hidden in
    /// that time — from Setup or the sidebar — must stop paying for formatting
    /// on the episodes still waiting, instead of the hide taking effect only
    /// after the backlog is gone.
    func bulkHydrationCandidateAtDispatch(
        _ candidate: PodcastTranscriptHydrationCandidate
    ) -> PodcastTranscriptHydrationCandidate {
        guard candidate.allowsFormatting,
              let article = articles.first(where: { $0.id == candidate.id }),
              isSourceHidden(article) else { return candidate }
        return PodcastTranscriptHydrationCandidate(
            id: candidate.id,
            url: candidate.url,
            title: candidate.title,
            podcastName: candidate.podcastName,
            webPageURL: candidate.webPageURL,
            prefersYouTube: candidate.prefersYouTube,
            allowsFormatting: false,
            userInitiated: candidate.userInitiated
        )
    }

    func applyPodcastHydrationResult(_ result: PodcastTranscriptHydrationResult) async {
        guard let idx = articles.firstIndex(where: { $0.id == result.id }) else { return }

        if let mergedInto = result.mergedIntoSourceID {
            // The row was archived into the episode that already carries its
            // public identity; the survivor keeps the sidebar seat.
            let mergedID = result.id
            articles.remove(at: idx)
            if selectedArticleId == mergedID { selectedArticleId = mergedInto }
            selectedArticleIds.remove(mergedID)
            invalidateFilteredSidebarCache()
            return
        }

        if let identity = result.resolvedIdentity {
            // Storage already holds the public address; the in-memory row must
            // agree before any later save, or it writes the old one back.
            articles[idx].url = identity.url
            articles[idx].normalizedURL = URLNormalizer.normalize(identity.url)
            articles[idx].podcastWebPageURL = identity.webPageURL
        }

        switch result.outcome {
        case .ready(let content, let persistedReadyState):
            articles[idx].content = content
            articles[idx].wordCount = KnowledgeStore.storedWordCount(of: content)
            articles[idx].state = .ready
            articles[idx].errorMessage = nil
            if !persistedReadyState {
                do {
                    try await storage.saveSource(articles[idx])
                } catch {
                    logger.error("saveSource failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            queueSourceEmbeddingRefreshIfReady(result.id)

        case .failed(let message):
            // A transcript saved while this pass ran (a confirmed YouTube
            // match) outranks the pass's stale failure.
            if articles[idx].state == .ready,
               !(articles[idx].content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }
            articles[idx].state = .error
            articles[idx].errorMessage = message
            do {
                try await storage.saveSource(articles[idx])
            } catch {
                logger.error("saveSource failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Run the configured transcript-formatting model over raw YouTube captions,
    /// producing readable Markdown with punctuation, paragraphs, and headings.
    func formatReadableYouTubeTranscriptWithLLM(
        _ raw: String,
        sourceID: String? = nil,
        videoTitle: String? = nil,
        channelName: String? = nil,
        removingPodcastAdReads: Bool = false
    ) async -> String? {
        guard let config = KeychainService.resolveConfig(for: .transcriptFormatting) else { return nil }
        guard raw.count > Self.minimumFormattableTranscriptLength else { return nil }

        let chunks = chunkTranscriptForReadableFormatting(raw)
        let baseSystem = AITask.transcriptFormatting.effectivePrompt
            ?? Prompts.readableYouTubeTranscriptFormatting
        let system = removingPodcastAdReads
            ? baseSystem + Prompts.podcastAdReadRemovalForReadableTranscript
            : baseSystem
        let metadata = [
            videoTitle.map { "Video title: \($0)" },
            channelName.map { "Channel/domain: \($0)" }
        ].compactMap { $0 }.joined(separator: "\n")
        // Long transcripts bill one charge per chunk, so without this the
        // ledger shows a run of identical "Transcript Formatting" rows with
        // nothing saying which video they came from.
        let ledgerTitle = Self.transcriptLedgerTitle(videoTitle, channelName)
        let activityID = UUID().uuidString

        do {
            // Sliding window rather than one task per chunk: this runs inside a
            // per-video concurrency limit, so an unbounded inner fan-out
            // multiplies against it instead of respecting it.
            let chunkResults = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                var nextIndex = 0
                while nextIndex < min(Self.transcriptChunkFormatConcurrency, chunks.count) {
                    let index = nextIndex
                    group.addTask { @MainActor in
                        try await self.formatReadableTranscriptChunk(
                            chunks[index], index: index, of: chunks.count,
                            metadata: metadata, system: system, config: config,
                            ledgerTitle: ledgerTitle,
                            subjectID: sourceID,
                            activityID: activityID
                        )
                    }
                    nextIndex += 1
                }

                var results: [(Int, String)] = []
                while let result = try await group.next() {
                    results.append(result)
                    guard nextIndex < chunks.count else { continue }
                    let index = nextIndex
                    group.addTask { @MainActor in
                        try await self.formatReadableTranscriptChunk(
                            chunks[index], index: index, of: chunks.count,
                            metadata: metadata, system: system, config: config,
                            ledgerTitle: ledgerTitle,
                            subjectID: sourceID,
                            activityID: activityID
                        )
                    }
                    nextIndex += 1
                }
                return results.sorted { $0.0 < $1.0 }
            }

            let formatted = chunkResults
                .map(\.1)
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard formattedTranscriptLooksUsable(formatted, comparedTo: raw) else {
                logger.warning("Formatted YouTube transcript failed validation")
                return nil
            }
            // Held to the captions: what the model left out goes back, what
            // it repeated or invented comes out, and the captions' markers,
            // not the model's, go on the words they time
            // (`ReadableTranscriptMarkers.checked`). Ad reads the podcast
            // prompt asked it to drop stay out. Aligning a long lecture is
            // work for a background thread.
            let restoring = !removingPodcastAdReads
            let checked = await Task.detached(priority: .utility) {
                ReadableTranscriptMarkers.checked(formatted, against: raw, restoringDroppedCaptions: restoring)
            }.value
            guard let checked else {
                logger.warning("Formatted YouTube transcript does not hold to its captions; the captions stay")
                return nil
            }
            if checked.restoredWords > 0 || checked.removedWords > 0 {
                logger.notice(
                    "Formatted YouTube transcript held to its captions: \(checked.restoredWords) of \(checked.captionWords) caption words put back [\(checked.restored.joined(separator: ", "))], \(checked.removedWords) of \(checked.formattedWords) model words taken out [\(checked.removed.joined(separator: " | "))]"
                )
            }
            logger.info("Readable YouTube transcript: \(raw.count) → \(checked.text.count) chars")
            return checked.text
        } catch {
            logger.warning("Readable YouTube transcript formatting failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Format one chunk of a YouTube transcript. Split out of the task group so
    /// the sliding window can enqueue it from two places without duplicating the
    /// request, and without a nested closure capturing the group.
    private func formatReadableTranscriptChunk(
        _ chunk: String,
        index: Int,
        of total: Int,
        metadata: String,
        system: String,
        config: AITaskConfig,
        ledgerTitle: String?,
        subjectID: String?,
        activityID: String
    ) async throws -> (Int, String) {
        let userMessage = """
        \(metadata)

        Transcript chunk \(index + 1) of \(total):
        \(chunk)
        """
        let formatted = try await aiService.formatTranscriptChunk(
            userMessage,
            system: system,
            config: config,
            maxTokens: 6_000,
            sourceTitle: ledgerTitle,
            subjectID: subjectID,
            subjectType: subjectID == nil ? nil : "video",
            activityID: activityID
        )
        return (index, cleanFormattedTranscriptOutput(formatted))
    }

    /// Which source a transcript charge belongs to, for the managed billing
    /// ledger. Falls back to the channel or podcast name so a source whose
    /// title has not been resolved yet still identifies itself.
    nonisolated static func transcriptLedgerTitle(_ title: String?, _ publisher: String?) -> String? {
        for candidate in [title, publisher] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// A model's JSON reply with the Markdown code fence around it, if any, taken off.
    nonisolated static func unfencedModelJSON(_ response: String) -> String {
        var json = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            json = json.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if json.hasSuffix("```") {
                json = String(json.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return json
    }

    /// A transcript cut into pieces of at most 50,000 characters for formatting,
    /// each ending at the last sentence break before the limit. Input context is
    /// cheap; only output needs to be small.
    nonisolated static func transcriptFormattingChunks(_ text: String) -> [String] {
        let chunkSize = 50_000
        guard text.count > chunkSize else { return [text] }
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            var breakAt = end
            if end < text.endIndex,
               let dotRange = text[start..<end].range(of: ". ", options: .backwards) {
                breakAt = text.index(after: dotRange.lowerBound)
            }
            result.append(String(text[start..<breakAt]))
            start = breakAt
        }
        return result
    }

    /// Cut a caption stream into pieces of at most `maxCharacters`, each ending
    /// at the last sentence break before the limit — else the last comma, else
    /// the last space — so a lecture formats in a handful of calls.
    ///
    /// Until 2026-09-21 the sentence and comma searches asked Foundation for
    /// the *last* match with `.backwards` on a regular-expression search, an
    /// option that search ignores: it returned the first break in the window
    /// instead, so every chunk was one caption sentence. A 50k-character
    /// lecture became some 370 model calls of ~250 tokens each, and a course
    /// import spent 25 minutes a lecture in formatting (product owner, "why does it
    /// take so long?"). The searches now find the last break themselves.
    func chunkTranscriptForReadableFormatting(_ text: String) -> [String] {
        let maxCharacters = 12_000
        guard text.count > maxCharacters else { return [text] }

        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maxCharacters, limitedBy: text.endIndex) ?? text.endIndex
            var breakAt = end
            if end < text.endIndex {
                let window = text[start..<end]
                if let sentenceEnd = Self.lastMatchEnd(of: #"(?<=[.!?])\s+"#, in: window) {
                    breakAt = sentenceEnd
                } else if let commaEnd = Self.lastMatchEnd(of: #",\s+"#, in: window) {
                    breakAt = commaEnd
                } else if let spaceRange = window.range(of: " ", options: .backwards) {
                    breakAt = spaceRange.upperBound
                }
            }
            // A break that made no progress would loop forever on the same
            // window; the hard cut is the way out.
            if breakAt <= start { breakAt = end }
            chunks.append(String(text[start..<breakAt]).trimmingCharacters(in: .whitespacesAndNewlines))
            start = breakAt
        }
        return chunks.filter { !$0.isEmpty }
    }

    /// Where the last match of `pattern` in `window` ends, or nil when it never
    /// matches. `NSString.range(of:options:)` ignores `.backwards` for a
    /// regular-expression search, so the last match has to be walked to.
    nonisolated static func lastMatchEnd(of pattern: String, in window: Substring) -> String.Index? {
        let text = String(window)
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let last = matches.last, let range = Range(last.range, in: text) else { return nil }
        let offset = text.distance(from: text.startIndex, to: range.upperBound)
        return window.index(window.startIndex, offsetBy: offset)
    }

    func cleanFormattedTranscriptOutput(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func formattedTranscriptLooksUsable(_ formatted: String, comparedTo raw: String) -> Bool {
        let rawWords = raw.split { $0.isWhitespace }.count
        let formattedWords = formatted
            .replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
            .split { $0.isWhitespace }
            .count

        guard formattedWords >= 80 else { return false }
        guard rawWords >= 200 else { return true }
        let ratio = Double(formattedWords) / Double(rawWords)
        return ratio >= 0.65 && ratio <= 1.45
    }

    /// Run a lightweight LLM pass to make a raw transcript readable.
    /// Instead of regenerating the entire text, the LLM outputs a compact JSON list of
    /// break-point annotations which are applied to the original text programmatically.
    /// This reduces output tokens from ~12k to a few hundred, making it much faster.
    func formatTranscriptWithLLM(
        _ raw: String,
        episodeTitle: String? = nil,
        podcastName: String? = nil
    ) async -> String? {
        // The model comes from the user's Transcript Formatting setting, like
        // every other transcript pass. Failing closed here is deliberate: a
        // literal fallback would bill a model the user never chose.
        guard let config = KeychainService.resolveConfig(for: .transcriptFormatting) else { return nil }
        guard raw.count > Self.minimumFormattableTranscriptLength else { return nil }

        let speakerNamedRaw = await replaceInferredSpeakerLabels(
            in: raw,
            config: config,
            episodeTitle: episodeTitle,
            podcastName: podcastName
        )

        // Chunk large transcripts. Input context is cheap; only output needs to be small.
        let chunks = Self.transcriptFormattingChunks(speakerNamedRaw)

        // Process chunks in parallel.
        let indexed = Array(chunks.enumerated())
        let ledgerTitle = Self.transcriptLedgerTitle(episodeTitle, podcastName)
        let chunkResults: [(Int, String, String)]  // (index, originalChunk, llmResponse)
        do {
            chunkResults = try await withThrowingTaskGroup(of: (Int, String, String).self) { group in
                for (i, chunk) in indexed {
                    group.addTask {
                        let aiService = self.aiService
                        let result = try await AIBackgroundRetry.run(config: config) { config in
                            try await aiService.call(
                                config: config,
                                system: Prompts.transcriptFormattingBreakPoints,
                                user: chunk,
                                maxTokens: 4_000,
                                temperature: 0.2,
                                sourceTitle: ledgerTitle
                            )
                        }
                        return (i, chunk, result)
                    }
                }
                var results = [(Int, String, String)]()
                for try await triple in group {
                    results.append(triple)
                }
                return results.sorted { $0.0 < $1.0 }
            }
        } catch {
            logger.warning("Transcript formatting failed: \(error.localizedDescription)")
            return nil
        }

        // Apply break points to each chunk. Whether the speakers are named on
        // label lines is read from the whole transcript: a chunk inside one
        // long turn holds none of its own.
        let diarized = Self.isDiarizedPodcastTranscriptOffMain(speakerNamedRaw)
        var formattedChunks: [String] = []
        for (_, chunk, response) in chunkResults {
            formattedChunks.append(applyTranscriptBreakPoints(to: chunk, from: response, transcriptIsDiarized: diarized))
        }

        let result = formattedChunks.joined(separator: "\n\n")
        logger.info("Formatted transcript: \(speakerNamedRaw.count) → \(result.count) chars")
        return result
    }

    /// Infer actual names for diarized podcast labels when the transcript provides enough evidence.
    /// The returned text keeps unknown speakers as SPEAKER_N instead of guessing.
    func replaceInferredSpeakerLabels(
        in raw: String,
        config: AITaskConfig,
        episodeTitle: String?,
        podcastName: String?
    ) async -> String {
        let mapping = await inferSpeakerNameMappingFromTranscript(
            raw,
            config: config,
            episodeTitle: episodeTitle,
            podcastName: podcastName
        )
        guard !mapping.isEmpty else { return raw }
        return applySpeakerNameMapping(mapping, to: raw)
    }

    func inferSpeakerNameMappingFromTranscript(
        _ raw: String,
        config: AITaskConfig,
        episodeTitle: String?,
        podcastName: String?
    ) async -> [String: String] {
        let speakerIDs = genericSpeakerIDs(in: raw)
        guard !speakerIDs.isEmpty else { return [:] }
        let system = """
        You identify actual speaker names in podcast transcripts.

        Return ONLY a JSON object whose keys are existing speaker IDs like "SPEAKER_1" and values are \
        the actual person's name.

        Rules:
        - Include a mapping only when the transcript or metadata makes the name clear.
        - Use real names only, such as "Dwarkesh Patel", "Nick Lane", or "Dwarkesh".
        - Do not use role labels like Host, Guest, Interviewer, Interviewee, Narrator, or Speaker 1.
        - Align the name to the speaker ID that actually says the turn. A person mentioned by a speaker \
        is not necessarily that speaker.
        - Intro clues like "I'm your host, X" identify the current speaker. Guest introductions like \
        "today's guest is Y" usually identify the next different speaker who responds to the welcome.
        - For multiple hosts, co-hosts, or guests, map each diarized speaker ID separately only when a \
        turn belongs to that person.
        - Do not invent names. Omit uncertain speakers.
        - Output valid JSON only, no commentary, no markdown fences.
        """
        let userMessage = speakerInferenceUserMessage(
            speakerIDs: speakerIDs,
            episodeTitle: episodeTitle,
            podcastName: podcastName,
            sourceURL: nil,
            podcastWebPageURL: nil,
            transcript: raw,
            excerptLimit: 80_000
        )

        do {
            let response = try await aiService.call(
                config: config,
                system: system,
                user: userMessage,
                maxTokens: 800,
                temperature: 0,
                sourceTitle: Self.transcriptLedgerTitle(episodeTitle, podcastName)
            )
            return parseSpeakerNameMapping(response, validSpeakerIDs: speakerIDs)
        } catch {
            logger.warning("Speaker-name inference failed: \(error.localizedDescription)")
            return [:]
        }
    }

    func inferSpeakerNameMappingWithWebSearch(
        _ raw: String,
        config: AITaskConfig,
        episodeTitle: String?,
        podcastName: String?,
        sourceURL: String?,
        podcastWebPageURL: String?
    ) async throws -> [String: String] {
        let speakerIDs = genericSpeakerIDs(in: raw)
        guard !speakerIDs.isEmpty else { return [:] }
        guard let system = AITask.podcastSpeakerIdentification.effectivePrompt else {
            throw AIError.apiError("Podcast speaker identification has no prompt configured.")
        }
        let userMessage = """
        \(speakerInferenceUserMessage(
            speakerIDs: speakerIDs,
            episodeTitle: episodeTitle,
            podcastName: podcastName,
            sourceURL: sourceURL,
            podcastWebPageURL: podcastWebPageURL,
            transcript: raw,
            excerptLimit: 120_000
        ))

        Research task:
        Search for the podcast episode/show and identify who is hosting/interviewing and who is being \
        interviewed. Then align those people to the speaker IDs using the transcript excerpt.
        """

        let response = try await aiService.call(
            config: config,
            system: system,
            user: userMessage,
            maxTokens: 1_200,
            temperature: 0,
            allowsResponseCache: false,
            jsonMode: true,
            webSearch: true,
            sourceTitle: episodeTitle
        )
        return parseSpeakerNameMapping(response, validSpeakerIDs: speakerIDs)
    }

    func speakerInferenceUserMessage(
        speakerIDs: Set<String>,
        episodeTitle: String?,
        podcastName: String?,
        sourceURL: String?,
        podcastWebPageURL: String?,
        transcript: String,
        excerptLimit: Int
    ) -> String {
        let metadata = [
            episodeTitle.map { "Episode title: \($0)" },
            podcastName.map { "Podcast/show: \($0)" },
            sourceURL.map { "Source URL: \($0)" },
            podcastWebPageURL.map { "Podcast episode web page: \($0)" }
        ].compactMap { $0 }.joined(separator: "\n")

        let transcriptExcerpt = transcript.count > excerptLimit
            ? String(transcript.prefix(excerptLimit))
            : transcript
        let speakerEvidence = PodcastSpeakerNameInference.evidenceSummary(
            from: transcript,
            speakerIDs: speakerIDs
        )

        return """
        Speaker IDs: \(speakerIDs.sorted().joined(separator: ", "))

        \(metadata)

        Speaker evidence:
        \(speakerEvidence)

        Transcript:
        \(transcriptExcerpt)
        """
    }

    func genericSpeakerIDs(in text: String) -> Set<String> {
        PodcastSpeakerNameInference.speakerIDs(in: text)
    }

    func parseSpeakerNameMapping(_ response: String, validSpeakerIDs: Set<String>) -> [String: String] {
        let json = Self.unfencedModelJSON(response)

        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            logger.warning("Could not parse speaker-name mapping")
            return [:]
        }

        var result: [String: String] = [:]
        for (speakerID, name) in decoded {
            let trimmedID = speakerID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validSpeakerIDs.contains(trimmedID),
                  isValidInferredSpeakerName(trimmedName) else { continue }
            result[trimmedID] = trimmedName
        }

        let duplicateNames = Dictionary(grouping: result) { $0.value.lowercased() }
            .filter { $0.value.count > 1 }
            .keys
        for duplicateName in duplicateNames {
            result = result.filter { $0.value.lowercased() != duplicateName }
        }

        return result
    }

    func isValidInferredSpeakerName(_ name: String) -> Bool {
        PodcastSpeakerNameInference.isValidPersonName(name)
    }

    func applySpeakerNameMapping(_ mapping: [String: String], to text: String) -> String {
        mapping.reduce(text) { partial, entry in
            partial
                .replacingOccurrences(of: "[\(entry.key)]", with: "[\(entry.value)]")
                .replacingOccurrences(of: "**\(entry.key.replacingOccurrences(of: "_", with: " ").capitalized):**", with: "**\(entry.value):**")
        }
    }

    /// Parse the LLM's JSON break-point annotations and apply them to the original text.
    func applyTranscriptBreakPoints(
        to text: String,
        from response: String,
        transcriptIsDiarized: Bool? = nil
    ) -> String {
        Self.applyPodcastTranscriptBreakPointsOffMain(
            to: text,
            from: response,
            transcriptIsDiarized: transcriptIsDiarized
        )
    }

    static func splitYouTubeSlideSection(from content: String) -> (transcript: String, slideSection: String?) {
        let header = "## Extracted video slide frames"
        guard let range = content.range(of: header) else {
            return (content, nil)
        }
        let transcript = String(content[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let slideSection = String(content[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (transcript.isEmpty ? content : transcript, slideSection.isEmpty ? nil : slideSection)
    }

    /// Rename diarized podcast speakers after import without changing transcript wording.
    @discardableResult
    func updatePodcastSpeakersWithAI(for articleId: String) async throws -> Bool {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }),
              articles[idx].sourceType == .podcast,
              ManagedAI.isSignedIn,
              let transcript = await currentTranscriptContent(for: articleId),
              !transcript.isEmpty else { return false }
        guard let config = KeychainService.resolveConfig(for: .podcastSpeakerIdentification) else {
            throw AIError.apiError(
                KeychainService.backgroundAIUnavailableMessage(for: .podcastSpeakerIdentification)
                    ?? "Sign in with Apple before identifying podcast speakers."
            )
        }

        let article = articles[idx]
        articles[idx].state = .fetching
        let rawTTMLTranscript: String?
        if let rawTTML = await loggedLookup("podcast transcript markup", { try await storage.loadPodcastRawTTML(articleId) }) {
            rawTTMLTranscript = await Self.extractPodcastTTMLTextOffMain(rawTTML)
        } else {
            rawTTMLTranscript = nil
        }

        let inferenceTranscript = rawTTMLTranscript ?? transcript
        let mapping: [String: String]
        do {
            mapping = try await inferSpeakerNameMappingWithWebSearch(
                inferenceTranscript,
                config: config,
                episodeTitle: article.title,
                podcastName: article.domain,
                sourceURL: article.url,
                podcastWebPageURL: article.podcastWebPageURL
            )
        } catch {
            if let idx = articles.firstIndex(where: { $0.id == articleId }) {
                articles[idx].state = .error
                articles[idx].errorMessage = "Could not identify podcast speakers: \(error.localizedDescription)"
            }
            throw error
        }
        guard !mapping.isEmpty else {
            if let idx = articles.firstIndex(where: { $0.id == articleId }) {
                articles[idx].state = .ready
            }
            return false
        }

        var renamed = applySpeakerNameMapping(mapping, to: transcript)

        // If the current transcript was already renamed incorrectly (for example both
        // speakers became "Nick Lane"), the stored TTML still preserves SPEAKER_N IDs.
        // Rebuild from that raw transcript so the researched mapping can repair it.
        if renamed == transcript,
           let rawTTMLTranscript {
            let repairedRaw = applySpeakerNameMapping(mapping, to: rawTTMLTranscript)
            if repairedRaw != rawTTMLTranscript {
                renamed = await formatTranscriptWithLLM(
                    repairedRaw,
                    episodeTitle: article.title,
                    podcastName: article.domain
                ) ?? repairedRaw
            }
        }

        guard renamed != transcript else {
            if let idx = articles.firstIndex(where: { $0.id == articleId }) {
                articles[idx].state = .ready
            }
            return false
        }

        return await persistPodcastTranscriptUpdate(articleId: articleId, transcript: renamed)
    }

    /// Apply user-entered speaker labels to the persisted podcast transcript.
    @discardableResult
    func updatePodcastSpeakersManually(for articleId: String, labels: [String: String]) async -> Bool {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }),
              articles[idx].sourceType == .podcast,
              let transcript = await currentTranscriptContent(for: articleId),
              !transcript.isEmpty else { return false }

        var updated = transcript
        for (oldLabel, newLabel) in labels {
            guard let cleanLabel = sanitizedManualSpeakerLabel(newLabel),
                  oldLabel.trimmingCharacters(in: .whitespacesAndNewlines) != cleanLabel else { continue }
            updated = replaceSpeakerLabel(oldLabel, with: cleanLabel, in: updated)
        }

        guard updated != transcript else { return false }
        return await persistPodcastTranscriptUpdate(articleId: articleId, transcript: updated)
    }

    func currentTranscriptContent(for articleId: String) async -> String? {
        if let idx = articles.firstIndex(where: { $0.id == articleId }),
           let content = articles[idx].content?.trimmingCharacters(in: .whitespacesAndNewlines),
           !content.isEmpty {
            return articles[idx].content
        }
        return await storage.loadSourceContent(articleId)
    }

    func persistPodcastTranscriptUpdate(articleId: String, transcript: String) async -> Bool {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return false }
        articles[idx].content = transcript
        articles[idx].wordCount = KnowledgeStore.storedWordCount(of: transcript)
        articles[idx].state = .ready
        articles[idx].errorMessage = nil
        do {
            try await storage.saveTranscript(articleId, transcript)
            queueSourceEmbeddingRefreshIfReady(articleId)
            return true
        } catch {
            articles[idx].state = .error
            articles[idx].errorMessage = "Could not update podcast speakers: \(error.localizedDescription)"
            return false
        }
    }

    func sanitizedManualSpeakerLabel(_ label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 80,
              trimmed.rangeOfCharacter(from: .newlines) == nil else {
            return nil
        }
        return trimmed
    }

    func replaceSpeakerLabel(_ oldLabel: String, with newLabel: String, in text: String) -> String {
        var result = text
        for variant in speakerLabelVariants(for: oldLabel) {
            result = result.replacingOccurrences(of: "[\(variant)]", with: "[\(newLabel)]")
            result = result.replacingOccurrences(of: "**\(variant):**", with: "**\(newLabel):**")
        }
        return result
    }

    func speakerLabelVariants(for label: String) -> Set<String> {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var variants: Set<String> = [trimmed]
        let normalized = trimmed.replacingOccurrences(of: "_", with: " ")
        if normalized.uppercased().hasPrefix("SPEAKER ") {
            variants.insert(normalized.capitalized)
            if let number = normalized.split(separator: " ").last {
                variants.insert("SPEAKER_\(number)")
            }
        }
        return variants
    }

    /// Fetch transcripts for all videos that don't have content yet.
    func fetchMissingTranscripts() async {
        let missing = articles.filter {
            $0.sourceType == .video
            && ($0.content ?? "").isEmpty
            && $0.state != .fetching
            && YouTubeTranscriptService.isYouTubeURL($0.url)
        }
        guard !missing.isEmpty else { return }
        logger.info("Fetching missing transcripts for \(missing.count) video(s)")
        await fetchYouTubeTranscriptsConcurrently(for: missing.map(\.id))
    }

    /// Fetch transcripts for Zoom cloud recordings that don't have content yet.
    /// The learner asked (the Meetings tab menu), so a recording Zoom has not
    /// transcribed is downloaded and transcribed here. Recordings are handled
    /// sequentially because that fallback may mean the full recording.
    func fetchMissingZoomTranscripts() async {
        let missingIDs: [String] = articles.compactMap { article -> String? in
            guard (article.content ?? "").isEmpty,
                  article.state != .fetching,
                  ZoomRecordingService.isZoomRecordingURL(article.url) else { return nil }
            return article.id
        }
        guard !missingIDs.isEmpty else { return }
        logger.info("Fetching missing transcripts for \(missingIDs.count) Zoom recording(s)")
        for articleID in missingIDs {
            await fetchZoomTranscript(for: articleID, request: .userInitiated)
        }
    }

    /// Ensure the requested sources attached to the active chat have their text
    /// content loaded before the conversation is handed to the AI. With no
    /// explicit IDs, this covers the whole attached pool.
    ///
    /// Source content is fetched lazily — only when a source is opened in the
    /// reader. A source dropped straight onto a chat (common for YouTube videos)
    /// is therefore never fetched, so it reaches the model with no readable text
    /// and the model reports that it "isn't loaded." This fetches the missing
    /// attached sources concurrently and idempotently before sending; sources
    /// that already have content, or are mid-fetch, are skipped. Reuses
    /// `fetchContent` so each source type (YouTube, web, podcast, local) follows
    /// its normal ingestion path and persists for CloudKit sync.
    ///
    /// Two tiers, because a send must not wait on anything it does not have to:
    ///
    /// 1. Text already stored in the database is read for every missing source
    ///    in one query and published in one `articles` assignment. This is the
    ///    common case — the transcript of a video imported hours ago — and it
    ///    costs a database read, nothing more. It does not go through
    ///    `fetchContent`, whose per-source path re-fetches, re-checks and
    ///    re-saves on the way to the same row, which would hold a send at
    ///    "Getting your sources ready" for 80 seconds with the text on disk.
    /// 2. Only a source with nothing stored — a video dropped on the chat before
    ///    its transcript ever downloaded — goes through its ingestion path, and
    ///    `progress` names it, so the wait says what it is waiting on.
    func ensureContextSourceContentLoaded(
        sourceIDs: Set<String>? = nil,
        progress: ((String) -> Void)? = nil
    ) async {
        let missing = contextSourceArticles.filter { article in
            let isRequested = sourceIDs?.contains(article.id) ?? true
            return isRequested
                && (article.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !contentFetchInFlight.contains(article.id)
        }
        guard !missing.isEmpty else { return }
        let clock = ContinuousClock()
        let startedAt = clock.now

        // Papers still in ingestion hold raw extraction, not canonical content;
        // `fetchContent` knows that boundary, so they skip the stored tier.
        let storedCandidateIDs = missing
            .filter { !($0.sourceType == .paper && $0.state != .ready) }
            .map(\.id)
        let stored = await storage.loadStoredSourceContents(for: storedCandidateIDs)
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !stored.isEmpty {
            // One assignment: writing `articles[index]` per source would run the
            // array's observer, and the store rebuild behind it, once per source.
            var updated = articles
            for index in updated.indices {
                guard let content = stored[updated[index].id] else { continue }
                updated[index].content = content
                if (updated[index].wordCount ?? 0) == 0 {
                    updated[index].wordCount = content.split(separator: " ").count
                }
            }
            articles = updated
        }
        let storedElapsed = clock.now - startedAt
        if storedElapsed >= .seconds(2) {
            logger.notice(
                "Attached chat sources: stored text for \(stored.count) of \(missing.count) took \(ChatSendPreparationTrace.format(storedElapsed), privacy: .public)"
            )
        }

        let toFetch = missing.filter { stored[$0.id] == nil }
        guard !toFetch.isEmpty else { return }
        logger.notice(
            "Loading content for \(toFetch.count) attached chat source(s) before sending: \(toFetch.map(\.title).joined(separator: " · "), privacy: .public)"
        )
        let titlesByID = Dictionary(uniqueKeysWithValues: toFetch.map { ($0.id, $0.title) })
        let ids = toFetch.map(\.id)

        var nextIndex = 0
        let total = ids.count
        await withTaskGroup(of: Void.self) { group in
            let initialCount = min(Self.bulkYouTubeTranscriptFetchLimit, total)
            for _ in 0..<initialCount {
                let articleId = ids[nextIndex]
                nextIndex += 1
                progress?(Self.sourceDownloadDetail(title: titlesByID[articleId]))
                group.addTask { @MainActor in
                    await self.fetchContent(for: articleId)
                }
            }

            while await group.next() != nil {
                guard nextIndex < total else { continue }
                let articleId = ids[nextIndex]
                nextIndex += 1
                progress?(Self.sourceDownloadDetail(title: titlesByID[articleId]))
                group.addTask { @MainActor in
                    await self.fetchContent(for: articleId)
                }
            }
        }
        let total_ = clock.now - startedAt
        if total_ >= .seconds(2) {
            logger.notice(
                "Attached chat sources: downloading \(toFetch.count) source(s) took \(ChatSendPreparationTrace.format(total_), privacy: .public)"
            )
        }
    }

    /// The working indicator's line while a send downloads one attached source.
    nonisolated static func sourceDownloadDetail(title: String?) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "Downloading a source" }
        return "Downloading \(trimmed)"
    }

    /// Podcast rows eligible for automatic transcript work. Hidden sources are
    /// also excluded from ambient search and AI discovery, so silently spending
    /// the only serial transcription slot on them both wastes work and makes the
    /// visible queue appear stuck behind nothing. Unhiding is an explicit event
    /// that starts this pipeline again.
    func pendingAutomaticPodcastTranscriptArticles() -> [StudioArticle] {
        articles.filter { article in
            article.sourceType == .podcast
                && (article.state == .queued || article.state == .fetching)
                && !Self.isTerminalPodcastTranscriptError(article.errorMessage)
                && Self.podcastRowCanHydrate(url: article.url, showName: article.domain)
                && !isSourceHidden(article)
        }
    }

    nonisolated static func prioritizedPodcastTranscriptIDs(
        _ pending: [StudioArticle],
        storedContentLengths: [String: Int]
    ) -> [String] {
        pending.enumerated().sorted { lhs, rhs in
            let lhsHasContent = (storedContentLengths[lhs.element.id] ?? 0) > 0
            let rhsHasContent = (storedContentLengths[rhs.element.id] ?? 0) > 0
            if lhsHasContent != rhsHasContent { return lhsHasContent }
            return lhs.offset < rhs.offset
        }.map { $0.element.id }
    }

    /// Resume interrupted Apple transcript lookups. Audio transcription is
    /// deliberately excluded: only the episode's explicit Transcribe Audio
    /// action is allowed to start paid speech-to-text.
    func processPendingPodcastTranscripts() async {
        if podcastTranscriptDrainInProgress {
            podcastTranscriptDrainRequested = true
            return
        }

        podcastTranscriptDrainInProgress = true
        defer {
            podcastTranscriptDrainInProgress = false
            podcastTranscriptDrainRequested = false
        }

        repeat {
            podcastTranscriptDrainRequested = false
            let pending = pendingAutomaticPodcastTranscriptArticles()
            guard !pending.isEmpty else { continue }

            // A sync or stale metadata save may leave a podcast queued even though
            // its complete transcript is already durable. Heal those rows before
            // another network lookup. This is one bounded SQLite length query,
            // never a per-source content load.
            let storedContentLengths = await storage.sourceContentLengths(for: pending.map(\.id))
            let pendingIDs = Self.prioritizedPodcastTranscriptIDs(
                pending,
                storedContentLengths: storedContentLengths
            )
            logger.info("Processing \(pendingIDs.count) pending podcast transcript(s)")
            await fetchPodcastTranscriptsConcurrently(for: pendingIDs)
        } while podcastTranscriptDrainRequested
    }

    /// Fetch transcripts for all podcasts that still have an apple-podcast:// URL or a stale file path.
    func fetchMissingPodcastTranscripts() async {
        let missing = articles.filter {
            $0.sourceType == .podcast
            && ($0.content ?? "").isEmpty
            && !contentFetchInFlight.contains($0.id)
            && !isSourceHidden($0)
            && (
                Self.podcastRowCanHydrate(url: $0.url, showName: $0.domain)
                || $0.state == .error
                || (!$0.url.hasPrefix("http") && !FileManager.default.fileExists(atPath: $0.url))
            )
        }
        guard !missing.isEmpty else { return }
        logger.info("Fetching missing podcast transcripts for \(missing.count) episode(s)")
        await fetchPodcastTranscriptsConcurrently(for: missing.map(\.id))
    }
}

/// The podcast shows hidden in the installed app's library, read once per
/// launch of a Dev or First Run build. The installed app reads nothing: its own
/// hidden shows already live in its library.
enum InstalledLibraryHiddenPodcastShows {
    /// Empty under a test host, which runs inside the Dev app: a test passes
    /// the shows it needs instead of inheriting this Mac's real library.
    static let names: Set<String> = isRunningTests ? [] : load(
        isDevelopment: ForeverLMRuntimeIdentity.isDevelopment,
        databaseURL: installedDatabaseURL
    )

    private static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static var installedDatabaseURL: URL {
        ForeverLMRuntimeIdentity.applicationSupportDirectoryURL
            .appendingPathComponent(
                ForeverLMRuntimeIdentity.profile(isDevelopment: false).productFolderName,
                isDirectory: true
            )
            .appendingPathComponent(".appdata", isDirectory: true)
            .appendingPathComponent("knowledge.db")
    }

    /// Read-only, and empty on any failure: a Mac with no installed library, or
    /// one whose library predates the table, has nothing hidden to honour.
    static func load(isDevelopment: Bool, databaseURL: URL) -> Set<String> {
        guard isDevelopment,
              FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT show_name FROM hidden_podcast_shows", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0) {
                names.insert(String(cString: text))
            }
        }
        return names
    }
}
