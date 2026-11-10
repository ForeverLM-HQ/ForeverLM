import Foundation
import CryptoKit
import Observation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import SwiftUI
import AppKit
import SQLite3
import WebKit
import Darwin

/// Immutable parsers shared by course-title normalization. These used to be
/// compiled inside the per-video helpers below, which made a 500-item YouTube
/// refresh spend seconds compiling the same ICU programs on the main actor.
private enum CourseTitleParserCache {
    private static let lessonLabel = #"(?:lecture|lec|chapter|chap|ch|session|week|class|unit|section)"#

    static let materialPartRegexes: [NSRegularExpression] = [
        #"(?i)\b\#(lessonLabel)\s*[_#.:\\-–—]*\s*(\d{1,3})\s*(?:[_#.:\\-–—]\s*)?part\s*[_#.:\\-–—]*\s*([a-z]|\d{1,2})\b"#,
        #"(?i)\b\#(lessonLabel)\s*[_#.:\\-–—]*\s*(\d{1,3})([a-z])\b"#,
        #"(?i)\b\#(lessonLabel)\s*[_#.:\\-–—]*\s*(\d{1,3})\s+([a-z])\s*(?:[\)_#.:\\-–—]|$)"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static let materialRegexes: [(kind: String, regex: NSRegularExpression)] = [
        ("lesson", #"(?i)\b(?:lecture|lec|chapter|chap|ch|session|week|class|unit|section)\s*[_#.:\\-–—]*\s*(\d{1,3}(?:\.\d{1,2}|[a-z]\b)?)"#),
        ("assignment", #"(?i)\b(?:hw|homework|pset|problem\s*set|assignment)\s*[_#.:\\-–—]*\s*(\d{1,3})"#),
        ("worksheet", #"(?i)\b(?:worksheet|work\s*sheet|solutions?\s+to\s+worksheet)\s*[_#.:\\-–—]*\s*(\d{1,3})"#),
        ("lesson", #"(?i)^\s*(\d{1,3}(?:\.\d{1,2}|[a-z]\b)?)\s*[\)_#.:\\-–—\s]"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// A title that already opens with its own lecture ordinal. Deliberately
    /// strict: a row decides from this whether
    /// numbering the title would repeat a number the title already carries, so
    /// "3 Body Problem" must not read as lecture 3.
    static let displayLectureOrdinalPrefixes: [NSRegularExpression] = [
        // The normalized form `Prompts.courseLectureTitleCleanup` emits.
        #"^\s*\d{1,3}(?:[a-z]|\.\d{1,3})?\)\s*"#,
        // A title the cleanup never saw, still naming its own lecture number.
        // The hyphen is escaped with one backslash on purpose: `\\-` in a raw
        // string is a literal backslash followed by a range operator, which
        // widens the class to every character between "\" and "–".
        #"^\s*\#(lessonLabel)s?\s*[_#.:\-–—]*\s*\d{1,3}(?:[a-z]|\.\d{1,3})?\s*(?:[\)_#.:\-–—]\s*|\s)"#,
    ].map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    static let leadingDanglingSeparators = try! NSRegularExpression(
        pattern: #"^[\s/\\|:;,\-–—·•]+"#
    )
    static let trailingDanglingSeparators = try! NSRegularExpression(
        pattern: #"[\s/\\|:;,\-–—·•]+$"#
    )
    static let nonAlphanumeric = CharacterSet.alphanumerics.inverted
}

enum MeetingTranscriptError: LocalizedError {
    case sourceNotFound
    case notMeeting
    case noRecording
    case ownTranscriptionDisabled

    var errorDescription: String? {
        switch self {
        case .sourceNotFound: return "The meeting could not be found."
        case .notMeeting: return "Transcripts can only be generated for meeting sources."
        case .noRecording: return "This meeting has no recording."
        case .ownTranscriptionDisabled:
            return "Google has no transcript for this recording, and ForeverLM is set not to make one itself. "
                + "Turn on \"Transcribe recordings Google didn't\" in Plugins › Google Drive."
        }
    }
}

extension StudioViewModel {

    // MARK: - Meeting Collections

    var allMeetingGroupNames: [String] {
        var names = Set(meetingMetadata.compactMap { id, metadata in
            metadata.mergedIntoGroupID == nil ? id : nil
        })
        for article in activeArticles where article.sourceType == .meeting {
            if let group = article.parentGroup { names.insert(canonicalMeetingGroupID(group)) }
        }
        return Self.meetingGroupNamesSortedByFolderImage(
            Array(names),
            imageURL: { meetingFolderImageURL($0) },
            displayName: { meetingDisplayName($0) }
        )
    }

    /// Meeting series ordered so every folder wearing the same logo stands
    /// together, alphabetically inside its logo.
    ///
    /// The three Example Fellowship series are read as one shelf; a
    /// plain sort by title scattered them among the series whose names happen to
    /// fall in between. Each logo's run takes the position of its own first
    /// title, so the list stays broadly alphabetical and never depends on
    /// dictionary iteration order. Folders with no image are a run of their own
    /// under the same rule, which is the alphabetical order they always had.
    nonisolated static func meetingGroupNamesSortedByFolderImage(
        _ names: [String],
        imageURL: (String) -> String?,
        displayName: (String) -> String
    ) -> [String] {
        func precedes(_ lhs: String, _ rhs: String) -> Bool {
            switch displayName(lhs).localizedStandardCompare(displayName(rhs)) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs < rhs
            }
        }

        var runs: [String: [String]] = [:]
        for name in names { runs[imageURL(name) ?? "", default: []].append(name) }

        return runs
            .map { image, members in (image: image, members: members.sorted(by: precedes)) }
            .sorted { lhs, rhs in
                guard let lhsFirst = lhs.members.first, let rhsFirst = rhs.members.first else {
                    return lhs.image < rhs.image
                }
                if lhsFirst == rhsFirst { return lhs.image < rhs.image }
                return precedes(lhsFirst, rhsFirst)
            }
            .flatMap(\.members)
    }

    /// Screen record mode (`ScreenRecordScope`) keeps only the folders with a
    /// session on screen: a folder's name and logo are the learner's own even
    /// when every session in it is filtered out.
    var visibleMeetingGroupNames: [String] {
        let unhidden = allMeetingGroupNames.filter { !(meetingMetadata[$0]?.isHidden ?? false) }
        guard screenRecordScope != nil else { return unhidden }
        var filmed: Set<String> = []
        for article in activeArticles where article.sourceType == .meeting && isVisibleInRecordingMode(article) {
            if let group = article.parentGroup { filmed.insert(canonicalMeetingGroupID(group)) }
        }
        return unhidden.filter { filmed.contains($0) }
    }

    var filteredMeetingGroupNames: [String] {
        visibleMeetingGroupNames.filter {
            meetingMatchesSearch($0) && meetingGroupMatchesProviderFilter($0)
        }
    }

    /// Which providers feed a meeting series, in stable presentation order.
    ///
    /// A series can legitimately draw from more than one — a Drive recording of
    /// the weekly call plus Read AI's summary of the same hour — which is why
    /// this returns a list rather than one answer. The split Google Drive and
    /// Read AI tabs listed exactly that series twice, once under each; one tab
    /// shows it once, wearing both badges.
    ///
    /// Pass `sessions` when the caller already has the group's rows in hand —
    /// the sidebar does — so drawing a badge costs no extra scan of the library.
    ///
    /// A linked folder counts as a provider even with no sessions left to read
    /// an origin from, so a series whose sessions were all archived still says
    /// where it came from instead of going blank. Under the split tabs that same
    /// case belonged to no tab at all and rendered a never-connected empty
    /// state over a folder that was, in fact, connected.
    func meetingGroupProviders(
        _ groupName: String,
        sessions: [StudioArticle]? = nil
    ) -> [MeetingProvider] {
        let sessions = sessions ?? activeArticles.filter {
            $0.sourceType == .meeting
                && $0.parentGroup.map(canonicalMeetingGroupID) == canonicalMeetingGroupID(groupName)
        }
        var providers = Set(sessions.map { MeetingProvider.forOrigin($0.discoveryOrigin) })
        if let meta = meetingMetadata[groupName] {
            if meta.driveFolderURL?.isEmpty == false { providers.insert(.googleDrive) }
            if meta.localFolderPath?.isEmpty == false { providers.insert(.localFolder) }
        }
        return providers.sorted { $0.sortRank < $1.sortRank }
    }

    /// Whether a series survives the provider filter.
    ///
    /// With no filter set — the default — every series does. That is the whole
    /// change: provider narrows what the learner is looking at, and no longer
    /// decides where a series is allowed to exist.
    func meetingGroupMatchesProviderFilter(_ groupName: String) -> Bool {
        guard let provider = meetingProviderFilter else { return true }
        return meetingGroupProviders(groupName).contains(provider)
    }

    /// Providers the library actually has meetings from, in stable order. Drives
    /// the provider filter menu so it never offers a provider with nothing
    /// behind it.
    var meetingProvidersInUse: [MeetingProvider] {
        var providers = Set<MeetingProvider>()
        for article in activeArticles where article.sourceType == .meeting {
            providers.insert(MeetingProvider.forOrigin(article.discoveryOrigin))
        }
        for meta in meetingMetadata.values {
            if meta.driveFolderURL?.isEmpty == false { providers.insert(.googleDrive) }
            if meta.localFolderPath?.isEmpty == false { providers.insert(.localFolder) }
        }
        return providers.sorted { $0.sortRank < $1.sortRank }
    }

    /// Active session count per provider, for the filter menu's counts.
    var meetingSessionCountsByProvider: [MeetingProvider: Int] {
        var counts: [MeetingProvider: Int] = [:]
        for article in activeArticles where article.sourceType == .meeting {
            counts[MeetingProvider.forOrigin(article.discoveryOrigin), default: 0] += 1
        }
        return counts
    }

    // MARK: - Zoom Recordings

    /// Put a Zoom cloud recording in the meeting series it belongs to, creating
    /// that series the first time one arrives from a given Zoom account.
    ///
    /// Every meeting reaches the Meetings tab through a series, so a session
    /// with no group is a session nothing can show — the bug that used to strand
    /// locally imported folders. A pasted Zoom link carries no series, so
    /// `ForeverLMCore.zoomMeetingSeries` derives one deterministically from
    /// the hosting account, and the learner renames the row to whatever the
    /// seminar is actually called. A series that already answers to that title —
    /// the same Drive or Read AI series, recorded on Zoom this week — takes the
    /// session instead of a second row being made for it, which is the whole
    /// point of one provider-agnostic Meetings tab.
    ///
    /// Mutates the article in place rather than saving it: callers are
    /// mid-insert and own the write.
    ///
    /// `explicit` is whether the learner is putting this recording in by hand
    /// — a pasted link. That is the learner asking for the series, so it lifts
    /// a removal tombstone and the hidden flag the way an explicit folder
    /// import does. Adopting a row that arrived some other way (synced from an
    /// older build, captured in Web Studio) is not, and a series the learner
    /// removed stays out of sight: the row lands in it hidden rather than
    /// standing the series back up.
    func assignZoomMeetingSeries(to article: inout StudioArticle, explicit: Bool) async {
        guard let series = ForeverLMCore.zoomMeetingSeries(forRecordingURL: article.url) else { return }
        let groupID = existingMeetingID(forTitle: series.title) ?? series.id
        let title = meetingMetadata[groupID]?.title ?? series.title

        article.sourceType = .meeting
        article.discoveryOrigin = .zoom
        article.parentGroup = groupID
        article.domain = title

        var metadata = meetingMetadata[groupID] ?? MeetingMetadata(title: title)
        metadata.title = title
        if metadata.timezone == nil { metadata.timezone = TimeZone.current.identifier }
        if explicit {
            Self.liftMeetingGroupRemoval(groupID: groupID, metadata: metadata)
            metadata.isHidden = false
        } else if Self.isMeetingGroupRemoved(groupID: groupID, metadata: metadata) {
            metadata.isHidden = true
        }
        if meetingMetadata[groupID] != metadata {
            // Stored first: memory never shows a series, or a lifted removal,
            // that the store did not take.
            do {
                try await storage.saveMeetingGroup(name: groupID, metadata: metadata)
                meetingMetadata[groupID] = metadata
            } catch {
                logger.error("Could not save meeting series \(groupID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                showToast("Could not save the meeting series \(title): \(error.localizedDescription)")
            }
        }
        if userMeetingGroupNames.insert(groupID).inserted { saveUserMeetingGroupNames() }
    }

    /// How many sessions a meeting series is holding, for a confirmation that
    /// has to say what deleting it costs.
    func meetingSessionCount(for groupName: String) -> Int {
        sourceIDsForGroupInOrder(canonicalMeetingGroupID(groupName)).count
    }

    /// Series the learner hid. A series inside its removal's Undo window is
    /// hidden too, but it is being removed rather than kept: the footer does
    /// not count it. See `isSourceBeingRemoved`.
    var hiddenMeetingGroupNames: [String] {
        allMeetingGroupNames.filter {
            meetingMetadata[$0]?.isHidden == true
                && !hasPendingDeletion(forDeletionKey: Self.meetingRemovalKey($0))
        }
    }

    func meetingDisplayName(_ groupName: String) -> String {
        let canonical = canonicalMeetingGroupID(groupName)
        return meetingMetadata[canonical]?.title ?? canonical
    }

    /// Follow synced meeting aliases without touching storage or blocking UI.
    /// Cycles should never survive the transactional writer; returning the last
    /// unique ID keeps rendering finite if malformed sync data is encountered.
    func canonicalMeetingGroupID(_ groupID: String) -> String {
        var current = groupID
        var visited = Set<String>()
        while visited.insert(current).inserted,
              let next = meetingMetadata[current]?.mergedIntoGroupID,
              !next.isEmpty {
            current = next
        }
        return current
    }

    func meetingDisplaySubtitle(_ groupName: String) -> String? {
        let trimmed = meetingMetadata[groupName]?.recurrenceRule?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Every `meetingFolder.image.*` row currently in `UserDefaults`, keyed by
    /// meeting group ID. One scan of the defaults dictionary beats one lookup per
    /// folder, and it is the only way to find keys whose names are runtime-built.
    nonisolated static func meetingFolderImageURLsFromDefaults(
        _ defaults: UserDefaults = .standard
    ) -> [String: String] {
        let prefix = MeetingMetadata.folderImagePreferenceKeyPrefix
        var images: [String: String] = [:]
        for (key, value) in defaults.dictionaryRepresentation()
        where key.hasPrefix(prefix) {
            guard let url = value as? String, !url.isEmpty else { continue }
            images[String(key.dropFirst(prefix.count))] = url
        }
        return images
    }

    func meetingFolderImageURL(_ groupName: String) -> String? {
        meetingFolderImageURLs[groupName]
    }

    /// Point one meeting folder's sidebar tile at an image. An empty value clears
    /// the choice and restores the shared meetings icon.
    ///
    /// A bare filesystem path is accepted and stored as a `file:` URL, because
    /// that is what people paste when the image is already on the Mac — but note
    /// that a local path only resolves on the Mac holding the file, while a web
    /// address follows the account to every client.
    func setMeetingFolderImageURL(_ raw: String?, for groupName: String) {
        let key = MeetingMetadata.folderImagePreferenceKey(for: groupName)
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            meetingFolderImageURLs.removeValue(forKey: groupName)
            PreferenceStore.remove(forKey: key)
            return
        }
        let normalized = Self.normalizedMeetingFolderImageURL(trimmed)
        guard URL(string: normalized) != nil else {
            errorMessage = "\"\(trimmed)\" is not an image address or a path to a file on this Mac."
            return
        }
        meetingFolderImageURLs[groupName] = normalized
        PreferenceStore.set(normalized, forKey: key)
    }

    nonisolated static func normalizedMeetingFolderImageURL(_ value: String) -> String {
        guard value.hasPrefix("/") || value.hasPrefix("~") else { return value }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).absoluteString
    }

    func meetingMatchesSearch(_ groupName: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parsed = SidebarSearchQuery(parsing: query)
        guard !parsed.isEmpty else { return true }
        let meta = meetingMetadata[groupName]
        let metadata = [
            groupName,
            meetingDisplayName(groupName),
            meta?.driveFolderURL,
            meta?.localFolderPath,
            meta?.recurrenceRule,
            meta?.timezone,
        ]
        .compactMap { $0 }

        if Self.sidebarGroupMatchesSearch(
            parsed,
            metadata: metadata,
            titles: [groupName, meetingDisplayName(groupName)]
        ) {
            return true
        }

        return activeArticles.contains { article in
            article.sourceType == .meeting
                && article.parentGroup == groupName
                && sourceMatchesSearch(article, query: query)
        }
    }

    /// When a series meets, set or cleared from its Schedule sheet or over
    /// MCP; the Planner redraws the day at once.
    func setMeetingSchedule(_ schedule: MeetingSchedule?, groupName: String) async {
        await updateMeetingMetadata(groupName: groupName) { $0.schedule = schedule }
        NotificationCenter.default.post(name: .meetingSchedulesDidChange, object: nil)
    }

    func updateMeetingMetadata(groupName: String, update: (inout MeetingMetadata) -> Void) async {
        var meta = meetingMetadata[groupName] ?? MeetingMetadata(title: groupName)
        update(&meta)
        meetingMetadata[groupName] = meta
        userMeetingGroupNames.insert(groupName)
        saveUserMeetingGroupNames()
        do {
            try await storage.saveMeetingGroup(name: groupName, metadata: meta)
        } catch {
            logger.error("Failed to save meeting group: \(error.localizedDescription)")
        }
    }

    /// How many sessions of a series share a local day with an earlier one —
    /// what the series' Merge Same-Day Sessions would fold. Zero hides the
    /// menu item. The explicit rule: the day alone, no window
    /// (`MeetingSessionContinuation`).
    func sameDayMeetingSessionSurplus(for groupName: String) -> Int {
        let groupID = canonicalMeetingGroupID(groupName)
        let sessions = articles
            .filter { article in
                article.sourceType == .meeting && article.status == .active
                    && (article.state == .ready || article.state == .error)
                    && article.parentGroup.map(canonicalMeetingGroupID) == groupID
            }
            .map { article in
                MeetingSessionContinuation.Session(
                    id: article.id,
                    startedAt: MeetingSessionContinuation.knownStart(of: article) ?? article.dateAdded
                )
            }
        return MeetingSessionContinuation.mergeGroups(sessions, window: nil).reduce(0) { $0 + $1.count - 1 }
    }

    /// Merge Same-Day Sessions on the series' sidebar menu: every day of the
    /// series that holds more than one finished session becomes one session,
    /// the earliest surviving (`KnowledgeStore.mergeMeetingSessions`). The
    /// MCP twin is `merge_meeting_sessions`. The product owner (2026-09-19): "there
    /// should just be 1 a day since there is only 1 standup a day".
    func mergeSameDayMeetingSessions(groupName: String) async {
        let groupID = canonicalMeetingGroupID(groupName)
        let title = meetingDisplayName(groupID)
        let outcomes: [MeetingSessionMergeOutcome]
        do {
            outcomes = try await storage.mergeSameDayMeetingSessions(groupID: groupID)
        } catch {
            logger.error("Failed to merge same-day sessions of '\(groupID)': \(error.localizedDescription)")
            errorMessage = "Could not merge the sessions of \(title): \(error.localizedDescription)"
            return
        }
        guard !outcomes.isEmpty else {
            showToast("Every day of \(title) already has one session.")
            return
        }
        for outcome in outcomes {
            MeetingActionItemExtractor.shared.noteSessionsMerged(survivorID: outcome.survivorID)
        }
        await reloadAfterMeetingSessionMerge(survivorIDs: Set(outcomes.map(\.survivorID)))
        let folded = outcomes.reduce(0) { $0 + $1.absorbedIDs.count }
        showToast(
            "Merged \(folded) session\(folded == 1 ? "" : "s") of \(title) into \(outcomes.count) day\(outcomes.count == 1 ? "" : "s")."
        )
    }

    /// Put a merge on screen: the absorbed rows leave, the survivors' files
    /// gather under them, and their readers show the whole sitting. Content
    /// the learner had open stays loaded, except a survivor's — that text is
    /// new and must be read from the store again.
    func reloadAfterMeetingSessionMerge(survivorIDs: Set<String>) async {
        do {
            let reloaded = try await storage.loadLibrarySources().sources
            let previous = articles.filter { !survivorIDs.contains($0.id) }
            articles = Self.preservingLoadedContent(in: reloaded, preservingFrom: previous)
            applyMeetingArtifacts(try await storage.loadMeetingArtifacts())
        } catch {
            logger.error("Sessions merged but the sidebar refresh failed: \(error.localizedDescription)")
        }
        await reloadSourceRelationshipsAfterMerge()
    }

    /// Merge an existing group into another and keep the source as a provider
    /// alias. The storage operation is atomic; observable collections publish
    /// only after it succeeds, so the sidebar never shows a half-moved group.
    func mergeMeetingGroup(_ sourceGroupID: String, into targetGroupID: String) async {
        let sourceID = canonicalMeetingGroupID(sourceGroupID)
        let targetID = canonicalMeetingGroupID(targetGroupID)
        guard sourceID != targetID,
              var sourceMetadata = meetingMetadata[sourceID],
              meetingMetadata[targetID] != nil else { return }
        let sourceTitle = meetingDisplayName(sourceID)
        let targetTitle = meetingDisplayName(targetID)
        do {
            try await storage.mergeMeetingGroup(sourceID, into: targetID)
        } catch {
            logger.error("Failed to merge meeting group '\(sourceID)' into '\(targetID)': \(error.localizedDescription)")
            errorMessage = "Could not merge \(sourceTitle): \(error.localizedDescription)"
            return
        }

        sourceMetadata.isHidden = true
        sourceMetadata.mergedIntoGroupID = targetID
        meetingMetadata[sourceID] = sourceMetadata
        articles = articles.map { article in
            guard article.sourceType == .meeting,
                  article.parentGroup == sourceID else { return article }
            var moved = article
            moved.parentGroup = targetID
            moved.domain = targetTitle
            return moved
        }
        meetingArtifactsBySourceId = meetingArtifactsBySourceId.mapValues { artifacts in
            artifacts.map { artifact in
                guard artifact.groupId == sourceID else { return artifact }
                var moved = artifact
                moved.groupId = targetID
                return moved
            }
        }
        userMeetingGroupNames.remove(sourceID)
        userMeetingGroupNames.insert(targetID)
        saveUserMeetingGroupNames()
        if meetingFolderImageURL(targetID) == nil,
           let sourceImage = meetingFolderImageURL(sourceID) {
            setMeetingFolderImageURL(sourceImage, for: targetID)
        }
        setMeetingFolderImageURL(nil, for: sourceID)
        showToast("Merged \(sourceTitle) into \(targetTitle)")
    }

    // MARK: - Google Drive meetings

    nonisolated static let meetingOwnTranscriptionEnabledKey = "meetings.transcribeWhenGoogleDidNot"

    /// Whether ForeverLM may run speech-to-text over a meeting recording itself.
    ///
    /// Off by default, and the default is the point. Google Meet already hands
    /// back Gemini's verbatim transcript in the same Doc as the notes, so the
    /// job here is to *read* what Google wrote, not to reproduce it: a session
    /// that looks untranscribed is nearly always a Doc that was not split
    /// properly, and transcribing anyway bills a provider to re-derive text the
    /// import already had. Whoever wants a transcript for a recording Google
    /// genuinely never transcribed can turn this on.
    ///
    /// Read live rather than cached: the toggle writes through `SyncedStorage`,
    /// and a value synced in from the user's other Mac lands in `UserDefaults`
    /// without passing through this type.
    nonisolated static var isMeetingOwnTranscriptionEnabled: Bool {
        UserDefaults.standard.bool(forKey: meetingOwnTranscriptionEnabledKey)
    }

    /// The path for adding a meeting folder: one Google sign-in (read-only Drive
    /// access), the learner choosing the folder in the app, then an immediate
    /// import. With `reconnectOnly`, a Drive that already has linked folders
    /// just signs in again and refreshes them, because the folder was chosen
    /// long ago and only the access is broken; with none linked it falls
    /// through to the chooser.
    func connectAndImportGoogleDriveMeetings(reconnectOnly: Bool = false) async throws {
        let account = try await GoogleDriveService.shared.connectAccount()
        if reconnectOnly, hasLinkedGoogleDriveFolders {
            await refreshConnectedGoogleDriveMeetings(silent: false)
            return
        }
        guard let folder = await GoogleDriveFolderPicker.choose(account: account) else {
            throw GoogleDriveServiceError.noFolderSelected
        }
        // Signing in is the evidence the Google Drive tab was waiting for; pin it
        // before the import so the meetings land somewhere the learner can see.
        pinIntegrationTabsInUse()
        try await importMeetingFolderFromAuthenticatedDrive(
            folder.webURL,
            groupTitle: folder.name,
            silent: false
        )
    }

    var hasLinkedGoogleDriveFolders: Bool {
        meetingMetadata.values.contains { $0.driveFolderURL?.isEmpty == false }
    }

    /// The repair offered wherever Drive health is broken. Closing the sign-in
    /// or the folder chooser is a plain cancel; any other failure is shown.
    /// Returns whether it completed.
    @discardableResult
    func reconnectGoogleDriveMeetings() async -> Bool {
        do {
            try await connectAndImportGoogleDriveMeetings(reconnectOnly: true)
            return true
        } catch GoogleDriveServiceError.noFolderSelected {
            return false
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            showToast(error.localizedDescription)
            return false
        }
    }

    /// Refresh one folder that was explicitly selected in Google Drive.
    func importMeetingFolderFromAuthenticatedDrive(
        _ driveFolderURL: String,
        groupTitle: String,
        silent: Bool
    ) async throws {
        let title = groupTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderID = try Self.googleDriveFolderID(from: driveFolderURL)
        let accountID = GoogleDriveService.accountID(from: driveFolderURL)
        guard !title.isEmpty else { throw SourceError.invalidURL }
        guard GoogleDriveService.shared.isSignedIn(accountID: accountID) else {
            throw GoogleDriveServiceError.notSignedIn
        }

        let artifacts = try await Self.fetchAuthenticatedGoogleDriveMeetingArtifacts(
            folderID: folderID,
            accountID: accountID,
            excludingFolderIDs: linkedGoogleDriveFolderIDs(excluding: folderID)
        )
        let canonicalFolderURL = GoogleDriveService.taggedURL(
            "https://drive.google.com/drive/folders/\(folderID)",
            accountID: accountID
        )
        try await importMeetingArtifacts(
            artifacts,
            groupTitle: title,
            driveFolderURL: canonicalFolderURL,
            localFolderPath: nil,
            discoveryOrigin: .googleDriveMeetings,
            emptyMessage: "No supported meeting files found in \(title)",
            silent: silent
        )
    }

    /// Event-driven refresh for every Drive folder already linked to a meeting
    /// group. Called when the Drive tab opens, the app activates, or the learner
    /// explicitly refreshes; never from a launch-time scan or polling loop.
    func refreshConnectedGoogleDriveMeetings(silent: Bool) async {
        _ = try? await GoogleDriveService.shared.adoptLegacyAccountIfNeeded()
        guard GoogleDriveService.shared.isSignedIn else { return }
        var folders: [(String, String)] = []
        for (groupID, metadata) in meetingMetadata {
            guard let url = metadata.driveFolderURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.isEmpty else { continue }
            let title = metadata.title ?? groupID
            if Self.isMeetingGroupRemoved(groupID: groupID, metadata: metadata) {
                if !Self.hasRecordedMeetingGroupRemovalIdentity(groupID: groupID, metadata: metadata) {
                    // Adopt a title-only tombstone from an older build into the
                    // stable identity as soon as the matching folder is known.
                    Self.recordMeetingGroupRemoval(groupID: groupID, metadata: metadata)
                }
                // A stale CloudKit copy can arrive after this Mac recorded the
                // removal but before its hidden MeetingGroup record uploads.
                // The synced tombstone is authoritative: repair the row instead
                // of merely skipping its refresh and leaving it visible forever.
                if !metadata.isHidden {
                    await updateMeetingMetadata(groupName: groupID) { $0.isHidden = true }
                }
                continue
            }
            guard !metadata.isHidden else { continue }
            folders.append((url, title))
        }
        for (url, title) in folders {
            do {
                try await importMeetingFolderFromAuthenticatedDrive(url, groupTitle: title, silent: silent)
            } catch {
                logger.error("Google Drive meeting refresh failed for \(title, privacy: .public): \(error.localizedDescription)")
                if !silent { showToast(error.localizedDescription) }
            }
        }
    }

    /// Ensure a meeting has a real transcript section.
    ///
    /// Google's own transcript always wins: the import reads it out of the
    /// Gemini Doc, and a session that has one returns here without doing any
    /// work. Only a recording Google never transcribed reaches speech-to-text,
    /// and only when `isMeetingOwnTranscriptionEnabled` says so — otherwise this
    /// throws rather than paying to re-derive what Google may already have.
    /// A generated transcript merges ahead of the notes without replacing them.
    @discardableResult
    func ensureMeetingTranscript(for sourceID: String) async throws -> Bool {
        guard let article = articles.first(where: { $0.id == sourceID }) else {
            throw MeetingTranscriptError.sourceNotFound
        }
        guard article.sourceType == .meeting else {
            throw MeetingTranscriptError.notMeeting
        }
        if await meetingHasTranscript(article) { return false }
        // Everything above this line is a read of what the plugin already
        // imported. Below it, transcription bills a provider — so it happens
        // only where the learner has asked for it.
        guard Self.isMeetingOwnTranscriptionEnabled else {
            throw MeetingTranscriptError.ownTranscriptionDisabled
        }
        if let task = meetingTranscriptTasks[sourceID] {
            return try await task.value
        }

        let task = Task { @MainActor [weak self] () throws -> Bool in
            guard let self else { throw CancellationError() }
            return try await self.generateMeetingTranscript(sourceID: sourceID)
        }
        meetingTranscriptTasks[sourceID] = task
        defer { meetingTranscriptTasks[sourceID] = nil }
        return try await task.value
    }

    /// Open one of a meeting session's files in ForeverLM's own reader, and say
    /// whether that was possible.
    ///
    /// The files listed under a session are not sources of their own: the import
    /// merges every text artifact into the session's one document, under its own
    /// `## Transcript` / `## Notes` / `## Chat` heading, and the reader plays the
    /// recording in place. So clicking a file means "show me that part of this
    /// session" — open the session and scroll to the section — and Google Drive
    /// is the fallback for a file whose text never made it in, not the default
    /// destination. The difference is not cosmetic: only the in-app reader can
    /// search and highlight the text, read it aloud, review it, find the papers
    /// a meeting mentioned, or capture the slides out of its recording.
    ///
    /// Returns false when there is nothing to show in-app, so the caller can
    /// open the external copy instead and an artifact row is never a dead click.
    func openMeetingArtifactInReader(_ artifact: MeetingArtifact) async -> Bool {
        guard let article = articlesById[artifact.sourceId],
              article.sourceType == .meeting else { return false }

        if artifact.kind == .recording {
            // The meeting reader owns the video pane, so the recording *is* the
            // top of the document — nothing to scroll to. A recording it cannot
            // play (neither a local file nor a Drive video, or sound with no
            // picture) stays with its external copy: Drive, or the file on disk.
            guard MeetingRecordingMedia.resolve(
                from: meetingArtifactsBySourceId[artifact.sourceId] ?? []
            ) != nil else { return false }
            meetingSectionReaderTarget = nil
            selectSessionRow(artifact.sourceId)
            await selectArticle(artifact.sourceId)
            return true
        }

        // Sources load without their text, so this reads storage rather than
        // trusting the in-memory copy: `article.content` is nil for every
        // session the learner has not opened yet this launch.
        var content = article.content
        if content == nil {
            content = await storage.loadSourceContent(artifact.sourceId)
        }
        guard let sectionText = MeetingContent.text(for: artifact.kind, in: content) else { return false }

        // Selection first, target second. `selectArticle` remounts the reader,
        // and a target set beforehand would be consumed by the mount before the
        // transcript has parsed; arriving as a change afterwards is a request
        // the reader can honor as soon as it has segments to scroll to.
        selectSessionRow(artifact.sourceId)
        await selectArticle(artifact.sourceId)
        let anchors = Self.meetingSectionAnchors(sectionText)
        meetingSectionReaderRevision &+= 1
        meetingSectionReaderTarget = MeetingSectionReaderTarget(
            sourceID: artifact.sourceId,
            kind: artifact.kind,
            subheading: anchors.subheading,
            anchorText: anchors.paragraph,
            revision: meetingSectionReaderRevision
        )
        return true
    }

    /// Opening a file selects the session it belongs to, the same way clicking
    /// the session row would: the file is a part of that source, not a source of
    /// its own, so the sidebar highlight belongs on the parent row.
    private func selectSessionRow(_ sourceID: String) {
        selectedArticleIds = [sourceID]
        readerPoppedOut = false
    }

    /// The two landmarks at the top of a section that the reader can scroll to:
    /// the section's own first heading, and its first real paragraph.
    ///
    /// Both exist because the `## Notes` heading itself often does not survive
    /// into the rendered document — a Gemini notes Doc opens with `### Quick
    /// notes`, which becomes the heading of the paragraph that follows. Lines
    /// holding nothing but a timestamp are skipped: the reader lifts those into
    /// the margin, and one alone identifies nothing anyway.
    nonisolated static func meetingSectionAnchors(
        _ sectionText: String
    ) -> (subheading: String?, paragraph: String?) {
        var subheading: String?
        var paragraph: String?
        for raw in sectionText.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if subheading == nil, paragraph == nil {
                    subheading = line
                        .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                        .trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            let withoutTime = line
                .replacingOccurrences(
                    of: #"^\[?(\d{1,2}:\d{2}(?::\d{2})?)\]?\s*"#,
                    with: "",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespaces)
            if withoutTime.isEmpty { continue }
            paragraph = String(withoutTime.prefix(120))
            break
        }
        return (
            subheading: subheading?.isEmpty == false ? subheading : nil,
            paragraph: paragraph
        )
    }

    /// Whether this session could still gain a transcript: it has a recording to
    /// transcribe and no transcript artifact.
    ///
    /// Artifact rows only, because SwiftUI builds sidebar context menus eagerly
    /// with the rows themselves — scanning every session's text for a
    /// `## Transcript` heading on each pass would put a megabyte of string
    /// search into sidebar layout. The looser answer costs nothing: a session
    /// that turns out to be transcribed already is caught by the async
    /// `meetingHasTranscript` check, which returns without transcribing.
    func meetingSessionNeedsTranscript(_ sourceID: String) -> Bool {
        // "Needs" means a transcript could be produced, so the preference that
        // decides whether ForeverLM ever produces one answers first. Every
        // affordance that offers transcription reads this, which is why turning
        // the preference off removes them all rather than leaving buttons that
        // only report a refusal.
        guard Self.isMeetingOwnTranscriptionEnabled else { return false }
        guard let article = articlesById[sourceID], article.sourceType == .meeting else { return false }
        let artifacts = meetingArtifactsBySourceId[sourceID] ?? []
        guard artifacts.contains(where: { $0.kind == .recording }) else { return false }
        return !artifacts.contains(where: { $0.kind == .transcript })
    }

    /// The sessions in one meeting folder that still have a recording and no
    /// transcript, in sidebar order.
    func meetingSessionIDsNeedingTranscript(inGroup groupName: String) -> [String] {
        sourceIDsForGroupInOrder(groupName).filter { meetingSessionNeedsTranscript($0) }
    }

    /// Transcribe meeting recordings on demand, from the sidebar rather than by
    /// opening each recording in the reader.
    ///
    /// Sessions run one at a time: each one downloads a recording and pushes it
    /// through the on-device model, so a folder's worth in parallel would only
    /// contend for the same GPU. Pass `groupName` for a whole-folder pass — it
    /// only marks the group row as busy and names the folder in the summary.
    func transcribeMeetingSessions(_ sourceIDs: [String], groupName: String? = nil) async {
        if let groupName {
            guard !transcribingMeetingGroupNames.contains(groupName) else { return }
            transcribingMeetingGroupNames.insert(groupName)
        }
        defer {
            if let groupName { transcribingMeetingGroupNames.remove(groupName) }
        }

        let pending = sourceIDs.filter { !transcribingMeetingSourceIDs.contains($0) }
        guard !pending.isEmpty else { return }

        var generated = 0
        var alreadyHad = 0
        var lastFailure: String?
        var failures = 0
        for sourceID in pending {
            if Task.isCancelled { break }
            transcribingMeetingSourceIDs.insert(sourceID)
            do {
                if try await ensureMeetingTranscript(for: sourceID) {
                    generated += 1
                } else {
                    alreadyHad += 1
                }
            } catch is CancellationError {
                transcribingMeetingSourceIDs.remove(sourceID)
                break
            } catch {
                failures += 1
                lastFailure = error.localizedDescription
            }
            transcribingMeetingSourceIDs.remove(sourceID)
        }

        showToast(Self.meetingTranscriptSummary(
            attempted: pending.count,
            generated: generated,
            alreadyHad: alreadyHad,
            failures: failures,
            lastFailure: lastFailure,
            singleTitle: pending.count == 1
                ? articlesById[pending[0]].map { displayTitle(for: $0) }
                : nil,
            groupTitle: groupName.map { meetingDisplayName($0) }
        ))
    }

    nonisolated static func meetingTranscriptSummary(
        attempted: Int,
        generated: Int,
        alreadyHad: Int,
        failures: Int,
        lastFailure: String?,
        singleTitle: String?,
        groupTitle: String?
    ) -> String {
        let subject = singleTitle ?? groupTitle ?? "these recordings"
        if attempted == 1 {
            if generated == 1 { return "Transcript ready for \(subject)." }
            if alreadyHad == 1 { return "\(subject) already had a transcript." }
            return "Couldn't transcribe \(subject): \(lastFailure ?? "no transcript was produced")"
        }
        if failures == 0 {
            return "Transcribed \(generated) of \(attempted) recordings in \(subject)."
        }
        return "Transcribed \(generated) of \(attempted) recordings in \(subject). "
            + "\(failures) failed — last error: \(lastFailure ?? "unknown")"
    }

    private func meetingHasTranscript(_ article: StudioArticle) async -> Bool {
        let loadedArtifacts = (try? await storage.loadMeetingArtifacts(sourceID: article.id)) ?? []
        let artifacts = meetingArtifactsBySourceId[article.id] ?? loadedArtifacts
        if artifacts.contains(where: { $0.kind == .transcript }) { return true }
        let content: String?
        if let loaded = article.content {
            content = loaded
        } else {
            content = await storage.loadSourceContent(article.id)
        }
        return await Task.detached(priority: .utility) {
            MeetingContent.contains(section: .transcript, in: content)
        }.value
    }

    /// The playable file behind a meeting's recording artifact.
    ///
    /// Local-folder imports point straight at a file on disk. Drive imports resolve through
    /// the plugin's OAuth grant into the same disposable local cache the player uses, so
    /// a recording is downloaded once and then shared by playback, on-device transcription,
    /// and slide extraction rather than fetched again per feature.
    func meetingRecordingURL(for sourceID: String) async throws -> URL {
        let storedArtifacts = (try? await storage.loadMeetingArtifacts(sourceID: sourceID)) ?? []
        let artifacts = meetingArtifactsBySourceId[sourceID] ?? storedArtifacts
        guard let recording = artifacts.first(where: { $0.kind == .recording }) else {
            throw MeetingTranscriptError.noRecording
        }

        if let localPath = recording.localFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !localPath.isEmpty {
            let resolvedPath = await Task.detached(priority: .utility) {
                StorageService.locateSourceFile(localPath)
                    ?? StorageService.absoluteSourcePath(localPath)
            }.value
            return URL(fileURLWithPath: resolvedPath)
        }
        if let remote = recording.url?.trimmingCharacters(in: .whitespacesAndNewlines),
           !remote.isEmpty {
            return try await GoogleDriveService.shared.cachedRecordingURL(
                fileURLOrID: remote,
                mimeType: recording.mimeType,
                modifiedAt: recording.modifiedAt
            )
        }
        throw MeetingTranscriptError.noRecording
    }

    private func generateMeetingTranscript(sourceID: String) async throws -> Bool {
        guard var article = articles.first(where: { $0.id == sourceID }) else {
            throw MeetingTranscriptError.sourceNotFound
        }
        if await meetingHasTranscript(article) { return false }

        let mediaURL = try await meetingRecordingURL(for: sourceID)
        let transcript = try await MeetingTranscriptionService.shared.transcribe(localMediaURL: mediaURL)
        // The source may have received fresher notes while transcription ran.
        // Merge into that current value, never the stale snapshot above.
        if let current = articles.first(where: { $0.id == sourceID }) { article = current }
        let storedContent: String?
        if let loaded = article.content {
            storedContent = loaded
        } else {
            storedContent = await storage.loadSourceContent(sourceID)
        }
        let title = article.title
        let prepared = await Task.detached(priority: .utility) {
            let content = MeetingContent.inserting(
                section: .transcript,
                text: transcript,
                into: storedContent,
                title: title
            )
            return (content: content, wordCount: content.split(separator: " ").count)
        }.value

        article.content = prepared.content
        article.wordCount = prepared.wordCount
        article.state = .ready
        article.errorMessage = nil
        try await storage.saveSource(article, syncImmediately: true)
        if let index = articles.firstIndex(where: { $0.id == sourceID }) {
            articles[index] = article
        }
        MeetingActionItemExtractor.shared.noteTranscriptReady(sourceID: sourceID)

        let transcriptArtifact = MeetingArtifact(
            id: SourceIdentity.stableID(for: "\(sourceID):generated:transcript"),
            sourceId: sourceID,
            groupId: article.parentGroup ?? "",
            kind: .transcript,
            title: "\(article.title) - Transcript",
            mimeType: "text/plain",
            modifiedAt: Date(),
            sortIndex: MeetingArtifactKind.transcript.sortRank
        )
        try await storage.saveMeetingArtifact(transcriptArtifact)
        let storedArtifacts = (try? await storage.loadMeetingArtifacts(sourceID: sourceID)) ?? []
        let existingArtifacts = meetingArtifactsBySourceId[sourceID] ?? storedArtifacts
        var merged = existingArtifacts.filter { $0.id != transcriptArtifact.id }
        merged.append(transcriptArtifact)
        meetingArtifactsBySourceId[sourceID] = merged.sorted { $0.sortIndex < $1.sortIndex }
        return true
    }

    /// Bring a hidden meeting group back, and unarchive its sessions with it.
    ///
    /// Deletion no longer archives anything, so the unarchive is for the groups
    /// an older build removed: it archived the sessions and kept the group as a
    /// hidden row, and without this they return as a series with no sessions in
    /// it. Archiving cleared each session's text, so those sessions come back
    /// empty until the group's plugin or an MCP import refills them.
    func restoreMeetingGroup(_ groupName: String) async {
        if await undoPendingDeletion(forDeletionKey: Self.meetingRemovalKey(groupName)) {
            guard meetingMetadata[groupName]?.isHidden == true else { return }
        }
        Self.liftMeetingGroupRemoval(
            groupID: groupName,
            metadata: meetingMetadata[groupName] ?? MeetingMetadata(title: meetingDisplayName(groupName))
        )
        do {
            try await storage.unarchiveSourcesByParentGroup(groupName)
        } catch {
            logger.error("Failed to restore sessions of meeting group '\(groupName)': \(error.localizedDescription)")
            errorMessage = "Could not restore \(meetingDisplayName(groupName)): \(error.localizedDescription)"
            return
        }
        await updateMeetingMetadata(groupName: groupName) { $0.isHidden = false }
        await refreshArticles()
    }

    func setMeetingHidden(_ groupName: String, hidden: Bool) async {
        if !hidden,
           await undoPendingDeletion(forDeletionKey: Self.meetingRemovalKey(groupName)) {
            guard meetingMetadata[groupName]?.isHidden == true else { return }
        }
        await updateMeetingMetadata(groupName: groupName) { metadata in
            metadata.isHidden = hidden
        }
        showToast(
            hidden ? "Hid \(meetingDisplayName(groupName))" : "Unhid \(meetingDisplayName(groupName))",
            undo: hidden ? { [weak self] in await self?.setMeetingHidden(groupName, hidden: false) } : nil
        )
    }

    /// Take a meeting group out of the sidebar immediately, and delete it and
    /// its sessions once the shared Undo grace period expires. The group is
    /// hidden and tombstoned first, so an Undo is a plain unhide and nothing is
    /// destroyed while the notice is still on screen.
    func removeMeetingGroup(name: String) async {
        guard !hasPendingDeletion(forDeletionKey: Self.meetingRemovalKey(name)) else { return }
        let title = meetingDisplayName(name)
        let sourceIDs = Set(articles.filter {
            $0.sourceType == .meeting && $0.parentGroup == name
        }.map(\.id))
        let originalMetadata = meetingMetadata[name] ?? MeetingMetadata(title: title)
        var hiddenMetadata = originalMetadata
        hiddenMetadata.isHidden = true
        let priorSelectedArticleID = selectedArticleId
        let priorSelectedArticleIDs = selectedArticleIds

        do {
            try await storage.saveMeetingGroup(name: name, metadata: hiddenMetadata)
        } catch {
            logger.error("Failed to remove meeting group '\(name)': \(error.localizedDescription)")
            showToast("Removing “\(title)” failed: \(error.localizedDescription)")
            return
        }
        meetingMetadata[name] = hiddenMetadata
        userMeetingGroupNames.insert(name)
        saveUserMeetingGroupNames()
        Self.recordMeetingGroupRemoval(groupID: name, metadata: hiddenMetadata)
        deselectSourcesInEveryWindow(sourceIDs)
        if let selectedArticleId, sourceIDs.contains(selectedArticleId) {
            self.selectedArticleId = articles.first(where: {
                !sourceIDs.contains($0.id) && !isSourceHidden($0)
            })?.id
            currentCardIndex = 0
        }

        deferDeletion(
            message: "Removed “\(title)”",
            sourceIDs: sourceIDs,
            deletionKey: Self.meetingRemovalKey(name),
            gracePeriod: deletionGracePeriod,
            undo: { [weak self] in
                guard let self else { return }
                do {
                    try await self.storage.saveMeetingGroup(name: name, metadata: originalMetadata)
                    self.meetingMetadata[name] = originalMetadata
                    Self.liftMeetingGroupRemoval(groupID: name, metadata: originalMetadata)
                    self.selectedArticleId = priorSelectedArticleID
                    self.selectedArticleIds = priorSelectedArticleIDs
                } catch {
                    self.logger.error("Failed to undo meeting removal '\(name)': \(error.localizedDescription)")
                    self.showToast("Undo failed for “\(title)”: \(error.localizedDescription)")
                }
            },
            commit: { [weak self] in
                guard let self else { return }
                await self.deleteMeetingGroupForGood(name: name, title: title, sessionIDs: sourceIDs)
            }
        )
    }

    /// Delete a meeting series once the Undo window has closed: its sessions,
    /// their artifacts and the folder's own rows leave the database, and the
    /// removal tombstone stays behind so a background Drive pass cannot import
    /// the folder again.
    ///
    /// Removal used to archive the sessions and keep the folder as a hidden row.
    /// Nothing about that read as deleted: the series stayed listed under Hidden
    /// Items, and archiving had already cleared every transcript, so the one
    /// action offered there brought the folder back empty. Deleting is now the
    /// whole of it — what the learner asked for, and the only outcome that
    /// Hidden Items can describe honestly.
    ///
    /// The learner's own files are untouched. This removes ForeverLM's copy of
    /// the series, not the Google Drive folder or the recordings behind it, so
    /// picking the same folder again re-imports it from scratch.
    func deleteMeetingGroupForGood(name: String, title: String, sessionIDs: Set<String>) async {
        let deletedSourceIDs: [String]
        do {
            deletedSourceIDs = try await storage.deleteMeetingGroupWithSessions(
                name: name,
                additionalSessionIDs: sessionIDs
            )
        } catch {
            logger.error("Failed to delete meeting group '\(name)': \(error.localizedDescription)")
            // The group stays hidden and tombstoned, so a failure here leaves it
            // out of sight rather than back in the sidebar.
            showToast("Deleting “\(title)” failed: \(error.localizedDescription)")
            return
        }
        // Alias rows merged into this series went with it in the same
        // transaction, so their in-memory metadata goes too.
        let removedGroupIDs = Set(
            meetingMetadata.keys.filter { $0 == name || canonicalMeetingGroupID($0) == name }
        ).union([name])
        let removedSourceIDs = Set(deletedSourceIDs)
        // The recordings go into `dismissed_sources` too, the same tombstone a
        // single removed session leaves. The series tombstone above stops the
        // series coming back under its title or folder; this stops each
        // recording coming back on its own — a Zoom notice re-forwarded to the
        // recordings mailbox, a plugin re-pushing its history — now that
        // the archived row that used to answer "already exists" is gone. Web
        // Studio reads the same synced DismissedSource records. Written after
        // the delete so nothing is archived only to be deleted a moment later.
        let removedSessions = articles.filter { removedSourceIDs.contains($0.id) }
        if !removedSessions.isEmpty {
            do {
                try await storage.dismissSources(removedSessions)
            } catch {
                logger.error("Failed to tombstone the sessions of meeting group '\(name)': \(error.localizedDescription)")
            }
        }
        for groupID in removedGroupIDs {
            meetingMetadata.removeValue(forKey: groupID)
            setMeetingFolderImageURL(nil, for: groupID)
        }
        let remainingUserGroups = userMeetingGroupNames.subtracting(removedGroupIDs)
        if remainingUserGroups != userMeetingGroupNames {
            userMeetingGroupNames = remainingUserGroups
            saveUserMeetingGroupNames()
        }
        for sourceID in removedSourceIDs {
            meetingArtifactsBySourceId.removeValue(forKey: sourceID)
        }
        articles.removeAll { removedSourceIDs.contains($0.id) || sessionIDs.contains($0.id) }
    }

    // MARK: - Meeting session keys

    /// Build a session key whose embedded `yyyy/MM/dd` (optionally with time) is
    /// recognized by `meetingDate(from:)` and `meetingSessionTitle(from:groupTitle:)`.
    nonisolated static func readAISessionKey(title: String, date: Date?, includeTime: Bool) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let date else { return trimmedTitle }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = includeTime ? "yyyy/MM/dd HH:mm" : "yyyy/MM/dd"
        return "\(trimmedTitle) - \(formatter.string(from: date))"
    }

    // MARK: - Removed meeting group tombstones

    /// Titles of meeting groups the user explicitly removed. Background and
    /// MCP-driven imports consult this so they never re-create a removed group;
    /// an explicit import or re-create of the same title lifts the tombstone.
    /// Synced (see `SyncedPreferenceKeys`) so a removal on one Mac also stops
    /// the other Mac's background passes, which would otherwise resurrect the
    /// group and sync it straight back.
    nonisolated static let removedMeetingGroupTitlesKey = "meetings.removedGroupTitles"

    /// Stable plugin/group identities for removals. Titles remain as a
    /// compatibility guard for local and older removals, but they are mutable
    /// presentation and cannot be the identity of a Google Drive folder.
    nonisolated static let removedMeetingGroupIdentitiesKey = "meetings.removedGroupIdentities"

    /// Oldest removals fall off first; the list stays bounded because it syncs.
    nonisolated private static let removedMeetingGroupTitlesCap = 200

    nonisolated static func loadRemovedMeetingGroupTitles() -> [String] {
        UserDefaults.standard.stringArray(forKey: removedMeetingGroupTitlesKey) ?? []
    }

    /// Whether `titles` covers `title` — trimmed and case-insensitive, the same
    /// identity rule as `existingMeetingID(forTitle:)`.
    nonisolated static func removedMeetingGroupTitles(_ titles: [String], include title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return titles.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// `titles` with `title` recorded as removed: deduplicated, newest last, capped.
    nonisolated static func removedMeetingGroupTitles(_ titles: [String], recording title: String) -> [String] {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return titles }
        var updated = titles.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        updated.append(trimmed)
        return Array(updated.suffix(removedMeetingGroupTitlesCap))
    }

    /// `titles` with the tombstone for `title` lifted.
    nonisolated static func removedMeetingGroupTitles(_ titles: [String], lifting title: String) -> [String] {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return titles.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
    }

    nonisolated static func isMeetingGroupTitleRemoved(_ title: String) -> Bool {
        removedMeetingGroupTitles(loadRemovedMeetingGroupTitles(), include: title)
    }

    nonisolated static func meetingGroupRemovalIdentities(
        groupID: String,
        metadata: MeetingMetadata
    ) -> Set<String> {
        var identities: Set<String> = ["group:\(groupID)"]
        if let folderURL = metadata.driveFolderURL,
           let folderID = try? googleDriveFolderID(from: folderURL) {
            identities.insert("google-drive-folder:\(folderID)")
        }
        return identities
    }

    nonisolated static func removedMeetingGroupIdentities(
        _ identities: [String],
        recording additions: Set<String>
    ) -> [String] {
        var updated = identities.filter { !additions.contains($0) }
        updated.append(contentsOf: additions.sorted())
        return Array(updated.suffix(removedMeetingGroupTitlesCap))
    }

    nonisolated static func removedMeetingGroupIdentities(
        _ identities: [String],
        lifting removals: Set<String>
    ) -> [String] {
        identities.filter { !removals.contains($0) }
    }

    nonisolated static func loadRemovedMeetingGroupIdentities() -> [String] {
        UserDefaults.standard.stringArray(forKey: removedMeetingGroupIdentitiesKey) ?? []
    }

    nonisolated static func isMeetingGroupRemoved(
        groupID: String,
        metadata: MeetingMetadata
    ) -> Bool {
        let recorded = Set(loadRemovedMeetingGroupIdentities())
        let candidates = meetingGroupRemovalIdentities(groupID: groupID, metadata: metadata)
        if !recorded.isDisjoint(with: candidates) { return true }
        // Once this build has recorded any exact Drive-folder tombstone, title
        // fallback must not hide a different same-named folder. Titles are used
        // only to adopt the pre-identity format from older builds.
        if candidates.contains(where: { $0.hasPrefix("google-drive-folder:") }),
           recorded.contains(where: { $0.hasPrefix("google-drive-folder:") }) {
            return false
        }
        return isMeetingGroupTitleRemoved(metadata.title ?? groupID)
    }

    nonisolated static func hasRecordedMeetingGroupRemovalIdentity(
        groupID: String,
        metadata: MeetingMetadata
    ) -> Bool {
        !Set(loadRemovedMeetingGroupIdentities()).isDisjoint(
            with: meetingGroupRemovalIdentities(groupID: groupID, metadata: metadata)
        )
    }

    nonisolated static func recordMeetingGroupRemoval(
        groupID: String,
        metadata: MeetingMetadata
    ) {
        recordRemovedMeetingGroupTitle(metadata.title ?? groupID)
        PreferenceStore.set(
            removedMeetingGroupIdentities(
                loadRemovedMeetingGroupIdentities(),
                recording: meetingGroupRemovalIdentities(groupID: groupID, metadata: metadata)
            ),
            forKey: removedMeetingGroupIdentitiesKey
        )
    }

    nonisolated static func liftMeetingGroupRemoval(
        groupID: String,
        metadata: MeetingMetadata
    ) {
        liftRemovedMeetingGroupTitle(metadata.title ?? groupID)
        PreferenceStore.set(
            removedMeetingGroupIdentities(
                loadRemovedMeetingGroupIdentities(),
                lifting: meetingGroupRemovalIdentities(groupID: groupID, metadata: metadata)
            ),
            forKey: removedMeetingGroupIdentitiesKey
        )
    }

    nonisolated static func recordRemovedMeetingGroupTitle(_ title: String) {
        PreferenceStore.set(
            removedMeetingGroupTitles(loadRemovedMeetingGroupTitles(), recording: title),
            forKey: removedMeetingGroupTitlesKey
        )
    }

    nonisolated static func liftRemovedMeetingGroupTitle(_ title: String) {
        PreferenceStore.set(
            removedMeetingGroupTitles(loadRemovedMeetingGroupTitles(), lifting: title),
            forKey: removedMeetingGroupTitlesKey
        )
    }

    func importMeetingArtifacts(
        _ parsedFiles: [ParsedMeetingArtifact],
        groupTitle title: String,
        driveFolderURL: String?,
        localFolderPath: String?,
        discoveryOrigin: DiscoveryOrigin,
        emptyMessage: String,
        silent: Bool = false
    ) async throws {
        let trimmedDriveURL = driveFolderURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedDriveFolderID = trimmedDriveURL.flatMap { try? Self.googleDriveFolderID(from: $0) }
        let linkedDriveGroupID = requestedDriveFolderID.flatMap { folderID in
            meetingMetadata.first { _, existing in
                guard let existingURL = existing.driveFolderURL,
                      let existingFolderID = try? Self.googleDriveFolderID(from: existingURL) else { return false }
                return existingFolderID == folderID
            }?.key
        }
        // A Drive folder ID is the identity boundary. Two folders can share a
        // human title, so title matching must never merge their sessions.
        let importIdentityGroupID = linkedDriveGroupID
            ?? (requestedDriveFolderID == nil ? existingMeetingID(forTitle: title) : nil)
            ?? UUID().uuidString
        let groupID = canonicalMeetingGroupID(importIdentityGroupID)
        let previousImportMetadata = meetingMetadata[importIdentityGroupID]
        var importMetadata = previousImportMetadata ?? MeetingMetadata(title: title)
        // A plugin's folder title seeds a new series; it does not own the
        // learner's display name after that. Re-imports can arrive much later
        // (app activation, tab opening, another explicit folder pick), and the
        // provider will keep reporting its own unchanged folder name. Replacing
        // metadata.title here silently undid every Rename on the next import.
        // The stable group/folder ID is identity, while the stored title is
        // user-authored presentation state and therefore wins once present.
        if importMetadata.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            importMetadata.title = title
        }
        // Preserve an existing folder link when this import does not supply one.
        // A group can mix sources (e.g. Drive sessions plus a read.ai session);
        // a later non-Drive import must not clear the Drive folder URL, or the
        // group becomes unrefreshable because refresh paths skip null-URL groups.
        if let localFolderPath, !localFolderPath.isEmpty {
            importMetadata.localFolderPath = localFolderPath
        }
        if let trimmedDriveURL, !trimmedDriveURL.isEmpty {
            importMetadata.driveFolderURL = trimmedDriveURL
        }
        var metadata = meetingMetadata[groupID] ?? MeetingMetadata(title: title)
        if metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            metadata.title = title
        }
        let displayTitle = metadata.title ?? title
        if importIdentityGroupID == groupID {
            metadata.driveFolderURL = importMetadata.driveFolderURL
            metadata.localFolderPath = importMetadata.localFolderPath
        }
        let previousMetadata = meetingMetadata[groupID]
        if silent, Self.isMeetingGroupRemoved(groupID: groupID, metadata: metadata) {
            if !Self.hasRecordedMeetingGroupRemovalIdentity(groupID: groupID, metadata: metadata) {
                Self.recordMeetingGroupRemoval(groupID: groupID, metadata: metadata)
            }
            // Import work may already be in flight when the learner removes a
            // folder, and a provider rename must not evade the removal. The
            // durable group/folder identity wins before any source is written.
            if let previousMetadata, !previousMetadata.isHidden {
                var hidden = previousMetadata
                hidden.isHidden = true
                meetingMetadata[groupID] = hidden
                try await storage.saveMeetingGroup(name: groupID, metadata: hidden)
            }
            return
        }
        // An explicit import is the learner deliberately bringing this exact
        // group/folder back. Background refreshes never lift the tombstone.
        if !silent {
            Self.liftMeetingGroupRemoval(groupID: groupID, metadata: metadata)
        }
        if metadata.timezone == nil {
            metadata.timezone = TimeZone.current.identifier
        }
        // An explicit import is the user asking for this group back, so it lifts
        // the hidden flag `removeMeetingGroup` sets — the same way it lifts the
        // removal tombstone above. Background refreshes are silent and leave a
        // hidden group hidden.
        if !silent { metadata.isHidden = false }
        // The identity row needs its own write only when it is a retired alias.
        // For an active group, `metadata` below already carries these fields and
        // writes once after timezone/visibility have been finalized.
        if importIdentityGroupID != groupID, previousImportMetadata != importMetadata {
            meetingMetadata[importIdentityGroupID] = importMetadata
            try await storage.saveMeetingGroup(name: importIdentityGroupID, metadata: importMetadata)
        }
        if previousMetadata != metadata {
            meetingMetadata[groupID] = metadata
        }
        let insertedGroup = userMeetingGroupNames.insert(groupID).inserted
        if insertedGroup { saveUserMeetingGroupNames() }
        if previousMetadata != metadata {
            try await storage.saveMeetingGroup(name: groupID, metadata: metadata)
        }

        var grouped = Dictionary(
            grouping: Self.separatingEmbeddedTranscripts(in: parsedFiles),
            by: \.sessionKey
        )
        // A session the learner removed on its own is archived and its URL is
        // in `dismissed_sources`; `articles` holds active rows only, so to this
        // loop it looks like a session the folder has just gained, and the
        // upsert below (`status = excluded.status`) would stand the archived
        // row back up as active on the next refresh. A background refresh
        // leaves a removed session removed. An explicit import — the learner
        // choosing this folder again — is the one act that lifts a removal, so
        // it clears the tombstone first, with a synced deletion, and imports.
        let dismissedURLs = (try? await storage.loadDismissedSourceURLs()) ?? []
        if !dismissedURLs.isEmpty {
            for sessionKey in Array(grouped.keys) {
                let sourceURL = "meeting://\(groupID)/\(Self.percentEncodedMeetingPathComponent(sessionKey))"
                guard dismissedURLs.contains(sourceURL) else { continue }
                if silent {
                    grouped.removeValue(forKey: sessionKey)
                } else {
                    try await storage.prepareExplicitSourceReAdd(sourceURL)
                }
            }
        }
        guard !grouped.isEmpty else {
            if !silent { showToast(emptyMessage) }
            return
        }

        // One call for the whole import, before the write loop, so the session
        // rows land already named. Grouping is already fixed at this point, so a
        // failure here costs the topic and presenter, never the sessions
        // themselves — surface it and keep the date-based titles.
        //
        // A session filed while the call could not run (no model to run it on,
        // a failed request) kept the date its key spells, and used to keep it
        // for good: only new sessions were ever asked about. Every Nexus
        // session from 2026-10-11 on stayed "2026/10/11" while meeting tasks
        // waited for a paid model. Such a session is asked about again on each
        // refresh until a call has read its current file names once.
        var descriptors: [String: (title: String, presenter: String?)] = [:]
        let existingArticlesByURL = Dictionary(
            articles.map { ($0.url, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var retriedSessionKeys: Set<String> = []
        var retryAttemptKeys: Set<String> = []
        let sessionsToDescribe = grouped.filter { sessionKey, artifacts in
            let url = "meeting://\(groupID)/\(Self.percentEncodedMeetingPathComponent(sessionKey))"
            guard let existing = existingArticlesByURL[url] else { return true }
            guard Self.meetingSessionNeedsDescriptor(
                storedTitle: existing.title,
                author: existing.author,
                sessionKey: sessionKey,
                groupTitle: displayTitle
            ) else { return false }
            let attemptKey = Self.meetingDescriptorAttemptKey(
                groupID: groupID,
                sessionKey: sessionKey,
                fileNames: artifacts.map(\.title)
            )
            guard !MeetingDescriptorAttempts.described.contains(attemptKey) else { return false }
            retriedSessionKeys.insert(sessionKey)
            retryAttemptKeys.insert(attemptKey)
            return true
        }
        if !sessionsToDescribe.isEmpty {
            do {
                descriptors = try await Self.meetingSessionDescriptors(for: sessionsToDescribe, groupTitle: displayTitle)
                // Read once with these file names: a session whose files carry
                // no topic is not asked about again until they change.
                MeetingDescriptorAttempts.described.formUnion(retryAttemptKeys)
            } catch {
                logger.error("Meeting session detail extraction failed: \(error.localizedDescription)")
                if !silent {
                    showToast("Could not read meeting topics: \(error.localizedDescription)")
                }
            }
        }

        let ownTranscriptionEnabled = Self.isMeetingOwnTranscriptionEnabled
        // Counted apart, because a refresh walks every session in the folder
        // whether or not anything about it moved. `importedSourceIDs` stays the
        // whole set: it feeds the icon backfill, which is about sessions that
        // still have no picture, not about sessions that arrived just now.
        var added = 0
        var updated = 0
        var importedSourceIDs: [String] = []
        // A plugin refresh can walk dozens of sessions. Keep its observable
        // state private until every durable write succeeds, then publish at
        // most one article snapshot and one artifact snapshot. Mutating either
        // collection once per session made List reconcile the whole Meetings
        // outline repeatedly while a silent tab-open refresh was still running,
        // which presented as rows jittering and flashing even when the provider
        // returned exactly the data already on screen.
        var stagedArticles = articles
        var stagedArtifactsBySourceID = meetingArtifactsBySourceId
        for (sessionKey, artifacts) in grouped {
            let sortedArtifacts = artifacts.sorted { $0.kind.sortRank < $1.kind.sortRank }
            let sourceURL = "meeting://\(groupID)/\(Self.percentEncodedMeetingPathComponent(sessionKey))"
            let descriptor = descriptors[sessionKey]
                ?? (title: Self.meetingSessionTitle(from: sessionKey, groupTitle: displayTitle), presenter: nil)
            let existingArticle = stagedArticles.first { $0.url == sourceURL }
            var article = existingArticle
                ?? StudioArticle(
                    url: sourceURL,
                    title: descriptor.title,
                    sourceType: .meeting,
                    discoveryOrigin: discoveryOrigin,
                    parentGroup: groupID
                )
            article.sourceType = .meeting
            // A session filed under its date takes the topic it was just read
            // for. A title the learner wrote never reaches here: it is not a
            // date, so the session was not asked about.
            if existingArticle != nil, retriedSessionKeys.contains(sessionKey),
               let described = descriptors[sessionKey] {
                article.title = described.title
            }
            // Only stamp the origin on sessions this import created. A group may
            // mix plugins (Drive sessions plus a read.ai session), and
            // overwriting on every re-import dragged existing sessions into
            // whichever plugin ran last, emptying the other tab.
            if article.discoveryOrigin == nil { article.discoveryOrigin = discoveryOrigin }
            article.parentGroup = groupID
            // Sessions used to be stored as "<series> - <topic>", which repeated
            // the row they already sit under on every line of the folder. Take
            // that prefix back off however this session is titled now: the
            // group's current and provider names, and the series its own key
            // spells out, which is the folder name from before a rename.
            article.title = Self.strippingMeetingSeriesPrefix(
                from: article.title,
                series: [displayTitle, title, Self.meetingSeriesTitle(from: sessionKey)].compactMap { $0 }
            )
            article.domain = displayTitle
            article.localFilePath = localFolderPath
            if let presenter = descriptor.presenter {
                article.author = presenter
            }
            if let occurredAt = Self.meetingDate(from: sessionKey) {
                article.dateAdded = occurredAt
            }
            let storedPriorArtifacts = (try? await storage.loadMeetingArtifacts(sourceID: article.id)) ?? []
            let priorArtifacts = stagedArtifactsBySourceID[article.id] ?? storedPriorArtifacts
            let generatedTranscriptID = SourceIdentity.stableID(for: "\(article.id):generated:transcript")
            let priorContent = existingArticle?.content
            let articleTitle = article.title
            let preparedContent = await Task.detached(priority: .utility) {
                let hasImportedTranscript = sortedArtifacts.contains(where: {
                    $0.kind == .transcript
                        && $0.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                })
                let preservedTranscript = hasImportedTranscript
                    ? nil
                    : MeetingContent.text(for: .transcript, in: priorContent)
                var sections = sortedArtifacts.compactMap { artifact -> String? in
                    guard let text = artifact.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty else { return nil }
                    return "## \(artifact.kind.label)\n\n\(text)"
                }
                if let preservedTranscript {
                    sections.insert("## Transcript\n\n\(preservedTranscript)", at: 0)
                }
                guard !sections.isEmpty else {
                    return (content: nil as String?, wordCount: nil as Int?, preservedTranscript: preservedTranscript)
                }
                let content = "# \(articleTitle)\n\n" + sections.joined(separator: "\n\n")
                return (content: content as String?, wordCount: content.split(separator: " ").count as Int?, preservedTranscript: preservedTranscript)
            }.value
            if preparedContent.content == nil {
                article.content = nil
                article.wordCount = nil
                article.state = .error
                article.errorMessage = ownTranscriptionEnabled
                    ? "No transcript, notes, or chat text found. Open the recording to generate its transcript."
                    : "Google Drive has no transcript, notes, or chat text for this session yet."
            } else {
                article.content = preparedContent.content
                article.wordCount = preparedContent.wordCount
                article.state = .ready
                article.errorMessage = nil
            }

            var sessionChanged = false
            if existingArticle != article {
                sessionChanged = true
                try await storage.saveSource(article, syncImmediately: true)
                if article.state == .ready { MeetingActionItemExtractor.shared.noteTranscriptReady(sourceID: article.id) }
                if let existingIndex = stagedArticles.firstIndex(where: { $0.id == article.id }) {
                    stagedArticles[existingIndex] = article
                } else {
                    stagedArticles.append(article)
                }
            }

            var savedArtifacts: [MeetingArtifact] = []
            var existingArtifacts: [String: MeetingArtifact] = [:]
            for artifact in priorArtifacts {
                existingArtifacts[artifact.id] = artifact
            }
            for (index, parsed) in sortedArtifacts.enumerated() {
                let artifact = MeetingArtifact(
                    id: SourceIdentity.stableID(for: "\(article.id):\(parsed.url.absoluteString):\(parsed.kind.rawValue)"),
                    sourceId: article.id,
                    groupId: groupID,
                    kind: parsed.kind,
                    title: parsed.title,
                    url: parsed.externalURL,
                    localFilePath: parsed.localFilePath,
                    mimeType: parsed.mimeType,
                    modifiedAt: parsed.modifiedAt,
                    sortIndex: index
                )
                if existingArtifacts[artifact.id] != artifact {
                    sessionChanged = true
                    try await storage.saveMeetingArtifact(artifact)
                }
                savedArtifacts.append(artifact)
            }
            if preparedContent.preservedTranscript != nil,
               let generated = existingArtifacts[generatedTranscriptID],
               !savedArtifacts.contains(where: { $0.id == generated.id }) {
                savedArtifacts.append(generated)
            }
            savedArtifacts.sort { $0.sortIndex < $1.sortIndex }
            stagedArtifactsBySourceID[article.id] = savedArtifacts
            importedSourceIDs.append(article.id)
            if existingArticle == nil {
                added += 1
            } else if sessionChanged {
                updated += 1
            }
        }

        // Fold sessions this folder filed a second time into the session that
        // holds their files now.
        //
        // A Drive file belongs to exactly one meeting, so a stored session that
        // shares a file with a session in this import *is* that meeting. Two
        // retired rules left such rows behind: the session key used to be built
        // from the group's display title, so renaming the folder re-keyed every
        // session in it, and a recursive listing used to walk into subfolders
        // that are series of their own, so a parent folder held a copy of every
        // session in the meetings folder nested inside it. The second case is
        // recognised by a file this folder no longer lists that another series
        // now owns — the folder gave it up, so the session goes with it.
        //
        // Matching on the file rather than on titles or dates is what makes the
        // fold safe: it can never merge two meetings that merely look alike, and
        // a folder holding no stale sessions does no work at all. Whatever the
        // stale row carried — schedule placements, Notebook membership, chats,
        // highlights — is handed to the surviving session before it is archived.
        var foldedSessionIDs: [String] = []
        let importedFiles = Set(parsedFiles.compactMap(Self.meetingFileIdentity))
        let importedOwnerByFile = Self.meetingArtifactFileOwners(
            sourceIDs: importedSourceIDs,
            artifacts: stagedArtifactsBySourceID
        )
        let otherSeriesOwnerByFile = Self.meetingArtifactFileOwners(
            sourceIDs: stagedArticles.lazy
                .filter { $0.sourceType == .meeting }
                .filter { $0.parentGroup.map(self.canonicalMeetingGroupID) != groupID }
                .map(\.id),
            artifacts: stagedArtifactsBySourceID
        )
        for stale in stagedArticles where stale.sourceType == .meeting
            && stale.parentGroup.map(canonicalMeetingGroupID) == groupID
            && !importedSourceIDs.contains(stale.id) {
            let files = stagedArtifactsBySourceID[stale.id] ?? []
            guard let canonicalID = files.lazy.compactMap({ artifact -> String? in
                guard let file = Self.meetingArtifactFileIdentity(artifact) else { return nil }
                if let owner = importedOwnerByFile[file] { return owner }
                // Only a file this listing no longer carries can move a session
                // out of this series; anything still in the folder stays here.
                guard !importedFiles.contains(file) else { return nil }
                return otherSeriesOwnerByFile[file]
            }).first(where: { $0 != stale.id }) else { continue }
            do {
                try await storage.archiveMeetingSessionDuplicate(stale.id, replacingWith: canonicalID)
                foldedSessionIDs.append(stale.id)
            } catch {
                logger.error("Folding duplicate meeting session failed: \(error.localizedDescription)")
            }
        }
        if !foldedSessionIDs.isEmpty {
            let folded = Set(foldedSessionIDs)
            stagedArticles.removeAll { folded.contains($0.id) }
            for sourceID in folded { stagedArtifactsBySourceID[sourceID] = nil }
            logger.notice("Folded \(folded.count) re-keyed meeting session(s) into their current session")
        }

        if stagedArticles != articles {
            articles = stagedArticles
        }
        if stagedArtifactsBySourceID != meetingArtifactsBySourceId {
            meetingArtifactsBySourceId = stagedArtifactsBySourceID
        }
        if !foldedSessionIDs.isEmpty {
            await reloadSourceRelationshipsAfterMerge()
        }

        // Artwork, once the artifacts are stored — the free sources read the
        // recording this loop just saved. Deliberately unawaited: an icon can
        // mean downloading a recording, and an import must not sit behind forty
        // of those before it reports what it brought in.
        let iconSourceIDs = importedSourceIDs
        Task { [weak self] in
            await self?.backfillIconsForImportedMeetings(sourceIDs: iconSourceIDs)
        }

        if !silent {
            // Every provider lands in the same place now, so there is no tab to
            // choose and no way to choose it wrongly. Picking one used to be a
            // real bug: the destination was hardcoded to Read AI, so importing a
            // Drive folder dropped the learner on an unrelated empty tab.
            //
            // Landing on a tab Studio unpinned for want of evidence: this import
            // is the evidence, so pin it rather than select a tab the tab bar
            // does not show.
            if autoUnpinnedIntegrationTabs.contains(.meetings) {
                showTab(.meetings)
            }
            sidebarTab = .meetings
            // Whichever provider this import came from, show it rather than
            // whatever provider was filtered to before.
            meetingProviderFilter = nil
            showToast(Self.meetingImportSummary(added: added, updated: updated))
        }
    }

    /// What an import actually brought in.
    ///
    /// Every import walks the whole folder, so the count of sessions it touched
    /// is just the size of the folder: refreshing a group of forty-two sessions
    /// reported "Imported 42 meeting sessions" every time, having imported none
    /// of them. Only sessions that did not exist before are imported. Ones whose
    /// files changed upstream — a transcript Google finished after the first
    /// import — are updates, and worth saying so. A refresh that found neither
    /// says that, rather than claiming an import that did not happen.
    nonisolated static func meetingImportSummary(added: Int, updated: Int) -> String {
        func sessions(_ count: Int) -> String {
            "\(count) meeting session\(count == 1 ? "" : "s")"
        }
        switch (added, updated) {
        case (0, 0): return "No new meeting sessions"
        case (0, _): return "Updated \(sessions(updated))"
        case (_, 0): return "Imported \(sessions(added))"
        default: return "Imported \(sessions(added)), updated \(updated)"
        }
    }

    /// Every Drive folder already standing as a meeting series of its own, apart
    /// from the one being imported. An import must not walk into these: they are
    /// their own identity boundary, and a parent folder that swept one up filed
    /// a second copy of every session inside it.
    func linkedGoogleDriveFolderIDs(excluding folderID: String) -> Set<String> {
        var ids: Set<String> = []
        for (groupID, metadata) in meetingMetadata {
            // A series the learner removed is no longer a boundary: its folder
            // is ordinary content of whatever contains it.
            guard !metadata.isHidden,
                  !Self.isMeetingGroupRemoved(groupID: groupID, metadata: metadata),
                  let url = metadata.driveFolderURL,
                  let id = try? Self.googleDriveFolderID(from: url),
                  id != folderID else { continue }
            ids.insert(id)
        }
        return ids
    }

    func existingMeetingID(forTitle title: String) -> String? {
        meetingMetadata.first { key, metadata in
            (metadata.title ?? key).caseInsensitiveCompare(title) == .orderedSame
        }.map { canonicalMeetingGroupID($0.key) }
    }

    /// Kind tokens Drive exports append (`… - Recording`) or that humans bracket
    /// inline (`2026-06-28 - [Recording] - Topic - Presenter`). Matched anywhere
    /// so a mid-string token still classifies; see `meetingSessionKey`.
    nonisolated private static let meetingKindTokenPattern =
        #"(?i)(?:\s*[-–—]\s*|^)\[?(chat|notes by gemini|meeting notes|notes|recording|transcript)\]?(?=\s*[-–—]|\s*$)"#

    /// The bracketed kind token in a name, if any (`[Notes]` -> "notes").
    nonisolated private static func bracketedKindToken(in stem: String) -> String? {
        guard let range = stem.range(of: #"\[([^\]]+)\]"#, options: .regularExpression) else { return nil }
        return stem[range]
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
    }

    /// Promote the transcript Google buries inside a Meet notes Doc into its
    /// own artifact.
    ///
    /// Meet writes one Doc holding all three of Gemini's tabs — quick notes,
    /// full notes, and the verbatim transcript — so classification by file name
    /// can only ever call the whole thing "notes". The session then showed Notes
    /// and Recording, the reader saw no transcript artifact, and it started a
    /// paid speech-to-text run to reproduce text that had shipped in the file.
    /// Splitting here — before grouping, so every part lands on the same session
    /// key — gives the session a real transcript artifact and stops that
    /// duplicate work.
    ///
    /// Both notes tabs are kept. They are separate things Gemini wrote about the
    /// same meeting, and the notes artifact carries them as two headed sections
    /// rather than dropping either.
    ///
    /// A session that already carries a standalone transcript file keeps it and
    /// only has the redundant copy trimmed out of its notes: an explicit
    /// artifact always outranks one recovered from inside another file.
    nonisolated static func separatingEmbeddedTranscripts(
        in parsed: [ParsedMeetingArtifact]
    ) -> [ParsedMeetingArtifact] {
        let sessionsWithTranscriptFile = Set(
            parsed.filter { $0.kind == .transcript }.map(\.sessionKey)
        )
        return parsed.flatMap { artifact -> [ParsedMeetingArtifact] in
            guard artifact.kind == .notes else { return [artifact] }
            let split = GoogleMeetNotesSplit.split(artifact.text)

            func part(_ kind: MeetingArtifactKind, _ text: String?) -> ParsedMeetingArtifact {
                ParsedMeetingArtifact(
                    url: artifact.url,
                    title: artifact.title,
                    sessionKey: artifact.sessionKey,
                    kind: kind,
                    text: text,
                    externalURL: artifact.externalURL,
                    localFilePath: artifact.localFilePath,
                    mimeType: artifact.mimeType,
                    modifiedAt: artifact.modifiedAt
                )
            }

            var separated = [part(.notes, split.notes)]
            if let transcript = split.transcript,
               !sessionsWithTranscriptFile.contains(artifact.sessionKey) {
                separated.append(part(.transcript, transcript))
            }
            return separated
        }
    }

    nonisolated static func meetingArtifactKind(fileName: String, mimeType: String?) -> MeetingArtifactKind? {
        let nsName = fileName as NSString
        let lower = nsName.deletingPathExtension.lowercased()
        let ext = nsName.pathExtension.lowercased()
        // A bracketed token is an explicit declaration, not an inferred label.
        if let token = bracketedKindToken(in: lower) {
            switch token {
            case "transcript": return .transcript
            case "notes", "meeting notes", "notes by gemini": return .notes
            case "chat": return .chat
            case "recording": return .recording
            default: break
            }
        }
        // Google's own Meet exports use unbracketed structural suffixes such
        // as "- Transcript", "- Notes by Gemini", and "- Recording". The
        // session-key parser already recognizes these tokens; classification
        // must use the same evidence or transcript Docs become generic
        // attachments and never appear as the meeting transcript.
        if let regex = try? NSRegularExpression(pattern: meetingKindTokenPattern),
           let match = regex.firstMatch(
               in: lower,
               range: NSRange(lower.startIndex..<lower.endIndex, in: lower)
           ),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: lower) {
            switch String(lower[range]) {
            case "transcript": return .transcript
            case "notes", "meeting notes", "notes by gemini": return .notes
            case "chat": return .chat
            case "recording": return .recording
            default: break
            }
        }
        if lower.range(of: #"\btranscript\b"#, options: .regularExpression) != nil {
            return .transcript
        }
        if lower.range(of: #"\b(notes by gemini|meeting notes)\b"#, options: .regularExpression) != nil {
            return .notes
        }
        if ext == "vtt" || ext == "srt" || ext == "ttml" {
            return .transcript
        }
        if ext == "sbv" { return .chat }
        if ["mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac"].contains(ext)
            || mimeType?.hasPrefix("audio/") == true
            || mimeType?.hasPrefix("video/") == true {
            return .recording
        }
        return nil
    }

    nonisolated private static func isSupportedMeetingAttachment(fileName: String, mimeType: String?) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if ["txt", "md", "markdown", "pdf", "docx", "gdoc", "html", "htm"].contains(ext) {
            return true
        }
        guard let mimeType else { return false }
        return [
            "text/plain",
            "text/markdown",
            "text/html",
            "application/pdf",
            "application/vnd.google-apps.document",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ].contains(mimeType)
    }

    nonisolated static func googleDriveFolderID(from value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SourceError.invalidURL }
        if !trimmed.contains("/") && !trimmed.contains(" ") { return trimmed }
        guard let url = URL(string: trimmed) else { throw SourceError.invalidURL }
        let parts = url.pathComponents
        if let folderIndex = parts.firstIndex(of: "folders") {
            let idIndex = parts.index(after: folderIndex)
            if parts.indices.contains(idIndex), !parts[idIndex].isEmpty { return parts[idIndex] }
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              !id.isEmpty else { throw SourceError.invalidURL }
        return id
    }

    nonisolated static func fetchAuthenticatedGoogleDriveMeetingArtifacts(
        folderID: String,
        accountID: String? = nil,
        excludingFolderIDs: Set<String> = []
    ) async throws -> [ParsedMeetingArtifact] {
        let files = try await GoogleDriveService.shared.listFolderItemsRecursively(
            folderID: folderID,
            accountID: accountID,
            excludingFolderIDs: excludingFolderIDs
        )
        var artifacts: [ParsedMeetingArtifact] = []
        for file in files where !file.isFolder {
            let kind = meetingArtifactKind(fileName: file.name, mimeType: file.effectiveMimeType)
            guard kind != nil || isSupportedMeetingAttachment(fileName: file.name, mimeType: file.effectiveMimeType) else {
                continue
            }
            let artifactKind = kind ?? .attachment
            let text = try await readAuthenticatedGoogleDriveTextArtifact(file, kind: artifactKind)
            let stem = (file.name as NSString).deletingPathExtension
            artifacts.append(ParsedMeetingArtifact(
                url: URL(string: file.webURL) ?? URL(string: "https://drive.google.com/file/d/\(file.id)/view")!,
                title: stem.isEmpty ? file.name : stem,
                sessionKey: meetingSessionKey(from: stem),
                kind: artifactKind,
                text: text,
                externalURL: file.webURL,
                localFilePath: nil,
                mimeType: meetingMimeType(fileName: file.name, mimeType: file.effectiveMimeType),
                modifiedAt: file.modifiedAt
            ))
        }
        return artifacts
    }

    nonisolated private static func readAuthenticatedGoogleDriveTextArtifact(
        _ file: GoogleDriveFile,
        kind: MeetingArtifactKind
    ) async throws -> String? {
        guard kind == .transcript || kind == .notes || kind == .chat || kind == .attachment else {
            return nil
        }
        guard let raw = try await GoogleDriveService.shared.downloadText(file: file) else { return nil }
        let ext = (file.name as NSString).pathExtension.lowercased()
        if ext == "ttml", let extracted = try? SourceService.extractTextFromTTMLContent(raw) {
            return extracted
        }
        if ext == "html" || ext == "htm" {
            return raw
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw
    }

    /// Collapse every file belonging to one real meeting onto a single key.
    ///
    /// Drive folders mix two naming conventions for the same series: the Meet
    /// export (`Acme Lab Nexus - 2026/06/21 09:00 PDT - Recording`) and
    /// hand-named uploads (`2026-06-28 - [Recording] - Topic - Presenter`). Both
    /// must land on one session, or a meeting fans out into a row per file.
    ///
    /// The key is canonicalised to `<series> - yyyy/MM/dd`: kind tokens are
    /// stripped wherever they appear, and the time-of-day is dropped so a
    /// timestamped export folds together with a date-only upload for the same
    /// day. Names with no parseable date fall back to the cleaned stem.
    ///
    /// Everything the key is made of comes out of the file's own name. Nothing
    /// mutable is allowed in: the key used to fall back to the group's display
    /// title whenever a file led with its date (`2026-08-30 - [Recording] - …`,
    /// the hand-named convention), which made session identity a function of a
    /// name the learner can edit. Renaming the folder therefore re-keyed every
    /// session in it, and the next refresh imported all of them a second time —
    /// forty-two sessions became eighty-four, each one twice. A date-led file
    /// keys on its date alone; the group id already says which series it is.
    nonisolated static func meetingSessionKey(from fileStem: String) -> String {
        let key = fileStem
            .replacingOccurrences(of: meetingKindTokenPattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—\t"))
        // A name that is nothing but a kind marker still has to key on
        // something of its own, so the untouched stem is all there is.
        guard !key.isEmpty else { return fileStem }
        guard let date = meetingDate(from: key) else { return key }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy/MM/dd"
        let day = formatter.string(from: date)
        guard let series = meetingSeriesTitle(from: key), !series.isEmpty else { return day }
        return "\(series) - \(day)"
    }

    /// The session key encoded in a `meeting://<groupID>/<sessionKey>` source URL.
    /// The session key of a `meeting://<group id>/<session key>` URL, percent-
    /// decoded. Parsed by hand: a group id such as
    /// `zoom:examplefellowship.zoom.us` carries a colon that `URLComponents`
    /// reads as a port and refuses the whole URL, which left every session of
    /// that series without a key here — and so without the start its key
    /// spells (`MeetingCalendarEvent.knownStart`).
    nonisolated static func meetingSessionKey(fromSourceURL url: String) -> String? {
        let prefix = "meeting://"
        guard url.hasPrefix(prefix) else { return nil }
        let rest = url.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let encoded = String(rest[rest.index(after: slash)...])
        let path = encoded.removingPercentEncoding ?? encoded
        return path.isEmpty ? nil : path
    }

    /// Resolve the topic and presenter for each session in one AI call.
    ///
    /// Meeting file names are hand-rolled and endlessly varied — the series may
    /// lead or follow the date, kind markers may be bracketed or trailing, and
    /// the presenter is just a name at the end that has to be told apart from
    /// the rest of the topic. That is a reading task, not a parsing one.
    ///
    /// Session *identity* stays deterministic: grouping is done by
    /// `meetingSessionKey` before this runs, so a failed or slow call can never
    /// change which files belong to which session — only how the session reads.
    nonisolated static func meetingSessionDescriptors(
        for grouped: [String: [ParsedMeetingArtifact]],
        groupTitle: String
    ) async throws -> [String: (title: String, presenter: String?)] {
        guard let config = KeychainService.resolveConfig(for: .meetingSessionDetails) else {
            throw AIError.missingAPIKey
        }
        let sessions = grouped.map { key, artifacts in
            (
                id: key,
                fileNames: artifacts.map(\.title),
                notesExcerpt: artifacts.first { $0.kind == .notes }?.text
            )
        }
        // AIService is an actor, so the call runs off the main actor.
        let details = try await AIService().extractMeetingSessionDetails(
            seriesTitle: groupTitle,
            sessions: sessions,
            config: config
        )
        return grouped.keys.reduce(into: [:]) { result, key in
            let detail = details[key]
            let topic = detail?.title ?? ""
            result[key] = (
                title: topic.isEmpty ? meetingSessionTitle(from: key, groupTitle: groupTitle) : topic,
                presenter: detail?.presenter
            )
        }
    }

    /// The file an artifact was read from, as the one thing about it that two
    /// sessions can only share by being the same meeting. A Drive artifact is
    /// its file's URL; a folder import is its path on disk.
    nonisolated static func meetingArtifactFileIdentity(_ artifact: MeetingArtifact) -> String? {
        meetingFileIdentity(url: artifact.url, localFilePath: artifact.localFilePath)
    }

    /// The same identity, read off a file an import has just parsed.
    nonisolated static func meetingFileIdentity(_ parsed: ParsedMeetingArtifact) -> String? {
        meetingFileIdentity(url: parsed.externalURL, localFilePath: parsed.localFilePath)
    }

    nonisolated private static func meetingFileIdentity(
        url: String?,
        localFilePath: String?
    ) -> String? {
        let url = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url, !url.isEmpty { return url }
        let path = localFilePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let path, !path.isEmpty { return "file:\(path)" }
        return nil
    }

    /// Which session currently owns each file, across the sessions an import
    /// just wrote. A file named by two of them cannot decide anything, so it is
    /// dropped rather than folding a session into an arbitrary one of the pair.
    nonisolated static func meetingArtifactFileOwners(
        sourceIDs: [String],
        artifacts: [String: [MeetingArtifact]]
    ) -> [String: String] {
        var owners: [String: String] = [:]
        var contested: Set<String> = []
        for sourceID in sourceIDs {
            for artifact in artifacts[sourceID] ?? [] {
                guard let file = meetingArtifactFileIdentity(artifact) else { continue }
                if let existing = owners[file], existing != sourceID {
                    contested.insert(file)
                    continue
                }
                owners[file] = sourceID
            }
        }
        for file in contested { owners[file] = nil }
        return owners
    }

    /// A session's own name, with the series it sits under taken back out.
    ///
    /// The series is the row this session is filed under, so repeating it in
    /// every child read as "Acme Lab Nexus — Acme Lab Nexus - Journal Club
    /// - …" down the whole folder. The session is named for what happened in
    /// it; when the file names carry nothing but a series and a date, the date
    /// is the honest answer.
    nonisolated static func meetingSessionTitle(from sessionKey: String, groupTitle: String) -> String {
        let stripped = strippingMeetingSeriesPrefix(from: sessionKey, series: [groupTitle])
        return stripped.isEmpty ? sessionKey : stripped
    }

    /// Whether a filed session still reads as nothing but when it happened,
    /// with no presenter: the name an import gives a session it could not
    /// read the topic of. A title the learner or a provider wrote, or a
    /// session that has a presenter, has been read and is left alone.
    nonisolated static func meetingSessionNeedsDescriptor(
        storedTitle: String,
        author: String?,
        sessionKey: String,
        groupTitle: String
    ) -> Bool {
        if let author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        let series = [groupTitle, meetingSeriesTitle(from: sessionKey)].compactMap { $0 }
        let stored = strippingMeetingSeriesPrefix(from: storedTitle, series: series)
        return stored == sessionKey
            || stored == meetingSessionTitle(from: sessionKey, groupTitle: groupTitle)
            || isRawMeetingDateTitle(stored)
    }

    /// One session read with one set of file names, so a session is asked
    /// about again only when its files change.
    nonisolated static func meetingDescriptorAttemptKey(
        groupID: String,
        sessionKey: String,
        fileNames: [String]
    ) -> String {
        ([groupID, sessionKey] + fileNames.sorted()).joined(separator: "\u{1F}")
    }

    /// What a session row prints where its name goes.
    ///
    /// `day` is set when `text` is a formatted day: the metadata line then
    /// prints `time` alone instead of saying the same day twice. `time` is the
    /// instant whose clock reading that line shows, and it is nil when nothing
    /// trustworthy says when on that day the meeting ran.
    struct MeetingSessionRowTitle: Equatable {
        var text: String
        var day: Date?
        var time: Date?
    }

    /// The row title for a session filed under `groupTitle`.
    ///
    /// Sessions arrive titled three ways: `<series> - <date time>` from the
    /// folder importers and MCP, `<shortened series> - <date time>` when the
    /// provider's topic was trimmed ("Alan <> Zara" under a series called
    /// "Alan <> Zara standup") or spelled the way a file name must spell it
    /// ("Alan __ Zara"), or a real topic the learner or the provider wrote.
    /// The first two are the same thing — a meeting named for nothing but
    /// when it happened — and read as one format: the day, spelled out.
    /// The day comes from the title itself when it carries one, because a
    /// session pushed in a day late without `occurred_at` is still the meeting
    /// its title names, not the moment it was filed. The time comes from the
    /// title too; a title with only a day borrows the filing time when that
    /// fell on the same day, and otherwise the row shows no time at all rather
    /// than midnight.
    nonisolated static func meetingSessionRowTitle(
        storedTitle: String,
        groupTitle: String,
        dateAdded: Date,
        calendar: Calendar = .current
    ) -> MeetingSessionRowTitle {
        var series = [groupTitle]
        if let own = meetingSeriesTitle(from: storedTitle), isSeriesVariant(own, of: groupTitle) {
            series.append(own)
        }
        let remainder = strippingMeetingSeriesPrefix(from: storedTitle, series: series)
        guard isRawMeetingDateTitle(remainder) else {
            return MeetingSessionRowTitle(text: remainder, day: nil, time: nil)
        }
        let day = meetingDate(from: remainder) ?? dateAdded
        let time: Date?
        if remainder.range(of: #"\d{1,2}[:.]\d{2}"#, options: .regularExpression) != nil {
            time = day
        } else if calendar.isDate(dateAdded, inSameDayAs: day) {
            time = dateAdded
        } else {
            time = nil
        }
        return MeetingSessionRowTitle(text: day.formatted(date: .long, time: .omitted), day: day, time: time)
    }

    /// True when the remainder of a session title is only a date, with or
    /// without a time and zone: "2026/05/10", "2026/05/10 08:00 PDT".
    nonisolated static func isRawMeetingDateTitle(_ value: String) -> Bool {
        value.range(of: #"^\d{4}[/-]\d{1,2}[/-]\d{1,2}[\s.:0-9]*[A-Z]{0,4}$"#, options: .regularExpression) != nil
    }

    /// Whether one series name is the other cut short at a word boundary:
    /// "Alan <> Zara" against "Alan <> Zara standup". A provider renames its
    /// recurring meeting, or a learner renames the series here, and the titles
    /// already stored keep the older spelling. The two are compared as Zoom
    /// spells them in a file name, because a recording folder cannot carry
    /// `<>` and its sessions arrive as "Alan __ Zara" under a series called
    /// "Alan <> Zara standup" — which read as the raw title in the middle of
    /// a folder of dates until 2026-09-28 (the product owner: "can you please make sure
    /// these zoom meetings show up consistently?"). Anything shorter than a
    /// few characters is not a name, it is a coincidence.
    nonisolated static func isSeriesVariant(_ candidate: String, of groupTitle: String) -> Bool {
        let first = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let second = groupTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard first.count >= 3, second.count >= 3 else { return false }
        let (short, long) = first.count < second.count ? (first, second) : (second, first)
        // The spelling maps one character to one, so an offset into the
        // file-name form is the same offset into the title.
        let shortForm = meetingTitleFileNameSpelling(short)
        let longForm = meetingTitleFileNameSpelling(long)
        if shortForm == longForm { return true }
        guard longForm.hasPrefix(shortForm) else { return false }
        let boundary = long[long.index(long.startIndex, offsetBy: short.count)]
        return boundary == " " || "-–—:".contains(boundary)
    }

    /// A meeting title the way Zoom writes it into a file or folder name:
    /// every character a file name cannot carry becomes `_`, so "Alan <>
    /// Zara" is "Alan __ Zara" on disk.
    nonisolated static func meetingTitleFileNameSpelling(_ title: String) -> String {
        let forbidden: Set<Character> = ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]
        return String(title.map { forbidden.contains($0) ? "_" : $0 })
    }

    /// Remove a leading `<series> - ` from a session title.
    ///
    /// Only a prefix this app wrote is removed: the match is anchored, spans a
    /// whole series name, and has to leave something behind. A session the
    /// learner renamed to something that merely mentions the series keeps it,
    /// because the prefix has to be followed by the separator to count.
    nonisolated static func strippingMeetingSeriesPrefix(
        from title: String,
        series candidates: [String]
    ) -> String {
        var result = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var stripped = true
        while stripped {
            stripped = false
            for candidate in candidates {
                let series = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !series.isEmpty,
                      result.count > series.count,
                      result.lowercased().hasPrefix(series.lowercased()) else { continue }
                // The separator is what proves this was a prefix rather than the
                // opening words of the session's own name.
                let afterSeries = result.dropFirst(series.count).drop { $0 == " " }
                guard let separator = afterSeries.first, "-–—".contains(separator) else { continue }
                let remainder = String(afterSeries.dropFirst())
                    .trimmingCharacters(in: CharacterSet(charactersIn: " -–—"))
                guard !remainder.isEmpty else { continue }
                result = remainder
                stripped = true
            }
        }
        return result
    }

    /// Extract the recurring-series name from a session key by stripping the
    /// trailing date/time portion, e.g. "Acme Lab Nexus - 2026/05/10 08:00 PDT"
    /// -> "Acme Lab Nexus". Returns nil when the key has no date or nothing
    /// precedes it.
    nonisolated static func meetingSeriesTitle(from sessionKey: String) -> String? {
        let pattern = #"(\d{4})[/-](\d{1,2})[/-](\d{1,2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: sessionKey, range: NSRange(sessionKey.startIndex..<sessionKey.endIndex, in: sessionKey)),
              let range = Range(match.range, in: sessionKey) else { return nil }
        let prefix = String(sessionKey[..<range.lowerBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—\t"))
        return prefix.isEmpty ? nil : prefix
    }

    nonisolated static func meetingDate(from sessionKey: String) -> Date? {
        let pattern = #"(\d{4})[/-](\d{1,2})[/-](\d{1,2})(?:\s+(\d{1,2})[:.](\d{2}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: sessionKey, range: NSRange(sessionKey.startIndex..<sessionKey.endIndex, in: sessionKey)),
              match.numberOfRanges >= 4,
              let yearRange = Range(match.range(at: 1), in: sessionKey),
              let monthRange = Range(match.range(at: 2), in: sessionKey),
              let dayRange = Range(match.range(at: 3), in: sessionKey),
              let year = Int(sessionKey[yearRange]),
              let month = Int(sessionKey[monthRange]),
              let day = Int(sessionKey[dayRange]) else { return nil }
        var components = DateComponents()
        components.calendar = Calendar.current
        components.timeZone = TimeZone.current
        components.year = year
        components.month = month
        components.day = day
        if match.numberOfRanges >= 6,
           let hourRange = Range(match.range(at: 4), in: sessionKey),
           let minuteRange = Range(match.range(at: 5), in: sessionKey) {
            components.hour = Int(sessionKey[hourRange])
            components.minute = Int(sessionKey[minuteRange])
        }
        return components.date
    }

    nonisolated private static func meetingMimeType(fileName: String, mimeType: String?) -> String? {
        if let mimeType, !mimeType.isEmpty { return mimeType }
        switch (fileName as NSString).pathExtension.lowercased() {
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "pdf": return "application/pdf"
        case "gdoc": return "application/vnd.google-apps.document"
        case "txt": return "text/plain"
        case "md", "markdown": return "text/markdown"
        case "vtt": return "text/vtt"
        case "srt": return "application/x-subrip"
        case "ttml": return "application/ttml+xml"
        default: return nil
        }
    }

    nonisolated static func percentEncodedMeetingPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? UUID().uuidString
    }

    func saveUserMeetingGroupNames() {
        PreferenceStore.set(Array(userMeetingGroupNames), forKey: "userMeetingGroupNames")
    }

    struct BookGroupNamesCacheKey: Equatable {
        let articlesRevision: Int
        let bookTitles: [String: String]
        let bookSubtitles: [String: String]
        let bookEditions: [String: String]
    }

    var allBookGroupNames: [String] {
        // The key reads stay observation-tracked, so callers still re-render
        // when the article list or book metadata changes; only the scan and
        // localized sort are skipped on repeat evaluation.
        let key = BookGroupNamesCacheKey(
            articlesRevision: articlesRevision,
            bookTitles: bookTitles,
            bookSubtitles: bookSubtitles,
            bookEditions: bookEditions
        )
        if allBookGroupNamesCacheKey == key, let cached = allBookGroupNamesCache {
            return cached
        }
        var names = Set<String>()
        for article in activeArticles where article.sourceType == .book {
            if let g = article.parentGroup { names.insert(g) }
        }
        // Resolve each display name once instead of per sort comparison.
        let sorted = names
            .map { (group: $0, display: bookDisplayName($0)) }
            .sorted { $0.display.localizedCaseInsensitiveCompare($1.display) == .orderedAscending }
            .map(\.group)
        allBookGroupNamesCacheKey = key
        allBookGroupNamesCache = sorted
        return sorted
    }

    var visibleBookGroupNames: [String] {
        allBookGroupNames.filter { !isBookHidden($0) }
    }

    struct FilteredBookGroupNamesCacheKey: Equatable {
        let filter: SidebarFilterCacheKey
        let bookTitles: [String: String]
        let bookSubtitles: [String: String]
        let bookEditions: [String: String]
        let bookAuthors: [String: String]
        let bookKinds: [String: String]
    }

    var filteredBookGroupNames: [String] {
        // The key reads every input `bookMatchesSearch` consults, so the view
        // stays observation-tracked on a cache hit and a renamed book or a new
        // category still recomputes; only the per-book scan is skipped.
        let key = FilteredBookGroupNamesCacheKey(
            filter: currentSidebarFilterCacheKey,
            bookTitles: bookTitles,
            bookSubtitles: bookSubtitles,
            bookEditions: bookEditions,
            bookAuthors: bookAuthors,
            bookKinds: bookKinds
        )
        if sidebarStore.filteredBookGroupNamesCacheKey == key,
           let cached = sidebarStore.filteredBookGroupNamesCache {
            return cached
        }
        // Books matched on their own metadata (or a chapter's) first, then books
        // that only answer for a chapter's text. The second set arrives a debounce
        // after the first is on screen, and must not slot in between rows the
        // learner is already reading — see `computeFilteredActiveItems`.
        var metadataMatches: [String] = []
        var contentOnlyMatches: [String] = []
        for groupName in visibleBookGroupNames where bookMatchesMetadataFilters(groupName) {
            if bookMatchesSearchMetadata(groupName) {
                metadataMatches.append(groupName)
            } else if bookMatchesSearchContent(groupName) {
                contentOnlyMatches.append(groupName)
            }
        }
        let names = metadataMatches + contentOnlyMatches
        sidebarStore.filteredBookGroupNamesCache = names
        sidebarStore.filteredBookGroupNamesCacheKey = key
        return names
    }

    func bookGroupMatchesCurrentFilters(_ groupName: String) -> Bool {
        bookMatchesMetadataFilters(groupName) && bookMatchesSearch(groupName)
    }

    func bookMatchesMetadataFilters(_ groupName: String) -> Bool {
        guard let selectedBookKind else { return true }
        return bookKinds[groupName] == selectedBookKind
    }

    func bookMatchesSearch(_ groupName: String) -> Bool {
        bookMatchesSearchMetadata(groupName) || bookMatchesSearchContent(groupName)
    }

    /// The synchronous half of `bookMatchesSearch`: the book's own metadata and its
    /// chapters' metadata, which the list can answer as the learner types.
    func bookMatchesSearchMetadata(_ groupName: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parsed = SidebarSearchQuery(parsing: query)
        guard !parsed.isEmpty else { return true }

        let bookMetadata = [
            groupName,
            bookDisplayName(groupName),
            bookDisplaySubtitle(groupName),
            bookDisplayAuthor(groupName),
            bookDisplayEdition(groupName),
            bookFormat(groupName),
            bookDisplayKind(groupName),
        ]
        .compactMap { $0 }

        if Self.sidebarGroupMatchesSearch(
            parsed,
            metadata: bookMetadata,
            titles: [groupName, bookDisplayName(groupName), bookDisplaySubtitle(groupName)].compactMap { $0 },
            authors: [bookDisplayAuthor(groupName)].compactMap { $0 }
        ) {
            return true
        }

        return bookSourceArticles(for: groupName).contains(where: { sourceMatchesSearch($0, query: query) })
    }

    /// The asynchronous half of `bookMatchesSearch`: the indexed pass behind the
    /// search field records chapters whose text contains every typed term, and a
    /// book answers for any chapter it owns, so a term that appears only inside a
    /// chapter still finds the book. False while no search is running — this is
    /// only ever asked after `bookMatchesSearchMetadata` said no.
    func bookMatchesSearchContent(_ groupName: String) -> Bool {
        let parsed = SidebarSearchQuery(parsing: searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        guard !parsed.isEmpty else { return false }
        // A scoped search reads metadata only; the indexed pass is cleared for it
        // and must not be consulted from a stale unscoped query.
        guard !parsed.isScoped else { return false }
        let contentMatches = sidebarStore.contentSearchMatchIDs
        guard !contentMatches.isEmpty else { return false }
        return (articlesStore.articleIDsByParentGroup[groupName] ?? [])
            .contains(where: contentMatches.contains)
    }

    func bookSourceArticles(for groupName: String) -> [StudioArticle] {
        // Read from the parent-group index rather than scanning the library. This
        // sits under every per-book question the sidebar asks — visibility, format,
        // search — and a whole-library scan per book made all of them quadratic.
        (articlesStore.articleIDsByParentGroup[groupName] ?? [])
            .compactMap { articlesById[$0] }
            .filter { $0.sourceType == .book }
    }

    func courseArticles(for courseName: String) -> [StudioArticle] {
        let ids = sourceIdsForGroup(courseName)
        return articles.filter { ids.contains($0.id) }
    }

    /// Course-owned sources that are not attached to a numbered lecture still
    /// belong in the course's Materials folder. Lecture relationships and
    /// parent-group ownership are independent, so removing a lecture item must
    /// not make its source disappear from the course UI.
    func unassignedCourseArticles(for courseName: String) -> [StudioArticle] {
        let assignedSourceIDs = Set(
            courseLectures(for: courseName).flatMap { lecture in
                courseLectureItems(for: lecture.id).compactMap(\.sourceId)
            }
        )
        return (articlesStore.articleIDsByParentGroup[courseName] ?? [])
            .compactMap { articlesById[$0] }
            .filter { !assignedSourceIDs.contains($0.id) }
            .sorted(by: learningGoalArticleOrder)
    }

    func courseLectures(for courseName: String) -> [CourseSession] {
        let lectures = courseLecturesByCourse[courseName]?.sorted { $0.number < $1.number } ?? []
        guard lectures.count > 1 else { return lectures }
        return lectures.filter { !isEmptyPlaceholderLecture($0) }
    }

    func courseLectureItems(for lectureId: String) -> [CourseLectureItem] {
        courseLectureItemsByLectureId[lectureId]?.sorted { $0.sortIndex < $1.sortIndex } ?? []
    }

    /// The papers attached to a lecture that has a video only because they are
    /// cited in it, which the course's path does not list: they open from the
    /// video's context menu the way a standalone YouTube video's papers do
    /// (product owner, 2026-09-27: "those attached papers should just be shown maybe
    /// upon right click on the video"). A paper whose item role is `reading`
    /// is assigned reading and keeps its row: "only if we deem it worth while
    /// that reading a paper is ACTUALLY necessary as assigned reading; but if
    /// it's just a citation on one of the slides, then no need to put it under
    /// a course". A lecture with no video keeps all its papers as rows, since
    /// nothing else could offer them. Paper identity is the source type.
    func lectureVideoPapers(for lectureId: String) -> [(item: CourseLectureItem, article: StudioArticle)] {
        guard lectureHasVideo(lectureId) else { return [] }
        return courseLectureItems(for: lectureId).compactMap { item in
            article(for: item).map { (item: item, article: $0) }
        }
        .filter { $0.article.sourceType == .paper && $0.item.role != .reading }
    }

    /// Whether a lecture has a video, which is what can offer its cited papers.
    func lectureHasVideo(_ lectureId: String) -> Bool {
        courseLectureItems(for: lectureId).contains { item in
            item.role == .video && article(for: item).map { $0.sourceType != .paper } == true
        }
    }

    /// Whether a paper on a lecture video's lecture is assigned reading (a row
    /// of the course's path, quizzed with the lecture) or only cited in the
    /// video (under the video's Papers menu).
    func setLectureItemRole(_ itemId: String, to role: CourseLectureItemRole) async {
        guard var item = courseLectureItemsByLectureId.values.lazy.flatMap({ $0 }).first(where: { $0.id == itemId }),
              item.role != role else { return }
        item.role = role
        do {
            _ = try await storage.saveCourseLectureItem(item)
            if let index = courseLectureItemsByLectureId[item.lectureId]?.firstIndex(where: { $0.id == itemId }) {
                courseLectureItemsByLectureId[item.lectureId]?[index] = item
            }
        } catch {
            logger.error("Failed to change lecture material role: \(error.localizedDescription)")
        }
    }

    /// The course row's completion, over the same lecture items its path
    /// lists (videos, papers, readings and materials). A lecture video's
    /// papers are not on the path, so they do not count either. Watch progress is read whatever the
    /// source's type: some playlist lectures are stored as `course` sources and
    /// still record it through the YouTube reader.
    func courseProgress(for courseName: String) -> CourseProgress {
        // Positions are unobserved; this re-renders the row when a lecture finishes.
        _ = readingProgressStore.finishedVideoRevision
        var items: [CourseProgress.Item] = []
        for lecture in courseLectures(for: courseName) {
            let videoPaperItemIDs = Set(lectureVideoPapers(for: lecture.id).map(\.item.id))
            for item in courseLectureItems(for: lecture.id) where !videoPaperItemIDs.contains(item.id) {
                guard let article = article(for: item) else { continue }
                let watched = readingProgressStore.videoWatchProgress(
                    for: article.id,
                    fallbackLocator: article.readingPositionLocator
                )?.isEssentiallyWatched == true
                items.append(CourseProgress.Item(
                    isLectureVideo: item.role == .video && article.sourceType != .paper,
                    isFinished: watched || article.isRead || sourceReviewedAt[article.id] != nil,
                    isStarted: readingProgressStore.hasProgress(for: article.id)
                        || article.hasSavedReadingPosition
                ))
            }
        }
        return CourseProgress(items: items)
    }

    func invalidateCourseDerivedState() {
        courseGroupIDsBySourceIDCache = nil
        allCourseGroupNamesCache = nil
        visibleCourseGroupNamesCache = nil
        invalidateSidebarCachesInEveryWindow()
        refreshScreenRecordShownCourses()
    }

    private func buildCourseGroupIDsBySourceID() -> [String: Set<String>] {
        let knownCourseNames = Set(courseMetadata.keys).union(courseLecturesByCourse.keys)
        var memberships: [String: Set<String>] = [:]

        for courseName in knownCourseNames {
            for sourceID in articlesStore.articleIDsByParentGroup[courseName] ?? [] {
                memberships[sourceID, default: []].insert(courseName)
            }
        }

        for (courseName, lectures) in courseLecturesByCourse {
            for lecture in lectures {
                for item in courseLectureItemsByLectureId[lecture.id] ?? [] {
                    guard let sourceID = item.sourceId else { continue }
                    memberships[sourceID, default: []].insert(courseName)
                }
            }
        }
        return memberships
    }

    func courseGroupIDs(for article: StudioArticle) -> Set<String> {
        if let cached = courseGroupIDsBySourceIDCache {
            return cached[article.id] ?? []
        }
        let memberships = buildCourseGroupIDsBySourceID()
        courseGroupIDsBySourceIDCache = memberships
        return memberships[article.id] ?? []
    }

    func article(for lectureItem: CourseLectureItem) -> StudioArticle? {
        guard let sourceId = lectureItem.sourceId else { return nil }
        return articlesById[sourceId]
    }

    func sourceIdsForGroup(_ groupName: String) -> Set<String> {
        Set(sourceIDsForGroupInOrder(groupName))
    }

    func selectBookGroup(_ groupName: String) async {
        guard let chapter = resumeBookChapter(for: groupName) else { return }
        await selectReaderSource(chapter.id)
    }

    func selectReaderSource(_ articleId: String) async {
        selectedArticleIds = [articleId]
        await selectArticle(articleId)
    }

    @discardableResult
    func selectReaderSource(matchingLocalPath path: String) async -> String? {
        guard let article = sourceMatchingLocalPath(path) else { return nil }
        await selectReaderSource(article.id)
        return article.id
    }

    func updateReadingPosition(forLocalPath path: String, page: Int) {
        guard let article = sourceMatchingLocalPath(path) else { return }
        updateReadingPosition(for: article.id, page: page)
    }

    func updateReadingLocator(forLocalPath path: String, locator: String) {
        guard let article = sourceMatchingLocalPath(path) else { return }
        updateReadingLocator(for: article.id, locator: locator)
    }

    func sourceMatchingLocalPath(_ path: String) -> StudioArticle? {
        let target = Self.standardizedReaderPath(path)
        return articles.first { article in
            // A chapter of a book kept as one file shares the book's path with
            // every other chapter, so a path names none of them.
            guard article.bookPages == nil else { return false }
            let candidates = [
                article.cachedResolvedLocalPath,
                article.localFilePath,
                article.url.hasPrefix("/") ? article.url : nil,
            ]
            .compactMap { $0 }
            return candidates.contains { Self.standardizedReaderPath($0) == target }
        }
    }

    nonisolated static func standardizedReaderPath(_ path: String) -> String {
        URL(fileURLWithPath: StorageService.absoluteSourcePath(path)).standardizedFileURL.path
    }

    func createLecture(in courseName: String, title: String? = nil, number requestedNumber: Int? = nil) async -> CourseSession? {
        let existingNumbers = Set(courseLecturesByCourse[courseName]?.map(\.number) ?? [])
        let fallbackNumber = (existingNumbers.max() ?? 0) + 1
        let number: Int
        if let requestedNumber, requestedNumber > 0, !existingNumbers.contains(requestedNumber) {
            number = requestedNumber
        } else {
            number = fallbackNumber
        }
        let lecture = CourseSession(courseName: courseName, number: number, title: title)
        do {
            try await storage.saveCourseLecture(lecture)
            courseLecturesByCourse[courseName, default: []].append(lecture)
            courseLecturesByCourse[courseName]?.sort { $0.number < $1.number }
            userCourseNames.insert(courseName)
            saveUserCourseNames()
            if courseMetadata[courseName] == nil {
                courseMetadata[courseName] = CourseMetadata()
                try? await storage.saveCourseGroup(name: courseName, metadata: CourseMetadata())
            }
            return lecture
        } catch {
            logger.error("Failed to create lecture in '\(courseName)': \(error.localizedDescription)")
            return nil
        }
    }

    func renameCourseLecture(_ lectureId: String, title: String?) async {
        await updateCourseLectureTitle(lectureId, title: title)
    }

    func firstOrCreateLecture(in courseName: String) async -> CourseSession? {
        if let first = courseLectures(for: courseName).first {
            return first
        }
        return await createLecture(in: courseName)
    }

    func matchingOrFirstLecture(in courseName: String, for article: StudioArticle) async -> CourseSession? {
        if let existing = existingLecture(containing: article.id, in: courseName) {
            return existing
        }
        if let matched = matchingLecture(in: courseName, title: article.title, article: article) {
            return matched
        }
        return await firstOrCreateLecture(in: courseName)
    }

    func playlistItemLecture(
        in courseName: String,
        title: String?,
        playlistPosition: Int,
        existingArticle: StudioArticle?,
        usedLectureIds: Set<String>
    ) async -> CourseSession? {
        if let existingArticle,
           let existing = existingLecture(containing: existingArticle.id, in: courseName),
           !usedLectureIds.contains(existing.id) {
            return existing
        }

        // Playlist imports should show every video the playlist is adding. Do
        // not merge by numbers found in conference/session titles; attached
        // course materials can still match these lectures later by ordinal.
        return await createLecture(in: courseName, title: title, number: playlistPosition)
    }

    func normalizePlaylistLectureOrder(_ lectureIdsInOrder: [String], in courseName: String) async {
        let playlistIds = Array(NSOrderedSet(array: lectureIdsInOrder).compactMap { $0 as? String })
        guard !playlistIds.isEmpty else { return }

        let playlistIdSet = Set(playlistIds)
        var lectures = courseLecturesByCourse[courseName] ?? []

        // An empty playlist lecture leaves the outline only once the store has
        // deleted it; one that could not be deleted stays, as it is stored.
        var deletedLectureIds = Set<String>()
        for lecture in lectures where playlistIdSet.contains(lecture.id) {
            if (courseLectureItemsByLectureId[lecture.id] ?? []).isEmpty {
                do {
                    try await storage.deleteCourseLecture(lecture.id)
                    courseLectureItemsByLectureId[lecture.id] = nil
                    deletedLectureIds.insert(lecture.id)
                } catch {
                    logger.error("Could not delete empty playlist lecture \(lecture.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    showToast("Could not remove an empty lecture: \(error.localizedDescription)")
                }
            }
        }

        lectures = courseLecturesByCourse[courseName]?.filter { !deletedLectureIds.contains($0.id) } ?? []
        courseLecturesByCourse[courseName] = lectures

        let orderedPlaylistLectures = playlistIds.compactMap { id in
            lectures.first { $0.id == id }
        }
        let remainingLectures = lectures
            .filter { !playlistIdSet.contains($0.id) }
            .sorted { $0.number < $1.number }

        let reordered = orderedPlaylistLectures + remainingLectures
        for (index, lecture) in reordered.enumerated() {
            let nextNumber = index + 1
            guard let currentIndex = courseLecturesByCourse[courseName]?.firstIndex(where: { $0.id == lecture.id }),
                  courseLecturesByCourse[courseName]?[currentIndex].number != nextNumber else {
                continue
            }

            courseLecturesByCourse[courseName]?[currentIndex].number = nextNumber
            if let updated = courseLecturesByCourse[courseName]?[currentIndex] {
                do {
                    try await storage.saveCourseLecture(updated)
                } catch {
                    logger.error("Failed to renumber playlist lecture: \(error.localizedDescription)")
                }
            }
        }
        courseLecturesByCourse[courseName]?.sort { $0.number < $1.number }
    }

    func updateLectureItemSortIndex(articleId: String, lectureId: String, sortIndex: Int) async {
        guard var items = courseLectureItemsByLectureId[lectureId],
              let itemIndex = items.firstIndex(where: { $0.sourceId == articleId }),
              items[itemIndex].sortIndex != sortIndex else {
            return
        }

        items[itemIndex].sortIndex = sortIndex
        courseLectureItemsByLectureId[lectureId] = items.sorted { $0.sortIndex < $1.sortIndex }
        do {
            try await storage.saveCourseLectureItem(items[itemIndex])
        } catch {
            logger.error("Failed to update playlist lecture item order: \(error.localizedDescription)")
        }
    }

    func updateCourseLectureTitle(_ lectureId: String, title: String?) async {
        guard let courseName = courseLecturesByCourse.first(where: { _, lectures in
            lectures.contains { $0.id == lectureId }
        })?.key,
              let index = courseLecturesByCourse[courseName]?.firstIndex(where: { $0.id == lectureId }) else {
            return
        }

        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextTitle = normalizedTitle?.isEmpty == true ? nil : normalizedTitle
        guard courseLecturesByCourse[courseName]?[index].title != nextTitle else { return }

        courseLecturesByCourse[courseName]?[index].title = nextTitle
        if let lecture = courseLecturesByCourse[courseName]?[index] {
            do {
                try await storage.saveCourseLecture(lecture)
            } catch {
                logger.error("Failed to update lecture title: \(error.localizedDescription)")
            }
        }
    }

    func removeEmptyPlaceholderLectureIfNeeded(in courseName: String, importedLectureNumbers: [Int]) async {
        guard importedLectureNumbers.contains(where: { $0 > 1 }),
              !importedLectureNumbers.contains(1),
              let placeholder = courseLecturesByCourse[courseName]?.first(where: isEmptyPlaceholderLecture) else {
            return
        }

        do {
            try await storage.deleteCourseLecture(placeholder.id)
            courseLecturesByCourse[courseName]?.removeAll { $0.id == placeholder.id }
            courseLectureItemsByLectureId[placeholder.id] = nil
        } catch {
            logger.error("Failed to remove empty placeholder lecture: \(error.localizedDescription)")
        }
    }

    func isEmptyPlaceholderLecture(_ lecture: CourseSession) -> Bool {
        lecture.number == 1
            && (lecture.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && (courseLectureItemsByLectureId[lecture.id]?.isEmpty ?? true)
    }

    func existingLecture(containing sourceId: String, in courseName: String) -> CourseSession? {
        courseLectures(for: courseName).first { lecture in
            courseLectureItems(for: lecture.id).contains { $0.sourceId == sourceId }
        }
    }

    func matchingLecture(
        in courseName: String,
        title: String?,
        preferredNumber: Int? = nil,
        article: StudioArticle? = nil
    ) -> CourseSession? {
        let lectures = courseLectures(for: courseName)
        guard !lectures.isEmpty else { return nil }

        let explicitOrdinal = article.flatMap { Self.materialOrdinal(for: $0, courseName: courseName) }
            ?? title.flatMap { Self.materialOrdinal(in: Self.stripCoursePrefix($0, courseName: courseName)) }
        let candidateOrdinals: [Int]
        if let explicitOrdinal {
            candidateOrdinals = [explicitOrdinal.major]
        } else if let preferredNumber {
            candidateOrdinals = [preferredNumber]
        } else {
            candidateOrdinals = []
        }

        for ordinal in candidateOrdinals {
            let matches = lectures.filter { lecture in
                if let lectureTitle = lecture.title,
                   Self.materialOrdinal(in: Self.stripCoursePrefix(lectureTitle, courseName: courseName))?.major == ordinal {
                    return true
                }
                return lecture.number == ordinal
            }
            if matches.count == 1 { return matches[0] }
        }

        guard candidateOrdinals.isEmpty else { return nil }

        if let title {
            let normalizedTitle = Self.normalizedLectureTitle(title, courseName: courseName)
            let exactMatches = lectures.filter {
                guard let lectureTitle = $0.title else { return false }
                return Self.normalizedLectureTitle(lectureTitle, courseName: courseName) == normalizedTitle
            }
            if exactMatches.count == 1 { return exactMatches[0] }
        }
        return nil
    }

    /// Move a source to another lecture of its course. The new lecture takes
    /// it first, and only then do the old lectures let it go, each item as
    /// the store deletes it: a failure leaves the source in both lectures,
    /// shown, never in neither. (Not one transaction: the item writes are the
    /// store's own `saveCourseLectureItem`/`deleteCourseLectureItem`, each
    /// committed on its own.)
    func moveArticle(_ articleId: String, toLecture targetLectureId: String, inCourse courseName: String) async {
        guard await addArticleToLecture(articleId: articleId, lectureId: targetLectureId) else { return }
        for lecture in courseLectures(for: courseName) where lecture.id != targetLectureId {
            let removed = (courseLectureItemsByLectureId[lecture.id] ?? []).filter { $0.sourceId == articleId }
            for item in removed {
                do {
                    try await storage.deleteCourseLectureItem(item.id)
                } catch {
                    logger.error("Could not take source \(articleId, privacy: .public) out of lecture \(lecture.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    showToast("Could not take it out of its old lecture: \(error.localizedDescription)")
                    continue
                }
                courseLectureItemsByLectureId[lecture.id]?.removeAll { $0.id == item.id }
            }
        }
    }

    static func materialOrdinal(for article: StudioArticle, courseName: String) -> CourseMaterialOrdinal? {
        var candidates = [stripCoursePrefix(article.title, courseName: courseName)]
        if let localFilePath = article.localFilePath {
            candidates.append((localFilePath as NSString).lastPathComponent)
            candidates.append((localFilePath as NSString).deletingPathExtension)
        }
        if article.url.hasPrefix("/") || article.url.contains("/") {
            candidates.append((article.url as NSString).lastPathComponent)
            candidates.append((article.url as NSString).deletingPathExtension)
        }
        for candidate in candidates {
            if let ordinal = materialOrdinal(in: candidate) {
                return ordinal
            }
        }
        return nil
    }

    nonisolated static func materialOrdinal(in rawTitle: String) -> CourseMaterialOrdinal? {
        let text = rawTitle.replacingOccurrences(of: "_", with: " ")

        // A sub-part is structural course metadata, not title meaning. Parse the
        // explicit shapes before the general ordinal patterns so "Lecture 3
        // Part a" and "Lecture 4 a - Topic" retain the detail that distinguishes
        // multiple videos belonging to the same lecture.
        for regex in CourseTitleParserCache.materialPartRegexes {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 2,
                  let majorRange = Range(match.range(at: 1), in: text),
                  let detailRange = Range(match.range(at: 2), in: text),
                  let major = Int(text[majorRange]),
                  major > 0 else { continue }
            return CourseMaterialOrdinal(
                kind: "lesson",
                major: major,
                detail: String(text[detailRange]).lowercased()
            )
        }

        for (kind, regex) in CourseTitleParserCache.materialRegexes {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let tokenRange = Range(match.range(at: 1), in: text) else { continue }
            let token = String(text[tokenRange]).lowercased()
            let majorString = token.prefix { $0.isNumber }
            guard let ordinal = Int(majorString),
                  ordinal > 0 else { continue }
            let detail: String?
            let suffix = token.dropFirst(majorString.count)
            if suffix.hasPrefix(".") {
                detail = String(suffix.dropFirst())
            } else if suffix.count == 1, suffix.first?.isLetter == true {
                detail = String(suffix)
            } else {
                detail = nil
            }
            return CourseMaterialOrdinal(kind: kind, major: ordinal, detail: detail)
        }
        return nil
    }

    static func playlistLectureNumber(from title: String, fallback: Int) -> Int {
        materialOrdinal(in: title)?.major ?? fallback
    }

    /// The range of a title's own leading lecture ordinal, if it has one: the
    /// normalized "3A) " prefix `Prompts.courseLectureTitleCleanup` puts on
    /// every title it can number, or an un-normalized "Lecture 3 - " on a title
    /// the cleanup never saw.
    nonisolated static func leadingLectureOrdinalRange(in title: String) -> Range<String.Index>? {
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        for regex in CourseTitleParserCache.displayLectureOrdinalPrefixes {
            guard let match = regex.firstMatch(in: title, range: range),
                  match.range.location == 0,
                  let matched = Range(match.range, in: title) else { continue }
            return matched
        }
        return nil
    }

    nonisolated static func titleLeadsWithLectureOrdinal(_ title: String) -> Bool {
        leadingLectureOrdinalRange(in: title) != nil
    }

    /// Number one row of a course or playlist outline. Cleaned lecture titles
    /// carry their own ordinal — that prefix is where a lecture *part* like
    /// "3A" lives, and it is what `materialOrdinal` reads back out — so a row
    /// that prepends `number` unconditionally numbered every imported lecture
    /// twice: "1) 1) Universal Patterns of Aging". The title's own ordinal
    /// wins; `number` fills in only for a title that names no lecture at all.
    nonisolated static func numberedOutlineRowTitle(_ title: String, number: Int) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "\(number))" }
        guard !titleLeadsWithLectureOrdinal(trimmed) else { return trimmed }
        return "\(number)) \(trimmed)"
    }

    /// A numbered title's topic, for telling two titles that differ only by
    /// their ordinal ("3) Feed Forward Loops" and "3A) Feed Forward Loops")
    /// apart from a lecture whose title somebody rewrote. Comparison only —
    /// never stored, never displayed.
    nonisolated static func lectureTitleTopicKey(_ title: String) -> String {
        var topic = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ordinal = leadingLectureOrdinalRange(in: topic) {
            topic.removeSubrange(ordinal)
        }
        return normalizedCourseLabel(topic)
    }

    /// The title for one video row inside a course's Lectures folder. Rows are
    /// numbered by lecture, but a lecture split across several videos records
    /// the split in the videos' own titles ("3A)", "3B)") while the lecture
    /// keeps the major number — so the video's title wins when it names the
    /// same topic, and a lecture somebody retitled keeps winning.
    nonisolated static func courseLectureRowTitle(
        lectureNumber: Int,
        lectureTitle: String?,
        itemTitle: String
    ) -> String {
        let lecture = (lectureTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let item = itemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferred: String
        if lecture.isEmpty {
            preferred = item
        } else if !item.isEmpty,
                  titleLeadsWithLectureOrdinal(item),
                  lectureTitleTopicKey(item) == lectureTitleTopicKey(lecture) {
            preferred = item
        } else {
            preferred = lecture
        }
        return numberedOutlineRowTitle(preferred, number: lectureNumber)
    }

    static func normalizedLectureTitle(_ title: String, courseName: String) -> String {
        stripCoursePrefix(title, courseName: courseName)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".pdf", with: "", options: [.caseInsensitive])
            .components(separatedBy: CourseTitleParserCache.nonAlphanumeric)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated static func stripCoursePrefix(_ title: String, courseName: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func normalizedCourseLabel(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "_", with: " ")
            .components(separatedBy: CourseTitleParserCache.nonAlphanumeric)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated static func stripDanglingLectureSeparators(_ title: String) -> String {
        let fullRange = NSRange(title.startIndex..<title.endIndex, in: title)
        let withoutLeading = CourseTitleParserCache.leadingDanglingSeparators
            .stringByReplacingMatches(in: title, range: fullRange, withTemplate: "")
        let trailingRange = NSRange(withoutLeading.startIndex..<withoutLeading.endIndex, in: withoutLeading)
        return CourseTitleParserCache.trailingDanglingSeparators
            .stringByReplacingMatches(in: withoutLeading, range: trailingRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func inferredLectureItemRole(for article: StudioArticle) -> CourseLectureItemRole {
        switch article.sourceType {
        case .video: return .video
        case .podcast: return .podcast
        case .meeting: return .reference
        case .article, .xPost, .manual, .unclassified: return .article
        case .paper: return .reading
        case .book: return .reading
        case .course:
            let title = article.title.lowercased()
            let path = (article.localFilePath ?? article.url).lowercased()
            if title.contains("slide") || path.contains("slide") { return .slides }
            if title.contains("exercise") || title.contains("problem") || title.contains("assignment")
                || path.contains("exercise") || path.contains("problem") || path.contains("assignment") {
                return .exercise
            }
            return .notes
        }
    }

    /// Add an article to a course by attaching it to the first lecture. This
    /// preserves the source's primary library home instead of moving parentGroup.
    func addArticleToCourse(articleId: String, courseName: String) async {
        guard let article = articles.first(where: { $0.id == articleId }),
              let lecture = await matchingOrFirstLecture(in: courseName, for: article) else { return }
        await addArticleToLecture(articleId: articleId, lectureId: lecture.id)
    }

    /// Whether the lecture holds the source afterwards. A failed write is
    /// shown and leaves the lecture as it was stored.
    @discardableResult
    func addArticleToLecture(articleId: String, lectureId: String, sortIndex: Int? = nil) async -> Bool {
        guard let article = articles.first(where: { $0.id == articleId }),
              let lecture = courseLecturesByCourse.values.flatMap({ $0 }).first(where: { $0.id == lectureId }) else { return false }
        if (courseLectureItemsByLectureId[lectureId] ?? []).contains(where: { $0.sourceId == articleId }) { return true }
        let items = courseLectureItemsByLectureId[lectureId] ?? []
        let item = CourseLectureItem(
            lectureId: lectureId,
            sourceId: articleId,
            role: inferredLectureItemRole(for: article),
            sortIndex: sortIndex ?? (items.map(\.sortIndex).max() ?? -1) + 1
        )
        userCourseNames.insert(lecture.courseName)
        saveUserCourseNames()
        do {
            let notebookSourcesAdded = try await storage.saveCourseLectureItem(item)
            var stored = courseLectureItemsByLectureId[lectureId] ?? []
            stored.append(item)
            courseLectureItemsByLectureId[lectureId] = stored.sorted { $0.sortIndex < $1.sortIndex }
            if notebookSourcesAdded > 0 {
                await loadLearningGoals()
            }
            return true
        } catch {
            logger.error("Failed to attach source to lecture: \(error.localizedDescription)")
            showToast("Could not add “\(article.title)” to the lecture: \(error.localizedDescription)")
            return false
        }
    }

    /// Remove an article from course lectures.
    ///
    /// Each lecture lets the source go as the store deletes its item, and the
    /// source leaves the course's folder once its row is saved. A failure is
    /// shown and stops there, so what the course shows is what it stores.
    func removeArticleFromCourse(articleId: String) async {
        for (lectureId, items) in courseLectureItemsByLectureId {
            for item in items where item.sourceId == articleId {
                do {
                    try await storage.deleteCourseLectureItem(item.id)
                } catch {
                    logger.error("Could not take source \(articleId, privacy: .public) out of lecture \(lectureId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    showToast("Could not remove it from the course: \(error.localizedDescription)")
                    return
                }
                courseLectureItemsByLectureId[lectureId]?.removeAll { $0.id == item.id }
            }
        }

        guard let idx = articles.firstIndex(where: { $0.id == articleId }),
              articles[idx].sourceType != .course,
              articles[idx].sourceType != .book else { return }
        if let group = articles[idx].parentGroup, allCourseGroupNames.contains(group) {
            var removed = articles[idx]
            removed.parentGroup = nil
            guard await persistSource(removed, context: "Remove from the course") else { return }
            mutateArticle(id: articleId) { $0.parentGroup = nil }
        }
    }

    func removeLectureItem(_ itemId: String) async {
        do {
            try await storage.deleteCourseLectureItem(itemId)
            for lectureId in courseLectureItemsByLectureId.keys {
                courseLectureItemsByLectureId[lectureId]?.removeAll { $0.id == itemId }
            }
        } catch {
            logger.error("Failed to remove lecture material: \(error.localizedDescription)")
        }
    }

    /// Create an empty course collection.
    func createCourse(name: String, metadata: CourseMetadata = CourseMetadata()) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !courseMetadata.values.contains(where: { ($0.title ?? "").caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            errorMessage = "A course named \"\(trimmed)\" already exists."
            return
        }
        let courseID = UUID().uuidString
        var metadata = metadata
        if metadata.title == nil {
            metadata.title = trimmed
        }
        userCourseNames.insert(courseID)
        saveUserCourseNames()
        courseMetadata[courseID] = metadata
        do {
            try await storage.saveCourseGroup(name: courseID, metadata: metadata)
        } catch {
            logger.error("Failed to persist course group '\(trimmed)': \(error.localizedDescription)")
        }
        courseMetadata[courseID] = metadata
    }

    /// Hide a course immediately, then delete its structure after the shared
    /// Undo grace period. Sources remain in the library after final deletion.
    func removeCourse(name: String) async {
        guard !hasPendingDeletion(forDeletionKey: Self.courseRemovalKey(name)) else { return }
        let title = courseDisplayName(name)
        let originalMetadata = courseMetadata[name] ?? CourseMetadata(title: title)
        var hiddenMetadata = originalMetadata
        hiddenMetadata.isHidden = true
        let sourceIDs = sourceIdsForGroup(name)
        let priorSelectedArticleID = selectedArticleId
        let priorSelectedArticleIDs = selectedArticleIds

        do {
            try await storage.saveCourseGroup(name: name, metadata: hiddenMetadata)
        } catch {
            logger.error("Failed to remove course group '\(name)': \(error.localizedDescription)")
            errorMessage = "Could not remove \(title): \(error.localizedDescription)"
            return
        }
        courseMetadata[name] = hiddenMetadata
        userCourseNames.insert(name)
        saveUserCourseNames()
        deselectSourcesInEveryWindow(sourceIDs)
        if let selectedArticleId, sourceIDs.contains(selectedArticleId) {
            self.selectedArticleId = articles.first(where: {
                !sourceIDs.contains($0.id) && !isSourceHidden($0)
            })?.id
            currentCardIndex = 0
        }

        deferDeletion(
            message: "Removed “\(title)”",
            sourceIDs: sourceIDs,
            deletionKey: Self.courseRemovalKey(name),
            gracePeriod: deletionGracePeriod,
            undo: { [weak self] in
                guard let self else { return }
                do {
                    try await self.storage.saveCourseGroup(name: name, metadata: originalMetadata)
                    self.courseMetadata[name] = originalMetadata
                    self.userCourseNames.insert(name)
                    self.saveUserCourseNames()
                    self.selectedArticleId = priorSelectedArticleID
                    self.selectedArticleIds = priorSelectedArticleIDs
                } catch {
                    self.logger.error("Failed to undo course removal '\(name)': \(error.localizedDescription)")
                    self.showToast("Undo failed for “\(title)”: \(error.localizedDescription)")
                }
            },
            commit: { [weak self] in
                guard let self else { return }
                let hiddenSourceIDs: [String]
                do {
                    hiddenSourceIDs = try await self.storage.deleteCourseGroup(name: name)
                } catch {
                    try? await self.storage.saveCourseGroup(name: name, metadata: originalMetadata)
                    self.courseMetadata[name] = originalMetadata
                    self.logger.error("Failed to finalize course removal '\(name)': \(error.localizedDescription)")
                    self.showToast("Removing “\(title)” failed: \(error.localizedDescription)")
                    return
                }

                self.userCourseNames.remove(name)
                self.saveUserCourseNames()
                self.courseMetadata[name] = nil
                if let lectures = self.courseLecturesByCourse.removeValue(forKey: name) {
                    for lecture in lectures {
                        self.courseLectureItemsByLectureId[lecture.id] = nil
                    }
                }
                for index in self.articles.indices where self.articles[index].parentGroup == name {
                    self.articles[index].parentGroup = nil
                }
                // Course material the deleted course was the only home for is
                // hidden with it, and the sidebar's hidden menu is where it
                // can be brought back from.
                let hidden = Set(hiddenSourceIDs)
                for index in self.articles.indices where hidden.contains(self.articles[index].id) {
                    self.articles[index].isHidden = true
                }
            }
        )
    }

    /// Organize items in a course: the Course Ordering model orders them when
    /// one is set up, and a natural title sort ("Chapter 1", "Lecture 2a")
    /// does when none is. A model call that fails is shown and changes
    /// nothing: the learner's order is never swapped for a title sort they
    /// did not ask for.
    func organizeCourse(name: String) async {
        let orderConfig = KeychainService.resolveConfig(for: .courseOrdering)
        let aiService = self.aiService
        await organizeCourse(
            name: name,
            modelOrder: orderConfig.map { config in
                { items in try await aiService.organizeCourse(items: items, courseName: name, config: config) }
            }
        )
    }

    /// `organizeCourse(name:)` with its model call handed in; nil orders by
    /// title. The new order is stored first and shown after, so a failed
    /// write leaves the course as it was too.
    func organizeCourse(
        name: String,
        modelOrder: ((_ items: [(id: String, title: String)]) async throws -> [String])?
    ) async {
        guard !organizingCourseNames.contains(name) else { return }
        organizingCourseNames.insert(name)
        defer { organizingCourseNames.remove(name) }

        let courseItems = courseArticles(for: name)
        guard courseItems.count >= 2 else {
            logger.warning("[Organize] Course '\(name)' has \(courseItems.count) items (need ≥2)")
            return
        }

        logger.info("[Organize] Organizing '\(name)' with \(courseItems.count) items")

        let orderedIds: [String]
        if let modelOrder {
            do {
                orderedIds = try await modelOrder(courseItems.map { (id: $0.id, title: $0.title) })
            } catch {
                logger.error("[Organize] Course ordering failed for '\(name)': \(error.localizedDescription)")
                showToast("Could not organize \(courseDisplayName(name)): \(error.localizedDescription)")
                return
            }
        } else {
            orderedIds = courseItems.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }.map(\.id)
        }

        let ordering: [(String, Int)] = orderedIds.enumerated().compactMap { index, id in
            articles.contains(where: { $0.id == id }) ? (id, index) : nil
        }
        logger.info("[Organize] Applying sort order: \(ordering.count)/\(orderedIds.count) IDs matched")
        do {
            try await storage.updateCourseSortOrder(ordering)
        } catch {
            logger.error("[Organize] Could not save the order of '\(name)': \(error.localizedDescription)")
            showToast("Could not save the order of \(courseDisplayName(name)): \(error.localizedDescription)")
            return
        }
        for (id, index) in ordering {
            mutateArticle(id: id) { $0.courseSortIndex = index }
        }
        await refreshArticles()
    }

    func saveUserCourseNames() {
        PreferenceStore.set(Array(userCourseNames), forKey: "userCourseNames")
    }

    func courseDisplayName(_ groupName: String) -> String {
        courseMetadata[groupName]?.title ?? groupName
    }

    func existingCourseID(forTitle title: String) -> String? {
        courseMetadata.first { key, metadata in
            (metadata.title ?? key).caseInsensitiveCompare(title) == .orderedSame
        }?.key
    }

    func courseID(forTitle title: String) -> String {
        existingCourseID(forTitle: title) ?? UUID().uuidString
    }

    func courseDisplaySubtitle(_ groupName: String) -> String? {
        let meta = courseMetadata[groupName]
        let parts = [meta?.courseCode, meta?.instructors, meta?.institution].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The image a course row shows in the sidebar: the YouTube thumbnail of its
    /// first video lecture, which is the cover YouTube itself uses for the
    /// playlist. Returns nil for a course with no video lecture yet, so the row
    /// falls back to the graduation-cap glyph. The persisted outline cache is
    /// authoritative because archived lecture sources are intentionally absent
    /// from `articlesById`.
    func courseArtworkURL(_ groupName: String) -> String? {
        if let persistedArtworkURL = courseCoverArtworkURLs[groupName] {
            return persistedArtworkURL
        }
        for id in sourceIDsForGroupInOrder(groupName) {
            if let article = articlesById[id],
               let thumbnail = article.artworkURL ?? article.youtubeThumbnailURL {
                return thumbnail
            }
        }
        return nil
    }

    /// Update a single field of course metadata.
    func updateCourseMetadata(groupName: String, update: (inout CourseMetadata) -> Void) async {
        var meta = courseMetadata[groupName] ?? CourseMetadata()
        update(&meta)
        courseMetadata[groupName] = meta
        userCourseNames.insert(groupName)
        saveUserCourseNames()
        do { try await storage.saveCourseGroup(name: groupName, metadata: meta) }
        catch { logger.error("Failed to save course group: \(error.localizedDescription)") }
        courseMetadata[groupName] = meta
    }

    func setCourseHidden(_ groupName: String, hidden: Bool) async {
        if !hidden,
           await undoPendingDeletion(forDeletionKey: Self.courseRemovalKey(groupName)) {
            guard courseMetadata[groupName]?.isHidden == true else { return }
        }
        await updateCourseMetadata(groupName: groupName) { metadata in
            metadata.isHidden = hidden
        }
        showToast(
            hidden ? "Hid \(courseDisplayName(groupName))" : "Unhid \(courseDisplayName(groupName))",
            undo: hidden ? { [weak self] in await self?.setCourseHidden(groupName, hidden: false) } : nil
        )
    }

    func persistCoursePlaylist(_ playlistURL: String, for courseName: String, defaultTitle: String?) async {
        var metadata = courseMetadata[courseName] ?? CourseMetadata()
        metadata.playlistURL = playlistURL
        if metadata.title == nil, let defaultTitle {
            metadata.title = defaultTitle
        }
        courseMetadata[courseName] = metadata
        userCourseNames.insert(courseName)
        saveUserCourseNames()

        do {
            try await storage.saveCourseGroup(name: courseName, metadata: metadata)
        } catch {
            logger.error("Failed to persist playlist for course '\(courseName)': \(error.localizedDescription)")
        }
    }

    /// Extract authors for all articles that don't have one yet using an LLM.
    func extractMissingArticleAuthors() async {
        guard let config = KeychainService.resolveConfig(for: .articleMetadata) else {
            showToast("Set an API key in Settings first")
            return
        }

        let missing = articles.filter {
            ($0.sourceType == .article || $0.sourceType == .unclassified)
            && ($0.author == nil || $0.author?.isEmpty == true)
            && $0.state == .ready
        }
        guard !missing.isEmpty else {
            showToast("All articles already have authors")
            return
        }

        logger.info("Extracting authors for \(missing.count) article(s)")
        var succeeded = 0
        for (i, article) in missing.enumerated() {
            paperDownloadStep = "Extracting author \(i + 1)/\(missing.count)…"
            var content = article.content
            if content == nil { content = await storage.loadSourceContent(article.id) }
            let result = await aiService.fixArticleTitle(
                source: AIUsageSource(source: article),
                currentTitle: article.title,
                url: article.url,
                content: content,
                config: config
            )
            if let result, let author = result.author,
               let idx = articles.firstIndex(where: { $0.id == article.id }) {
                var updated = articles[idx]
                updated.author = author
                if await persistSource(updated, context: "Save extracted author") {
                    // Re-resolve by id: persistSource suspended, so `idx` may be stale.
                    if let writeIdx = articles.firstIndex(where: { $0.id == article.id }) {
                        articles[writeIdx] = updated
                    }
                    succeeded += 1
                }
            }
        }
        paperDownloadStep = ""
        showToast("Extracted \(succeeded) author\(succeeded == 1 ? "" : "s")")
    }

    func updateArticleAuthor(id: String, author: String) async {
        guard let idx = articles.firstIndex(where: { $0.id == id }) else { return }
        let value = author.isEmpty ? nil : author
        var article = articles[idx]
        article.author = value
        if await persistSource(article, context: "Save author") {
            if let idx2 = articles.firstIndex(where: { $0.id == id }) {
                articles[idx2] = article
            }
            await completePaperIngestionAfterManualMetadata(id: id)
        }
    }

    /// Use an LLM to extract author, journal, and year from the paper's first PDF page.
    func extractPaperMetadataWithAI(id: String) async {
        _ = await extractPaperMetadataWithAI(id: id, showToasts: true)
    }

    /// - Parameter metadataOnly: Return as soon as the one front-matter call has
    ///   been applied and attested. The full-document cleanup moves to a
    ///   background task and the DOI title lookup is skipped, so Edit Details
    ///   waits for one short model call instead of the whole pipeline.
    /// - Parameter progressPrefix: Pass a non-nil value to publish this method's
    ///   own phase captions into `paperDownloadStep`. An empty string reports the
    ///   phase alone; a non-empty one prefixes it (batch callers use their
    ///   "3/7" counter). `nil` leaves `paperDownloadStep` untouched.
    @discardableResult
    func extractPaperMetadataWithAI(
        id: String,
        showToasts: Bool,
        progressPrefix: String? = nil,
        metadataOnly: Bool = false
    ) async -> Bool {
        guard let idx = articles.firstIndex(where: { $0.id == id }),
              articles[idx].sourceType == .paper else { return false }
        guard !extractingPaperMetadataIds.contains(id) else { return false }
        guard let config = KeychainService.resolveConfig(for: .paperMetadata) else {
            // "Not configured" is true of an absent account and of nothing
            // else. When the blocker is a stale model route, an empty balance,
            // or unaccepted background usage, say that instead: the generic
            // sentence sent a signed-in learner to the sign-in sheet for a
            // problem only the model picker or AI Usage can fix.
            let reason = KeychainService.backgroundAIUnavailableMessage(for: .paperMetadata)
                ?? "Paper Metadata AI is not configured."
            await failPaperMetadataExtraction(
                id: id,
                message: "Paper ingestion failed: \(reason)",
                showToasts: showToasts
            )
            return false
        }
        extractingPaperMetadataIds.insert(id)
        let previousProcessingStep = paperProcessingSteps[id]
        defer {
            extractingPaperMetadataIds.remove(id)
            if let previousProcessingStep {
                paperProcessingSteps[id] = previousProcessingStep
            } else {
                paperProcessingSteps.removeValue(forKey: id)
            }
            // The restored caption belongs to whichever pass published it. If
            // that pass has already exited, nothing owns the row and the caption
            // must go with it.
            dropPaperProcessingStepIfIdle(id)
        }

        // A manual or queued retry starts from a persisted terminal error. Clear
        // that old result before the new request begins so the sidebar never
        // presents the same paper as both actively processing and already failed.
        // Persisting the queued state also makes an interrupted retry eligible for
        // the ordinary startup metadata sweep instead of preserving a stale error.
        if articles[idx].state == .error || articles[idx].errorMessage != nil {
            var retryingArticle = articles[idx]
            retryingArticle.prepareForPaperMetadataExtraction()
            guard await persistSource(
                retryingArticle,
                context: "Save paper metadata retry state",
                showErrorToast: showToasts
            ) else { return false }
            guard let latestIdx = articles.firstIndex(where: { $0.id == id }) else { return false }
            articles[latestIdx] = retryingArticle
        }

        guard let currentArticle = articles.first(where: { $0.id == id }) else { return false }
        let firstPageText = await Self.frontMatterTextOffMain(for: currentArticle)
        guard !firstPageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await failPaperMetadataExtraction(
                id: id,
                message: "Paper ingestion failed: no readable PDF or full-text paper content was available for AI metadata extraction.",
                showToasts: showToasts
            )
            return false
        }

        reportPaperIngestionStep(id, progressPrefix, "Extracting paper metadata…")

        // The registered title is only a glyph repair for the model's title, so
        // it is asked for beside the model call, not after it: Crossref alone can
        // take several seconds. The DOI comes from the row, its address, or the
        // front matter's own text, which the model does not need to have read.
        let candidateDOI = Self.paperDOI(for: currentArticle)
            ?? Self.extractDOIFromText(firstPageText)
        let registeredTitleLookup: Task<String?, Never>? = metadataOnly || candidateDOI == nil
            ? nil
            : Task { await PaperService.registeredTitleIfKnown(forDOI: candidateDOI) }
        defer { registeredTitleLookup?.cancel() }

        let maximumAttempts = 3
        var attemptsMade = 0
        var result: AIService.PaperMetadataResult?
        var lastError: Error?
        var metadataMaxTokens = AIService.paperMetadataMaxTokens
        for attempt in 1...maximumAttempts {
            guard !Task.isCancelled,
                  let currentArticle = articles.first(where: { $0.id == id }) else { return false }
            attemptsMade = attempt
            do {
                result = try await aiService.extractPaperMetadata(
                    source: AIUsageSource(source: currentArticle),
                    url: currentArticle.url,
                    title: currentArticle.title,
                    firstPageText: firstPageText,
                    maxTokens: metadataMaxTokens,
                    config: config
                )
                break
            } catch {
                lastError = error
                logger.warning(
                    "Paper metadata extraction attempt \(attempt)/\(maximumAttempts) failed for \(id) using \(config.provider.shortName): \(error.localizedDescription)"
                )
                PaperIngestionDiagnostics.recordAttempt(
                    sourceID: id,
                    provider: config.provider.shortName,
                    attempt: attempt,
                    maximumAttempts: maximumAttempts,
                    message: error.localizedDescription
                )
                // A reasoning model that spent its whole output ceiling thinking
                // answers within a larger one.
                if case AIError.outputTokenLimit = error,
                   let raised = AIService.paperMetadataRaisedMaxTokens(after: metadataMaxTokens) {
                    metadataMaxTokens = raised
                    continue
                }
                guard attempt < maximumAttempts,
                      AITransientErrorClassifier.isTransient(error) else { break }
                let retryAfter = AITransientErrorClassifier.retryAfterSeconds(error) ?? 0
                guard retryAfter <= AITransientErrorClassifier.maximumRetryAfterWait else { break }
                let delay = min(
                    max(Double(attempt), retryAfter),
                    AITransientErrorClassifier.maximumRetryAfterWait
                )
                try? await Task.sleep(for: .seconds(delay))
            }
        }

        // The first pages did not name everything. A title page that prints no
        // venue, or a cover sheet ahead of the real one, leaves fields the next
        // pages (a running header, a footer's "Published in", a citation line)
        // often carry. One longer look fills only those gaps; it is skipped when
        // it would hand the model nothing it has not already seen.
        if let first = result,
           first.title == nil || first.author == nil || first.journal == nil || first.year == nil,
           let latest = articles.first(where: { $0.id == id }) {
            let longer = await Self.frontMatterTextOffMain(
                for: latest,
                maximumPages: Self.paperLongLookMaximumPages,
                minimumCharacters: Self.paperLongLookCharacters
            )
            if longer.count > min(firstPageText.count, 6000) + 200 {
                reportPaperIngestionStep(id, progressPrefix, "Reading further for paper metadata…")
                if let second = try? await aiService.extractPaperMetadata(
                    source: AIUsageSource(source: latest),
                    url: latest.url,
                    title: latest.title,
                    firstPageText: longer,
                    characterLimit: Self.paperLongLookCharacters,
                    config: config
                ) {
                    result = AIService.PaperMetadataResult(
                        title: first.title ?? second.title,
                        author: first.author ?? second.author,
                        journal: first.journal ?? second.journal,
                        year: first.year ?? second.year,
                        doi: first.doi ?? second.doi
                    )
                }
            }
        }

        guard let result else {
            let detail = lastError?.localizedDescription ?? "unknown error"
            let attemptLabel = attemptsMade == 1 ? "attempt" : "attempts"
            await failPaperMetadataExtraction(
                id: id,
                message: "Paper ingestion failed: Paper Metadata AI (\(config.provider.shortName)) failed after \(attemptsMade) \(attemptLabel): \(detail)",
                showToasts: showToasts
            )
            return false
        }

        // The model read the title off the PDF's text, and PDF text drops a
        // glyph its font cannot map (J Neurosci's "α-Ketoglutarate" arrived as
        // "-Ketoglutarate"). The title the DOI is registered under is where
        // the character survives; its lookup has been running since before the
        // model call, so this wait is normally already over. A DOI only the
        // model found is not looked up: the repair never holds the row back.
        // It is given two seconds past the model's answer and then left behind,
        // so a slow catalog cannot hold the row.
        let registeredTitle: String?
        if let registeredTitleLookup {
            registeredTitle = await withTaskGroup(of: String?.self) { group in
                group.addTask { await registeredTitleLookup.value }
                group.addTask {
                    try? await Task.sleep(for: .seconds(2))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        } else {
            registeredTitle = nil
        }

        guard let idx = articles.firstIndex(where: { $0.id == id }) else { return false }
        var article = articles[idx]
        _ = Self.applyExtractedPaperMetadata(
            result,
            to: &article,
            overwriteTitle: true,
            registeredTitle: registeredTitle
        )
        // A field the document does not print is a blank, not a failure. The
        // paper ingests on whatever the extractor resolved — a preprint with no
        // venue, an unsigned editorial, a thesis with no year — and the blank
        // stays editable in Edit Details. Only a result that resolved nothing at
        // all is treated as an extraction that did not happen.
        guard article.hasAttestablePaperMetadata else {
            let missing = article.missingRequiredPaperMetadataFields

            // An unusable bibliography says nothing about the document's text.
            // Skipping cleanup here meant the paper was stored with no canonical
            // text at all: unsearchable on the Mac, and on iOS a source that
            // offered Listen and could only report that it was still preparing.
            // Cleanup is independent of the metadata gate, so run it before
            // recording the failure. Already-cleaned text is left alone — this
            // path is re-entered on every launch until the learner fills the
            // fields in.
            if !metadataOnly, !article.hasCompletedPaperContentCleanup {
                let cleanupError = await installCanonicalPaperContent(
                    on: &article,
                    progressPrefix: progressPrefix
                )
                if let cleanupError {
                    logger.error(
                        "Paper content cleanup failed for \(id) while its metadata was incomplete: \(cleanupError.localizedDescription)"
                    )
                }
            }

            // One save for the partial metadata, the canonical text, and the
            // failure. The Listen queue reads the source's state in the same
            // transaction that writes its content, so splitting the failure into
            // a second write would enqueue nothing.
            let message = StudioArticle.paperMetadataIncompleteMessage(missing: missing)
            article.failPaperIngestionMetadata(message)
            if await persistSource(
                article,
                context: "Save partial paper metadata",
                showErrorToast: false
            ) {
                article.discardPersistedPaperContentFromMemory()
                if let partialIdx = articles.firstIndex(where: { $0.id == id }) {
                    articles[partialIdx] = article
                }
                reportPaperMetadataFailure(id: id, message: message, showToasts: showToasts)
            } else {
                // The combined save did not commit. Record the failure on its own
                // so the row never stays silently mid-extraction.
                await failPaperMetadataExtraction(
                    id: id,
                    message: message,
                    showToasts: showToasts
                )
            }
            return false
        }

        // Metadata is its own durable stage. Attest it before the independent
        // full-document cleanup call so a cleanup failure cannot be mislabeled
        // as an empty metadata response or cause a duplicate metadata charge.
        guard article.attestPaperMetadataExtractionAfterLLM() else { return false }

        // Publish the resolved title/author/venue/year now, before Source Content
        // Cleanup below. Cleanup is a full-document model pass and can take time;
        // holding these fields until it returns left the
        // sidebar showing a bare domain long after the real title was known. The
        // source stays out of `.ready` — only `completePaperMetadataExtractionAfterLLM()`
        // admits it — so this publishes display metadata, not ingestion success.
        if await persistSource(
            article,
            context: "Save extracted paper metadata",
            showErrorToast: false,
            syncImmediately: true
        ),
           let metadataIdx = articles.firstIndex(where: { $0.id == id }) {
            articles[metadataIdx] = article
        }

        if metadataOnly {
            if !article.hasCompletedPaperContentCleanup, !processingPaperIDs.contains(id) {
                pendingPaperProcessingIds.insert(id)
                reportPaperIngestionStep(id, nil, "Cleaning up paper text…")
                Task {
                    defer {
                        pendingPaperProcessingIds.remove(id)
                        paperProcessingSteps.removeValue(forKey: id)
                    }
                    guard !Task.isCancelled else { return }
                    await cleanUpPaperContentAfterManualMetadata(id: id, showToasts: false)
                }
            }
            if showToasts { showToast("Metadata saved") }
            return true
        }

        // Cleanup is a full-document model pass that takes minutes on a free
        // model. The paper is readable (its PDF or page) once its metadata is
        // in, so the pass goes to the durable cleanup queue instead of holding
        // the row in Processing — and every paper queued behind it — until it
        // returns (product owner, 2026-10-13: "should be ingested instantly
        // basically; and cleanup happens in the background"). The queue's
        // drain moves the row from `.queued` to `.ready` when it lands.
        if !article.hasCompletedPaperContentCleanup,
           let raw = await rawPaperTextForCleanup(article),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let rawSHA256 = await Self.contentSHA256OffMain(raw)
            article.stagePaperContentCleanup(raw: raw, rawSHA256: rawSHA256)
            article.state = .queued
            article.errorMessage = nil
            guard await persistSource(
                article,
                context: "Queue paper content cleanup",
                showErrorToast: false,
                syncImmediately: true
            ) else { return false }
            article.discardPersistedPaperContentFromMemory()
            if let latestIdx = articles.firstIndex(where: { $0.id == id }) {
                articles[latestIdx] = article
            }
            NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
            if showToasts { showToast("Metadata saved") }
            return true
        }

        // Only a paper with no text to stage reaches the inline pass, which
        // records why cleanup could not run. A paper that already carries
        // canonical text is re-entering this method only for its metadata — a
        // retry, or a row an earlier build failed over a blank field — and
        // re-cleaning it would charge the learner twice for the same text.
        if !article.hasCompletedPaperContentCleanup,
           let cleanupError = await installCanonicalPaperContent(
               on: &article,
               progressPrefix: progressPrefix
           ) {
            if AITransientErrorClassifier.shouldRetryAutomatically(cleanupError),
               let raw = await storage.loadRawPaperContent(id) {
                let rawSHA256 = await Self.contentSHA256OffMain(raw)
                article.stagePaperContentCleanup(raw: raw, rawSHA256: rawSHA256)
                article.state = .queued
                article.errorMessage = nil
                if await persistSource(
                    article,
                    context: "Queue transient paper content cleanup",
                    showErrorToast: false,
                    syncImmediately: true
                ), let latestIdx = articles.firstIndex(where: { $0.id == id }) {
                    article.discardPersistedPaperContentFromMemory()
                    articles[latestIdx] = article
                }
                return false
            }
            let message = StudioArticle.paperContentCleanupFailureMessage(
                cleanupError.localizedDescription
            )
            article.failPaperContentCleanup(message)
            if await persistSource(
                article,
                context: "Save paper content cleanup failure",
                showErrorToast: false,
                syncImmediately: true
            ), let latestIdx = articles.firstIndex(where: { $0.id == id }) {
                articles[latestIdx] = article
            }
            PaperIngestionDiagnostics.recordFailure(
                sourceID: id,
                title: article.title,
                message: message
            )
            logger.error("\(message)")
            if showToasts { showToast(message) }
            return false
        }
        guard article.completePaperMetadataExtractionAfterLLM() else { return false }

        do {
            // This is the durable paper-metadata boundary. Push promptly so an
            // older whole-record snapshot from another Mac cannot remain the
            // CloudKit winner while the completed extraction sits behind a bulk
            // background-repair backlog.
            try await storage.saveSource(article, syncImmediately: true)
            article.discardPersistedPaperContentFromMemory()
            if let latestIdx = articles.firstIndex(where: { $0.id == id }) {
                articles[latestIdx] = article
            }
            if showToasts {
                showToast("Metadata saved")
            }
            return true
        } catch {
            logger.error("Failed to save AI-extracted paper metadata for \(id): \(error.localizedDescription)")
            if showToasts {
                showToast("Metadata save failed: \(error.localizedDescription)")
            }
            return false
        }
    }

    /// Finish ingestion for a paper whose required metadata the learner just
    /// supplied by hand. Some documents never print all three fields — a
    /// repository thesis can carry no journal and no year anywhere in its front
    /// matter — so the extractor can be permanently unable to attest a paper a
    /// human can complete in seconds. Once they do, the stale extraction error
    /// must clear and the remaining Source Content Cleanup must run.
    ///
    /// Returns once the metadata itself is attested and on disk. The cleanup is
    /// a full-document model pass that takes tens of seconds, so it runs in the
    /// returned task rather than under the caller's await: the Edit Details
    /// sheet used to sit on a disabled Save button for the whole pass, showing
    /// "Cleaning up paper text…" in the sidebar while the learner waited for a
    /// dialog that had nothing left to do. The row moves to Processing for the
    /// duration instead. `nil` means no cleanup was started — either the paper
    /// did not need attesting, the save failed, or its text is already clean.
    @discardableResult
    func completePaperIngestionAfterManualMetadata(
        id: String,
        showToasts: Bool = false
    ) async -> Task<Void, Never>? {
        guard let idx = articles.firstIndex(where: { $0.id == id }) else { return nil }
        var article = articles[idx]
        // Only papers the pipeline could not attest itself. An already-attested
        // paper keeps its own ingestion record; ordinary metadata edits on it
        // are not an ingestion event.
        guard article.sourceType == .paper,
              article.requiresPaperMetadataAI,
              article.hasAttestablePaperMetadata,
              article.completePaperMetadataFromManualEntry() else { return nil }

        guard await persistSource(article, context: "Save manual paper metadata") else { return nil }
        if let latestIdx = articles.firstIndex(where: { $0.id == id }) {
            articles[latestIdx] = article
        }
        guard !article.hasCompletedPaperContentCleanup else {
            if showToasts { showToast("Paper metadata saved") }
            return nil
        }
        // Another pass — a Retry, or a second Save while the first is still
        // cleaning — already owns this paper's cleanup and will install the text.
        guard !processingPaperIDs.contains(id) else { return nil }

        pendingPaperProcessingIds.insert(id)
        reportPaperIngestionStep(id, nil, "Cleaning up paper text…")
        return Task {
            defer {
                pendingPaperProcessingIds.remove(id)
                paperProcessingSteps.removeValue(forKey: id)
            }
            // The metadata is attested and saved either way; a cancelled pass
            // leaves the text to the ordinary repair path, like an empty one.
            guard !Task.isCancelled else { return }
            await cleanUpPaperContentAfterManualMetadata(id: id, showToasts: showToasts)
        }
    }

    /// The Source Content Cleanup half of a manual attestation. Runs after the
    /// metadata is durable, so every failure here keeps the attestation and
    /// Retry resumes from the cleanup step instead of asking for the fields again.
    private func cleanUpPaperContentAfterManualMetadata(id: String, showToasts: Bool) async {
        guard let idx = articles.firstIndex(where: { $0.id == id }) else { return }
        var article = articles[idx]
        guard !article.hasCompletedPaperContentCleanup else { return }

        let storedRaw = await storage.loadRawPaperContent(id)
        let rawText: String
        if let storedRaw {
            rawText = storedRaw
        } else if let inMemoryRaw = article.content {
            rawText = inMemoryRaw
        } else {
            rawText = await Self.fullPaperTextOffMain(for: article)
        }
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Nothing to clean yet. The metadata itself is attested and saved,
            // so the ordinary repair path can supply the text later.
            return
        }

        do {
            let prepared = try await PaperContentPreparationService(aiService: aiService).prepare(
                source: AIUsageSource(source: article),
                rawText: rawText
            )
            article.installPreparedPaperContent(
                raw: prepared.raw,
                clean: prepared.clean,
                metadata: prepared.metadata,
                wordCount: prepared.wordCount
            )
            article.state = .ready
            article.errorMessage = nil
        } catch {
            if AITransientErrorClassifier.shouldRetryAutomatically(error) {
                let rawSHA256 = await Self.contentSHA256OffMain(rawText)
                article.stagePaperContentCleanup(raw: rawText, rawSHA256: rawSHA256)
                article.state = .queued
                article.errorMessage = nil
                let persisted = await persistSource(
                    article,
                    context: "Queue transient manual-metadata cleanup",
                    showErrorToast: false
                )
                if persisted {
                    article.discardPersistedPaperContentFromMemory()
                }
                if persisted, let latestIdx = articles.firstIndex(where: { $0.id == id }) {
                    articles[latestIdx] = article
                }
                return
            }
            let message = StudioArticle.paperContentCleanupFailureMessage(error.localizedDescription)
            article.state = .error
            article.errorMessage = message
            PaperIngestionDiagnostics.recordFailure(
                sourceID: id,
                title: article.title,
                message: message
            )
            _ = await persistSource(
                article,
                context: "Save manual metadata cleanup error",
                showErrorToast: false
            )
            if let latestIdx = articles.firstIndex(where: { $0.id == id }) {
                articles[latestIdx] = article
            }
            if showToasts { showToast(message) }
            return
        }

        guard await persistSource(
            article,
            context: "Save manually attested paper",
            showErrorToast: false,
            syncImmediately: true
        ) else { return }
        article.discardPersistedPaperContentFromMemory()
        if let latestIdx = articles.firstIndex(where: { $0.id == id }) {
            articles[latestIdx] = article
        }
        if showToasts { showToast("Paper metadata saved") }
    }

    /// Publish the per-paper ingestion phase. A non-nil prefix also mirrors the
    /// phase into the batch header's shared `paperDownloadStep` caption.
    func reportPaperIngestionStep(_ articleID: String, _ prefix: String?, _ phase: String) {
        paperProcessingSteps[articleID] = phase
        guard let prefix else { return }
        paperDownloadStep = prefix.isEmpty ? phase : "\(prefix) \(phase)"
    }

    /// The text Source Content Cleanup reads: the stored raw extraction, else
    /// the row's loaded text, else the PDF's full text.
    private func rawPaperTextForCleanup(_ article: StudioArticle) async -> String? {
        if let storedRaw = await storage.loadRawPaperContent(article.id) { return storedRaw }
        if let inMemoryRaw = article.content { return inMemoryRaw }
        return await Self.fullPaperTextOffMain(for: article)
    }

    /// Run Source Content Cleanup and install the canonical derivative on
    /// `article`, leaving it for the caller to persist. Returns the failure when
    /// cleanup could not produce canonical text, so the caller decides which
    /// error the row should carry.
    ///
    /// This stage is deliberately independent of the metadata gate: cleanup is
    /// what gives a paper readable, searchable, listenable text, and a document
    /// that prints no author still has all of it.
    private func installCanonicalPaperContent(
        on article: inout StudioArticle,
        progressPrefix: String?
    ) async -> Error? {
        let rawText = await rawPaperTextForCleanup(article) ?? ""
        reportPaperIngestionStep(article.id, progressPrefix, "Cleaning up paper text…")
        do {
            let prepared = try await PaperContentPreparationService(aiService: aiService).prepare(
                source: AIUsageSource(source: article),
                rawText: rawText
            )
            article.installPreparedPaperContent(
                raw: prepared.raw,
                clean: prepared.clean,
                metadata: prepared.metadata,
                wordCount: prepared.wordCount
            )
            return nil
        } catch {
            return error
        }
    }

    private func failPaperMetadataExtraction(
        id: String,
        message: String,
        showToasts: Bool
    ) async {
        guard let idx = articles.firstIndex(where: { $0.id == id }),
              articles[idx].sourceType == .paper else { return }
        var article = articles[idx]
        article.failPaperIngestionMetadata(message)
        if await persistSource(article, context: "Save failed paper metadata ingestion") {
            if let latestIdx = articles.firstIndex(where: { $0.id == id }) {
                articles[latestIdx] = article
            }
        }
        reportPaperMetadataFailure(id: id, message: message, showToasts: showToasts)
    }

    /// Diagnostics, logging, and the toast for a paper-ingestion failure the
    /// caller has already recorded on the row. Split out so a caller that has to
    /// persist the failure alongside other state — canonical text, partial
    /// metadata — can still report it exactly like the ordinary path.
    private func reportPaperMetadataFailure(
        id: String,
        message: String,
        showToasts: Bool
    ) {
        PaperIngestionDiagnostics.recordFailure(
            sourceID: id,
            title: articles.first(where: { $0.id == id })?.title ?? id,
            message: message
        )
        logger.error("\(message)")
        if showToasts {
            showToast(message)
        }
    }

    /// Run AI metadata extraction for every paper that lacks an attested metadata
    /// stage. A paper the extractor attested on partial fields is deliberately
    /// excluded: the model already answered "?" for the blank, so asking again
    /// spends tokens on the same answer. Those blanks are filled in Edit Details.
    func extractMissingPaperMetadata() async {
        guard KeychainService.resolveConfig(for: .paperMetadata) != nil else {
            showToast("Set an API key in Settings first")
            return
        }

        let missing = articles.filter {
            $0.sourceType == .paper && !$0.hasPaperIngestionAttestation
        }
        guard !missing.isEmpty else {
            showToast("All papers have verified metadata")
            return
        }

        logger.info("Extracting metadata for \(missing.count) paper(s) with unknown authors")
        var succeeded = 0
        for (i, paper) in missing.enumerated() {
            let progressPrefix = "\(i + 1)/\(missing.count)"
            paperDownloadStep = "\(progressPrefix) Extracting paper metadata…"
            if await extractPaperMetadataWithAI(
                id: paper.id,
                showToasts: false,
                progressPrefix: progressPrefix
            ) {
                succeeded += 1
            }
        }
        paperDownloadStep = ""
        showToast("Extracted metadata for \(succeeded) of \(missing.count) paper\(missing.count == 1 ? "" : "s")")
    }

    /// `registeredTitle` is the title the paper's DOI is registered under,
    /// when known. It replaces the title only when that title is it with
    /// characters the PDF's text lost (`RegisteredPaperTitle`), so a DOI that
    /// names some other work cannot bring that work's title with it, and the
    /// DOI, URL and id are never touched by it.
    @discardableResult
    nonisolated static func applyExtractedPaperMetadata(
        _ result: AIService.PaperMetadataResult,
        to article: inout StudioArticle,
        overwriteTitle: Bool,
        registeredTitle: String? = nil
    ) -> Bool {
        var updated = false
        if let title = result.title, !title.isEmpty,
           article.title != title,
           overwriteTitle || titleNeedsResolution(article.title, domain: article.domain, url: article.url) {
            article.title = title
            updated = true
        }
        if let restored = RegisteredPaperTitle.restoringLostCharacters(
            in: article.title,
            registered: registeredTitle
        ) {
            article.title = restored
            updated = true
        }
        if let doi = result.doi, article.doi != doi {
            article.doi = doi
            updated = true
        }
        if let author = result.author, article.author != author {
            article.author = author
            updated = true
        }
        if let journal = result.journal, article.journal != journal {
            article.journal = journal
            updated = true
        }
        if let year = result.year, article.publishedYear != year {
            article.publishedYear = year
            updated = true
        }
        return updated
    }

    nonisolated static func firstPageText(for article: StudioArticle) -> String {
        firstPageText(fromPDFPath: article.resolvedPDFPath)
    }

    nonisolated static func firstPageText(fromPDFPath pdfPath: String?) -> String {
        #if canImport(PDFKit)
        if let pdfPath,
           let doc = PDFDocument(url: URL(fileURLWithPath: pdfPath)),
           let page = doc.page(at: 0) {
            return page.string ?? ""
        }
        #endif
        return ""
    }

    /// Metadata extraction reads front matter, not strictly page one. A
    /// repository copy of a thesis or report opens with a library cover sheet
    /// that carries the title and little else, pushing the real title page —
    /// with the awarding institution and the degree year — to the next page.
    /// Pages are added only until there is enough text to work with, so an
    /// ordinary paper, whose first page already clears the threshold, is read
    /// exactly as before.
    nonisolated static let paperFrontMatterMinimumCharacters = 2500
    nonisolated static let paperFrontMatterMaximumPages = 3
    /// The longer look taken when the first page or two did not name every
    /// field: more pages, and a larger share of them handed to the model.
    nonisolated static let paperLongLookMaximumPages = 6
    nonisolated static let paperLongLookCharacters = 14_000

    nonisolated static func frontMatterText(
        fromPDFPath pdfPath: String?,
        maximumPages: Int = StudioViewModel.paperFrontMatterMaximumPages,
        minimumCharacters: Int = StudioViewModel.paperFrontMatterMinimumCharacters
    ) -> String {
        #if canImport(PDFKit)
        guard let pdfPath,
              let doc = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else { return "" }
        var collected = ""
        for index in 0..<min(doc.pageCount, maximumPages) {
            guard let page = doc.page(at: index)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !page.isEmpty else { continue }
            collected += collected.isEmpty ? page : "\n\n\(page)"
            if collected.count >= minimumCharacters { break }
        }
        return collected
        #else
        return ""
        #endif
    }

    /// Front matter for the metadata extractor. Kept separate from
    /// `firstPageTextOffMain`, whose callers scan for a DOI and must not see
    /// the reference DOIs that later pages can contain.
    nonisolated static func frontMatterTextOffMain(
        for article: StudioArticle,
        maximumPages: Int = StudioViewModel.paperFrontMatterMaximumPages,
        minimumCharacters: Int = StudioViewModel.paperFrontMatterMinimumCharacters
    ) async -> String {
        let pdfPath = article.resolvedPDFPath
        let storedText = article.content?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return await Task.detached(priority: .utility) {
            let pdfText = Self.frontMatterText(
                fromPDFPath: pdfPath,
                maximumPages: maximumPages,
                minimumCharacters: minimumCharacters
            )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !pdfText.isEmpty {
                return pdfText
            }
            return storedText.map { String($0.prefix(12_000)) } ?? ""
        }.value
    }

    nonisolated static func firstPageTextOffMain(for article: StudioArticle) async -> String {
        let pdfPath = article.resolvedPDFPath
        let storedText = article.content?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return await Task.detached(priority: .utility) {
            let pdfText = Self.firstPageText(fromPDFPath: pdfPath)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !pdfText.isEmpty {
                return pdfText
            }
            // Full-text scholarly repositories can provide the paper without a
            // PDF. The opening text is still paper content, not a title-only
            // heuristic, and is therefore valid input to the mandatory model call.
            return storedText.map { String($0.prefix(12_000)) } ?? ""
        }.value
    }

    nonisolated static func fullPaperTextOffMain(for article: StudioArticle) async -> String {
        let pdfPath = article.resolvedPDFPath
        return await Task.detached(priority: .utility) {
            guard let pdfPath else { return "" }
            return (try? SourceService.shared.extractTextFromPDF(at: pdfPath)) ?? ""
        }.value
    }

    /// Use API lookups (for papers) then LLM to fix title, author, and year for an article.
    /// Returns whether anything was found and saved, so a caller can say so
    /// when the answer is no instead of leaving the learner staring at an
    /// unchanged form.
    @discardableResult
    func fixTitle(for articleId: String) async -> Bool {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return false }
        guard !fixingTitleIds.contains(articleId) else { return false }
        fixingTitleIds.insert(articleId)
        defer { fixingTitleIds.remove(articleId) }

        // Work on a local copy across the awaits below; the captured index can go
        // stale if a concurrent refresh reorders `articles`. Written back by id at the end.
        var working = articles[idx]
        var didUpdate = false

        // Step 0: For YouTube videos, fetch the title from YouTube (fast, no LLM needed)
        if YouTubeTranscriptService.isYouTubeURL(working.url),
           let videoId = YouTubeTranscriptService.extractVideoId(from: working.url),
           let title = await YouTubeTranscriptService.shared.fetchVideoTitle(videoId: videoId) {
            working.title = title
            didUpdate = true
        }

        // Step 1: For papers, try API metadata lookups first
        if working.sourceType == .paper {
            var doi = PaperService.extractDOI(from: working.url)
            #if canImport(PDFKit)
            if doi == nil {
                let candidates = [
                    working.localFilePath,
                    working.url.hasPrefix("/") ? working.url : nil,
                    working.resolvedPDFPath,
                ].compactMap { $0 }
                doi = await Self.firstPDFDOIOffMain(in: candidates)
            }
            #endif
            if let meta = await PaperService.fetchPaperMetadata(url: working.url, title: working.title, doi: doi) {
                if let apiTitle = meta.title, !apiTitle.isEmpty {
                    working.title = apiTitle
                    didUpdate = true
                }
                if let authors = meta.authorsDisplay, !authors.isEmpty {
                    didUpdate = await applyMetadataAuthor(authors, to: &working) || didUpdate
                }
                if let journal = meta.journal, !journal.isEmpty {
                    working.journal = journal
                    didUpdate = true
                }
                if let year = meta.year, !year.isEmpty {
                    working.publishedYear = year
                    didUpdate = true
                }
            }
        }

        // Step 2: LLM fix for remaining gaps (or all fields for non-papers)
        let needsTitle = !didUpdate || working.title.hasPrefix("http") || working.title.hasSuffix(".pdf")
        let needsAuthor = working.author == nil || working.author?.isEmpty == true
        let needsYear = working.publishedYear == nil || working.publishedYear?.isEmpty == true

        if needsTitle || needsAuthor || needsYear {
            if let metaConfig = KeychainService.resolveConfig(for: .articleMetadata) {
                // A PDF imported from disk or a link carries no stored text, so
                // the model got only an address and answered with a request to
                // fetch it. Hand it what the document itself says on its first
                // pages, as the paper path does.
                var evidenceText = working.content ?? ""
                if evidenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    evidenceText = await Self.frontMatterTextOffMain(for: working)
                }
                let result = await aiService.fixArticleTitle(
                    source: AIUsageSource(source: working),
                    currentTitle: working.title,
                    url: working.url,
                    content: evidenceText,
                    config: metaConfig
                )
                if let result {
                    if needsTitle, let title = result.title {
                        working.title = title
                        didUpdate = true
                    }
                    if needsAuthor, let author = result.author {
                        working.author = author
                        didUpdate = true
                    }
                    if needsYear, let year = result.year {
                        working.publishedYear = year
                        didUpdate = true
                    }
                }
            }
        }

        if didUpdate {
            // Re-resolve and write the working copy back by id (the captured
            // index may be stale after the awaits above), then persist.
            if let writeIdx = articles.firstIndex(where: { $0.id == articleId }) {
                articles[writeIdx] = working
            }
            if await persistSource(working, context: "Save title metadata") {
                logger.info("Fixed title/metadata for: \(working.title)")
                return true
            }
        }
        return false
    }

    nonisolated static func firstPDFDOIOffMain(in candidates: [String]) async -> String? {
        await Task.detached(priority: .utility) {
            for candidate in candidates {
                if let doi = extractDOIFromPDF(at: candidate) {
                    return doi
                }
            }
            return nil
        }.value
    }

    /// True when the title is just the domain, URL, or otherwise clearly not a real title.
    nonisolated static func titleLooksBad(_ title: String, domain: String, url: String) -> Bool {
        titleNeedsResolution(title, domain: domain, url: url)
    }

    /// True when an article's title is one its page supplied — the head's
    /// metadata, the headline, the site's own name, the host placeholder —
    /// rather than one a person typed. The article-metadata model's answer may
    /// replace the former; the latter is the learner's and stays.
    nonisolated static func articleTitleIsPageSupplied(
        _ title: String,
        pageTitle: String?,
        evidence: PaperService.WebArticleTitleEvidence?,
        domain: String,
        url: String
    ) -> Bool {
        if titleLooksBad(title, domain: domain, url: url) { return true }
        let current = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pageTitle = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           pageTitle.caseInsensitiveCompare(current) == .orderedSame {
            return true
        }
        let host = URL(string: url)?.host ?? domain
        return evidence?.supplied(current, host: host) ?? false
    }

    /// Replace placeholder article titles/authors using HTML metadata, then body text.
    nonisolated static func applyWebArticleMetadataIfNeeded(
        to article: inout StudioArticle,
        pageTitle: String?,
        pageAuthor: String?,
        content: String
    ) {
        if titleLooksBad(article.title, domain: article.domain, url: article.url) {
            if let pageTitle = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pageTitle.isEmpty,
               pageTitle.count < 300 {
                article.title = pageTitle
            }
        }
        if article.author == nil,
           let pageAuthor = pageAuthor?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pageAuthor.isEmpty {
            article.author = pageAuthor
        }
    }
}

/// Sessions whose topic has been read with the file names they have now, for
/// this launch. A session filed under its date is asked about on each refresh
/// until one call has read it; this keeps a session whose files carry no topic
/// at all from being sent again every few minutes. Nothing here is stored: a
/// relaunch reads each such session once more.
@MainActor
enum MeetingDescriptorAttempts {
    static var described: Set<String> = []
}
