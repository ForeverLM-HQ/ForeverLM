import Foundation

// Generated for step 0 of the typed settings layer from the key census; kept by hand from here on.
// A name is the stored string and is frozen (`UnitTests/Fixtures/preference-keys.golden.json`).

extension Prefs {
    /// Updates, one-time markers, sync bookkeeping and screen record mode.
    enum Lifecycle {
        /// Signed up for beta releases (`BetaReleases`, Mac only): a choice the
        /// learner makes once for the account, so every Mac of theirs follows it.
        static let betaReleases = AccountKey<Bool>("updates.betaReleases", default: false)
        static let runningBuildIsBeta = DeviceKey<Any?>("updates.runningBuildIsBeta.v1", coding: .any, reason: "which channel the build running on this Mac came from")
        static let installerKeptImagePaths = DeviceKey<[String]?>("installer.keptImagePaths", reason: "installer images on this Mac's disk")
        static let appUpdateLastNotifiedBuild = DeviceKey<Any?>("appUpdate.lastNotifiedBuild", coding: .any, reason: "which update this Mac has already offered")
        static let whatsNewLastSeenBuild = DeviceKey<Any?>("whatsNew.lastSeenBuild", coding: .any, reason: "which What's New this Mac has shown; each Mac updates on its own schedule")
        static let bookFolderNamesAdopted = DeviceKey<Bool?>("StorageService.didAdoptBookFolderNames.v1", reason: "one-shot adoption marker")
        static let retiredFileVaultAdopted = DeviceKey<Bool?>("keychain.retiredProductFileVaultAdopted", reason: "one-shot adoption marker")
        static let retiredReminderNotificationsCleared = DeviceKey<Bool?>("retiredReminderNotificationsCleared.v1", reason: "one-shot cleanup marker")
        static let retiredQuestionCalibrationCleared = DeviceKey<Bool?>("retiredQuestionCalibrationCleared.v1", reason: "one-shot cleanup marker")
        static let retiredDefaultsCleanupDone = DeviceKey<Any?>("retiredDefaultsCleanup.v2", coding: .any, reason: "one-shot cleanup marker: this device's preferences hold no retired keys")
        static let retiredProviderDataPurged = DeviceKey<Bool?>("retiredProviderDataPurged.v1", reason: "one-shot cleanup marker")
        static let retiredGoogleCalendarGrantsPurged = DeviceKey<Bool?>("retiredGoogleCalendarGrantsPurged.v1", reason: "one-shot cleanup marker")
        /// One-shot markers and per-device bookkeeping. Resyncing one re-applies
        /// something the receiving Mac has already done or must do itself.
        static let syncLastContainerEnvironment = DeviceKey<Any?>("CloudKitSync.lastContainerEnvironment.v2", coding: .any, reason: "which container this Mac last synced against")
        static let syncLastContainerIdentifier = DeviceKey<Any?>("CloudKitSync.lastContainerIdentifier.v1", coding: .any, reason: "which container this Mac last synced against")
        static let syncDidRepublishBookCovers = DeviceKey<Any?>("CloudKitSync.didRepublishBookCovers.v4", coding: .any, reason: "one-shot republish marker for this Mac")
        static let syncDidRepublishMeetingIcons = DeviceKey<Any?>("CloudKitSync.didRepublishMeetingIcons.v1", coding: .any, reason: "one-shot republish marker for this Mac")
        static let syncDidRepublishPaperThumbnails = DeviceKey<Any?>("CloudKitSync.didRepublishPaperThumbnails.v1", coding: .any, reason: "one-shot republish marker for this Mac")
        static let spaceLastOpenedAtByTeam = DeviceKey<[String: Any]?>("sync.spaceLastOpenedAtByTeam", coding: .dictionary, reason: "when this device last opened each team space; orders its own fetches")
        /// Which of this Mac's preference writes knowledge.db has not confirmed.
        static let unconfirmedPreferenceWrites = DeviceKey<Any?>("preferenceStore.unconfirmedWrites", coding: .any, reason: "bookkeeping for this Mac's own unfinished writes")
        /// One-shot markers. Resyncing one re-applies a default the user overrode.
        static let retiredPendingMigrationDone = DeviceKey<Any?>.unread("pendingMigrationV1Done", reason: "one-shot marker")
        /// Machine identity, plus retired one-time-license/trial keys kept excluded
        /// so any values left in an existing install never start syncing.
        static let retiredLicenseActivationDeviceID = DeviceKey<Any?>.unread("license.activationDeviceID", reason: "identifies this Mac (retired license rail)")
        static let retiredLicenseFallbackDeviceID = DeviceKey<Any?>.unread("license.fallbackDeviceID", reason: "identifies this Mac (retired license rail)")
        static let retiredTrialStartDate = DeviceKey<Any?>.unread("trial.startDate", reason: "retired 7-day-trial marker; stays out of the sync rail")
        /// Synced until 2026-09-27: the question calibration the chat's thumbs
        /// fed. Nothing reads it, and `RetiredQuestionCalibration` clears the
        /// stored copy once; excluded so an older Mac writing it again never
        /// brings it back into this Mac's defaults.
        static let retiredQuestionCalibration = DeviceKey<Any?>.unread("review.questionCalibration.v1", reason: "retired with the chat's thumbs; cleared once, never read")
        static let screenRecordEnabled = DeviceKey<Bool>("screenRecordMode.enabled", default: false, reason: "admin-only filming scope; must reach no other device or account")
        static let screenRecordConfirmedAdmin = DeviceKey<Bool>("screenRecordMode.confirmedAdmin", default: false, reason: "admin-only filming scope; must reach no other device or account")
        static let screenRecordLibrarySources = DeviceKey<Bool>("screenRecordMode.librarySources", default: false, reason: "admin-only filming scope; must reach no other device or account")
        static let screenRecordNotebookID = DeviceKey<String>("screenRecordMode.notebookID", default: "", reason: "admin-only filming scope; must reach no other device or account")
        static let screenRecordCutoff = DeviceKey<Date?>("screenRecordMode.cutoff", reason: "admin-only filming scope; must reach no other device or account")
        static let screenRecordImageIDs = DeviceKey<[String]?>("screenRecordMode.imageIDs", reason: "admin-only filming scope; must reach no other device or account")
        static let screenRecordSourceIDs = DeviceKey<[String]?>("screenRecordMode.sourceIDs", reason: "admin-only filming scope; must reach no other device or account")
        static let screenRecordMeetingGroupIDs = DeviceKey<[String]?>("screenRecordMode.meetingGroupIDs", reason: "admin-only filming scope; must reach no other device or account")

        static let all: [AnyPreferenceKey] = [
            betaReleases.erased,
            runningBuildIsBeta.erased,
            installerKeptImagePaths.erased,
            appUpdateLastNotifiedBuild.erased,
            whatsNewLastSeenBuild.erased,
            bookFolderNamesAdopted.erased,
            retiredFileVaultAdopted.erased,
            retiredReminderNotificationsCleared.erased,
            retiredQuestionCalibrationCleared.erased,
            retiredDefaultsCleanupDone.erased,
            retiredProviderDataPurged.erased,
            retiredGoogleCalendarGrantsPurged.erased,
            syncLastContainerEnvironment.erased,
            syncLastContainerIdentifier.erased,
            syncDidRepublishBookCovers.erased,
            syncDidRepublishMeetingIcons.erased,
            syncDidRepublishPaperThumbnails.erased,
            spaceLastOpenedAtByTeam.erased,
            unconfirmedPreferenceWrites.erased,
            retiredPendingMigrationDone.erased,
            retiredLicenseActivationDeviceID.erased,
            retiredLicenseFallbackDeviceID.erased,
            retiredTrialStartDate.erased,
            retiredQuestionCalibration.erased,
            screenRecordEnabled.erased,
            screenRecordConfirmedAdmin.erased,
            screenRecordLibrarySources.erased,
            screenRecordNotebookID.erased,
            screenRecordCutoff.erased,
            screenRecordImageIDs.erased,
            screenRecordSourceIDs.erased,
            screenRecordMeetingGroupIDs.erased,
        ]
    }
}
