import Foundation

enum YouTubeLikedImportPolicy: String, CaseIterable {
    case undecided
    case importExisting
    case futureOnly

    var displayName: String {
        switch self {
        case .undecided: return "Choose what to import"
        case .importExisting: return "Existing and future likes"
        case .futureOnly: return "Future likes only"
        }
    }
}

enum YouTubeImportSource: String, CaseIterable, Identifiable {
    case likedVideos
    case foreverLMPlaylist

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .likedVideos: return "Liked videos"
        case .foreverLMPlaylist: return "ForeverLM playlist"
        }
    }

    var connectorKind: String {
        switch self {
        case .likedVideos: return "liked"
        case .foreverLMPlaylist: return "foreverlm"
        }
    }

    var iconName: String {
        switch self {
        case .likedVideos: return "hand.thumbsup"
        case .foreverLMPlaylist: return "list.and.film"
        }
    }
}

/// YouTube plugin: follow either the signed-in user's Liked videos or their
/// owned playlist named "ForeverLM", plus any number of channels, and
/// auto-import new entries in the background. Removing an entry upstream removes the plugin-owned row on
/// the next complete sync. Removing a video in the app sticks too: the removal
/// is a timestamped dismissal that an older upstream entry cannot undo — only
/// re-adding it after the removal brings it back. Both feeds go through the
/// authenticated YouTube Data API via `YouTubeService`.
extension StudioViewModel {

    // MARK: - Auto-import preference

    nonisolated static let youtubeAutoImportEnabledKey = "youtube.autoImportEnabled"
    nonisolated static let youtubeLikedImportPolicyKey = "youtube.likedImportPolicy"
    nonisolated static let youtubeLikedImportCutoffKey = "youtube.likedImportCutoff"
    nonisolated static let youtubeLikedTranscriptFormattingKey =
        "youtube.likedTranscriptFormattingEnabled"

    /// Liked-video history can contain thousands of videos, and formatting one
    /// long transcript can fan out into several billed LLM calls. Keep that
    /// bulk work off until the learner explicitly opts in. Raw captions are
    /// still fetched and stored, so search and per-video reading keep working.
    nonisolated static var isLikedYouTubeTranscriptFormattingEnabled: Bool {
        UserDefaults.standard.bool(forKey: youtubeLikedTranscriptFormattingKey)
    }

    nonisolated static func setLikedYouTubeTranscriptFormattingEnabled(_ enabled: Bool) {
        PreferenceStore.set(enabled, forKey: youtubeLikedTranscriptFormattingKey)
    }

    /// Queued content work can outlive the playlist refresh that created it and
    /// resume on a later launch. Re-check persisted Liked-feed identity at the
    /// formatter boundary so that generic backlog processing cannot bypass the
    /// bulk-cost opt-in. The explicit ingest flag separately covers the brief
    /// case where YouTube's ratings view sees a brand-new like before its dated
    /// playlist entry appears.
    nonisolated static func permitsAutomaticTranscriptFormatting(
        for article: StudioArticle,
        likedFormattingEnabled: Bool
    ) -> Bool {
        article.likedAt == nil || likedFormattingEnabled
    }

    var youtubeLikedImportPolicy: YouTubeLikedImportPolicy {
        if let policy = YouTubeLikedImportPolicy(rawValue: youtubeLikedImportPolicyRaw) {
            return policy
        }
        // Existing installs followed Liked videos before this choice existed and
        // already mirror the whole feed. Preserve that established behavior.
        let likedGroupID = videoPlaylistID(for: YouTubeService.likedVideosPlaylistURL)
        return videoPlaylistMetadata[likedGroupID]?.connectorKind == "liked"
            ? .importExisting
            : .undecided
    }

    var youtubeLikedImportCutoff: Date? {
        youtubeLikedImportCutoffTimestamp > 0
            ? Date(timeIntervalSince1970: youtubeLikedImportCutoffTimestamp)
            : nil
    }

    /// Whether the user opted into periodic background import of their YouTube
    /// Liked videos. Stored in the synced Keychain so the choice carries
    /// between the user's Macs; falls back to the legacy per-device UserDefaults
    /// value when never set.
    nonisolated static var isYouTubeAutoImportEnabled: Bool {
        KeychainService.loadBool(.youtubeAutoImportEnabled)
            ?? UserDefaults.standard.bool(forKey: youtubeAutoImportEnabledKey)
    }

    /// Persist the YouTube auto-import preference to the synced Keychain (so it
    /// carries between Macs) and mirror it to UserDefaults for legacy local reads.
    nonisolated static func setYouTubeAutoImportEnabled(_ enabled: Bool) {
        // The Keychain copy is a *synced* key — a synchronizable SecItem write,
        // i.e. securityd IPC — and this runs from the Settings toggle. Keep the
        // toggle instant; the mirror write drains off the click.
        Task.detached(priority: .userInitiated) {
            KeychainService.saveBool(enabled, for: .youtubeAutoImportEnabled)
        }
        PreferenceStore.set(enabled, forKey: youtubeAutoImportEnabledKey)
    }

    /// Browser Reading Lists never become video or X post sources — liking a
    /// video on YouTube and bookmarking a post on X are the only ingestion
    /// paths for those types.
    nonisolated static func filterBrowserReadingListPluginSources(
        _ articles: [StudioArticle]
    ) -> [StudioArticle] {
        articles.filter { article in
            guard isBrowserReadingListSource(article) else { return true }
            return !YouTubeTranscriptService.isYouTubeURL(article.url) && !isXHostURL(article.url)
        }
    }

    /// The Videos tab mirrors the Liked feed: a synced video row is archived
    /// once its video no longer appears in the freshly fetched feed. Callers
    /// must only apply this to a feed that was read to the end — see the
    /// `isComplete` flag from `listLikedVideosFeed`. Videos in playlist groups
    /// (legacy channel follows), videos attached to a course lecture, and
    /// manually added URLs are left alone.
    ///
    /// Course lectures are scraped from public course playlists, so their rows
    /// carry `discoveryOrigin == .youtubePlaylist` and usually have no
    /// `parentGroup` (course structure lives in `course_lecture_items`, not in
    /// a video-playlist group). Without the explicit `courseLectureSourceIDs`
    /// exemption they would match this predicate and get archived — which wipes
    /// their transcript — on every Liked-feed sync.
    ///
    /// The sweep only retracts rows the Liked feed itself created. It used to
    /// exempt just `.manual`, which meant a YouTube video found in a browser
    /// Reading List was archived for the sole reason that it wasn't liked — a
    /// video the learner never claimed was liked in the first place. Absence
    /// from the feed says nothing about a row the feed didn't put there.
    nonisolated static func shouldArchiveUnlikedYouTubeVideo(
        _ article: StudioArticle,
        likedGroupID: String,
        likedURLKeys: Set<String>,
        courseLectureSourceIDs: Set<String> = []
    ) -> Bool {
        guard article.sourceType == .video,
              YouTubeTranscriptService.isYouTubeURL(article.url),
              article.discoveryOrigin == .youtubePlaylist,
              !courseLectureSourceIDs.contains(article.id),
              article.parentGroup == nil || article.parentGroup == likedGroupID else {
            return false
        }
        return !likedURLKeys.contains(sourceURLIdentityKey(article.url))
    }

    // MARK: - Followed items

    /// Video playlist groups followed through the YouTube plugin, distinct
    /// from ordinary manually-added playlists. Legacy channel/playlist follows
    /// may still exist in the store.
    var followedYouTubePluginGroupIDs: [String] {
        orderedVideoPlaylistNames(
            videoPlaylistMetadata.filter { $0.value.connectorKind != nil }.map(\.key)
        )
    }

    /// The current mutually-exclusive YouTube import source. Existing installs
    /// that already follow Liked videos naturally resolve to that source from
    /// their synced playlist metadata.
    var youtubeImportSource: YouTubeImportSource? {
        YouTubeImportSource.allCases.first { source in
            videoPlaylistMetadata.values.contains {
                $0.autoImport && $0.connectorKind == source.connectorKind
            }
        }
    }

    /// Follow the signed-in user's "Liked videos": import them now and keep them
    /// fresh in the background. Requires a connected YouTube account (the Liked
    /// feed is private). Returns the playlist group id.
    @discardableResult
    func followYouTubeLikedVideos() async -> String? {
        let id = videoPlaylistID(for: YouTubeService.likedVideosPlaylistURL)
        await refreshLikedYouTubeVideos()
        guard videoPlaylistMetadata[id] != nil else { return nil }
        await markYouTubePluginPlaylist(id: id, kind: "liked", preferredTitle: "Liked videos")
        await unfollowOtherYouTubeImportSources(except: id)
        Self.setYouTubeAutoImportEnabled(true)
        return id
    }

    /// Configure the Liked-videos plugin without ever importing historical
    /// likes before the learner has chosen what should happen to them.
    @discardableResult
    func configureYouTubeLikedVideos(
        _ policy: YouTubeLikedImportPolicy,
        automaticallyFormatTranscripts: Bool? = nil
    ) async -> String? {
        guard policy != .undecided else { return nil }
        if let automaticallyFormatTranscripts {
            Self.setLikedYouTubeTranscriptFormattingEnabled(automaticallyFormatTranscripts)
        }
        youtubeLikedImportPolicyRaw = policy.rawValue
        PreferenceStore.set(policy.rawValue, forKey: Self.youtubeLikedImportPolicyKey)

        switch policy {
        case .importExisting:
            youtubeLikedImportCutoffTimestamp = 0
            PreferenceStore.remove(forKey: Self.youtubeLikedImportCutoffKey)
            return await followYouTubeLikedVideos()
        case .futureOnly:
            // YouTube timestamps likes to whole seconds. Store the same precision
            // so a like made immediately after this choice is not lost merely
            // because the local cutoff carried subsecond precision.
            let cutoff = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            youtubeLikedImportCutoffTimestamp = cutoff.timeIntervalSince1970
            PreferenceStore.set(cutoff.timeIntervalSince1970, forKey: Self.youtubeLikedImportCutoffKey)
            let id = videoPlaylistID(for: YouTubeService.likedVideosPlaylistURL)
            await persistVideoPlaylist(
                id: id,
                title: "Liked videos",
                playlistURL: YouTubeService.likedVideosPlaylistURL
            )
            await markYouTubePluginPlaylist(id: id, kind: "liked", preferredTitle: "Liked videos")
            await unfollowOtherYouTubeImportSources(except: id)
            Self.setYouTubeAutoImportEnabled(true)
            showToast("Watching for new liked videos")
            return id
        case .undecided:
            return nil
        }
    }

    /// Follow the signed-in user's owned playlist named "ForeverLM". The Data
    /// API lookup is authenticated, so private playlists work too. The playlist
    /// is the plugin source, not a course: its videos render inline in Videos.
    @discardableResult
    func followYouTubeForeverLMPlaylist(
        silent: Bool = false,
        enablesAutoImport: Bool = true
    ) async -> String? {
        let feed: (playlist: YouTubePluginPlaylist, items: [YouTubePlaylistItem], isComplete: Bool)
        do {
            feed = try await YouTubeService.shared.listForeverLMPlaylistFeed()
        } catch {
            if !silent {
                errorMessage = "Failed to import ForeverLM playlist: \(error.localizedDescription)"
            }
            if Self.isYouTubeReconnectRequired(error) {
                youtubePluginNeedsReconnect = true
            }
            if !hasLoggedYouTubePluginFailure {
                hasLoggedYouTubePluginFailure = true
                logger.warning("ForeverLM playlist import failed: \(error.localizedDescription)")
            }
            return nil
        }

        youtubePluginNeedsReconnect = false
        hasLoggedYouTubePluginFailure = false
        let groupID = videoPlaylistID(for: feed.playlist.url)
        await persistVideoPlaylist(
            id: groupID,
            title: feed.playlist.title,
            playlistURL: feed.playlist.url
        )
        await markYouTubePluginPlaylist(
            id: groupID,
            kind: YouTubeImportSource.foreverLMPlaylist.connectorKind,
            preferredTitle: feed.playlist.title
        )
        await unfollowOtherYouTubeImportSources(except: groupID)
        if enablesAutoImport {
            Self.setYouTubeAutoImportEnabled(true)
        }

        let archivedCount = feed.isComplete
            ? await archiveMissingYouTubePlaylistVideos(
                groupID: groupID,
                currentURLKeys: Set(feed.items.map { Self.sourceURLIdentityKey($0.url) })
            )
            : 0

        guard !feed.items.isEmpty else {
            if !silent {
                showToast("ForeverLM playlist is empty")
            }
            return groupID
        }

        await refreshYouTubeVideoPlaylist(
            url: feed.playlist.url,
            groupID: groupID,
            silent: silent,
            assignsParentGroup: true,
            unarchivesExistingSources: true,
            prefetched: (title: feed.playlist.title, items: feed.items)
        )
        if archivedCount > 0 && !silent {
            showToast("Archived \(archivedCount) video\(archivedCount == 1 ? "" : "s") removed from ForeverLM")
        }
        return groupID
    }

    nonisolated static func eligibleLikedVideoItems(
        _ items: [YouTubePlaylistItem],
        policy: YouTubeLikedImportPolicy,
        cutoff: Date?,
        existingURLKeys: Set<String>
    ) -> [YouTubePlaylistItem] {
        guard policy == .futureOnly, let cutoff else { return items }
        return items.filter { item in
            if existingURLKeys.contains(sourceURLIdentityKey(item.url)) { return true }
            guard let likedAt = item.likedAt else { return false }
            return likedAt >= cutoff
        }
    }

    /// Pull-to-refresh on the Videos tab: sync the Liked feed and every
    /// followed channel, then heal any rows still missing a channel subtitle.
    func refreshYouTubeVideosOnSidebarRefresh() async {
        if YouTubeService.shared.isSignedIn {
            switch youtubeImportSource {
            case .likedVideos:
                await refreshLikedYouTubeVideos(silent: true)
            case .foreverLMPlaylist:
                _ = await followYouTubeForeverLMPlaylist(silent: true, enablesAutoImport: false)
            case nil:
                break
            }
            await refreshFollowedYouTubeChannels(silent: true)
        }
        await backfillMissingVideoChannels()
    }

    // MARK: - Followed channels

    nonisolated static let youtubeChannelPluginKind = "channel"

    /// How much of a channel a follow brings in: its newest page of uploads.
    /// Everything published after that arrives with the plugin refresh; the
    /// older catalog stays on YouTube unless it is pasted in as a playlist.
    nonisolated static let youtubeChannelFollowImportCount = 50

    /// Channels followed through the plugin, by their uploads-playlist
    /// group id. They sit beside the one import source, not instead of it.
    var followedYouTubeChannelGroupIDs: [String] {
        orderedVideoPlaylistNames(
            videoPlaylistMetadata.filter {
                $0.value.autoImport && $0.value.connectorKind == Self.youtubeChannelPluginKind
            }.map(\.key)
        )
    }

    /// Follow a channel pasted as a handle, id or address: resolve it, import
    /// its newest uploads into a group named after it, and keep it fresh with
    /// the plugin's refresh. Returns the group id, or nil with
    /// `errorMessage` set.
    @discardableResult
    func followYouTubeChannel(_ input: String) async -> String? {
        guard let reference = YouTubeService.channelReference(from: input) else {
            errorMessage = "Paste a channel address such as youtube.com/@handle, or an @handle."
            return nil
        }
        let channel: YouTubeService.Channel
        let feed: (items: [YouTubePlaylistItem], isComplete: Bool)
        do {
            channel = try await YouTubeService.shared.resolveChannel(reference)
            feed = try await YouTubeService.shared.listChannelUploadsFeed(
                uploadsPlaylistID: channel.uploadsPlaylistID,
                maxCount: Self.youtubeChannelFollowImportCount
            )
        } catch {
            errorMessage = "Couldn’t follow that channel: \(error.localizedDescription)"
            if Self.isYouTubeReconnectRequired(error) {
                youtubePluginNeedsReconnect = true
            }
            return nil
        }
        youtubePluginNeedsReconnect = false
        let url = channel.uploadsPlaylistURL
        let groupID = videoPlaylistID(for: url)
        await persistVideoPlaylist(id: groupID, title: channel.title, playlistURL: url)
        await markYouTubePluginPlaylist(
            id: groupID,
            kind: Self.youtubeChannelPluginKind,
            preferredTitle: channel.title
        )
        Self.setYouTubeAutoImportEnabled(true)
        guard !feed.items.isEmpty else {
            showToast("Following \(channel.title); it has no videos yet")
            return groupID
        }
        await refreshYouTubeVideoPlaylist(
            url: url,
            groupID: groupID,
            assignsParentGroup: true,
            reparentsExistingSources: false,
            allowsAutomaticTranscriptFormatting: Self.isLikedYouTubeTranscriptFormattingEnabled,
            prefetched: (title: channel.title, items: feed.items)
        )
        return groupID
    }

    /// Re-check the newest uploads of every followed channel and import what is
    /// new. Nothing is archived: a video gone from a channel is not the
    /// learner's removal.
    func refreshFollowedYouTubeChannels(silent: Bool = true) async {
        for groupID in followedYouTubeChannelGroupIDs {
            guard let metadata = videoPlaylistMetadata[groupID],
                  let playlistID = YouTubeService.playlistID(fromPlaylistURL: metadata.playlistURL) else { continue }
            let feed: (items: [YouTubePlaylistItem], isComplete: Bool)
            do {
                feed = try await YouTubeService.shared.listChannelUploadsFeed(
                    uploadsPlaylistID: playlistID,
                    maxCount: Self.youtubeChannelFollowImportCount
                )
            } catch {
                if !silent {
                    errorMessage = "Failed to refresh \(metadata.title): \(error.localizedDescription)"
                }
                if Self.isYouTubeReconnectRequired(error) {
                    youtubePluginNeedsReconnect = true
                }
                if !hasLoggedYouTubePluginFailure {
                    hasLoggedYouTubePluginFailure = true
                    logger.warning("Channel refresh failed for \(metadata.title): \(error.localizedDescription)")
                }
                continue
            }
            youtubePluginNeedsReconnect = false
            hasLoggedYouTubePluginFailure = false
            guard !feed.items.isEmpty else { continue }
            await refreshYouTubeVideoPlaylist(
                url: metadata.playlistURL,
                groupID: groupID,
                silent: silent,
                assignsParentGroup: true,
                reparentsExistingSources: false,
                allowsAutomaticTranscriptFormatting: Self.isLikedYouTubeTranscriptFormattingEnabled,
                prefetched: (title: metadata.title, items: feed.items)
            )
        }
    }

    /// Videos imported before channel capture hold the URL host or playlist
    /// title in `domain`, so their rows render no channel subtitle. The liked
    /// sync only refreshes videos still in the feed, so older imports never
    /// heal on their own — fetch the uploader via oEmbed for any active
    /// YouTube video still missing a channel and persist it. Runs after the
    /// sync (so freshly imported rows are already covered and skipped) and
    /// no-ops once everything has a channel.
    ///
    /// A video YouTube refuses to describe — private, deleted — has no channel
    /// to find, and asking again on the next sync gets the same refusal. Those
    /// are remembered for the launch, so a library holding eighteen of them
    /// costs eighteen requests once, not eighteen per plugin event. A public
    /// video whose uploader turned embedding off is not one of them, though
    /// oEmbed refuses it the same way: the lookup asks the player for it
    /// (`lookUpVideoMetadata`). Eighteen Stanford CS336 lectures were taken for
    /// private on that refusal from 2026-09-02 until 2026-09-28.
    func backfillMissingVideoChannels() async {
        guard !videoChannelBackfillInFlight else { return }
        videoChannelBackfillInFlight = true
        defer { videoChannelBackfillInFlight = false }

        let candidates = videoChannelBackfillCandidates()
        guard !candidates.isEmpty else { return }
        logger.info("Backfilling channel names for \(candidates.count) video(s)")

        let results = await Self.fetchVideoChannelBackfillResults(for: candidates)
        // Persist first, then apply to the published `articles` in one pass —
        // per-item mutations between the persist awaits re-render the sidebar.
        var updatedByID: [String: StudioArticle] = [:]
        var unavailable = 0
        var failed = 0
        for result in results {
            switch result.outcome {
            case .unavailable:
                videoChannelBackfillUnavailableVideoIDs.insert(result.videoId)
                unavailable += 1
            case .failed:
                failed += 1
            case .found(let channelName):
                guard let idx = articles.firstIndex(where: { $0.id == result.id }) else { continue }
                var article = articles[idx]
                guard article.domain != channelName else { continue }
                article.domain = channelName
                if (try? await storage.saveSource(article)) != nil {
                    updatedByID[article.id] = article
                }
            }
        }
        logger.info(
            "Named the channel of \(updatedByID.count) of \(candidates.count) video(s); \(unavailable) unavailable on YouTube, \(failed) lookup(s) failed"
        )
        guard !updatedByID.isEmpty else { return }
        for idx in articles.indices {
            if let updated = updatedByID[articles[idx].id] {
                articles[idx] = updated
            }
        }
    }

    /// The active YouTube videos still without a channel name, less the ones
    /// YouTube has already refused to describe this launch.
    func videoChannelBackfillCandidates() -> [VideoChannelBackfillCandidate] {
        activeArticles.compactMap { article in
            guard article.sourceType == .video,
                  videoChannelName(for: article) == nil,
                  YouTubeTranscriptService.isYouTubeURL(article.url),
                  let videoId = YouTubeTranscriptService.extractVideoId(from: article.url),
                  !videoChannelBackfillUnavailableVideoIDs.contains(videoId) else {
                return nil
            }
            return VideoChannelBackfillCandidate(id: article.id, videoId: videoId)
        }
    }

    struct VideoChannelBackfillCandidate: Sendable {
        let id: String
        let videoId: String
    }

    struct VideoChannelBackfillResult: Sendable {
        enum Outcome: Sendable {
            case found(channelName: String)
            /// YouTube answered and will not name this video's channel to an
            /// anonymous client. Remembered so it is not asked again this launch.
            case unavailable
            /// Nothing learned; the next pass may ask again.
            case failed
        }

        let id: String
        let videoId: String
        let outcome: Outcome
    }

    nonisolated private static func fetchVideoChannelBackfillResults(
        for candidates: [VideoChannelBackfillCandidate]
    ) async -> [VideoChannelBackfillResult] {
        let maxConcurrent = 6
        return await withTaskGroup(of: VideoChannelBackfillResult.self) { group in
            var results: [VideoChannelBackfillResult] = []
            var iterator = candidates.makeIterator()

            for _ in 0..<maxConcurrent {
                guard let candidate = iterator.next() else { break }
                group.addTask { await fetchVideoChannel(for: candidate) }
            }
            while let result = await group.next() {
                results.append(result)
                if let candidate = iterator.next() {
                    group.addTask { await fetchVideoChannel(for: candidate) }
                }
            }
            return results
        }
    }

    nonisolated private static func fetchVideoChannel(
        for candidate: VideoChannelBackfillCandidate
    ) async -> VideoChannelBackfillResult {
        let outcome: VideoChannelBackfillResult.Outcome
        switch await YouTubeTranscriptService.shared.lookUpVideoMetadata(videoId: candidate.videoId) {
        case .found(let metadata):
            // A public video with no uploader name is a gap a later lookup may
            // fill, not a verdict on the video.
            if let channel = YouTubeTranscriptService.channelName(of: metadata) {
                outcome = .found(channelName: channel)
            } else {
                outcome = .failed
            }
        case .unavailable:
            outcome = .unavailable
        case .failed:
            outcome = .failed
        }
        return VideoChannelBackfillResult(id: candidate.id, videoId: candidate.videoId, outcome: outcome)
    }

    /// Import (or refresh) the user's liked videos through the authenticated Data
    /// API, then reuse the shared playlist ingest path and archive rows whose
    /// videos are no longer liked. The Liked feed is private, so it cannot use
    /// the keyless playlist scrape that course playlists use. On fetch errors
    /// nothing is archived — no feed data, no changes.
    func refreshLikedYouTubeVideos(silent: Bool = false) async {
        guard youtubeLikedImportPolicy != .undecided else {
            if !silent {
                showToast("Choose whether to import existing liked videos first.")
            }
            return
        }
        let url = YouTubeService.likedVideosPlaylistURL
        let likedGroupID = videoPlaylistID(for: url)
        let feed: (items: [YouTubePlaylistItem], isComplete: Bool)
        do {
            feed = try await YouTubeService.shared.listLikedVideosFeed()
        } catch {
            if !silent {
                errorMessage = "Failed to import liked videos: \(error.localizedDescription)"
            }
            // A lost connection is not a transient hiccup: it never heals on its
            // own, so it has to be visible even on the silent background pass.
            // Quota trips and network blips deliberately don't set this — they
            // recover by themselves and a false "reconnect" prompt would train
            // the user to ignore a real one.
            if Self.isYouTubeReconnectRequired(error) {
                youtubePluginNeedsReconnect = true
            }
            if !hasLoggedYouTubePluginFailure {
                hasLoggedYouTubePluginFailure = true
                logger.warning("Liked videos import failed: \(error.localizedDescription)")
            }
            return
        }
        youtubePluginNeedsReconnect = false
        hasLoggedYouTubePluginFailure = false
        let items = feed.items
        let existingURLKeys = Set(activeArticles.map { Self.sourceURLIdentityKey($0.url) })
        let importItems = Self.eligibleLikedVideoItems(
            items,
            policy: youtubeLikedImportPolicy,
            cutoff: youtubeLikedImportCutoff,
            existingURLKeys: existingURLKeys
        )
        // Absence from a truncated feed proves nothing — the video may simply be
        // older than the fetch window — and archiving deletes the transcript and
        // embeddings, so only sweep when the whole feed was read.
        let archivedCount = feed.isComplete
            ? await archiveUnlikedYouTubeVideos(
                likedGroupID: likedGroupID,
                likedURLKeys: Set(items.map { Self.sourceURLIdentityKey($0.url) })
            )
            : 0
        guard !importItems.isEmpty else {
            await persistVideoPlaylist(id: likedGroupID, title: "Liked videos", playlistURL: url)
            if !silent {
                showToast(items.isEmpty ? "No liked videos found." : "No new liked videos found.")
            }
            return
        }
        await refreshYouTubeVideoPlaylist(
            url: url,
            groupID: likedGroupID,
            silent: silent,
            assignsParentGroup: false,
            // The Liked feed is a mirror: this sync archives on unlike, so a
            // re-like — or a video that drifted past the fetch window and came
            // back — has to undo that archive rather than be dropped.
            unarchivesExistingSources: true,
            allowsAutomaticTranscriptFormatting: Self.isLikedYouTubeTranscriptFormattingEnabled,
            prefetched: (title: "Liked videos", items: importItems)
        )
        if archivedCount > 0 && !silent {
            showToast("Archived \(archivedCount) unliked video\(archivedCount == 1 ? "" : "s").")
        }
    }

    /// Whether a liked-videos failure means the connection itself is gone and
    /// only the user can fix it, as opposed to something that will clear up on
    /// the next pass.
    nonisolated static func isYouTubeReconnectRequired(_ error: Error) -> Bool {
        switch error as? YouTubeServiceError {
        case .notSignedIn, .authFailed:
            return true
        default:
            return false
        }
    }

    func archiveUnlikedYouTubeVideos(likedGroupID: String, likedURLKeys: Set<String>) async -> Int {
        // Never let the Liked-feed mirror archive a video that backs a course
        // lecture: archiving deletes source_content, which would silently wipe
        // the lecture transcript. StorageService is an actor, so this query
        // runs off the main actor.
        let courseLectureItems = (try? await storage.loadCourseLectureItems()) ?? []
        let courseLectureSourceIDs = Set(courseLectureItems.compactMap(\.sourceId))
        let idsToArchive = activeArticles
            .filter {
                Self.shouldArchiveUnlikedYouTubeVideo(
                    $0,
                    likedGroupID: likedGroupID,
                    likedURLKeys: likedURLKeys,
                    courseLectureSourceIDs: courseLectureSourceIDs
                )
            }
            .map(\.id)
        guard !idsToArchive.isEmpty else { return 0 }

        for sourceID in idsToArchive {
            try? await storage.archiveSource(sourceID)
        }
        let archived = Set(idsToArchive)
        articles.removeAll { archived.contains($0.id) }
        invalidateFilteredSidebarCache()
        if let selectedArticleId, archived.contains(selectedArticleId) {
            // activeArticles is the raw list including hidden rows; falling back
            // to a hidden article would open the reader on a source no sidebar
            // tab displays.
            self.selectedArticleId = articles.first(where: { !isSourceHidden($0) })?.id
            currentCardIndex = 0
        }
        return idsToArchive.count
    }

    nonisolated static func shouldArchiveMissingYouTubePlaylistVideo(
        _ article: StudioArticle,
        groupID: String,
        currentURLKeys: Set<String>,
        courseLectureSourceIDs: Set<String> = []
    ) -> Bool {
        guard article.sourceType == .video,
              article.discoveryOrigin == .youtubePlaylist,
              !courseLectureSourceIDs.contains(article.id),
              article.parentGroup == groupID else { return false }
        return !currentURLKeys.contains(sourceURLIdentityKey(article.url))
    }

    /// Mirror removals from the named ForeverLM playlist, scoped to that
    /// playlist's stable group id. Manual videos and Liked-feed rows do not
    /// qualify, and course-lecture membership is explicitly exempted because
    /// archiving would wipe the lecture transcript.
    func archiveMissingYouTubePlaylistVideos(
        groupID: String,
        currentURLKeys: Set<String>
    ) async -> Int {
        let courseLectureItems = (try? await storage.loadCourseLectureItems()) ?? []
        let courseLectureSourceIDs = Set(courseLectureItems.compactMap(\.sourceId))
        let idsToArchive = activeArticles
            .filter {
                Self.shouldArchiveMissingYouTubePlaylistVideo(
                    $0,
                    groupID: groupID,
                    currentURLKeys: currentURLKeys,
                    courseLectureSourceIDs: courseLectureSourceIDs
                )
            }
            .map(\.id)
        guard !idsToArchive.isEmpty else { return 0 }

        for sourceID in idsToArchive {
            try? await storage.archiveSource(sourceID)
        }
        let archived = Set(idsToArchive)
        articles.removeAll { archived.contains($0.id) }
        invalidateFilteredSidebarCache()
        if let selectedArticleId, archived.contains(selectedArticleId) {
            self.selectedArticleId = articles.first(where: { !isSourceHidden($0) })?.id
            currentCardIndex = 0
        }
        return idsToArchive.count
    }

    /// Stop auto-importing a followed item without removing the videos already
    /// imported. To delete everything, use `removeVideoPlaylistGroup` instead.
    func unfollowYouTubePluginPlaylist(_ groupID: String) async {
        guard var metadata = videoPlaylistMetadata[groupID] else { return }
        metadata.autoImport = false
        metadata.connectorKind = nil
        videoPlaylistMetadata[groupID] = metadata
        do {
            try await storage.saveVideoPlaylistGroup(id: groupID, metadata: metadata)
            showToast("Stopped following \(metadata.title)")
        } catch {
            logger.error("Failed to unfollow YouTube playlist: \(error.localizedDescription)")
        }
    }

    private func markYouTubePluginPlaylist(id: String, kind: String, preferredTitle: String?) async {
        guard var metadata = videoPlaylistMetadata[id] else { return }
        metadata.autoImport = true
        metadata.connectorKind = kind
        if metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let preferredTitle, !preferredTitle.isEmpty {
            metadata.title = preferredTitle
        }
        videoPlaylistMetadata[id] = metadata
        do {
            try await storage.saveVideoPlaylistGroup(id: id, metadata: metadata)
        } catch {
            logger.error("Failed to mark YouTube plugin playlist: \(error.localizedDescription)")
        }
    }

    /// Liked videos and the named playlist are alternative intake rails. Keep
    /// imported sources, but stop every other rail from continuing to sync.
    private func unfollowOtherYouTubeImportSources(except selectedID: String) async {
        let supportedKinds = Set(YouTubeImportSource.allCases.map(\.connectorKind))
        let otherIDs: [String] = videoPlaylistMetadata.compactMap { id, metadata -> String? in
            guard id != selectedID,
                  metadata.autoImport,
                  let kind = metadata.connectorKind,
                  supportedKinds.contains(kind) else { return nil }
            return id
        }
        for id in otherIDs {
            guard var metadata = videoPlaylistMetadata[id] else { continue }
            metadata.autoImport = false
            metadata.connectorKind = nil
            videoPlaylistMetadata[id] = metadata
            do {
                try await storage.saveVideoPlaylistGroup(id: id, metadata: metadata)
            } catch {
                logger.error("Failed to switch YouTube import source: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Background auto-import

    /// Start the post-launch YouTube auto-import loop. Safe to call once after the
    /// initial queue load; it never runs at startup and no-ops unless the user has
    /// enabled auto-import and selected a YouTube source.
    func startYouTubeAutoImport() {
        guard youtubeAutoImportTask == nil else { return }
        youtubeAutoImportTask = Task { [weak self] in
            await self?.runYouTubeAutoImportLoop()
        }
    }

    nonisolated func runYouTubeAutoImportLoop() async {
        // Event-triggered refreshes (Videos refresh and app activation) are the
        // primary freshness path. This delayed loop is only a low-frequency
        // backstop, and a full pass pages to the end of the selected source.
        do { try await Task.sleep(for: .seconds(75)) } catch { return }
        while !Task.isCancelled {
            await runYouTubeAutoImportOnce()
            do { try await Task.sleep(for: .seconds(3 * 60 * 60)) } catch { return }
        }
    }

    /// One background pass: re-check the selected YouTube feed and import any new
    /// videos. Silent (no toasts, no sidebar changes); existing videos are updated
    /// in place, not duplicated. New metadata is published first, then transcript
    /// processing continues independently in the background. The Liked feed is
    /// private, so this goes through the authenticated API.
    func runYouTubeAutoImportOnce() async {
        guard Self.isYouTubeAutoImportEnabled else { return }
        guard !Task.isCancelled else { return }
        switch youtubeImportSource {
        case .likedVideos:
            await refreshLikedYouTubeVideos(silent: true)
        case .foreverLMPlaylist:
            _ = await followYouTubeForeverLMPlaylist(silent: true, enablesAutoImport: false)
        case nil:
            break
        }
        guard !Task.isCancelled else { return }
        await refreshFollowedYouTubeChannels(silent: true)
    }
}
