import Foundation

/// The single declaration of which `UserDefaults` keys are *user preferences* that
/// follow the account across Macs, and which are deliberately device-local.
///
/// Preferences are persisted to `user_preferences` in `knowledge.db` and synced as
/// the `.preference` CloudKit entity — one row and one record per key, so two Macs
/// changing two different settings never collide. (Conflict resolution is row-level
/// last-write-wins over an opaque payload; a single shared blob row would silently
/// drop one of the two edits.)
///
/// Both lists live here rather than next to their call sites so the boundary can be
/// reviewed in one place. `excluded` carries a reason per entry — an unexplained
/// exclusion is indistinguishable from an oversight.
enum SyncedPreferenceKeys {

    /// Model configuration that must survive a rebuild even when that rebuild
    /// lands in a fresh `UserDefaults` container. Version 14 of knowledge.db
    /// promotes any existing values for these keys into `user_preferences`.
    ///
    /// Chat-bar picks are deliberately absent: `.chat` is session-scoped,
    /// while the default chat model itself is represented by `ai_provider` plus
    /// the provider's model key. The one chat-bar choice kept is the effort,
    /// which every new chat starts on (`aiRoute.defaultChat.effort`).
    static let persistedModelConfiguration: Set<String> = [
        "ai_provider",
        "anthropic_model", "openai_model", "groq_model", "cerebras_model",
        "xai_model", "gemini_model", "meta_model", "together_model",
        "fireworks_model", "nvidia_model", "openrouter_model",
        "anthropic_model_explicitly_picked", "openai_model_explicitly_picked",
        "chatModels.enabledIDs", "chatModels.openRouterCustom",
        "aiRoute.defaultChat", "aiRoute.defaultChat.effort",
        "aiRoute.background", "aiRoute.background.multimodal",
        "aiRoute.docs",
        "aiRoute.textRoutingMode",
        "stt_provider",
        "stt_model_openai", "stt_model_groq", "stt_model_openrouter",
        "stt_model_wispr", "stt_model_whisperkit", "stt_model_assemblyai",
        "stt_model_cartesia", "stt_model_tailscale", "stt_local_server_url",
        "tts_provider", "tts_model_apple", "tts_model_openai", "tts_model_groq",
        "tts_model_elevenlabs", "tts_model_together", "tts_model_local_mac",
        "tts_model_xai", "tts_model_openrouter", "tts_model_gemini",
        "tts_model_cartesia", "tts_model_tailscale", "tts_local_server_url",
    ]

    static func isPersistedModelConfiguration(_ key: String) -> Bool {
        guard isSynced(key) else { return false }
        if persistedModelConfiguration.contains(key) { return true }
        if key.hasPrefix("aiBackground.") { return true }
        if key.hasPrefix("aiRoute.task.") { return true }
        if key.hasPrefix(OpenRouterHostPreference.keyPrefix) { return true }
        if key.hasPrefix(AIBackupModels.keyPrefix) { return true }
        return key.hasPrefix("aiTask.") && !key.hasPrefix("aiTask.chat.")
    }

    // MARK: - Synced

    /// Exact keys that sync. Runtime-built keys go in `syncedPrefixes` instead.
    static let synced: Set<String> = [
        // User-owned profile chrome. The web app cannot reliably recover the
        // Apple Account name because CloudKit withholds name components when
        // discoverability is unavailable, so the native app seeds this once and
        // every client thereafter uses the synced value.
        "account.displayName",
        // Whether the complimentary-account crown shows (the web's footer, the
        // Mac account menu's row); the learner hides it once, for every
        // client's screenshots.
        "account.showsCompCrown",
        // The learner's own words about where they are coming from
        // (`LearnerProfile.aboutYouPreferenceKey`): every course tailors its
        // readings and quizzes to it, on whichever Mac they study.
        LearnerProfile.aboutYouPreferenceKey,

        // The learner's daily cap on background AI spend
        // (`BackgroundAIDailyCap.preferenceKey`): a decision about the
        // account's spend, and every Mac reads the same synced ledger.
        "aiSpend.backgroundDailyCapUSD",

        // AI model selection. The `<provider>_model` / `*_provider` keys are the
        // `KeychainService.Key` raw values migrated out of the Keychain vault; see
        // `KeychainService.preferenceBackedKeys`.
        "ai_provider",
        "anthropic_model", "openai_model", "groq_model", "cerebras_model",
        "xai_model", "gemini_model", "meta_model", "together_model",
        "fireworks_model", "nvidia_model", "openrouter_model",
        "anthropic_model_explicitly_picked", "openai_model_explicitly_picked",
        "chatModels.enabledIDs", "chatModels.openRouterCustom",
        "aiRoute.defaultChat", "aiRoute.defaultChat.effort",
        "aiRoute.background", "aiRoute.background.multimodal",
        "aiRoute.docs",
        "aiRoute.textRoutingMode",
        // Whether OpenRouter may route to hosts that keep or train on prompts.
        // A statement about the learner's data, not the device, so it follows
        // the account; the phone writes the same row from its own Settings.
        AIDataPolicy.denyDataCollectionKey,

        // Speech-to-text and text-to-speech selection. The realtime voice
        // and live dictation keys (`realtimeVoiceModel`, `realtimeVoice.*`,
        // `stt_engine`, `stt_model_realtime`) stopped syncing when those went
        // on 2026-10-01.
        "stt_provider",
        "stt_model_openai", "stt_model_groq", "stt_model_openrouter",
        "stt_model_wispr", "stt_model_whisperkit", "stt_model_assemblyai",
        "stt_model_cartesia", "stt_model_tailscale", "stt_local_server_url",
        "tts_provider", "tts_model_apple", "tts_model_openai", "tts_model_groq",
        "tts_model_elevenlabs", "tts_model_together", "tts_model_local_mac",
        "tts_model_xai", "tts_model_openrouter", "tts_model_gemini",
        "tts_model_cartesia", "tts_model_tailscale", "tts_local_server_url",

        // Text-to-speech tuning. Voices and instructions are hand-written; losing them
        // is the single most annoying thing on this list.
        "macos.tts.speed",
        "macos.tts.confirmCostBeforeListening",
        "readAloud.costConfirmation.suppressedModels.v1",
        "macos.tts.apple.voiceIdentifier",
        "macos.tts.openai.voice", "macos.tts.groq.voice",
        "macos.tts.elevenlabs.voice", "macos.tts.xai.voice",
        "macos.tts.gemini.voice", "macos.tts.together.voice",
        "macos.tts.openrouter.voice", "macos.tts.local_qwen3.voice",
        "macos.tts.openai.instructions", "macos.tts.local_qwen3.instructions",
        "readAloud.autoGenerate.articles", "readAloud.autoGenerate.papers",
        "readAloud.autoGenerate.books", "readAloud.autoGenerate.courses",
        // Explainers are article-typed sources with a switch of their own
        // (`SourceAudioAutomation.explainerKind`).
        "readAloud.autoGenerate.explainers",
        "readAloud.autoGenerate.constraint.article",
        "readAloud.autoGenerate.constraint.paper",
        "readAloud.autoGenerate.constraint.book",
        "readAloud.autoGenerate.constraint.course",
        "readAloud.autoGenerate.constraint.explainer",
        "readAloud.autoGenerate.allowPaidVoices",

        // Generated imagery. The model is a spending decision like the voices
        // above, and Web Studio draws with it too, so it has to follow the
        // account rather than the Mac it was picked on. Keys owned by
        // `MacImageGenerationSettings`.
        "images.model", "images.style", "images.source",
        "images.generateIcons", "images.generateIcons.automatic",
        "images.drawQuizPictures.automatic",
        // Generated video: the model and resolution a film is made at, a
        // spending decision like the image model above. Keys owned by
        // `MacVideoGenerationSettings`.
        "videos.model", "videos.resolution",

        // Studio source participation, layout, and display.
        "studio.hiddenTabs", "studio.tabOrder", "studio.excludedKnowledgeSourceTabs",
        "studio.centerTabGroups.v1",
        "studio.courseOrder", "studio.projectOrder", "studio.chatOrder",
        // The notebooks the learner pinned to the rail (`NotebookPins`). Like
        // the orders beside it, an arranged rail is work that has to reach the
        // other Mac.
        NotebookPins.preferenceKey,
        "studio.expandedPanel", "studio.showSearchPanel",
        "studio.navigationRailVisible", "studio.sourceTabBarLayout",
        "studio.showSourceTabLabels", "studio.sourceTabIconSize",
        "studio.assistantIntegrationsEnabled", "studio.showMCPStatusLight",
        // Signed up for beta releases (`BetaReleases`, Mac only): a choice the
        // learner makes once for the account, so every Mac of theirs follows it.
        "updates.betaReleases",
        // The one-time integration-tab unpin and its record of which unpins were
        // Studio's own. They belong with `studio.hiddenTabs`: left device-local,
        // a rebuild into a fresh preferences container re-applied the default and
        // then pinned Read AI, Zoom and Slack back over a deliberate unpin.
        "studio.integrationTabUnpinDefaultsApplied",
        "studio.integrationTabsUnpinnedByDefault",
        // Chat's pinch zoom is one offset per chat panel, in memory on the
        // panel's session store, so it is neither stored nor synced.
        "uiZoomStep", "metadataVisibility", "showReadStatus", "showReviewedStatus",
        "showSyncSubtitles", "podcastSortMode", "videoSortMode", "meetingListOrder",
        // Reading a paper as published rather than inverted for Dark Mode. It is
        // a property of the reader and the figures they are reading, not of the
        // Mac they happen to be at, so it follows the account like the rest of
        // the display preferences above. See `ReaderDarkMode`.
        "readerOriginalPageColors",
        // How wide a Doc's page is drawn. A reading preference like the zoom step
        // above, so it follows the account. See `ArtifactPageWidth`.
        "notepad.pageWidth",
        // Whether a Doc draws its margin cards; a reading preference like the
        // page width. See `ArtifactMarginCards`.
        "notepad.showsMarginCards",
        // How a video source is laid out beside its transcript, and how much of
        // the pane the video takes. The mode is a reading preference like the
        // two above; the sizes are *fractions* of the pane (0 means auto), not
        // the absolute pixel widths excluded below, so they mean the same thing
        // on a laptop screen and a 6K display and can follow the account with
        // them.
        "reader.youtubeTranscriptBesideVideo",
        "reader.youtubeVideoPaneFraction", "reader.youtubeVideoPaneWidthFraction",
        "reader.meetingVideoPaneFraction",

        // The navigation rail's hidden rows and its folds. Hiding a row is the
        // same act as `studio.hiddenTabs` and the pins above,
        // and a fold is the same act as `studio.expandedPanel` — all of which
        // already sync, so these did the opposite of their neighbours until
        // 2026-09-14.
        StudioRailHiddenItems.storageKey,
        "studio.navigation.chatsExpanded.v1",
        "studio.navigation.hiddenChatsExpanded.v1",
        "studio.navigation.expandedProjectIDs.v1",

        // Plugin toggles and discovery scope.
        "youtube.autoImportEnabled", "youtube.likedImportPolicy",
        "youtube.likedImportCutoff", "youtube.likedTranscriptFormattingEnabled",
        "gettingStarted.completed", "gettingStarted.dismissed", "gettingStarted.completedSteps",
        // Which AI apps the learner pays for, asked in setup: a fact about the
        // person, so the other Mac's guide does not ask again.
        "gettingStarted.aiSubscriptions",
        // Don't Ask Again on the offer to leave a slow free chat model
        // (`SlowFreeModelWait.dismissedKey`): "forever" means on every Mac.
        "chat.slowFreeModelOffer.dismissed",
        "studio.applePodcastDiscoveryScope", "podcasts.youtubeFallbackShows",

        // Shows whose episodes are never imported. This one has to sync or it
        // does not work: both Macs read the same Apple Podcasts library, so a
        // block held on one of them is undone by the other importing the same
        // episodes and syncing the rows straight back. (The follow list next to
        // it in the preference store is deliberately not here — it only adds
        // episodes that already reach both Macs through sync anyway, so a
        // per-Mac follow costs nothing.)
        SourceDiscovery.blockedPodcastShowsPreferenceKey,

        // User-created taxonomy — losing these collapses grouping.
        "userCourseNames", "userMeetingGroupNames",

        // Removal tombstones: meeting groups the user deleted. Must sync, or a
        // background or MCP-driven import on the other Mac resurrects the group
        // and syncs it straight back to the Mac that removed it.
        "meetings.removedGroupTitles", "meetings.removedGroupIdentities",
        // Whether ForeverLM may transcribe a meeting recording itself instead of
        // importing the transcript Google wrote. A spending decision, so it must
        // follow the account: leaving it device-local means the other Mac opens
        // the same meeting and bills a transcription the learner turned off here.
        "meetings.transcribeWhenGoogleDidNot",

        // The hours the Planner's clock draws. A statement about the learner's
        // day, not the Mac it was said on, so it follows the account.
        PlannerDayHours.startKey,
        PlannerDayHours.endKey,

        // Whether today's memory review is prepared ahead of the click — one
        // planner call and one opening message a day, billed whether or not the
        // review is opened. A spending decision, so it follows the account; the
        // hour it runs at is the device's and stays below.
        DailyReviewPreparation.enabledKey,
        // How many minutes a day the memory review gets. It sizes the review
        // wherever it is planned and is a statement about the learner's day,
        // not the device it was said on, so it follows the account; the phone
        // writes the same row from its own Settings.
        MemoryReviewBudget.preferenceKey,
        // Whether the day closes itself each evening: its chats' closer,
        // idea extraction, background card drafting and rewording are the
        // account's spend, so it follows the account; the hour stays below.
        DayClosePreferences.enabledKey,
        // Whether ForeverLM keeps notes about the learner's work: it is about
        // the learner, and the notes' Doc follows the account.
        WorkingNotesPreference.enabledKey,
        // The day's new cards, which also set how many sources are drafted
        // in the background a day; whether they are drafted at all; and
        // whether the "Cards to check" card is shown. Statements about the
        // learner's day and spend, not the Mac they were said on.
        MemoryCardSettings.newCardsPerDayKey,
        MemoryCardSettings.autoDraftKey,
        MemoryCardSettings.draftNudgesKey,
        // Whether review questions are written ahead of time for the sources
        // a review is likely to be about: the account's background spend.
        MemoryCardSettings.prepareReviewQuestionsKey,
        // Think first's level for the whole library (`ThinkFirst`): how much the
        // learner wants to be asked for their own line first is a choice about
        // how they learn, not about the Mac they said it on.
        ThinkFirst.levelKey,

        // The learner's word that they may share the sources they share
        // (`SharingRightsAffirmation`, its version and when): asked once,
        // before the first share, and once means on every device, so the
        // iPhone and the web read and write the same row.
        SharingRightsAffirmation.preferenceKey,

    ]

    /// Prefixes whose keys are built at runtime and cannot be enumerated.
    static let syncedPrefixes: [String] = [
        // One row per named workspace view, so independently saved monitor
        // arrangements never contend in a shared preference blob.
        StudioSavedWorkspaceView.preferenceKeyPrefix,
        // `aiTask.<task>.{provider,model,effort,speed,prompt}` — the per-task
        // Advanced overrides. Built in KeychainService from the AITask case.
        "aiTask.",
        "aiRoute.task.",
        // `aiHost.<slot>|<model slug>` — which OpenRouter host serves one
        // model for one task (`OpenRouterHostPreference`). A choice about the
        // account's work and spend, like the routes beside it.
        OpenRouterHostPreference.keyPrefix,
        // `aiBackups.<slot>` — the models a Background setting falls back to
        // when its own cannot answer (`AIBackupModels`). Account spend too.
        AIBackupModels.keyPrefix,
        // `aiBackground.provider` plus `aiBackground.model.<provider>`, the latter
        // built by KeychainService.backgroundTaskModelKey(for:).
        "aiBackground.",
        // One row per model/voice pair. Keeping reactions independent prevents
        // a thumb changed on one device from overwriting reactions to other voices.
        ArticleSpeechVoiceRating.preferencePrefix,
        // `meetingFolder.image.<groupID>` — one row per meeting folder that has
        // been given its own sidebar tile, for the same reason.
        MeetingMetadata.folderImagePreferenceKeyPrefix,
        // `lectureQuiz.score.<sourceID>` — the latest sitting of each course
        // lecture's quiz. Per-member state kept in the private database, so a
        // team's copy of the course never carries it; one row per lecture so
        // two Macs finishing two quizzes never collide.
        LectureQuizScore.preferenceKeyPrefix,
        // `courseQuiz.score.<quizID>` — the latest sitting of each stored course
        // quiz (practice, checkpoint, course test), for the same reasons.
        LectureQuizScore.courseQuizPreferenceKeyPrefix,
        // `course.focus.<courseID>` — what the learner wants from one course, in
        // their words. Per-member like the scores above, so a team's copy of
        // the course never carries it; one row per course.
        LearnerProfile.courseFocusPreferenceKeyPrefix,
        // Operational meeting-plugin health contains no credentials. Syncing
        // it lets Web Studio warn about a dead Mac-side feed instead of showing
        // historical meetings as though they were current.
        "connectorHealth.",
        // `memory.reviewDepth.type.<sourceType>` — how much of a memory review a
        // kind of source gets by default ("keep podcasts quick"). Said about
        // the material, not the Mac it was said on, so it follows the account.
        MemoryReviewDepth.typePreferenceKeyPrefix,
        // `listen.position.<sourceID>` — where the listener stopped in a
        // narration, so the next device resumes there. One row per source; the
        // file beside the audio in iCloud Drive is the offline copy and this
        // is the one that actually arrives in time. See `ListeningPositionSync`.
        ListeningPositionSync.preferenceKeyPrefix,
        // `notebook.chatExcluded.<notebookID>` — the sources a notebook's chats
        // leave out, as the learner unticked them. Per member like the course
        // focus above, so a team's copy never carries it; one row per notebook
        // (`NotebookChatSelection`).
        NotebookChatSelection.preferenceKeyPrefix,
        // `notebook.chatContextNotebooks.<notebookID>` — the context notebooks
        // whose sources a notebook's chats read, as the learner put them in.
        // Per member for the same reason; the link itself rides the Notebook
        // record (`NotebookChatContext`).
        NotebookChatContext.preferenceKeyPrefix,
        // `notebookCollection.<collectionID>` (a collection's name) and
        // `notebook.collections.<notebookID>` (the collections one notebook is
        // in): the learner's collections of notebooks, grouped in the Space's
        // All and on the iPhone's Home (`NotebookCollections`). Their own taxonomy, like the course and
        // meeting-group names above, so it follows the account; one row per
        // collection and one per notebook, so two devices filing two
        // notebooks at once both keep theirs, and per member, so a team's
        // notebook never carries one member's collections.
        NotebookCollections.namePreferenceKeyPrefix,
        NotebookCollections.membershipPreferenceKeyPrefix,
        // `pageSpace.<spaceID>` (a space's name) and `page.space.<artifactID>`
        // (the one space a page is in): the learner's spaces of pages in the
        // Space sidebar (`PageSpaces`), ChatGPT's spaces. Their own grouping,
        // like the collections above, so it follows the account; one row per
        // space and one per page, so two devices moving two pages at once
        // both keep theirs, and per member, never on the Artifact record.
        PageSpaces.namePreferenceKeyPrefix,
        PageSpaces.membershipPreferenceKeyPrefix,
        // `page.pinned.<artifactID>`: when the learner pinned a page
        // (`PagePins`), ChatGPT's Pin. One row per page, per member.
        PagePins.preferenceKeyPrefix,
        // `page.parent.<childArtifactID>`: the page a page is nested under
        // (`PageParents`), ChatGPT's subpages. One row per child, per member.
        PageParents.preferenceKeyPrefix,
        // `notebook.naming.<notebookID>` — the name and description ForeverLM
        // last put on a notebook made without one, which it may replace while
        // the notebook still carries them (`NotebookNaming`). Follows the
        // account so a notebook made on the phone is named on the Mac, and so
        // a second Mac never renames what the learner named on the first;
        // one row per notebook.
        NotebookNaming.preferenceKeyPrefix,
        // `notebook.thinkFirst.<notebookID>` — one notebook's own Think first
        // level over the library's (`ThinkFirst`). Per member, like the
        // notebook rows above, so a teammate's choice never changes it; one
        // row per notebook.
        ThinkFirst.notebookKeyPrefix,
        // `notebook.questions.<notebookID>` — the questions the notebook's
        // guide suggested for its sources and which of them were asked
        // (`NotebookSuggestedQuestions`), so a new chat on any device offers
        // what is left without a model call. Per member, one row per notebook.
        NotebookSuggestedQuestions.preferenceKeyPrefix,
        // `cards.state.<deckID>` — what the learner changed about each card of
        // one deck outside its Memory item: kept, skipped or still a draft, an
        // edited front, variants, "always ask it this way", the seed it was
        // drafted from (`MemoryCardDeckState`). Per member, in the private
        // database, so a team's notebook never carries it; one row per deck,
        // merged card by card on every write.
        MemoryCardDeckState.preferenceKeyPrefix,
        // `map.layout.<mapID>` — one of the learner's canvases: the cards
        // they placed, the regions they drew and the arrows between them,
        // and the canvas's name and Trash mark (`KnowledgeMapLayout`). Their
        // own arrangement, so it follows the account; one row per canvas,
        // merged entry by entry on receipt so two Macs that moved different
        // cards both keep their moves.
        KnowledgeMap.layoutKeyPrefix,
        // `spaceList.<listID>` (a list of goals or ideas in the Space: its
        // kind, name, made time and Trash mark) and `spaceListItem.<recordID>`
        // (the one list a goal or an idea is in), `SpaceLists`. Per member.
        SpaceLists.listPreferenceKeyPrefix,
        SpaceLists.itemPreferenceKeyPrefix,
    ]

    // MARK: - Excluded

    /// Keys that must never sync, with the reason. Checked before `syncedPrefixes`,
    /// so an exclusion always beats a prefix match.
    static let excluded: [String: String] = [
        // Absolute pixels, tied to display size.
        "studio.navigationRailWidth": "absolute pixels, display-dependent",
        "studio.sourcesPanelWidth": "absolute pixels, display-dependent",
        // The notebook workspace's Sources column as the learner dragged it
        // (`NotebookWorkspaceSizing.sourcesWidthPreferenceKey`).
        "notebook.sourcesColumnWidth": "absolute pixels, display-dependent",
        "studio.learningProgressPanelHeight": "absolute pixels, display-dependent",
        "studio.mcpContextTrayHeight": "absolute pixels, display-dependent",
        "studio.reviewSessionPanelHeight": "absolute pixels, display-dependent",
        "studio.assistantOverlay.width": "absolute pixels, display-dependent",
        "studio.assistantOverlay.height": "absolute pixels, display-dependent",

        // Whether a journal check that finds new matches raises a banner. The
        // journals themselves are followed per Mac, so the banner about what
        // this Mac found is this Mac's decision too.
        JournalWatch.notifyOnMatchKey: "device-local like the journal feeds it announces; a banner is about the Mac that found the article",

        // What the reader folded in each doc (`ArtifactOutlineFolds`): how one
        // reader left a doc on one screen, keyed by doc id.
        "docs.outlineFolds": "view state of each doc on this Mac, not a setting",

        // Machine identity, plus retired one-time-license/trial keys kept excluded
        // so any values left in an existing install never start syncing.
        "license.activationDeviceID": "identifies this Mac (retired license rail)",
        "license.fallbackDeviceID": "identifies this Mac (retired license rail)",
        "trial.startDate": "retired 7-day-trial marker; stays out of the sync rail",

        // Caches and sync cursors — refetched or rebuilt, and meaningless elsewhere.
        "reader.recentSourceIDs": "cache; deliberately out of the sync pipeline",
        "enrichedChapterTitles": "cache keyed by local PDF path",
        "mcpCloudflareTunnelURL": "per-machine tunnel",
        "mcp_oauth_pairing_code": "single-use",

        // `defaults write` escape hatches. Moving them to SQLite would remove the
        // CLI workaround entirely. (Note: these are currently broken for an
        // unrelated reason — the sandboxed and non-sandboxed builds read different
        // preference domains, so `defaults write com.foreverlm` targets a plist the
        // dev builds never read.)
        "studio.mcpZeroClickOAuthApproval": "defaults-write escape hatch",
        "preferredBrowser": "defaults-write escape hatch",
        "readingListSafari": "per-Mac browser choice from setup; each Mac has its own browsers",
        "readingListChrome": "per-Mac browser choice from setup; each Mac has its own browsers",
        "readingListBrave": "per-Mac browser choice from setup; each Mac has its own browsers",
        SourceDiscovery.ReadingListImportWindow.sinceKey: "per-Mac Reading List backlog cutoff from setup; qualifies the per-Mac browser choice",
        SourceDiscovery.ReadingListImportWindow.windowKey: "per-Mac Reading List backlog choice from setup; names the cutoff above",

        // One-shot markers. Resyncing one re-applies a default the user overrode.
        "pendingMigrationV1Done": "one-shot marker",

        // Taste, per device. Read straight from UserDefaults on the Mac and the
        // iPhone alike (Settings → Appearance / Display); the phone has no
        // synchronous view of the synced rows, and a logo's pace is not worth
        // carrying across an account.
        LoadingIndicatorSpeed.key: "device-local animation pace, read directly on both platforms",

        // The hour today's review should be waiting is a property of this
        // machine's mornings, not of the account; the other Mac may keep another.
        // The offer marker is one-shot, and the attempt receipt describes what
        // this device did today, which the other device must not inherit.
        DailyReviewPreparation.hourKey: "device-local hour for the daily review preparation",
        DailyReviewPreparation.offerDecidedKey: "one-shot marker: the in-chat offer was answered here",
        DailyReviewPreparation.offerShownCountKey: "how many planning waits showed the in-chat offer here",
        "memoryReview.dailyPreparation.lastAttempt.v1": "this device's preparation receipt for today",
        // The card review ran out of cards on this Mac today, which made the
        // day done here (`MemoryReviewEngagementTracker.finishDayByCards`).
        "memoryReview.cardsFinishedDay": "the day this Mac's card review ran out of cards",
        // Think first's tally of answered and skipped asks is measured where
        // it happens, and the sources whose gist this Mac has asked about are
        // this Mac's memory of asking; a take itself lives in the source's
        // understanding document, which travels.
        ThinkFirstTally.countsKey: "how often each Think first moment was answered or skipped here",
        ThinkFirstAskedSources.preferenceKey: "the sources whose gist this Mac has already asked about",
        // The evening half of the same switch: the hour this Mac closes the
        // day is this Mac's, and the receipt says what this device did.
        DayClosePreferences.hourKey: "device-local hour for the day close",
        DayClosePreferences.lastRunKey: "this device's day-close receipt",
        // The id this device signs its review-time rows with; the rows themselves
        // sync, the name of the device that wrote them does not need to.
        MemoryReviewActivityDevice.preferenceKey: "identifies this device's memory_review_activity rows",
        // Which sources the model could not turn into ideas, and when. Cache: a
        // failure remembered here only stops this device re-billing the same
        // call for a day, and the other device is welcome to try once itself.
        SourceIdeaExtractionFailures.key: "device-local retry backoff for idea extraction",
        // The same for background card drafting, and what this Mac's last
        // run did; and the day this Mac's "Cards to check" card was put off,
        // which, like "Plan your day?", is asked on the Mac being sat at.
        AutomaticCardDraftingFailures.key: "device-local retry backoff for background card drafting",
        AutomaticCardDraftingRun.key: "this device's last background card drafting run",
        CardsToCheckNudge.putOffKey: "the day this Mac's Cards to check card was put off",
        CardsToCheckBanner.ledgerKey: "which sources this Mac's morning cards banner has told, and the banner it has queued with this Mac's notification centre",

        // Reasoned at their call sites before 2026-09-14 but never declared here,
        // which is the one thing this file exists to prevent. Each keeps the
        // reason its own code gives.
        "browser.profiles.v1": "a profile names a data store on this disk; a synced list would name jars another Mac does not have",
        "browser.session.v1": "which tabs are open in this Mac's browser window",
        "cohortReview.dismissedSignatures.v1": "\"not right now\" is about the machine being sat at; syncing it would let a dismissal here swallow the phone's morning nudge",
        "studio.activeMCPNotebookID": "which Notebook this Mac's own MCP endpoint serves",
        "studio.lastSessionResumesContent": "this Mac's window restore",
        "appUpdate.lastNotifiedBuild": "which update this Mac has already offered",
        "whatsNew.lastSeenBuild": "which What's New this Mac has shown; each Mac updates on its own schedule",
        "managedAI.comp.textRouter": "cache of server-held account state",
        "managedAI.creditsAreEmpty": "cache of server-held account state",
        "youtube.hiddenChannels": "retired: migrated into the hidden-channels table, which syncs, and then removed",
        // One-shot markers and per-device bookkeeping. Resyncing one re-applies
        // something the receiving Mac has already done or must do itself.
        "CloudKitSync.lastContainerEnvironment.v2": "which container this Mac last synced against",
        "CloudKitSync.lastContainerIdentifier.v1": "which container this Mac last synced against",
        "CloudKitSync.didRepublishBookCovers.v4": "one-shot republish marker for this Mac",
        "CloudKitSync.didRepublishMeetingIcons.v1": "one-shot republish marker for this Mac",
        "CloudKitSync.didRepublishPaperThumbnails.v1": "one-shot republish marker for this Mac",
        "StorageService.didAdoptBookFolderNames.v1": "one-shot adoption marker",
        "foreverlm.retiredMethodPreferenceKeysAdopted.v1": "one-shot adoption marker",
        "keychain.retiredProductFileVaultAdopted": "one-shot adoption marker",
        "retiredReminderNotificationsCleared.v1": "one-shot cleanup marker",
        RetiredQuestionCalibration.clearedKey: "one-shot cleanup marker",
        RetiredDefaultsCleanup.completionKey: "one-shot cleanup marker: this Mac's preferences hold no retired keys",
        // Synced until 2026-09-27: the question calibration the chat's thumbs
        // fed. Nothing reads it, and `RetiredQuestionCalibration` clears the
        // stored copy once; excluded so an older Mac writing it again never
        // brings it back into this Mac's defaults.
        RetiredQuestionCalibration.preferenceKey: "retired with the chat's thumbs; cleared once, never read",
        // Synced until 2026-09-28: the Quiz me switch on a video's transcript
        // bar. The checkpoint quiz it turned on is gone (a course quiz is taken
        // in a chat), so nothing reads it.
        "reader.videoQuizCheckpoints": "retired with the video checkpoint quiz; never read",
        // Synced until 2026-10-03: the notebooks taken off the rail, when
        // every notebook was on it unless taken off. The rail lists the
        // learner's explicit pins now (`NotebookPins`), so nothing reads it,
        // and schema v2 maps the pins, not this.
        StudioViewModel.unpinnedNotebooksPreferenceKey: "retired with the rail that listed every notebook; never read",

        // Transient window state.
        "studio.chatPoppedOut": "transient window state",
        "studio.readerPoppedOut": "transient window state",
        "studio.recordingPrivacyCutoff": "retired user-facing recording privacy boundary",

        // Whether this Mac holds off idle sleep for scheduled tasks: a
        // decision about this Mac's power, which the other Mac makes for itself.
        ScheduledTaskWakePolicy.keepMacAwakeKey: "device-local: whether this Mac stays awake for scheduled tasks",

        // When this Mac last worked in each notebook: which notebook a new
        // window here opens in is this Mac's arrangement, like its windows,
        // and opening a notebook must write nothing that travels.
        NotebookRecency.preferenceKey: "device-local: the notebook each new window on this Mac opens in",
        // How the iPhone's and iPad's Home draws and orders the notebooks:
        // Grid or List, the sort and its direction. The view of the catalog on
        // that device's screen. The Mac's Notebooks home, which read the same
        // keys, went on 2026-10-09; the Space keeps its own (`space.layout`,
        // `space.sort`).
        NotebooksHomeLayout.preferenceKey: "device-local: Grid or List on this device's Home",
        NotebooksHomeOrder.sortPreferenceKey: "device-local: the sort on this device's Home",
        NotebooksHomeOrder.reversedPreferenceKey: "device-local: the sort's direction on this device's Home",
        // The Space (docs/docs-design.md, "The Space"): what this Mac opened
        // last, which opening a page must not make travel, and how this Mac's
        // screen draws the lists and the sidebar.
        "space.recents.v1": "device-local: the Space sidebar's Recents on this Mac",
        "space.layout": "device-local: List or Grid in this Mac's Space",
        "space.sort": "device-local: the sort in this Mac's Space",
        "space.groupByCollection": "device-local: whether this Mac's Space groups All under its collections",
        "space.sidebarHidden": "device-local: whether this Mac's Space sidebar is hidden",
        "space.pagesExpanded": "device-local: which pages' subpages this Mac's Space lists show",

        // Which of this Mac's preference writes knowledge.db has not confirmed.
        PreferenceWriteJournal.defaultsKey: "bookkeeping for this Mac's own unfinished writes",

        // Superseded by `tts_provider`, which is synced. Keeping both would give
        // one setting two rows racing over last-write-wins.
        "macos.tts.mode": "legacy fallback for tts_provider",
    ]

    /// Prefixes that never sync.
    static let excludedPrefixes: [String] = [
        "NSWindow Frame",       // AppKit window geometry — ~180 of these in the plist
        "NSSplitView",          // AppKit splitter geometry
        "NSNavPanel",           // AppKit open/save panel state
        "NSOSPLastRootDirectory",
        "studio.movableOverlay.", // dragged overlay positions, absolute pixels
        "screenRecordMode.",    // admin-only filming scope; must reach no other device or account
        "securityBookmark_",    // security-scoped bookmarks are machine-local
        "aiPricing.",           // remote price cache, ~50 KB
        "aiCapabilities.",      // remote capability cache, refetched
        "x_bookmarks_",         // sync cursor
        "ai.usage.ledger_",     // diagnostics counters
        "usage_daily_total_",   // cache
        "usage_records_",       // cache
        "billing_trial_start_", // anti-tamper
        "ios.",                 // iOS-local; reader progress must never sync back
        "openai_slides_skill_", // cache
        // Foreign domains that land in our plist.
        "CK", "SU", "SK", "com.apple.", "kAOSUI",
    ]

    // MARK: - Lookup

    /// Whether a key is a synced user preference. Exclusions win over prefix matches.
    static func isSynced(_ key: String) -> Bool {
        isSynced(key, for: ForeverLMRuntimeIdentity.syncGeneration)
    }

    /// Whether a key is a synced user preference under a generation.
    static func isSynced(_ key: String, for generation: SyncGeneration) -> Bool {
        if excluded[key] != nil { return false }
        if excludedPrefixes.contains(where: { key.hasPrefix($0) }) { return false }
        if generation2OnlyKeys.contains(key) { return generation == .two }
        if synced.contains(key) { return generation == .one || !generation2MovedKeys.contains(key) }
        return syncedPrefixes(for: generation).contains(where: { key.hasPrefix($0) })
    }

    /// The exact keys that sync under generation 2 only: Settings of features generation 1 does not
    /// have, so a generation-1 build neither shows them nor syncs them (schema v2 D40). Whether a new
    /// notebook gets its AI-drawn cover, and whether the cover backfill runs
    /// (`MacImageGenerationSettings.automaticForNewNotebooksKey`, D53): a spending decision, so it
    /// follows the account.
    static let generation2OnlyKeys: Set<String> = [
        "images.drawNotebookCovers.automatic",
    ]

    /// The exact keys that are no synced preference under generation 2, each with the record that holds
    /// it there and a writer that keeps that record: the import-blocked shows (`Mark(importBlocked)`,
    /// `BlockedShowsSync`), and the rail's order, pins and folds (`NotebookState.sidebarKey`, `pinned`,
    /// `expanded`; `NotebookSidebarSync`).
    static let generation2MovedKeys: Set<String> = [
        SourceDiscovery.blockedPodcastShowsPreferenceKey,
        "studio.projectOrder", NotebookPins.preferenceKey, "studio.navigation.expandedProjectIDs.v1",
    ]

    /// Whether a key is a `Setting` record of its own under generation 2 (schema v2 §3.5.3): a synced
    /// key that no record took over. The keys and prefixes that became fields of records (§10, the
    /// settings catalog's `records`) are never Settings, whether or not their rows still exist for the
    /// writers that read them.
    static func isSetting(_ key: String) -> Bool {
        guard !recordKeys.contains(key), !recordPrefixes.contains(where: { key.hasPrefix($0) }) else { return false }
        return isSynced(key, for: .two)
    }

    /// The exact keys whose rows became fields of records (schema v2 §10): the sidebar's order, pins and
    /// folds (`NotebookState.sidebarKey`, `pinned`, `expanded`) and the import-blocked shows
    /// (`Mark(importBlocked)`).
    static let recordKeys: Set<String> = [
        "studio.projectOrder", NotebookPins.preferenceKey, "studio.navigation.expandedProjectIDs.v1",
        SourceDiscovery.blockedPodcastShowsPreferenceKey,
    ]

    /// The prefixes whose rows became fields of records (schema v2 §10): NotebookState's and Enrollment's,
    /// a narration's resume point (`ReadingState.listen`), a deck's card state (`Card`), the quiz scores
    /// (`Sitting`) and a connector's health (`Device.connectorHealth`).
    static let recordPrefixes: [String] = notebookStatePrefixes + enrollmentPrefixes + [
        ListeningPositionSync.preferenceKeyPrefix, MemoryCardDeckState.preferenceKeyPrefix,
        LectureQuizScore.preferenceKeyPrefix, LectureQuizScore.courseQuizPreferenceKeyPrefix,
    ] + devicePrefixes

    /// The domain prefixes whose rows became fields of the member's `NotebookState` (schema v2 §10,
    /// §3.5.20): under generation 2 they are no preference rows any more.
    static let notebookStatePrefixes: [String] = [
        NotebookChatSelection.preferenceKeyPrefix,
        NotebookChatContext.preferenceKeyPrefix,
        NotebookCollections.membershipPreferenceKeyPrefix,
    ]

    /// The domain prefix whose rows became the member's `Enrollment` records (schema v2 §10, §3.5.12): a
    /// course's focus. Under generation 2 it is no preference row any more.
    static let enrollmentPrefixes: [String] = [
        LearnerProfile.courseFocusPreferenceKeyPrefix,
    ]

    /// The domain prefixes whose rows became fields of the member's `ReadingState` (schema v2 §10,
    /// §3.5.18): the narration's resume point is `ReadingState.listen` under generation 2.
    static let readingStatePrefixes: [String] = [
        ListeningPositionSync.preferenceKeyPrefix,
    ]

    /// The domain prefix whose rows became this Mac's `Device.connectorHealth` (schema v2 §10, §3.5.2):
    /// under generation 2 a connector's health stays in this Mac's `UserDefaults` and its Device record.
    static let devicePrefixes: [String] = [
        "connectorHealth.",
    ]

    /// The synced prefixes under a generation: generation 1's whole list; generation 2 leaves out the
    /// prefixes that moved into records (§14.1).
    static func syncedPrefixes(for generation: SyncGeneration) -> [String] {
        generation == .one
            ? syncedPrefixes
            : syncedPrefixes.filter {
                !notebookStatePrefixes.contains($0) && !enrollmentPrefixes.contains($0) && !readingStatePrefixes.contains($0)
                    && !devicePrefixes.contains($0)
            }
    }
}
