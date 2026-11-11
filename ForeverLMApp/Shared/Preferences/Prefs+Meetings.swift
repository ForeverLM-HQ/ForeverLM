import Foundation

// Generated for step 0 of the typed settings layer from the key census; kept by hand from here on.
// A name is the stored string and is frozen (`UnitTests/Fixtures/preference-keys.golden.json`).

extension Prefs {
    /// Meetings and local recordings.
    enum Meetings {
        static let userGroupNames = AccountKey<[String]?>("userMeetingGroupNames")
        /// Removal tombstones: meeting groups the user deleted. Must sync, or a
        /// background or MCP-driven import on the other Mac resurrects the group
        /// and syncs it straight back to the Mac that removed it.
        static let removedGroupTitles = AccountKey<[String]?>("meetings.removedGroupTitles")
        static let removedGroupIdentities = AccountKey<[String]?>("meetings.removedGroupIdentities")
        /// Whether ForeverLM may transcribe a meeting recording itself instead of
        /// importing the transcript Google wrote. A spending decision, so it must
        /// follow the account: leaving it device-local means the other Mac opens
        /// the same meeting and bills a transcription the learner turned off here.
        static let transcribeWhenGoogleDidNot = AccountKey<Bool>("meetings.transcribeWhenGoogleDidNot", default: false)
        /// Where Zoom saves captions is a Zoom setting, and its default,
        /// `~/Documents/Zoom`, is not always somewhere the transcripts should
        /// live: `~/Documents` can be a symlink into cloud storage someone else
        /// controls. Moving Zoom's folder has to be possible without ingestion
        /// silently stopping, so the folder is a preference and both it and the
        /// default are watched. A path is a fact about one Mac, so it never syncs.
        static let zoomLocalTranscriptFolder = DeviceKey<String?>("studio.zoomLocalTranscriptFolder", reason: "a folder on this Mac's disk")
        /// Recording folders the learner said to leave alone: a meeting that did
        /// not happen, a recording not worth transcribing. A folder that is gone
        /// drops out on the next write.
        static let zoomLocalRecordingIgnoredFolders = DeviceKey<[String]?>("studio.zoomLocalRecordingIgnoredFolders", reason: "folders on this Mac's disk")
        /// Folder path to the automatic conversions made, pruned of folders that are gone.
        static let zoomLocalRecordingAutoConversions = DeviceKey<[String: Any]?>("studio.zoomLocalRecordingAutoConversions", coding: .dictionary, reason: "which of this Mac's recordings it has already converted")
        static let retiredZoomLocalRecordingConversionRequests = DeviceKey<Any?>.unread("studio.zoomLocalRecordingConversionRequests", reason: "the retired per-launch request counter, cleared on the next pass")

        static let all: [AnyPreferenceKey] = [
            userGroupNames.erased,
            removedGroupTitles.erased,
            removedGroupIdentities.erased,
            transcribeWhenGoogleDidNot.erased,
            zoomLocalTranscriptFolder.erased,
            zoomLocalRecordingIgnoredFolders.erased,
            zoomLocalRecordingAutoConversions.erased,
            retiredZoomLocalRecordingConversionRequests.erased,
        ]
    }
}
