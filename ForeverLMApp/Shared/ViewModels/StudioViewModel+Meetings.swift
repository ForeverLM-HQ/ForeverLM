import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import AppKit

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
    /// With no filter set — the default — every series does. Provider narrows what the
    /// learner is looking at; it does not decide where a series is allowed to exist.
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
    /// with no group is a session nothing can show — a session like that strands
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
        let loadedArtifacts = (await loggedRead("meeting artifacts") { try await storage.loadMeetingArtifacts(sourceID: article.id) }) ?? []
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
        let storedArtifacts = (await loggedRead("meeting artifacts") { try await storage.loadMeetingArtifacts(sourceID: sourceID) }) ?? []
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
        let storedArtifacts = (await loggedRead("meeting artifacts") { try await storage.loadMeetingArtifacts(sourceID: sourceID) }) ?? []
        let existingArtifacts = meetingArtifactsBySourceId[sourceID] ?? storedArtifacts
        var merged = existingArtifacts.filter { $0.id != transcriptArtifact.id }
        merged.append(transcriptArtifact)
        meetingArtifactsBySourceId[sourceID] = merged.sorted { $0.sortIndex < $1.sortIndex }
        return true
    }

    /// Bring a hidden meeting group back, and unarchive its sessions with it.
    ///
    /// Deletion archives nothing, so the unarchive is for a hidden group whose
    /// sessions were archived: without it the group returns as a series with no
    /// sessions in it. Archiving clears each session's text, so those sessions
    /// come back empty until the group's plugin or an MCP import refills them.
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
    /// Removal does not archive the sessions and keep the folder as a hidden row:
    /// that would not read as deleted, the series would stay listed under Hidden
    /// Items, and archiving clears every transcript, so the one action offered
    /// there would bring the folder back empty. Deleting is the whole of it —
    /// what the learner asked for, and the only outcome that Hidden Items can
    /// describe honestly.
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
        // recordings mailbox, a plugin re-pushing its history — since
        // no archived row answers "already exists". Web
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

    func saveUserMeetingGroupNames() {
        PreferenceStore.set(Array(userMeetingGroupNames), forKey: "userMeetingGroupNames")
    }

}

