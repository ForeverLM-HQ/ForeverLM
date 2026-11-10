import Foundation
import OSLog

// Teams: the lifecycle (a team is a space of the library container, whose
// share and roster StorageService+Spaces runs), the copy operations that put
// library items into a team, and the task board. See docs/teams-design.md for
// the product model and KnowledgeStore+Teams for the rows.
extension StorageService {
    private static let teamFilesDirectoryName = "Teams"

    // MARK: - Reading

    func loadTeams() throws -> [TeamRecord] {
        try notebookFilesKnowledgeStore().loadTeams()
    }

    func loadTeam(_ id: String) throws -> TeamRecord? {
        try notebookFilesKnowledgeStore().loadTeam(id)
    }

    func loadTeamMembers(teamID: String) throws -> [TeamMemberRecord] {
        try notebookFilesKnowledgeStore().loadTeamMembers(teamID: teamID)
    }

    func teamIDsHoldingSource(url: String) throws -> Set<String> {
        try notebookFilesKnowledgeStore().teamIDsHoldingSource(url: url)
    }

    func teamsHoldingArtifact(_ artifactID: String) throws -> [TeamRecord] {
        try notebookFilesKnowledgeStore().teamsHoldingArtifact(artifactID)
    }

    /// The teams each My Library artifact is in
    /// (`KnowledgeStore.teamIDsByMyLibraryArtifact`).
    func teamIDsByMyLibraryArtifact() throws -> [String: Set<String>] {
        try notebookFilesKnowledgeStore().teamIDsByMyLibraryArtifact()
    }

    /// What My Library lists: personal records plus the team records this
    /// account can see, a team's copy of a personal original counted once
    /// (`KnowledgeStore.loadMyLibraryArtifacts`, decision 18).
    func myLibraryArtifacts() throws -> [ArtifactRecord] {
        try notebookFilesKnowledgeStore().loadMyLibraryArtifacts()
    }

    /// The id a team's copy of an artifact has, or would take
    /// (`KnowledgeStore.teamArtifactCopyID`).
    func teamArtifactCopyID(teamID: String, original: ArtifactRecord) throws -> String {
        try notebookFilesKnowledgeStore().teamArtifactCopyID(teamID: teamID, original: original)
    }

    /// The team of every course that is a team's (decision 21).
    func loadCourseTeamIDs() throws -> [String: String] {
        try notebookFilesKnowledgeStore().loadCourseTeamIDs()
    }

    func teamsHoldingCourse(_ courseID: String) throws -> [TeamRecord] {
        try notebookFilesKnowledgeStore().teamsHoldingCourse(courseID)
    }

    // MARK: - Lifecycle

    /// Create a team: a space of the library container, shared zone-wide so
    /// members can be added through Apple's sharing sheet (`createTeamAsSpace`).
    /// A generation-1 store (a test pins one) keeps the team as local rows only:
    /// generation 1's zone and share lived in the old Apple team's container,
    /// which no build is entitled to.
    func createTeam(name rawName: String) async throws -> TeamRecord {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw KnowledgeStoreError.invalidData("A team needs a name.")
        }
        return try await createTeamAsSpace(name: name)
    }

    func renameTeam(_ teamID: String, name: String) async throws {
        return try await renameTeamAsSpace(teamID, name: name)
    }

    /// Copy Link means anyone with the link. A share whose public permission is
    /// `.none` hands out a URL only named participants can open, so the owner's
    /// Copy Link opens the share to the public at read/write — what Apple's
    /// sheet does for "Anyone with the link · can edit" — and returns the URL.
    /// An already open share is returned as it is.
    func openTeamShareToAnyoneWithLink(_ team: TeamRecord) async throws -> URL {
        return try await spaceInvitationLink(teamID: team.id)
    }

    /// Re-read the roster from the share. Called after the sharing sheet
    /// closes and when a team's page opens.
    func refreshTeamMembers(teamID: String) async throws -> [TeamMemberRecord] {
        return try await refreshSpaceMembers(teamID: teamID)
    }

    /// Leave a team someone else owns (`leaveTeamAsSpace`): leaving the space
    /// is how a participant removes themselves, and the team's copies then
    /// leave this Mac.
    func leaveTeam(_ teamID: String) async throws {
        return try await leaveTeamAsSpace(teamID)
    }

    /// Delete a team this account owns (`deleteTeamAsSpace`): the space goes,
    /// and with it every member's view of the team. Nothing anyone shared into it is in anyone's
    /// own library any more than it was before; originals stay where they are.
    func deleteTeam(_ teamID: String) async throws {
        return try await deleteTeamAsSpace(teamID)
    }

    // MARK: - Sharing (copying) into a team

    private func teamFilesDirectory(teamID: String, createIfNeeded: Bool) throws -> URL {
        let directory = libraryRootURL
            .appendingPathComponent(Self.teamFilesDirectoryName, isDirectory: true)
            .appendingPathComponent(teamID, isDirectory: true)
        if createIfNeeded {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// The team keeps its own copy of a shared file, so deleting the original
    /// from the learner's library never takes the team's copy with it.
    func copyFileIntoTeam(relativePath: String, teamID: String) throws -> String? {
        let source = URL(fileURLWithPath: StorageService.absoluteSourcePath(relativePath))
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let directory = try teamFilesDirectory(teamID: teamID, createIfNeeded: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return StorageService.relativeSourcePath(destination.path)
    }

    /// Share sources with a team. Each becomes a team copy with a team-scoped
    /// id; the originals stay in My Library untouched. Returns the copies' ids.
    @discardableResult
    /// The ids a Notebook or Goal files `sourceIDs` under. A team's Notebook
    /// holds the team's copies, and while a team library is open the source
    /// list shows the learner's own rows (docs/teams-design.md, decision 19),
    /// so an own source dropped on a team Notebook is copied into the team —
    /// file included — and filed as the copy. Order is kept; a source that
    /// cannot be copied is logged and left out rather than filed under an id
    /// no teammate can open. A personal Notebook takes the ids as they are.
    func sourceIDsForGoalLibrary(goalID: String, _ sourceIDs: [String]) throws -> [String] {
        let store = try notebookFilesKnowledgeStore()
        guard !sourceIDs.isEmpty, let teamID = try store.loadLearningGoal(goalID)?.teamID else {
            return sourceIDs
        }
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Teams")
        var mapped: [String] = []
        var copied = false
        for sourceID in sourceIDs {
            let result = store.carrySourcesIntoTeam([sourceID], teamID: teamID) { path in
                try self.copyFileIntoTeam(relativePath: path, teamID: teamID)
            }
            if let failure = result.carried.failed.first {
                logger.error("Could not copy source \(sourceID, privacy: .public) into team \(teamID, privacy: .public) for Notebook \(goalID, privacy: .public): \(failure.reason, privacy: .public)")
            }
            copied = copied || result.carried.count > 0
            for id in result.sourceIDs where !mapped.contains(id) { mapped.append(id) }
        }
        if copied {
            scheduleImmediateCloudKitSyncForTeams()
            NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
        }
        return mapped
    }

    func shareSources(_ sourceIDs: [String], withTeam teamID: String) throws -> [String] {
        let store = try notebookFilesKnowledgeStore()
        var copies: [String] = []
        for sourceID in sourceIDs {
            let copyID = try store.copySourceIntoTeam(sourceID: sourceID, teamID: teamID) { path in
                try self.copyFileIntoTeam(relativePath: path, teamID: teamID)
            }
            copies.append(copyID)
        }
        scheduleImmediateCloudKitSyncForTeams()
        NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
        return copies
    }

    /// A team's copy taken while its source was still being fetched is taken again when the fetch
    /// lands (`KnowledgeStore.teamCopiesAwaitingText`), on whichever path the source was added and
    /// filed — the app, MCP's `add_source` without `content`, a Job — because every fetch, paper
    /// processing and transcript ends in `saveSource`. Under generation 2 the refreshed copy takes
    /// its space identity as any team copy does (`keepTeamCopiesForGeneration2`). Never throws: the
    /// source's own save has already happened.
    func refreshTeamCopiesAwaitingText(of articles: [StudioArticle]) {
        let candidates = articles.filter { $0.teamID == nil && $0.state == .ready }
        guard !candidates.isEmpty else { return }
        do {
            let store = try notebookFilesKnowledgeStore()
            var refreshed = false
            for article in candidates {
                for teamID in try store.teamCopiesAwaitingText(ofSource: article.id) {
                    try store.copySourceIntoTeam(sourceID: article.id, teamID: teamID) { path in
                        try self.copyFileIntoTeam(relativePath: path, teamID: teamID)
                    }
                    refreshed = true
                }
            }
            guard refreshed else { return }
            scheduleImmediateCloudKitSyncForTeams()
            NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Teams")
                .error("A team's copy could not take its source's fetched text: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Share a Notebook with a team, with its nested Goals and optionally its
    /// sources, Docs and chats. Returns the team Notebook's id. From then on
    /// additions to the Notebook follow it (see "Additions follow a shared
    /// Notebook" below).
    @discardableResult
    func shareNotebook(
        _ notebookID: String,
        withTeam teamID: String,
        includeSources: Bool = true,
        includeDocs: Bool = true,
        includeChats: Bool = true
    ) throws -> String {
        let store = try notebookFilesKnowledgeStore()
        // Into a space this account owns, a notebook moves (D21); the move job keeps its id.
        if try store.loadTeam(teamID)?.role == .owner {
            try requestMoveIntoSpace(notebookID, teamID: teamID)
            return notebookID
        }
        let copyID = try store.copyNotebookIntoTeam(
            notebookID: notebookID,
            teamID: teamID,
            includeSources: includeSources,
            includeDocs: includeDocs,
            includeChats: includeChats,
            fileCopy: { path in try self.copyFileIntoTeam(relativePath: path, teamID: teamID) },
            artifactCopy: { artifactID, teamNotebookID in
                try self.shareArtifact(artifactID, withTeam: teamID, linkedTeamNotebookIDs: [teamNotebookID], scheduleSync: false).id
            }
        )
        scheduleImmediateCloudKitSyncForTeams()
        NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
        return copyID
    }

    /// Share a Doc or a page with a team: a copy of the record and its body
    /// under a team-scoped id — by record for a Doc, by address for a page
    /// (`TeamContentIdentity.artifactCopyID`). The sources it carries travel
    /// with it into the team's library (docs/teams-design.md, decision 16):
    /// the record's own `sourceIDs`, which the copy names by the team's ids,
    /// and unless `carryCitedSources` is off the web references its body
    /// cites that only this library holds (`citedSourcesToCarry`). Each source
    /// is best effort: one that cannot be copied is logged and reported in
    /// the result, and the artifact still goes. Returns the team copy's id
    /// and what travelled.
    @discardableResult
    func shareArtifact(
        _ artifactID: String,
        withTeam teamID: String,
        linkedTeamNotebookIDs: [String] = [],
        scheduleSync: Bool = true,
        carryCitedSources: Bool = true
    ) throws -> ArtifactTeamCopy {
        let store = try notebookFilesKnowledgeStore()
        guard let original = try store.loadArtifact(artifactID) else {
            throw KnowledgeStoreError.invalidData("Page \(artifactID) does not exist.")
        }
        // An audio overview's script and audio live on a carrier source in
        // its author's library, which a team copy cannot reach: it would list
        // in the team and play nothing.
        guard try !store.isAudioOverview(original) else {
            throw KnowledgeStoreError.invalidData(
                "‘\(original.title)’ is an audio overview, and audio overviews are not shared with a team yet: its script and audio stay in your own library. Share the Notebook's sources or a Page instead."
            )
        }
        // A source's draft deck of cards to check is the learner's own memory
        // state, which never enters a team record (docs/teams-design.md rule 7).
        guard !original.isCardDeck else {
            throw KnowledgeStoreError.invalidData(
                "‘\(original.title)’ holds your cards to check, which stay yours: cards are never shared with a team. Share the Notebook's sources or a Page instead."
            )
        }
        // A team's own record is not copied into that team. Without this a
        // save of a team row wrote its body and site files into a folder for
        // a copy that `copyArtifactRowIntoTeam` then never made. The record's
        // own change still goes out promptly.
        if original.teamID == teamID {
            if scheduleSync {
                scheduleImmediateCloudKitSyncForTeams()
                NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
            }
            return ArtifactTeamCopy(id: original.id, carriedSources: CarriedTeamSources())
        }
        let snapshot = try artifactMarkdown(artifactID)
        let copyID = try store.teamArtifactCopyID(teamID: teamID, original: original)
        let directory = try artifactDirectoryURL(artifactID: copyID, createIfNeeded: true)
        let document = directory.appendingPathComponent("document.md")
        // A mnemonic reading's sections name its sources; the team's copy
        // names the team's copies of them, which the copy's grounding
        // carries in below, so a member reads it over the team's sources.
        let body = original.isMnemonicReading(markdown: snapshot.markdown)
            ? try store.mnemonicReadingTeamCopyBody(snapshot.markdown, fallbackTitle: original.title, teamID: teamID)
            : snapshot.markdown
        try Data(body.utf8).write(to: document, options: .atomic)
        // Inline images travel with the body package, so the attachments
        // folder is copied whole when the original has one.
        let originalAttachments = try artifactDirectoryURL(artifactID: artifactID, createIfNeeded: false)
            .appendingPathComponent("Attachments", isDirectory: true)
        if FileManager.default.fileExists(atPath: originalAttachments.path) {
            let copyAttachments = directory.appendingPathComponent("Attachments", isDirectory: true)
            try? FileManager.default.removeItem(at: copyAttachments)
            try FileManager.default.copyItem(at: originalAttachments, to: copyAttachments)
        }
        // A site kept in the library is its files: the team's copy holds its
        // own, which ride the team record's body package to every member.
        if let siteFiles = try store.localSiteFiles(artifactID) {
            try store.writeLocalSiteFiles(siteFiles, artifactID: copyID)
        }
        var saved = try store.copyArtifactRowIntoTeam(
            artifactID: artifactID,
            teamID: teamID,
            linkedTeamNotebookIDs: linkedTeamNotebookIDs,
            fileCopy: { path in try self.copyFileIntoTeam(relativePath: path, teamID: teamID) }
        )
        if carryCitedSources {
            saved.carriedSources.merge(carriedCitedSources(of: artifactID, into: teamID, store: store))
        }
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Teams")
        for failure in saved.carriedSources.failed {
            logger.error("Source \(failure.originalID, privacy: .public) did not travel with \(artifactID, privacy: .public) into team \(teamID, privacy: .public): \(failure.reason, privacy: .public)")
        }
        if scheduleSync {
            scheduleImmediateCloudKitSyncForTeams()
            NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
        }
        return saved
    }

    /// The closed sources a Doc cites, copied into the team one by one; a
    /// source that cannot be copied is reported, and the rest still go.
    private func carriedCitedSources(of artifactID: String, into teamID: String, store: KnowledgeStore) -> CarriedTeamSources {
        var carried = CarriedTeamSources()
        let cited: [StudioArticle]
        do {
            cited = try citedSourcesToCarry(artifactID: artifactID, teamID: teamID)
        } catch {
            carried.failed.append(.init(originalID: artifactID, reason: "The Page's cited sources could not be read: \(error.localizedDescription)"))
            return carried
        }
        for article in cited {
            do {
                let copyID = try store.copySourceIntoTeam(sourceID: article.id, teamID: teamID) { path in
                    try self.copyFileIntoTeam(relativePath: path, teamID: teamID)
                }
                carried.cited.append(.init(originalID: article.id, teamCopyID: copyID, title: article.title, url: article.url))
            } catch {
                carried.failed.append(.init(originalID: article.id, reason: error.localizedDescription))
            }
        }
        return carried
    }

    /// The rows a course files `sourceIDs` as (docs/teams-design.md, decision
    /// 21): the same ids for a course of My Library. A team's course names
    /// only the team's rows, and a team library lists the learner's own rows
    /// beside them, so an own source added to a team's course — dropped on
    /// it, a playlist refreshed into it, a textbook read with it — is copied
    /// into the team first, file included, the way a team Notebook's pool is
    /// (`sourceIDsForGoalLibrary`); the store then files the copy
    /// (`KnowledgeStore.lectureItemFiledInCourse`). A source that cannot be
    /// copied is logged and has no entry.
    func courseLibrarySourceIDs(courseID: String, _ sourceIDs: [String]) throws -> [String: String] {
        let store = try notebookFilesKnowledgeStore()
        guard let teamID = try store.courseTeamID(courseID) else {
            return Dictionary(sourceIDs.map { ($0, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Teams")
        var mapped: [String: String] = [:]
        var copied = false
        for sourceID in Set(sourceIDs) {
            let result = store.carrySourcesIntoTeam([sourceID], teamID: teamID) { path in
                try self.copyFileIntoTeam(relativePath: path, teamID: teamID)
            }
            if let failure = result.carried.failed.first {
                logger.error("Could not copy source \(sourceID, privacy: .public) into team \(teamID, privacy: .public) for course \(courseID, privacy: .public): \(failure.reason, privacy: .public)")
                continue
            }
            copied = copied || result.carried.count > 0
            if let id = result.sourceIDs.first { mapped[sourceID] = id }
        }
        if copied {
            scheduleImmediateCloudKitSyncForTeams()
            NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
        }
        return mapped
    }

    /// Share a course with a team (docs/teams-design.md, decision 21): the
    /// course, its lectures, readings and quizzes under team-scoped ids, with
    /// every source on its path copied into the team, files included, so each
    /// member takes it with their own progress. Returns the team's course id
    /// and what travelled; a source that could not be copied is logged and
    /// reported, and the course still goes.
    @discardableResult
    func shareCourse(_ courseID: String, withTeam teamID: String) throws -> CourseTeamCopy {
        let copy = try notebookFilesKnowledgeStore().copyCourseIntoTeam(courseID: courseID, teamID: teamID) { path in
            try self.copyFileIntoTeam(relativePath: path, teamID: teamID)
        }
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Teams")
        for failure in copy.carriedSources.failed {
            logger.error("Source \(failure.originalID, privacy: .public) did not travel with course \(courseID, privacy: .public) into team \(teamID, privacy: .public): \(failure.reason, privacy: .public)")
        }
        scheduleImmediateCloudKitSyncForTeams()
        NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
        return copy
    }

    /// Share a chat with a team as a read-only transcript snapshot. Returns
    /// the snapshot's id.
    @discardableResult
    func shareChat(_ sessionID: String, withTeam teamID: String, notebookID: String? = nil) throws -> String {
        let copyID = try notebookFilesKnowledgeStore().snapshotChatIntoTeam(
            sessionID: sessionID,
            teamID: teamID,
            notebookID: notebookID
        )
        scheduleImmediateCloudKitSyncForTeams()
        NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
        return copyID
    }

    // MARK: - Share… on a notebook

    /// Share… on a notebook in one step (docs/teams-design.md, decision 22):
    /// the team that holds the notebook, ready for people to be invited.
    ///
    /// With `teamID`, the notebook is shared into that team. Without one, a
    /// team's own notebook is its team's; a notebook one team already holds a
    /// copy of is that team's; and a notebook no team holds gets a
    /// new team named after it, its title as written, emoji included, which
    /// then holds it. A team that already has the notebook, named or found,
    /// gets nothing copied again: what was filed since followed it (decision
    /// 10), and copying again would put back what a teammate removed. Sharing
    /// is the existing Share with Team path, unchanged: the notebook's
    /// approved sources with their files, its Goals, Docs and chats, and from
    /// then on what is filed under it. A notebook two or more
    /// teams hold is refused, naming them, rather than guessing or making
    /// another; a team this account may only read is refused too, since its
    /// members cannot invite. A team made here whose share then fails is
    /// deleted again, so a retry never leaves an empty one behind. Shares of
    /// one notebook run one at a time (`inNotebookShareLane`).
    func shareNotebook(_ notebookID: String, intoTeam teamID: String? = nil) async throws -> NotebookTeamShare {
        try await inNotebookShareLane(notebookID) {
            try await self.shareNotebookNow(notebookID, intoTeam: teamID)
        }
    }

    /// Runs `work` for a notebook once the Share… already running for it has
    /// finished. Deciding the team and making it are apart in time (iCloud
    /// makes the zone and its share), so a second press, or the popover and
    /// an assistant at once, would otherwise both find no team and make two;
    /// waiting, the second finds the team the first made. Another notebook's
    /// share does not wait.
    func inNotebookShareLane<T: Sendable>(
        _ notebookID: String,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = notebookShareLanes[notebookID]
        let task = Task<T, Error> {
            await previous?.value
            return try await work()
        }
        let marker = Task<Void, Never> { _ = await task.result }
        notebookShareLanes[notebookID] = marker
        let result = await task.result
        if notebookShareLanes[notebookID] == marker { notebookShareLanes[notebookID] = nil }
        return try result.get()
    }

    private func shareNotebookNow(_ notebookID: String, intoTeam teamID: String?) async throws -> NotebookTeamShare {
        let store = try notebookFilesKnowledgeStore()
        switch try notebookShareTarget(notebookID, intoTeam: teamID) {
        case let .team(team, teamNotebookID?):
            return try notebookShare(team: team, createdTeam: false, teamNotebookID: teamNotebookID, store: store)
        case let .team(team, nil):
            let copyID = try shareNotebook(notebookID, withTeam: team.id)
            return try notebookShare(team: team, createdTeam: false, teamNotebookID: copyID, store: store)
        case let .newTeam(name):
            let team = try await createTeam(name: name)
            let copyID: String
            do {
                copyID = try shareNotebook(notebookID, withTeam: team.id)
            } catch {
                try? await deleteTeam(team.id)
                throw error
            }
            return try notebookShare(team: team, createdTeam: true, teamNotebookID: copyID, store: store)
        }
    }

    /// Where Share… on a notebook would share it, decided without sharing,
    /// so a caller can refuse before it asks anything (`shareNotebook`'s
    /// rules and refusals, which it calls).
    func notebookShareTarget(_ notebookID: String, intoTeam teamID: String? = nil) throws -> NotebookShareTarget {
        let store = try notebookFilesKnowledgeStore()
        guard let notebook = try store.loadLearningGoal(notebookID), notebook.isNotebook else {
            throw NotebookShareError.notANotebook(notebookID)
        }
        if let teamID {
            guard let team = try store.loadTeam(teamID) else { throw TeamError.unknownTeam(teamID) }
            guard team.canEdit else { throw NotebookShareError.readOnly(team) }
            if notebook.teamID == team.id { return .team(team, teamNotebookID: notebook.id) }
            // A team that has the notebook keeps its copy as it is: copying
            // it again would put back what a teammate removed (decision 10).
            let copyID = TeamContentIdentity.notebookID(teamID: team.id, originalNotebookID: notebookID)
            return .team(team, teamNotebookID: try store.loadLearningGoal(copyID) == nil ? nil : copyID)
        }
        if let ownTeamID = notebook.teamID {
            guard let team = try store.loadTeam(ownTeamID) else { throw TeamError.unknownTeam(ownTeamID) }
            guard team.canEdit else { throw NotebookShareError.readOnly(team) }
            return .team(team, teamNotebookID: notebook.id)
        }
        let holding = try store.teamsHoldingNotebookCopy(notebookID)
        if holding.count > 1 {
            throw NotebookShareError.inSeveralTeams(notebookTitle: notebook.title, teams: holding)
        }
        if let team = holding.first {
            guard team.canEdit else { throw NotebookShareError.readOnly(team) }
            return .team(team, teamNotebookID: TeamContentIdentity.notebookID(teamID: team.id, originalNotebookID: notebookID))
        }
        let title = notebook.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return .newTeam(name: title.isEmpty ? "Untitled notebook" : title)
    }

    /// Who has a notebook, for its Share… popover: its team, for a team's own
    /// notebook; otherwise every team holding a copy, read-only ones included.
    func teamsHoldingNotebook(_ notebookID: String) throws -> [TeamRecord] {
        let store = try notebookFilesKnowledgeStore()
        if let teamID = try store.loadLearningGoal(notebookID)?.teamID {
            return try store.loadTeam(teamID).map { [$0] } ?? []
        }
        return try store.teamsHoldingNotebookCopy(notebookID)
    }

    /// The team as stored now (its share link included) and the sources its
    /// notebook holds.
    private func notebookShare(
        team: TeamRecord,
        createdTeam: Bool,
        teamNotebookID: String,
        store: KnowledgeStore
    ) throws -> NotebookTeamShare {
        let current = try store.loadTeam(team.id) ?? team
        let sources = try store.loadLearningGoal(teamNotebookID)?.approvedSourceIDs.count ?? 0
        return NotebookTeamShare(team: current, createdTeam: createdTeam, teamNotebookID: teamNotebookID, sharedSourceCount: sources)
    }

    /// The link Copy Invitation Link copies: an owner's opens the team's
    /// share to anyone with the link, at read and write, first
    /// (`openTeamShareToAnyoneWithLink`); a member's is the link as it
    /// stands. A team iCloud has not shared yet has no link.
    func invitationLink(for team: TeamRecord) async throws -> URL {
        return try await spaceInvitationLink(teamID: team.id)
    }

    // MARK: - Share requests

    /// A request one editor answers on behalf of the team: the request and the
    /// row in My Library that would fulfil it.
    struct FulfillableShareRequest: Equatable, Sendable {
        let request: ShareRequestRecord
        let sourceID: String
    }

    func loadShareRequests(teamID: String, status: ShareRequestStatus? = nil) throws -> [ShareRequestRecord] {
        try notebookFilesKnowledgeStore().loadShareRequests(teamID: teamID, status: status)
    }

    func loadOpenShareRequests() throws -> [ShareRequestRecord] {
        try notebookFilesKnowledgeStore().loadOpenShareRequests()
    }

    func loadShareRequest(_ id: String) throws -> ShareRequestRecord? {
        try notebookFilesKnowledgeStore().loadShareRequest(id)
    }

    /// The open request standing for an address in a team, if any — what a
    /// card shows as Requested.
    func openShareRequest(teamID: String, url: String) throws -> ShareRequestRecord? {
        try notebookFilesKnowledgeStore().openShareRequest(teamID: teamID, url: url)
    }

    /// A member asks the team for a source a card could not add. Idempotent on
    /// the address: a second ask while one stands returns the standing request.
    /// Refused when the team already holds the source — the card should have
    /// been a check — and when this account can only read the team.
    @discardableResult
    func requestShare(
        teamID: String,
        url rawURL: String,
        title: String?,
        artifactID: String?,
        requestedBy member: TeamMemberRecord?
    ) throws -> ShareRequestRecord {
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { throw KnowledgeStoreError.invalidData("A share request needs the source's address.") }
        let store = try notebookFilesKnowledgeStore()
        guard let team = try store.loadTeam(teamID) else {
            throw KnowledgeStoreError.invalidData("Team \(teamID) does not exist.")
        }
        guard team.canEdit else {
            throw KnowledgeStoreError.invalidData("Only an editor of \(team.name) can ask it for a source.")
        }
        if let held = store.activeSourceID(forReferenceURL: url, teamID: teamID) {
            throw KnowledgeStoreError.invalidData("\(team.name) already holds this source (\(held)).")
        }
        if let standing = try store.openShareRequest(teamID: teamID, url: url) {
            return standing
        }
        let request = ShareRequestRecord(
            teamID: teamID,
            url: url,
            title: title.flatMap { raw -> String? in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            },
            artifactID: artifactID,
            requestedByRecordName: member?.userRecordName,
            requestedByDisplayName: member?.displayName
        )
        try store.saveShareRequest(request)
        scheduleImmediateCloudKitSyncForTeams()
        NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
        return request
    }

    /// The open requests this Mac can answer: the team is editable for this
    /// account and My Library holds the source, matched the way the card
    /// matched it (URL, DOI, arXiv id). Newest first.
    func fulfillableShareRequests() throws -> [FulfillableShareRequest] {
        let store = try notebookFilesKnowledgeStore()
        var editable: [String: TeamRecord] = [:]
        for team in try store.loadTeams() where team.canEdit { editable[team.id] = team }
        var result: [FulfillableShareRequest] = []
        for request in try store.loadOpenShareRequests() where editable[request.teamID] != nil {
            guard let ownID = store.activeSourceID(forReferenceURL: request.url, teamID: nil) else { continue }
            result.append(FulfillableShareRequest(request: request, sourceID: ownID))
        }
        return result
    }

    /// Answer a request with this Mac's own copy: the source is shared into the
    /// team (file and all) and the request records the copy that answered it.
    @discardableResult
    func fulfilShareRequest(_ id: String, resolvedBy member: TeamMemberRecord?) throws -> ShareRequestRecord {
        let store = try notebookFilesKnowledgeStore()
        guard var request = try store.loadShareRequest(id) else {
            throw KnowledgeStoreError.invalidData("No share request with id \(id).")
        }
        guard request.isOpen else {
            throw KnowledgeStoreError.invalidData("This request was already \(request.status.rawValue).")
        }
        guard let team = try store.loadTeam(request.teamID) else {
            throw KnowledgeStoreError.invalidData("Team \(request.teamID) does not exist.")
        }
        guard team.canEdit else {
            throw KnowledgeStoreError.invalidData("Only an editor of \(team.name) can share into it.")
        }
        let copyID: String
        if let held = store.activeSourceID(forReferenceURL: request.url, teamID: team.id) {
            // Someone else answered it in the meantime; record the copy that is there.
            copyID = held
        } else {
            guard let ownID = store.activeSourceID(forReferenceURL: request.url, teamID: nil) else {
                throw KnowledgeStoreError.invalidData("My Library does not hold \(request.title ?? request.url), so this Mac cannot answer the request.")
            }
            copyID = try shareSources([ownID], withTeam: team.id).first ?? ownID
        }
        let now = Date()
        request.status = .fulfilled
        request.fulfilledSourceID = copyID
        request.resolvedByRecordName = member?.userRecordName
        request.resolvedByDisplayName = member?.displayName
        request.resolvedAt = now
        request.updatedAt = now
        try store.saveShareRequest(request)
        scheduleImmediateCloudKitSyncForTeams()
        NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
        return request
    }

    /// Close a request without a copy. Any editor of the team may.
    @discardableResult
    func declineShareRequest(_ id: String, resolvedBy member: TeamMemberRecord?) throws -> ShareRequestRecord {
        let store = try notebookFilesKnowledgeStore()
        guard var request = try store.loadShareRequest(id) else {
            throw KnowledgeStoreError.invalidData("No share request with id \(id).")
        }
        guard request.isOpen else {
            throw KnowledgeStoreError.invalidData("This request was already \(request.status.rawValue).")
        }
        guard let team = try store.loadTeam(request.teamID), team.canEdit else {
            throw KnowledgeStoreError.invalidData("Only an editor of the team can decline a request.")
        }
        let now = Date()
        request.status = .declined
        request.resolvedByRecordName = member?.userRecordName
        request.resolvedByDisplayName = member?.displayName
        request.resolvedAt = now
        request.updatedAt = now
        try store.saveShareRequest(request)
        scheduleImmediateCloudKitSyncForTeams()
        NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
        return request
    }

    /// The web references a Doc cites that My Library holds and the team does
    /// not — the sources that travel with the Doc when it is shared with the
    /// team (`shareArtifact`). Only the ones a teammate could not simply add
    /// for themselves: a paper or a book, or anything with a file on this Mac;
    /// an article is a fetch away.
    func citedSourcesToCarry(artifactID: String, teamID: String) throws -> [StudioArticle] {
        let snapshot = try artifactMarkdown(artifactID)
        let hrefs = Self.webReferences(in: snapshot.markdown)
        guard !hrefs.isEmpty else { return [] }
        let own = librarySourceIDs(forReferenceURLs: hrefs, teamID: nil)
        guard !own.isEmpty else { return [] }
        let held = librarySourceIDs(forReferenceURLs: hrefs, teamID: teamID)
        let candidateIDs = Set(hrefs.compactMap { href -> String? in
            guard let ownID = own[href], held[href] == nil else { return nil }
            return ownID
        })
        guard !candidateIDs.isEmpty else { return [] }
        let articles = try loadActiveSources(teamID: nil).filter { candidateIDs.contains($0.id) }
        return articles.filter { article in
            article.sourceType == .paper || article.sourceType == .book || article.localFilePath != nil
        }
    }

    /// Compiled once: the notes graph reads every block of a library with it.
    private nonisolated static let webReferenceExpression = try? NSRegularExpression(
        pattern: #"\]\((https?://[^\s)]+)\)|(?<![\w(\]])(https?://[^\s<>()\]]+)"#
    )

    /// Every http(s) link a Markdown body carries, in order, once each.
    nonisolated static func webReferences(in markdown: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        guard let regex = webReferenceExpression else { return [] }
        let ns = markdown as NSString
        for match in regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            for group in 1...2 {
                let range = match.range(at: group)
                guard range.location != NSNotFound else { continue }
                var url = ns.substring(with: range)
                while let last = url.last, ".,;:".contains(last) { url.removeLast() }
                if seen.insert(url).inserted { result.append(url) }
            }
        }
        return result
    }

    // MARK: - Notebook tasks

    func loadNotebookTasks(notebookID: String) throws -> [NotebookTaskRecord] {
        try notebookFilesKnowledgeStore().loadNotebookTasks(notebookID: notebookID)
    }

    func loadNotebookTasks(teamID: String) throws -> [NotebookTaskRecord] {
        try notebookFilesKnowledgeStore().loadNotebookTasks(teamID: teamID)
    }

    func loadNotebookTask(_ id: String) throws -> NotebookTaskRecord? {
        try notebookFilesKnowledgeStore().loadNotebookTask(id)
    }

    @discardableResult
    func saveNotebookTask(_ task: NotebookTaskRecord) throws -> NotebookTaskRecord {
        var saved = task
        saved.updatedAt = Date()
        try notebookFilesKnowledgeStore().saveNotebookTask(saved)
        scheduleImmediateCloudKitSyncForTeams()
        NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
        return try notebookFilesKnowledgeStore().loadNotebookTask(task.id) ?? saved
    }

    func deleteNotebookTask(_ id: String) throws {
        try notebookFilesKnowledgeStore().deleteNotebookTask(id)
        scheduleImmediateCloudKitSyncForTeams()
        NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
    }
}

/// Where Share… on a notebook shares it (`StorageService.notebookShareTarget`).
enum NotebookShareTarget: Equatable {
    /// An existing team; `teamNotebookID` is the notebook it already holds,
    /// nil when the share copies the notebook in.
    case team(TeamRecord, teamNotebookID: String?)
    /// No team holds the notebook: a new team with this name will.
    case newTeam(name: String)
}

/// Why Share… on a notebook did not share it (docs/teams-design.md, decision 22).
enum NotebookShareError: LocalizedError, Equatable {
    case notANotebook(String)
    /// This account may only read the team that holds the notebook, so it
    /// cannot invite anyone to it.
    case readOnly(TeamRecord)
    /// More than one team holds the notebook; the caller names the one to
    /// invite people to.
    case inSeveralTeams(notebookTitle: String, teams: [TeamRecord])

    var errorDescription: String? {
        switch self {
        case .notANotebook(let id):
            return "No notebook with id \(id)."
        case .readOnly(let team):
            return "\(team.name) is read-only for you, so only its owner can invite people to it."
        case let .inSeveralTeams(title, teams):
            return "‘\(title)’ is in \(teams.count) teams: \(teams.map(\.name).joined(separator: ", ")). Choose the one to invite people to."
        }
    }
}

enum TeamError: LocalizedError {
    case unknownTeam(String)
    case shareUnavailable(String)
    case notATeamShare
    case ownerCannotLeave
    case memberCannotDelete
    /// CloudKit created the zone but refused the zone-wide share; the zone was
    /// deleted again and no team exists.
    case shareRefused(name: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .unknownTeam(let id):
            return "Team \(id) is not on this Mac."
        case .shareUnavailable(let name):
            return "The invitation link for \(name) could not be read from iCloud."
        case .shareRefused(let name, let underlying):
            return "iCloud refused to create the share for “\(name)”, so the team was not created. \(underlying.localizedDescription)"
        case .notATeamShare:
            return "This link is not a ForeverLM team invitation."
        case .ownerCannotLeave:
            return "You own this team. Delete it instead of leaving it."
        case .memberCannotDelete:
            return "Only the team's owner can delete it. You can leave it."
        }
    }
}
