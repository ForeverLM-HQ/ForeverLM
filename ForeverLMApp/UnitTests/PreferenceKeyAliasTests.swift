import Foundation
import Testing
@testable import ForeverLM

#if os(macOS)

/// Until every call site reads its key from `Prefs`, the constants the features
/// declared before the typed layer stay, and each must spell the same stored
/// string as its declaration. A failure here means one of the two was edited
/// alone: the stored name is frozen, so put the constant back.
///
/// The list was generated with the declarations and shrinks as the batches
/// delete the old constants; a constant that is private to its file, or that
/// only the iPhone target compiles, is held to its declaration by the golden
/// key file instead.
@Suite("Preference key aliases")
@MainActor
struct PreferenceKeyAliasTests {

    static let keys: [(declared: String, constant: String)] = [
        (Prefs.Account.displayName.name, MacAccountUser.displayNamePreferenceKey),
        (Prefs.Account.aboutYou.name, LearnerProfile.aboutYouPreferenceKey),
        (Prefs.Models.ttsProvider.name, ArticleSpeechSelection.syncedProviderKey),
        (Prefs.Models.ttsModelOpenRouter.name, ArticleSpeechSelection.syncedModelKey),
        (Prefs.Models.backgroundUsageConsented.name, KeychainService.backgroundAIUsageConsentKey),
        (Prefs.Models.meetingsMayUseFree.name, MeetingModels.mayUseFreeKey),
        (Prefs.Models.chatRecentModels.name, ChatRecentModels.defaultsKey),
        (Prefs.Spend.backgroundDailyCapUSD.name, BackgroundAIDailyCap.preferenceKey),
        (Prefs.ReadAloud.costConfirmationSuppressedModels.name, TextToSpeechCostConfirmationPreferences.suppressedModelIDsKey),
        (Prefs.ReadAloud.openRouterVoice.name, ArticleSpeechSelection.syncedVoiceKey),
        (Prefs.ReadAloud.autoGenerateAllowPaidVoices.name, SourceAudioAutomation.paidVoiceConsentPreferenceKey),
        (Prefs.Imaging.drawNotebookCoversAutomatic.name, MacImageGenerationSettings.automaticForNewNotebooksKey),
        (Prefs.Studio.excludedKnowledgeSourceTabs.name, StudioSidebarTab.knowledgeExclusionPreferenceKey),
        (Prefs.Studio.chatOrder.name, StudioViewModel.chatOrderPreferenceKey),
        (Prefs.Studio.pinnedNotebooks.name, NotebookPins.preferenceKey),
        (Prefs.Studio.integrationTabUnpinDefaultsApplied.name, StudioSidebarTab.integrationUnpinAppliedPreferenceKey),
        (Prefs.Studio.integrationTabsUnpinnedByDefault.name, StudioSidebarTab.autoUnpinnedIntegrationTabsPreferenceKey),
        (Prefs.Studio.lastSessionWindows.name, StudioLastSessionStore.preferenceKey),
        (Prefs.Studio.lastSessionResumesContent.name, StudioLastSessionStore.resumeContentKey),
        (Prefs.Studio.activeTeamID.name, StudioViewModel.activeTeamPreferenceKey),
        (Prefs.Studio.chatUnreadMarks.name, ChatReadMarks.defaultsKey),
        (Prefs.Studio.retiredUnpinnedNotebooks.name, StudioViewModel.unpinnedNotebooksPreferenceKey),
        (Prefs.Rail.hiddenItems.name, StudioRailHiddenItems.storageKey),
        (Prefs.Rail.aiSubscriptions.name, AISubscription.storageKey),
        (Prefs.Rail.slowFreeModelOfferDismissed.name, SlowFreeModelWait.dismissedKey),
        (Prefs.Readers.pageColumnWidth.name, ArtifactPageWidth.key),
        (Prefs.Readers.outlineFolds.name, ArtifactOutlineFolds.key),
        (Prefs.Readers.webLinksOpenIn.name, WebLinkOpening.preferenceKey),
        (Prefs.Space.recents.name, SpaceRecents.preferenceKey),
        (Prefs.Space.layout.name, SpaceLayout.preferenceKey),
        (Prefs.Space.sort.name, SpaceSort.preferenceKey),
        (Prefs.Space.groupByCollection.name, SpaceLayout.groupsByCollectionKey),
        (Prefs.Space.notebooksHomeLayout.name, NotebooksHomeLayout.preferenceKey),
        (Prefs.Space.notebooksHomeSort.name, NotebooksHomeOrder.sortPreferenceKey),
        (Prefs.Space.notebooksHomeSortReversed.name, NotebooksHomeOrder.reversedPreferenceKey),
        (Prefs.Space.notebookLastWorked.name, NotebookRecency.preferenceKey),
        (Prefs.KnowledgeMap.summaryCache.name, KnowledgeMapSummaries.cacheKey),
        (Prefs.Memory.newCardsPerDay.name, MemoryCardSettings.newCardsPerDayKey),
        (Prefs.Memory.autoDraftCards.name, MemoryCardSettings.autoDraftKey),
        (Prefs.Memory.draftNudges.name, MemoryCardSettings.draftNudgesKey),
        (Prefs.Memory.budgetMinutes.name, MemoryReviewBudget.preferenceKey),
        (Prefs.Readers.notebookSourcesColumnWidth.name, NotebookWorkspaceSizing.sourcesWidthPreferenceKey),
        (Prefs.Discovery.readingListImportSince.name, SourceDiscovery.ReadingListImportWindow.sinceKey),
        (Prefs.Discovery.readingListImportWindow.name, SourceDiscovery.ReadingListImportWindow.windowKey),
        (Prefs.Memory.dailyPreparationEnabled.name, DailyReviewPreparation.enabledKey),
        (Prefs.Memory.workingNotesEnabled.name, WorkingNotesPreference.enabledKey),
        (Prefs.Memory.dailyPreparationHour.name, DailyReviewPreparation.hourKey),
        (Prefs.Memory.ideaExtractionFailures.name, SourceIdeaExtractionFailures.key),
        (Prefs.Memory.reviewLayout.name, MemoryReviewLayout.storageKey),
        (Prefs.Planner.dayStart.name, PlannerDayHours.startKey),
        (Prefs.Planner.dayEnd.name, PlannerDayHours.endKey),
        (Prefs.Planner.thinkFirstLevel.name, ThinkFirst.levelKey),
        (Prefs.Planner.suggestPlanningTheDay.name, PlanTheDay.settingKey),
        (Prefs.Planner.forcePlanningTheDay.name, PlanTheDay.forcedKey),
        (Prefs.Planner.nudgeBackOnTrack.name, FocusWatch.settingKey),
        (Prefs.Planner.focusReadsScreen.name, FocusWatch.readsScreenKey),
        (Prefs.Planner.thinkFirstCounts.name, ThinkFirstTally.countsKey),
        (Prefs.Planner.thinkFirstAskedSources.name, ThinkFirstAskedSources.preferenceKey),
        (Prefs.Planner.activityPaneLayout.name, DayActivityLayout.storageKey),
        (Prefs.Planner.quickAssistantShortcut.name, QuickAssistantShortcut.storageKey),
        (Prefs.Planner.calendarGroups.name, CalendarGroups.defaultsKey),
        (Prefs.Planner.loadingIndicatorSpeed.name, LoadingIndicatorSpeed.key),
        (Prefs.Discovery.applePodcastDiscoveryScope.name, ApplePodcastDiscoveryScope.defaultsKey),
        (Prefs.Discovery.blockedPodcastShows.name, SourceDiscovery.blockedPodcastShowsPreferenceKey),
        (Prefs.Discovery.browserAccessPromptDismissed.name, StudioViewModel.browserAccessPromptDismissedKey),
        (Prefs.Meetings.removedGroupTitles.name, StudioViewModel.removedMeetingGroupTitlesKey),
        (Prefs.Meetings.removedGroupIdentities.name, StudioViewModel.removedMeetingGroupIdentitiesKey),
        (Prefs.Meetings.transcribeWhenGoogleDidNot.name, StudioViewModel.meetingOwnTranscriptionEnabledKey),
        (Prefs.Lifecycle.betaReleases.name, BetaReleases.preferenceKey),
        (Prefs.Lifecycle.runningBuildIsBeta.name, RunningBuildChannel.preferenceKey),
        (Prefs.Lifecycle.screenRecordEnabled.name, ScreenRecordMode.enabledKey),
        (Prefs.Lifecycle.screenRecordConfirmedAdmin.name, ScreenRecordMode.confirmedAdminKey),
        (Prefs.Lifecycle.screenRecordLibrarySources.name, ScreenRecordMode.librarySourcesKey),
        (Prefs.Lifecycle.screenRecordNotebookID.name, ScreenRecordMode.notebookIDKey),
        (Prefs.Lifecycle.screenRecordCutoff.name, ScreenRecordMode.cutoffKey),
        (Prefs.Lifecycle.screenRecordImageIDs.name, ScreenRecordMode.imageIDsKey),
        (Prefs.Lifecycle.screenRecordSourceIDs.name, ScreenRecordMode.sourceIDsKey),
        (Prefs.Lifecycle.screenRecordMeetingGroupIDs.name, ScreenRecordMode.meetingGroupIDsKey),
        (Prefs.MCP.pageSideChatDock.name, PageSideChatDock.key),
        (Prefs.Mobile.lastOpenedNotebookID.name, MobileNotebookResume.defaultsKey),
        (Prefs.Mobile.readAloudModel.name, ArticleSpeechSelection.modelDefaultsKey),
        (Prefs.Mobile.spaceRecents.name, MobileSpaceRecents.preferenceKey),
    ]

    static let families: [(declared: String, constant: String)] = [
        (Prefs.Families.openRouterHost.prefix, OpenRouterHostPreference.keyPrefix),
        (Prefs.Families.aiBackups.prefix, AIBackupModels.keyPrefix),
        (Prefs.Families.courseQuizScore.prefix, LectureQuizScore.courseQuizPreferenceKeyPrefix),
        (Prefs.Families.courseFocus.prefix, LearnerProfile.courseFocusPreferenceKeyPrefix),
        (Prefs.Families.chatPins.prefix, ChatPins.preferenceKeyPrefix),
        (Prefs.Families.notebookThinkFirst.prefix, ThinkFirst.notebookKeyPrefix),
    ]

    /// The model-selection rows are `KeychainService.Key` raw values that moved
    /// out of the Keychain: the raw value is the stored name.
    static let keychainBacked: [(declared: String, constant: String)] = [
        (Prefs.Models.aiProvider.name, KeychainService.Key.aiProvider.rawValue),
        (Prefs.Models.anthropicModel.name, KeychainService.Key.anthropicModel.rawValue),
        (Prefs.Models.openAIModel.name, KeychainService.Key.openAIModel.rawValue),
        (Prefs.Models.groqModel.name, KeychainService.Key.groqModel.rawValue),
        (Prefs.Models.cerebrasModel.name, KeychainService.Key.cerebrasModel.rawValue),
        (Prefs.Models.xaiModel.name, KeychainService.Key.xaiModel.rawValue),
        (Prefs.Models.geminiModel.name, KeychainService.Key.geminiModel.rawValue),
        (Prefs.Models.metaModel.name, KeychainService.Key.metaModel.rawValue),
        (Prefs.Models.togetherModel.name, KeychainService.Key.togetherModel.rawValue),
        (Prefs.Models.fireworksModel.name, KeychainService.Key.fireworksModel.rawValue),
        (Prefs.Models.nvidiaModel.name, KeychainService.Key.nvidiaModel.rawValue),
        (Prefs.Models.openRouterModel.name, KeychainService.Key.openRouterModel.rawValue),
        (Prefs.Models.sttProvider.name, KeychainService.Key.sttProvider.rawValue),
        (Prefs.Models.sttModelOpenAI.name, KeychainService.Key.sttModelOpenAI.rawValue),
        (Prefs.Models.sttModelGroq.name, KeychainService.Key.sttModelGroq.rawValue),
        (Prefs.Models.sttModelOpenRouter.name, KeychainService.Key.sttModelOpenRouter.rawValue),
        (Prefs.Models.sttModelWispr.name, KeychainService.Key.sttModelWispr.rawValue),
        (Prefs.Models.sttModelWhisperKit.name, KeychainService.Key.sttModelWhisperKit.rawValue),
        (Prefs.Models.sttModelAssemblyAI.name, KeychainService.Key.sttModelAssemblyAI.rawValue),
        (Prefs.Models.sttModelCartesia.name, KeychainService.Key.sttModelCartesia.rawValue),
        (Prefs.Models.sttModelTailscale.name, KeychainService.Key.sttModelTailscale.rawValue),
        (Prefs.Models.sttLocalServerURL.name, KeychainService.Key.sttLocalServerURL.rawValue),
        (Prefs.Models.ttsProvider.name, KeychainService.Key.ttsProvider.rawValue),
        (Prefs.Models.ttsModelApple.name, KeychainService.Key.ttsModelApple.rawValue),
        (Prefs.Models.ttsModelOpenAI.name, KeychainService.Key.ttsModelOpenAI.rawValue),
        (Prefs.Models.ttsModelGroq.name, KeychainService.Key.ttsModelGroq.rawValue),
        (Prefs.Models.ttsModelElevenLabs.name, KeychainService.Key.ttsModelElevenLabs.rawValue),
        (Prefs.Models.ttsModelTogetherAI.name, KeychainService.Key.ttsModelTogetherAI.rawValue),
        (Prefs.Models.ttsModelLocalMac.name, KeychainService.Key.ttsModelLocalMac.rawValue),
        (Prefs.Models.ttsModelXAI.name, KeychainService.Key.ttsModelXAI.rawValue),
        (Prefs.Models.ttsModelOpenRouter.name, KeychainService.Key.ttsModelOpenRouter.rawValue),
        (Prefs.Models.ttsModelGemini.name, KeychainService.Key.ttsModelGemini.rawValue),
        (Prefs.Models.ttsModelCartesia.name, KeychainService.Key.ttsModelCartesia.rawValue),
        (Prefs.Models.ttsModelTailscale.name, KeychainService.Key.ttsModelTailscale.rawValue),
        (Prefs.Models.ttsLocalServerURL.name, KeychainService.Key.ttsLocalServerURL.rawValue),
        (Prefs.Models.sttModelMedia.name, KeychainService.Key.sttModelMedia.rawValue),
    ]

    @Test("Each constant from before the typed layer equals its declaration's stored name")
    func constantsEqualTheirDeclarations() {
        #expect(!Self.keys.isEmpty)
        for pair in Self.keys {
            #expect(pair.declared == pair.constant)
        }
    }

    @Test("Each family prefix constant equals its declaration's prefix")
    func prefixConstantsEqualTheirDeclarations() {
        #expect(!Self.families.isEmpty)
        for pair in Self.families {
            #expect(pair.declared == pair.constant)
        }
    }

    @Test("Each preference-backed Keychain key's raw value is its declaration's stored name")
    func keychainRawValuesEqualTheirDeclarations() {
        #expect(Self.keychainBacked.count > 30)
        for pair in Self.keychainBacked {
            #expect(pair.declared == pair.constant)
        }
    }

    @Test("A key that both platforms name keeps its portable constant")
    func portableConstantsEqualTheirDeclarations() {
        #expect(Prefs.Memory.dailyPreparationEnabled.name == DailyReviewPreparationKeys.enabled)
        #expect(Prefs.Memory.budgetMinutes.name == MemoryReviewBudget.preferenceKey)
        #expect(Prefs.Memory.newCardsPerDay.name == MemoryCardQueue.newPerDayPreferenceKey)
    }
}

#endif
