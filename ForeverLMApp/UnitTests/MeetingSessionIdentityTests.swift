import Testing
import Foundation
@testable import ForeverLM

/// A meeting session's identity is made only of things the meeting's own files
/// say. The regression these pin: the session key used to fall back to the
/// group's display title whenever a file led with its date, so renaming a Drive
/// folder re-keyed every session inside it and the next refresh imported all of
/// them a second time.
@Suite("Meeting session identity")
struct MeetingSessionIdentityTests {

    /// The exact naming convention that produced 42 duplicated sessions:
    /// date first, bracketed kind, topic, presenter.
    private static let handNamedStems = [
        "2026-08-30 - [Recording] - Journal Club - Somatic Mutations in Hashimoto's Thyroiditis - Morgan Ellery",
        "2026-08-30 - [Notes] - Journal Club - Somatic Mutations in Hashimoto's Thyroiditis - Morgan Ellery",
    ]

    @Test("a date-led file keys on its date, never on the folder it sits in")
    func dateLedFilesKeyOnTheirDate() {
        for stem in Self.handNamedStems {
            #expect(StudioViewModel.meetingSessionKey(from: stem) == "2026/08/30")
        }
    }

    @Test("every file of one meeting lands on one session key")
    func filesOfOneMeetingShareAKey() {
        let keys = Set(Self.handNamedStems.map { StudioViewModel.meetingSessionKey(from: $0) })
        #expect(keys.count == 1)
    }

    @Test("a Meet export keeps the series its own file name carries")
    func meetExportKeepsItsSeries() {
        #expect(
            StudioViewModel.meetingSessionKey(
                from: "Acme Longevity Nexus - 2026/06/21 09:00 PDT - Notes by Gemini"
            ) == "Acme Longevity Nexus - 2026/06/21"
        )
    }

    /// A timestamped export and a date-only upload for the same day are one
    /// meeting, which is why the time of day is dropped from the key.
    @Test("a timestamped export folds together with a date-only upload")
    func timestampAndDateOnlyFoldTogether() {
        #expect(
            StudioViewModel.meetingSessionKey(from: "Acme Longevity Nexus - 2026/06/21 09:00 PDT")
                == StudioViewModel.meetingSessionKey(from: "Acme Longevity Nexus - 2026-06-21")
        )
    }

    @Test("a file with no date keys on its cleaned name")
    func undatedFileKeepsItsName() {
        #expect(
            StudioViewModel.meetingSessionKey(from: "Nexus Arc Audit - Notes") == "Nexus Arc Audit"
        )
    }

    @Test("a name that is only a kind marker still keys on itself")
    func kindOnlyNameKeepsItsStem() {
        #expect(StudioViewModel.meetingSessionKey(from: "[Recording]") == "[Recording]")
    }

    @Test("a session title carries the topic, not the folder it sits in")
    func sessionTitleDropsTheSeries() {
        #expect(
            StudioViewModel.meetingSessionTitle(
                from: "Acme Lab Nexus - 2026/08/30",
                groupTitle: "Acme Lab Nexus"
            ) == "2026/08/30"
        )
    }

    @Test("a title keeps a retired folder name from being reapplied")
    func stripsRetiredSeriesPrefix() {
        let stripped = StudioViewModel.strippingMeetingSeriesPrefix(
            from: "Meeting Notes & Recordings - Nexus - Journal Club - Somatic Mutations in Hashimoto's Thyroiditis",
            series: ["Acme Lab Nexus", "Meeting Notes & Recordings - Nexus"]
        )
        #expect(stripped == "Journal Club - Somatic Mutations in Hashimoto's Thyroiditis")
    }

    /// Only a prefix this app wrote comes off. A session whose name merely opens
    /// with the same words is the learner's, and keeps them.
    @Test("a title that only begins with the series keeps it")
    func keepsSeriesWordsWithoutSeparator() {
        #expect(
            StudioViewModel.strippingMeetingSeriesPrefix(
                from: "Acme Lab Nexus Retrospective",
                series: ["Acme Lab Nexus"]
            ) == "Acme Lab Nexus Retrospective"
        )
        #expect(
            StudioViewModel.strippingMeetingSeriesPrefix(
                from: "Acme Lab Nexus",
                series: ["Acme Lab Nexus"]
            ) == "Acme Lab Nexus"
        )
    }

    @Test("a file belongs to exactly one session, and a contested file decides nothing")
    func artifactFileOwnership() {
        func artifact(_ id: String, source: String, url: String?) -> MeetingArtifact {
            MeetingArtifact(
                id: id,
                sourceId: source,
                groupId: "group",
                kind: .recording,
                title: id,
                url: url,
                localFilePath: url == nil ? "/Volumes/Meetings/\(id).mp4" : nil
            )
        }
        let owners = StudioViewModel.meetingArtifactFileOwners(
            sourceIDs: ["session-a", "session-b"],
            artifacts: [
                "session-a": [
                    artifact("recording", source: "session-a", url: "https://drive.google.com/file/d/rec/view"),
                    artifact("local", source: "session-a", url: nil),
                    artifact("shared", source: "session-a", url: "https://drive.google.com/file/d/shared/view"),
                ],
                "session-b": [
                    artifact("shared", source: "session-b", url: "https://drive.google.com/file/d/shared/view"),
                ],
            ]
        )
        #expect(owners["https://drive.google.com/file/d/rec/view"] == "session-a")
        #expect(owners["file:/Volumes/Meetings/local.mp4"] == "session-a")
        #expect(owners["https://drive.google.com/file/d/shared/view"] == nil)
    }
}

/// A folder that already stands as its own series is an identity boundary. The
/// regression: a parent folder's recursive listing walked into the meetings
/// folder nested inside it and filed a second copy of all forty-two sessions.
@Suite("Meeting folder boundaries")
@MainActor
struct MeetingFolderBoundaryTests {

    private func makeViewModel() -> StudioViewModel {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingBoundaryTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return StudioViewModel(storageService: StorageService(storeRoot: tmp))
    }

    @Test("an import skips folders that are series of their own")
    func linkedFoldersAreExcluded() {
        let vm = makeViewModel()
        var nested = MeetingMetadata(title: "Acme Lab Nexus")
        nested.driveFolderURL = "https://drive.google.com/drive/folders/nested-meetings"
        var parent = MeetingMetadata(title: "Acme Nexus - Member Drive")
        parent.driveFolderURL = "https://drive.google.com/drive/folders/member-drive"
        var removed = MeetingMetadata(title: "Retired series")
        removed.driveFolderURL = "https://drive.google.com/drive/folders/retired"
        removed.isHidden = true
        vm.meetingMetadata = ["nested": nested, "parent": parent, "retired": removed]

        let excluded = vm.linkedGoogleDriveFolderIDs(excluding: "member-drive")
        #expect(excluded.contains("nested-meetings"))
        // The folder being imported is never excluded from its own listing, and
        // a removed series stops being a boundary.
        #expect(!excluded.contains("member-drive"))
        #expect(!excluded.contains("retired"))
    }
}

@Suite("Meeting session duplicate merge")
struct MeetingSessionDuplicateMergeTests {

    @Test("folding a re-keyed session keeps its relationships and drops its duplicate files")
    func foldingKeepsRelationships() throws {
        let store = try KnowledgeStore(inMemory: true)
        let groupID = "785B6DF8"
        try store.saveMeetingGroup(name: groupID, metadata: MeetingMetadata(title: "Acme Lab Nexus"))

        var canonical = StudioArticle(
            url: "meeting://\(groupID)/2026/08/30",
            title: "Journal Club - Somatic Mutations in Hashimoto's Thyroiditis",
            sourceType: .meeting,
            parentGroup: groupID,
            id: "canonical-session"
        )
        canonical.state = .queued
        var stale = StudioArticle(
            url: "meeting://\(groupID)/Meeting%20Notes%20&%20Recordings%20-%20Nexus%20-%202026/08/30",
            title: "Meeting Notes & Recordings - Nexus - Journal Club - Somatic Mutations in Hashimoto's Thyroiditis",
            sourceType: .meeting,
            parentGroup: groupID,
            id: "stale-session"
        )
        stale.state = .queued
        try store.saveSource(canonical)
        try store.saveSource(stale)

        for (sourceID, artifactID) in [(canonical.id, "canonical-recording"), (stale.id, "stale-recording")] {
            try store.saveMeetingArtifact(
                MeetingArtifact(
                    id: artifactID,
                    sourceId: sourceID,
                    groupId: groupID,
                    kind: .recording,
                    title: "2026-08-30 - [Recording] - Journal Club - Morgan Ellery",
                    url: "https://drive.google.com/file/d/recording/view"
                )
            )
        }

        let goalID = "somatic-mutations"
        let now = Date(timeIntervalSinceReferenceDate: 100)
        try store.saveLearningGoalRecord(
            LearningGoalRecord(
                id: goalID,
                title: "Somatic mutations",
                startAt: now,
                endAt: Date(timeIntervalSinceReferenceDate: 200),
                createdAt: now,
                updatedAt: now,
                status: LearningGoalStatus.active.rawValue,
                items: [
                    LearningGoalItem(
                        id: "stale-item",
                        goalID: goalID,
                        sourceID: stale.id,
                        addedAt: now,
                        reviewState: LearningGoalItemReviewState.approved.rawValue
                    )
                ],
                kind: "companion"
            )
        )
        try store.createReviewSession(
            id: "stale-review",
            topic: "Review",
            sourceIDs: [stale.id]
        )

        try store.archiveMeetingSessionDuplicate(stale.id, replacingWith: canonical.id)

        #expect(try store.loadActiveSources().map(\.id) == [canonical.id])
        #expect(try store.loadSources().first { $0.id == stale.id }?.status == .archived)
        let items = try store.loadLearningGoalItems(goalID: goalID)
        #expect(items.map(\.sourceID) == [canonical.id])
        #expect(try store.reviewSessionSourceIDsBySessionID()["stale-review"] == [canonical.id])
        // The surviving session already lists the file; the fold must not leave
        // the same recording under the meeting twice.
        let artifacts = try store.loadMeetingArtifacts(groupID: groupID)
        #expect(artifacts.map(\.id) == ["canonical-recording"])
    }
}

/// Deleting a meeting series deletes it. The behaviour these pin: removal used
/// to hide the folder and archive its sessions, which left the series listed
/// under Hidden Items with every transcript already cleared — a folder the
/// learner had deleted, still in the database, and restorable only as an empty
/// shell.
@Suite("Meeting group deletion")
struct MeetingGroupDeletionTests {

    private func meetingSession(id: String, group: String, day: String) -> StudioArticle {
        var session = StudioArticle(
            url: "meeting://\(group)/\(day)",
            title: "Journal Club - \(day)",
            sourceType: .meeting,
            parentGroup: group,
            id: id
        )
        session.state = .queued
        return session
    }

    @Test("deleting a series takes its sessions, artifacts and alias rows with it")
    func deletingTakesTheWholeSeries() throws {
        let store = try KnowledgeStore(inMemory: true)
        let groupID = "14A3C35D"
        let aliasID = "0FF81077"
        let otherGroupID = "785B6DF8"
        try store.saveMeetingGroup(
            name: groupID,
            metadata: MeetingMetadata(title: "Acme Nexus - Member Drive")
        )
        var alias = MeetingMetadata(title: "Member Drive")
        alias.mergedIntoGroupID = groupID
        try store.saveMeetingGroup(name: aliasID, metadata: alias)
        try store.saveMeetingGroup(
            name: otherGroupID,
            metadata: MeetingMetadata(title: "Acme Lab Nexus")
        )

        let session = meetingSession(id: "session-a", group: groupID, day: "2026/08/30")
        let aliasSession = meetingSession(id: "session-b", group: aliasID, day: "2026/08/23")
        let keeper = meetingSession(id: "session-c", group: otherGroupID, day: "2026/08/16")
        for source in [session, aliasSession, keeper] {
            try store.saveSource(source)
            try store.saveMeetingArtifact(
                MeetingArtifact(
                    id: "\(source.id)-recording",
                    sourceId: source.id,
                    groupId: source.parentGroup ?? "",
                    kind: .recording,
                    title: "\(source.title) - Recording",
                    url: "https://drive.google.com/file/d/\(source.id)/view"
                )
            )
        }

        let deleted = try store.deleteMeetingGroupWithSessions(name: groupID)

        #expect(Set(deleted) == ["session-a", "session-b"])
        #expect(try store.loadSources().map(\.id) == ["session-c"])
        #expect(try store.loadMeetingGroups().keys.sorted() == [otherGroupID])
        #expect(try store.loadMeetingArtifacts(groupID: groupID).isEmpty)
        #expect(try store.loadMeetingArtifacts(groupID: aliasID).isEmpty)
        #expect(try store.loadMeetingArtifacts(groupID: otherGroupID).count == 1)

        // The other Mac has to hear about it, or the folder syncs straight back.
        let pending = try store.pendingSyncChanges()
        let deletions = Set(
            pending.filter { $0.operation == .delete }.map { "\($0.entity.rawValue):\($0.logicalKey)" }
        )
        #expect(deletions.contains("meetingGroup:\(groupID)"))
        #expect(deletions.contains("meetingGroup:\(aliasID)"))
        #expect(deletions.contains("source:session-a"))
        #expect(deletions.contains("source:session-b"))
    }

    @Test("a session shared with another group survives, losing only its membership here")
    func aSharedSessionSurvives() throws {
        let store = try KnowledgeStore(inMemory: true)
        let groupID = "14A3C35D"
        let otherGroupID = "785B6DF8"
        try store.saveMeetingGroup(
            name: groupID,
            metadata: MeetingMetadata(title: "Acme Nexus - Member Drive")
        )
        let shared = meetingSession(id: "session-shared", group: groupID, day: "2026/08/30")
        try store.saveSource(shared)
        // `saveSource` writes one membership per source, so the second one is
        // written the way an inbound sync writes it.
        try store.execBind("INSERT INTO group_members (source_id, group_id) VALUES (?, ?)") { stmt in
            store.bind(stmt, 1, shared.id)
            store.bind(stmt, 2, otherGroupID)
        }

        let deleted = try store.deleteMeetingGroupWithSessions(name: groupID)

        #expect(deleted.isEmpty)
        #expect(try store.loadSources().map(\.id) == [shared.id])
        var remainingGroups: [String] = []
        try store.queryBind("SELECT group_id FROM group_members WHERE source_id = ?", bind: { stmt in
            store.bind(stmt, 1, shared.id)
        }) { stmt in
            if let group = store.string(stmt, 0) { remainingGroups.append(group) }
        }
        #expect(remainingGroups == [otherGroupID])
    }

    @Test("a session the group no longer lists is deleted with it")
    func aDriftedSessionGoesToo() throws {
        let store = try KnowledgeStore(inMemory: true)
        let groupID = "14A3C35D"
        try store.saveMeetingGroup(
            name: groupID,
            metadata: MeetingMetadata(title: "Acme Nexus - Member Drive")
        )
        var orphan = meetingSession(id: "session-orphan", group: groupID, day: "2026/08/30")
        try store.saveSource(orphan)
        try store.execBind("DELETE FROM group_members WHERE source_id = ?") { stmt in
            store.bind(stmt, 1, orphan.id)
        }
        orphan.parentGroup = nil

        let deleted = try store.deleteMeetingGroupWithSessions(
            name: groupID,
            additionalSessionIDs: ["session-orphan"]
        )

        #expect(deleted == ["session-orphan"])
        #expect(try store.loadSources().isEmpty)
    }
}

@Suite("Meeting group deletion in the sidebar")
@MainActor
struct MeetingGroupDeletionViewModelTests {

    private func makeViewModel() -> StudioViewModel {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingDeletionTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return StudioViewModel(storageService: StorageService(storeRoot: tmp))
    }

    @Test("a deleted series leaves no row behind to unhide")
    func deletedSeriesLeavesNoRow() async {
        let vm = makeViewModel()
        let groupID = "14A3C35D"
        let aliasID = "0FF81077"
        var metadata = MeetingMetadata(title: "Acme Nexus - Member Drive")
        metadata.isHidden = true
        var alias = MeetingMetadata(title: "Member Drive")
        alias.mergedIntoGroupID = groupID
        vm.meetingMetadata = [groupID: metadata, aliasID: alias]
        vm.userMeetingGroupNames = [groupID, aliasID]

        await vm.deleteMeetingGroupForGood(
            name: groupID,
            title: "Acme Nexus - Member Drive",
            sessionIDs: []
        )

        #expect(vm.meetingMetadata.isEmpty)
        #expect(vm.userMeetingGroupNames.isEmpty)
        #expect(vm.hiddenMeetingGroupNames.isEmpty)
        #expect(vm.allMeetingGroupNames.isEmpty)
    }

    @Test("a deleted series tombstones each of its recordings")
    func deletedSeriesTombstonesItsRecordings() async throws {
        let vm = makeViewModel()
        let groupID = "zoom:examplefellowship.zoom.us"
        var metadata = MeetingMetadata(title: "Robin <> Zara standup")
        metadata.isHidden = true
        vm.meetingMetadata = [groupID: metadata]
        vm.userMeetingGroupNames = [groupID]
        try await vm.storage.saveMeetingGroup(name: groupID, metadata: metadata)
        let recordingURL = "https://examplefellowship.zoom.us/rec/share/ExampleShareAAAA0000111122223333"
        var session = StudioArticle(
            url: recordingURL,
            title: "Robin <> Zara standup",
            sourceType: .meeting,
            discoveryOrigin: .zoom,
            parentGroup: groupID
        )
        session.state = .error
        try await vm.storage.saveSource(session)
        vm.articles = [session]

        await vm.deleteMeetingGroupForGood(
            name: groupID,
            title: "Robin <> Zara standup",
            sessionIDs: [session.id]
        )

        #expect(vm.articles.isEmpty)
        #expect(try await vm.storage.loadPersistedSources(ids: [session.id]).isEmpty)
        // The row is gone, so "already exists" can no longer answer for it; the
        // recording's URL is now the learner's removal, and every discovery
        // route — the MCP add_source the recordings mailbox calls included —
        // refuses it.
        #expect(await vm.storage.isSourceDismissed(url: recordingURL))
        var again = StudioArticle(
            url: recordingURL,
            title: "Robin <> Zara standup",
            sourceType: .meeting,
            discoveryOrigin: .zoom,
            parentGroup: groupID
        )
        #expect(try await vm.storage.insertSourceIfNew(&again) == false)
    }
}

/// Every session row in a series reads the same way whatever shape its title
/// was stored in. The regression these pin: one series showed "September 17,
/// 2026" beside "Robin <> Zara - 2026/09/19 09:10" beside "2026/09/11 (notes)",
/// and a session pushed in a day late was titled with the day it was filed.
@Suite("Meeting session row title")
struct MeetingSessionRowTitleTests {
    private static let group = "Robin <> Zara standup"
    private static let filedAt = Date(timeIntervalSince1970: 1_790_000_000)

    private static func expectedDay(_ title: String) -> (text: String, date: Date) {
        let date = StudioViewModel.meetingDate(from: title)!
        return (date.formatted(date: .long, time: .omitted), date)
    }

    @Test("a series-and-date title becomes the spelled-out day")
    func seriesAndDateBecomesDay() {
        let expected = Self.expectedDay("2026/09/17 08:55")
        let row = StudioViewModel.meetingSessionRowTitle(
            storedTitle: "Robin <> Zara standup - 2026/09/17 08:55",
            groupTitle: Self.group,
            dateAdded: Self.filedAt
        )
        #expect(row.text == expected.text)
        #expect(row.day == expected.date)
        #expect(row.time == expected.date)
    }

    @Test("a shortened provider topic in front of the date is still the series")
    func shortenedSeriesIsStillTheSeries() {
        let expected = Self.expectedDay("2026/09/19 09:10")
        let row = StudioViewModel.meetingSessionRowTitle(
            storedTitle: "Robin <> Zara - 2026/09/19 09:10",
            groupTitle: Self.group,
            dateAdded: Self.filedAt
        )
        #expect(row.text == expected.text)
        #expect(row.day == expected.date)
    }

    @Test("a topic in Zoom's file-name spelling in front of the date is still the series")
    func fileNameSpelledSeriesIsStillTheSeries() {
        // The 2026-09-28 standup's stored title, which the row printed raw.
        let expected = Self.expectedDay("2026/09/28 10:02")
        let row = StudioViewModel.meetingSessionRowTitle(
            storedTitle: "Robin __ Zara - 2026/09/28 10:02",
            groupTitle: Self.group,
            dateAdded: Self.filedAt
        )
        #expect(row.text == expected.text)
        #expect(row.day == expected.date)
        #expect(row.time == expected.date)
    }

    @Test("a bare date title, as the importers store it, reads the same")
    func bareDateReadsTheSame() {
        let expected = Self.expectedDay("2026/09/15 08:30")
        let row = StudioViewModel.meetingSessionRowTitle(
            storedTitle: "2026/09/15 08:30",
            groupTitle: Self.group,
            dateAdded: Self.filedAt
        )
        #expect(row.text == expected.text)
    }

    @Test("the day comes from the title, not from when the session was filed")
    func dayComesFromTheTitle() {
        let row = StudioViewModel.meetingSessionRowTitle(
            storedTitle: "Robin <> Zara standup - 2026/09/17 11:55",
            groupTitle: Self.group,
            dateAdded: Self.filedAt
        )
        #expect(row.day == StudioViewModel.meetingDate(from: "2026/09/17 11:55"))
        #expect(row.time == row.day)
        #expect(row.day != Self.filedAt)
    }

    @Test("a day-only title borrows the filing time on the same day, and none otherwise")
    func dayOnlyTitleTime() {
        let day = StudioViewModel.meetingDate(from: "2026/09/12")!
        let sameDay = day.addingTimeInterval(11 * 3600 + 31 * 60)
        let onTheDay = StudioViewModel.meetingSessionRowTitle(
            storedTitle: "Robin <> Zara standup - 2026/09/12",
            groupTitle: Self.group,
            dateAdded: sameDay
        )
        #expect(onTheDay.day == day)
        #expect(onTheDay.time == sameDay)
        let daysLater = StudioViewModel.meetingSessionRowTitle(
            storedTitle: "Robin <> Zara standup - 2026/09/12",
            groupTitle: Self.group,
            dateAdded: Self.filedAt
        )
        #expect(daysLater.day == day)
        #expect(daysLater.time == nil)
    }

    @Test("a real topic keeps its name and carries no day")
    func topicKeepsItsName() {
        let row = StudioViewModel.meetingSessionRowTitle(
            storedTitle: "Robin <> Zara standup - Product narrative",
            groupTitle: Self.group,
            dateAdded: Self.filedAt
        )
        #expect(row.text == "Product narrative")
        #expect(row.day == nil)
    }

    @Test("a suffix after the date is a name, and stays")
    func suffixedDateIsAName() {
        let row = StudioViewModel.meetingSessionRowTitle(
            storedTitle: "Robin <> Zara standup - 2026/09/11 (notes)",
            groupTitle: Self.group,
            dateAdded: Self.filedAt
        )
        #expect(row.text == "2026/09/11 (notes)")
        #expect(row.day == nil)
    }

    @Test("an unrelated series in front of the date is not stripped")
    func unrelatedSeriesIsKept() {
        let row = StudioViewModel.meetingSessionRowTitle(
            storedTitle: "Biostasis Working Group - 2026/09/19 09:10",
            groupTitle: Self.group,
            dateAdded: Self.filedAt
        )
        #expect(row.text == "Biostasis Working Group - 2026/09/19 09:10")
        #expect(row.day == nil)
    }

    @Test("a series variant has to end at a word boundary")
    func variantEndsAtAWordBoundary() {
        #expect(StudioViewModel.isSeriesVariant("Robin <> Zara", of: "Robin <> Zara standup"))
        #expect(StudioViewModel.isSeriesVariant("Robin __ Zara", of: "Robin <> Zara standup"))
        #expect(StudioViewModel.isSeriesVariant("robin __ zara standup", of: "Robin <> Zara standup"))
        #expect(StudioViewModel.isSeriesVariant("Lab", of: "Lab: weekly"))
        #expect(!StudioViewModel.isSeriesVariant("Robin __ Za", of: "Robin <> Zara standup"))
        #expect(StudioViewModel.isSeriesVariant("Acme Lab Nexus", of: "Acme Lab Nexus - Sunday"))
        #expect(!StudioViewModel.isSeriesVariant("Robin <> Za", of: "Robin <> Zara standup"))
        #expect(!StudioViewModel.isSeriesVariant("Ro", of: "Robin <> Zara standup"))
        #expect(!StudioViewModel.isSeriesVariant("Biostasis", of: "Robin <> Zara standup"))
    }

    // MARK: - Sessions filed under their date

    /// A session filed while the topic call could not run kept its date and,
    /// until 2026-11-08, kept it for good. These pin which filed sessions are
    /// asked about again.
    @Test("a session titled only by its date and with no presenter is read again")
    func dateOnlySessionNeedsDescriptor() {
        #expect(StudioViewModel.meetingSessionNeedsDescriptor(
            storedTitle: "2026/10/11", author: nil,
            sessionKey: "2026/10/11", groupTitle: "Acme Lab Nexus"
        ))
        #expect(StudioViewModel.meetingSessionNeedsDescriptor(
            storedTitle: "Acme Lab Nexus - 2026/07/12 11:48", author: "  ",
            sessionKey: "Acme Lab Nexus - 2026/07/12 11:48", groupTitle: "Acme Lab Nexus"
        ))
    }

    @Test("a session with a topic, a presenter, or the learner's own name is left alone")
    func describedSessionIsLeftAlone() {
        #expect(!StudioViewModel.meetingSessionNeedsDescriptor(
            storedTitle: "JC: Cellular Identity in Aging", author: nil,
            sessionKey: "2026/10/11", groupTitle: "Acme Lab Nexus"
        ))
        #expect(!StudioViewModel.meetingSessionNeedsDescriptor(
            storedTitle: "2026/10/11", author: "Morgan Ellery",
            sessionKey: "2026/10/11", groupTitle: "Acme Lab Nexus"
        ))
        #expect(!StudioViewModel.meetingSessionNeedsDescriptor(
            storedTitle: "Acme Lab Nexus Retrospective", author: nil,
            sessionKey: "2026/10/11", groupTitle: "Acme Lab Nexus"
        ))
    }

    @Test("a session is read again only when its file names change")
    func attemptKeyFollowsFileNames() {
        let first = StudioViewModel.meetingDescriptorAttemptKey(
            groupID: "G", sessionKey: "2026/10/11",
            fileNames: ["2026-10-11 - [Notes]", "2026-10-11 - [Recording]"]
        )
        let reordered = StudioViewModel.meetingDescriptorAttemptKey(
            groupID: "G", sessionKey: "2026/10/11",
            fileNames: ["2026-10-11 - [Recording]", "2026-10-11 - [Notes]"]
        )
        let renamed = StudioViewModel.meetingDescriptorAttemptKey(
            groupID: "G", sessionKey: "2026/10/11",
            fileNames: ["2026-10-11 - [Notes] - Topic - Morgan Ellery", "2026-10-11 - [Recording]"]
        )
        #expect(first == reordered)
        #expect(first != renamed)
    }
}
