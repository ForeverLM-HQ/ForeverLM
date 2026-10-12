import CloudKit
import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// The rows and routing that make a team a library of its own: team copies get
/// deterministic team-scoped ids and never appear in My Library; every team
/// record is queued for the team's zone; a member's progress never leaves the
/// Mac inside a team record; chats share as stripped transcripts; tasks follow
/// their Notebook's team; a read-only team refuses writes; and removing a team
/// takes only the team's copies with it.
@Suite("Teams store")
struct TeamsStoreTests {

    private static func makeTeam(
        _ store: KnowledgeStore,
        id: String = "team-1",
        name: String = "Nexus",
        role: TeamRole = .owner,
        permission: TeamPermission = .readWrite
    ) throws -> TeamRecord {
        let now = Date()
        let team = TeamRecord(
            id: id,
            name: name,
            role: role,
            permission: permission,
            zoneScope: role == .owner ? .privateScope : .shared,
            zoneName: TeamRecord.zoneName(forTeamID: id),
            zoneOwnerRecordName: role == .owner ? nil : "_owner-record",
            shareRecordName: nil,
            shareURL: nil,
            createdAt: now,
            joinedAt: now,
            updatedAt: now
        )
        try store.saveTeam(team)
        return team
    }

    /// docs/teams-design.md, decision 18 (product owner, 2026-09-19: team artifacts
    /// "should STILL be shown under my personal library"): My Library lists
    /// its own records and the teams', a copy of an own record counted once.
    @Test("My Library lists team records beside its own, and a team's copy of an own record only once")
    func myLibraryListsTeamRecordsOnce() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        let now = Date()
        // Own Doc, and its copy in the team.
        try store.saveArtifactRecord(ArtifactRecord(
            id: "doc-own", title: "Own Doc", homeNotebookID: nil, linkedNotebookIDs: [],
            isDraft: false, teamID: nil, createdAt: now, updatedAt: now
        ))
        let copyID = try store.copyArtifactRowIntoTeam(artifactID: "doc-own", teamID: team.id, linkedTeamNotebookIDs: [], fileCopy: { $0 }).id
        // A teammate's Doc, only in the team.
        try store.saveArtifactRecord(ArtifactRecord(
            id: "doc-team", title: "Team Doc", homeNotebookID: nil, linkedNotebookIDs: [],
            isDraft: false, teamID: team.id, createdAt: now, updatedAt: now
        ))
        // Own linked site, and a team row at the same address (its shared copy).
        try store.saveArtifactRecord(ArtifactRecord(
            id: "site-own", title: "Atlas", homeNotebookID: nil, linkedNotebookIDs: [],
            isDraft: false, linkedURL: "https://atlas.learner-1234.chatgpt.site/", teamID: nil, createdAt: now, updatedAt: now
        ))
        try store.saveArtifactRecord(ArtifactRecord(
            id: "site-team-row", title: "Atlas", homeNotebookID: nil, linkedNotebookIDs: [],
            isDraft: false, linkedURL: "https://atlas.learner-1234.chatgpt.site/", teamID: team.id, createdAt: now, updatedAt: now
        ))
        // A site linked straight into the team, no own entry.
        try store.saveArtifactRecord(ArtifactRecord(
            id: "site-team-only", title: "Team Site", homeNotebookID: nil, linkedNotebookIDs: [],
            isDraft: false, linkedURL: "https://team-site.learner-1234.chatgpt.site/", teamID: team.id, createdAt: now, updatedAt: now
        ))

        let listed = Set(try store.loadMyLibraryArtifacts().map(\.id))
        #expect(listed == ["doc-own", "doc-team", "site-own", "site-team-only"])
        #expect(!listed.contains(copyID), "the team's copy of an own Doc is the Doc, seen once")
        #expect(!listed.contains("site-team-row"), "a team row at an own page's address is that page")
    }

    @Test("The Artifacts home's team filter knows which team each My Library artifact is in")
    func myLibraryArtifactTeams() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        let now = Date()
        // Own Doc shared with the team, and own Doc no team has.
        try store.saveArtifactRecord(ArtifactRecord(
            id: "doc-shared", title: "Shared Doc", homeNotebookID: nil, linkedNotebookIDs: [],
            isDraft: false, teamID: nil, createdAt: now, updatedAt: now
        ))
        _ = try store.copyArtifactRowIntoTeam(artifactID: "doc-shared", teamID: team.id, linkedTeamNotebookIDs: [], fileCopy: { $0 })
        try store.saveArtifactRecord(ArtifactRecord(
            id: "doc-private", title: "Private Doc", homeNotebookID: nil, linkedNotebookIDs: [],
            isDraft: false, teamID: nil, createdAt: now, updatedAt: now
        ))
        // A teammate's Doc, and an own linked site with a team row at its
        // address, written without the trailing slash. The address is compared
        // through `URLNormalizer`, which drops a path's trailing slash but keeps
        // a bare host's ("example.com/" is not "example.com", pinned in
        // schema/vectors/url-normalize.json), so the page here has a path.
        try store.saveArtifactRecord(ArtifactRecord(
            id: "doc-team", title: "Team Doc", homeNotebookID: nil, linkedNotebookIDs: [],
            isDraft: false, teamID: team.id, createdAt: now, updatedAt: now
        ))
        try store.saveArtifactRecord(ArtifactRecord(
            id: "site-own", title: "Atlas", homeNotebookID: nil, linkedNotebookIDs: [],
            isDraft: false, linkedURL: "https://learner-1234.chatgpt.site/atlas/", teamID: nil, createdAt: now, updatedAt: now
        ))
        try store.saveArtifactRecord(ArtifactRecord(
            id: "site-team-row", title: "Atlas", homeNotebookID: nil, linkedNotebookIDs: [],
            isDraft: false, linkedURL: "https://learner-1234.chatgpt.site/atlas", teamID: team.id, createdAt: now, updatedAt: now
        ))

        let teams = try store.teamIDsByMyLibraryArtifact()
        #expect(teams["doc-shared"] == [team.id])
        #expect(teams["doc-private"] == nil)
        #expect(teams["doc-team"] == [team.id])
        #expect(teams["site-own"] == [team.id], "a team row at an own page's address is that page's copy")
    }

    private static func readySource(id: String, url: String, title: String, content: String) -> StudioArticle {
        var article = StudioArticle(url: url, title: title, sourceType: .article, discoveryOrigin: .manual, id: id)
        article.domain = URL(string: url)?.host ?? ""
        article.content = content
        article.wordCount = content.split(separator: " ").count
        article.state = .ready
        article.readAt = Date(timeIntervalSinceReferenceDate: 1_000)
        article.readingPositionPage = 7
        return article
    }

    @Test("Team-scoped identities are deterministic and distinct from My Library's")
    func identities() {
        let url = "https://www.nature.com/articles/s41593-026-02421-x?utm_source=x"
        let own = SourceIdentity.stableID(for: url)
        let team = TeamContentIdentity.sourceID(teamID: "team-1", url: url)
        #expect(team.hasPrefix("src_"))
        #expect(team != own)
        #expect(team == TeamContentIdentity.sourceID(teamID: "team-1", url: "https://www.nature.com/articles/s41593-026-02421-x"))
        #expect(team != TeamContentIdentity.sourceID(teamID: "team-2", url: url))
        #expect(TeamContentIdentity.notebookID(teamID: "t", originalNotebookID: "p").hasPrefix("proj_"))
        #expect(TeamContentIdentity.chatSnapshotID(teamID: "t", originalSessionID: "s").hasPrefix("teamchat-"))
        #expect(ReviewSessionOrigin.infer(from: TeamContentIdentity.chatSnapshotID(teamID: "t", originalSessionID: "s")) == .other)
        #expect(TeamRecord.teamID(fromZoneName: "Team-abc") == "abc")
        #expect(TeamRecord.teamID(fromZoneName: "Knowledge") == nil)
    }

    @Test("A zone home turns a record name into the right CloudKit address")
    func zoneHomes() {
        #expect(CloudKitZoneHome.knowledge.zoneID == CKRecordZone.ID(zoneName: "Knowledge", ownerName: CKCurrentUserDefaultName))
        let ownerTeam = CloudKitZoneHome(scope: .privateScope, zoneName: "Team-1", ownerRecordName: "ignored")
        #expect(ownerTeam.ownerRecordName == nil)
        #expect(ownerTeam.isTeamZone)
        #expect(ownerTeam.teamID == "1")
        let memberTeam = CloudKitZoneHome(zoneID: CKRecordZone.ID(zoneName: "Team-1", ownerName: "_abc"), scope: .shared)
        #expect(memberTeam.ownerRecordName == "_abc")
        #expect(memberTeam.zoneID.ownerName == "_abc")
        let name = CloudKitRecordMapper.recordName(for: .source, logicalKey: "src_x")
        #expect(CloudKitRecordMapper.recordID(for: .source, logicalKey: "src_x").zoneID == CloudKitZoneHome.knowledge.zoneID)
        #expect(CloudKitRecordMapper.recordID(for: .source, logicalKey: "src_x", in: memberTeam).recordName == name)
        #expect(CloudKitRecordMapper.recordID(for: .source, logicalKey: "src_x", in: memberTeam).zoneID == memberTeam.zoneID)
    }

    @Test("Sharing a source copies it into the team and leaves My Library alone")
    func copySourceIntoTeam() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        let original = Self.readySource(
            id: "src-own",
            url: "https://example.com/paper",
            title: "The paper",
            content: "Enough text to count as a readable source for the copy."
        )
        try store.saveSource(original)
        try store.clearAllPendingSyncChanges()

        let copyID = try store.copySourceIntoTeam(sourceID: "src-own", teamID: team.id) { path in "Teams/team-1/\(path)" }
        #expect(copyID == TeamContentIdentity.sourceID(teamID: team.id, url: original.url))

        let own = try store.loadActiveSources()
        #expect(own.map(\.id) == ["src-own"])
        #expect(own[0].teamID == nil)
        #expect(own[0].readAt == original.readAt)

        let teamSources = try store.loadActiveSources(teamID: team.id)
        #expect(teamSources.map(\.id) == [copyID])
        let copy = teamSources[0]
        #expect(copy.teamID == team.id)
        #expect(copy.title == "The paper")
        #expect(copy.state == .ready)
        #expect(try store.loadSourceContent(copyID) == original.content)
        #expect(try store.teamIDsHoldingSource(url: original.url) == [team.id])

        // The copy is queued for the team's zone; the original is not queued at all.
        let pending = try store.pendingSyncChanges()
        let copyChange = try #require(pending.first { $0.logicalKey == copyID })
        #expect(copyChange.home == team.home)
        #expect(copyChange.home.zoneName == "Team-team-1")
        #expect(copyChange.home.scope == .privateScope)
        #expect(!pending.contains { $0.logicalKey == "src-own" })
        #expect(try store.resolveRecordHome(entity: .source, logicalKey: copyID) == team.home)
        #expect(try store.resolveRecordHome(entity: .source, logicalKey: "src-own") == .knowledge)

        // Sharing again is an update, not a second copy.
        let again = try store.copySourceIntoTeam(sourceID: "src-own", teamID: team.id) { path in path }
        #expect(again == copyID)
        #expect(try store.loadActiveSources(teamID: team.id).count == 1)
    }

    /// docs/teams-design.md, decision 19 (product owner, 2026-09-22: in a team "I
    /// just want to still show all my personal sources there"): a team
    /// library lists the learner's own sources, the team's copy of one folded
    /// into it, and the team's rows the learner lacks.
    @Test("A team library lists own sources, a team copy once, and the team's other rows")
    func teamLibraryListsOwnSources() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        try store.saveSource(Self.readySource(id: "src-own", url: "https://example.com/paper", title: "Own paper", content: "Text of the paper."))
        try store.saveSource(Self.readySource(id: "src-private", url: "https://example.com/private", title: "Kept private", content: "Text."))
        let copyID = try store.copySourceIntoTeam(sourceID: "src-own", teamID: team.id) { $0 }
        var teammates = Self.readySource(id: "src-teammate", url: "https://example.com/teammate", title: "Teammate's", content: "Text.")
        teammates.teamID = team.id
        try store.saveSource(teammates)

        let library = try store.loadLibrarySources(teamID: team.id)
        #expect(Set(library.sources.map(\.id)) == ["src-own", "src-private", "src-teammate"])
        #expect(library.teamCopyAliases == [copyID: "src-own"])

        // My Library is unchanged, and the team's own rows are still the team's.
        let mine = try store.loadLibrarySources(teamID: nil)
        #expect(Set(mine.sources.map(\.id)) == ["src-own", "src-private"])
        #expect(mine.teamCopyAliases.isEmpty)
        #expect(Set(try store.loadActiveSources(teamID: team.id).map(\.id)) == [copyID, "src-teammate"])
    }

    /// A copy's id is keyed by the address it was made at, and a later rename
    /// of that address (the 2026-09-17 chapter-folder rename rewrote team rows
    /// in place) leaves the id behind. The copy at the address is still the
    /// team's copy: sharing again updates it, the menu ticks the team, and the
    /// team library folds it into the own row.
    @Test("A team copy whose address was rewritten in place is still the team's copy")
    func renamedTeamCopyIsStillTheCopy() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        let oldURL = "https://example.com/old-folder/chapter"
        let newURL = "https://example.com/new-folder/chapter"
        try store.saveSource(Self.readySource(id: "src-own", url: oldURL, title: "Chapter", content: "Text of the chapter."))
        let copyID = try store.copySourceIntoTeam(sourceID: "src-own", teamID: team.id) { $0 }
        #expect(copyID == TeamContentIdentity.sourceID(teamID: team.id, url: oldURL))
        for id in ["src-own", copyID] {
            try store.execForTesting("UPDATE articles SET url = '\(newURL)', normalized_url = '\(URLNormalizer.normalize(newURL))' WHERE source_id = '\(id)'")
        }
        #expect(copyID != TeamContentIdentity.sourceID(teamID: team.id, url: newURL))

        #expect(try store.teamSourceCopyID(teamID: team.id, url: newURL) == copyID)
        #expect(try store.teamIDsHoldingSource(url: newURL) == [team.id])
        #expect(try store.copySourceIntoTeam(sourceID: "src-own", teamID: team.id) { $0 } == copyID)
        #expect(try store.loadActiveSources(teamID: team.id).map(\.id) == [copyID])
        let library = try store.loadLibrarySources(teamID: team.id)
        #expect(library.sources.map(\.id) == ["src-own"])
        #expect(library.teamCopyAliases == [copyID: "src-own"])
    }

    @Test("A team record carries none of the member's reading progress")
    func outboundTeamRecordStripsProgress() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        let original = Self.readySource(
            id: "src-own",
            url: "https://example.com/progress",
            title: "Progress",
            content: "Readable text for the progress test source."
        )
        try store.saveSource(original)
        let copyID = try store.copySourceIntoTeam(sourceID: "src-own", teamID: team.id) { $0 }
        // Give the copy local progress, the way reading it would.
        try store.execForTesting("UPDATE sources SET read_at = 1000, reading_position_page = 3 WHERE id = '\(copyID)'")

        let changes = try store.pendingSyncChanges()
        let teamChange = try #require(changes.first { $0.logicalKey == copyID })
        let ownChange = try #require(changes.first { $0.logicalKey == "src-own" })

        let teamRecord = try #require(try CloudKitRecordMapper.makeRecord(for: teamChange, store: store))
        #expect(teamRecord.recordID.zoneID == team.home.zoneID)
        let teamPayload = try JSONDecoder().decode(
            CloudKitSourcePayload.self,
            from: try #require(teamRecord.encryptedValues[.payload] as? Data)
        )
        #expect(teamPayload.article.readAt == nil)
        #expect(teamPayload.article.readingPositionPage == nil)
        #expect(teamPayload.article.teamID == team.id)

        let ownRecord = try #require(try CloudKitRecordMapper.makeRecord(for: ownChange, store: store))
        #expect(ownRecord.recordID.zoneID == CloudKitZoneHome.knowledge.zoneID)
        let ownPayload = try JSONDecoder().decode(
            CloudKitSourcePayload.self,
            from: try #require(ownRecord.encryptedValues[.payload] as? Data)
        )
        #expect(ownPayload.article.readAt == original.readAt)
        #expect(ownPayload.article.readingPositionPage == 7)

        // Inbound: what this member did with the copy survives an apply.
        let snapshot = try #require(try store.captureMemberState(entity: .source, logicalKey: copyID))
        try store.execForTesting("UPDATE sources SET read_at = NULL, reading_position_page = NULL WHERE id = '\(copyID)'")
        try store.restoreMemberState(snapshot)
        var restoredPage = -1
        try store.query("SELECT reading_position_page FROM sources WHERE id = '\(copyID)'") { stmt in
            restoredPage = Int(sqlite3_column_int(stmt, 0))
        }
        #expect(restoredPage == 3)
    }

    @Test("Sharing a Notebook copies its sources, remapped to the team's copies, and leaves its suggestions and removals behind")
    func copyNotebookIntoTeam() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        try store.saveSource(Self.readySource(id: "src-1", url: "https://example.com/1", title: "One", content: "Text one for the notebook copy."))
        try store.saveSource(Self.readySource(id: "src-2", url: "https://example.com/2", title: "Two", content: "Text two for the notebook copy."))
        try store.saveSource(Self.readySource(id: "src-3", url: "https://example.com/3", title: "Three", content: "Text three, still a suggestion."))
        try store.saveSource(Self.readySource(id: "src-4", url: "https://example.com/4", title: "Four", content: "Text four, removed by the learner."))
        let notebook = LearningGoalRecord(
            id: "proj-own",
            title: "Mitochondria",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: Date(),
            updatedAt: Date(),
            status: "active",
            items: [
                LearningGoalItem(id: "item-1", goalID: "proj-own", sourceID: "src-1", addedAt: Date(), completedAt: Date(), sequence: 1),
                LearningGoalItem(id: "item-2", goalID: "proj-own", sourceID: "src-2", addedAt: Date(), reviewState: LearningGoalItemReviewState.approved.rawValue, sequence: 2),
                LearningGoalItem(id: "item-3", goalID: "proj-own", sourceID: "src-3", addedAt: Date(), origin: LearningGoalItemOrigin.discovered.rawValue, reviewState: LearningGoalItemReviewState.pending.rawValue),
                LearningGoalItem(id: "item-4", goalID: "proj-own", sourceID: "src-4", addedAt: Date(), origin: LearningGoalItemOrigin.discovered.rawValue, reviewState: LearningGoalItemReviewState.rejected.rawValue),
            ],
            kind: LearningGoalRecord.companionKind,
            description: "Standing instructions",
            notes: "Synthesis so far",
            researchQuestions: ["Why calcium?"]
        )
        try store.saveLearningGoalRecord(notebook)

        let copyID = try store.copyNotebookIntoTeam(
            notebookID: "proj-own",
            teamID: team.id,
            includeSources: true,
            includeDocs: false,
            fileCopy: { $0 },
            artifactCopy: { _, _ in nil }
        )
        #expect(copyID == TeamContentIdentity.notebookID(teamID: team.id, originalNotebookID: "proj-own"))

        let copy = try #require(try store.loadLearningGoal(copyID))
        #expect(copy.teamID == team.id)
        #expect(copy.title == "Mitochondria")
        #expect(copy.description == "Standing instructions")
        #expect(copy.researchQuestions == ["Why calcium?"])
        #expect(copy.isNotebook)
        let expectedSources = Set([
            TeamContentIdentity.sourceID(teamID: team.id, url: "https://example.com/1"),
            TeamContentIdentity.sourceID(teamID: team.id, url: "https://example.com/2"),
        ])
        // Only the notebook's sources travel: the suggestion still awaiting a
        // verdict and the source the learner removed stay behind, and neither
        // is copied into the team's library.
        #expect(Set(copy.items.map(\.sourceID)) == expectedSources)
        #expect(copy.items.allSatisfy { $0.isApproved })
        // The member's completion did not travel into the team's Notebook.
        #expect(copy.items.allSatisfy { $0.completedAt == nil })
        #expect(Set(copy.items.compactMap(\.sequence)) == [1, 2])

        // The original is untouched and still in My Library only.
        let original = try #require(try store.loadLearningGoal("proj-own"))
        #expect(original.teamID == nil)
        #expect(original.items.count == 4)
        #expect(original.items.contains { $0.completedAt != nil })
        #expect(original.items.first { $0.sourceID == "src-3" }?.isPendingApproval == true)
        #expect(original.items.first { $0.sourceID == "src-4" }?.reviewState == LearningGoalItemReviewState.rejected.rawValue)
        #expect(try store.loadActiveSources().map(\.id).sorted() == ["src-1", "src-2", "src-3", "src-4"])
        #expect(try store.loadActiveSources(teamID: team.id).count == 2)

        let pending = try store.pendingSyncChanges()
        let notebookChange = try #require(pending.first { $0.entity == .learningGoal && $0.logicalKey == copyID })
        #expect(notebookChange.home == team.home)

        // The outbound team Notebook carries membership but no member progress.
        let record = try #require(try CloudKitRecordMapper.makeRecord(for: notebookChange, store: store))
        let payload = try JSONDecoder().decode(
            CloudKitLearningGoalPayload.self,
            from: try #require(record.encryptedValues[.payload] as? Data)
        )
        #expect(payload.goal.items.count == 2)
        #expect(payload.goal.items.allSatisfy { $0.completedAt == nil && $0.lastScore == nil })
        #expect(payload.goal.teamID == team.id)
    }

    /// A team Notebook as one member's Mac holds it: an approved item this
    /// member has read and been quizzed on, a legacy item (nil approval), a
    /// pending suggestion and a rejected removal.
    private static func teamNotebook(teamID: String, lastQuizDate: String? = nil) -> LearningGoalRecord {
        let addedAt = Date(timeIntervalSinceReferenceDate: 500)
        return LearningGoalRecord(
            id: "team-proj",
            title: "Mitochondria",
            startAt: addedAt,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: addedAt,
            updatedAt: addedAt,
            status: "active",
            items: [
                LearningGoalItem(
                    id: "item-approved", goalID: "team-proj", sourceID: "src-approved", addedAt: addedAt,
                    completedAt: Date(timeIntervalSinceReferenceDate: 1_000),
                    origin: LearningGoalItemOrigin.seed.rawValue,
                    reviewState: LearningGoalItemReviewState.approved.rawValue,
                    lastQuizzedAt: Date(timeIntervalSinceReferenceDate: 2_000), quizCount: 3, lastScore: 0.9, sequence: 1
                ),
                LearningGoalItem(id: "item-legacy", goalID: "team-proj", sourceID: "src-legacy", addedAt: addedAt, sequence: 2),
                LearningGoalItem(
                    id: "item-pending", goalID: "team-proj", sourceID: "src-pending", addedAt: addedAt,
                    origin: LearningGoalItemOrigin.discovered.rawValue,
                    reviewState: LearningGoalItemReviewState.pending.rawValue, relevance: 0.8
                ),
                LearningGoalItem(
                    id: "item-rejected", goalID: "team-proj", sourceID: "src-rejected", addedAt: addedAt,
                    origin: LearningGoalItemOrigin.discovered.rawValue,
                    reviewState: LearningGoalItemReviewState.rejected.rawValue, relevance: 0.4
                ),
            ],
            kind: LearningGoalRecord.companionKind,
            lastQuizDate: lastQuizDate,
            teamID: teamID
        )
    }

    /// The team Notebook's outbound record, as the sync engine would send it.
    private static func outboundTeamNotebook(_ store: KnowledgeStore, team: TeamRecord) throws -> (CKRecord, CloudKitLearningGoalPayload) {
        let change = try #require(try store.pendingSyncChanges().first { $0.entity == .learningGoal && $0.logicalKey == "team-proj" })
        #expect(change.home == team.home)
        let record = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: store))
        #expect(record.recordID.zoneID == team.home.zoneID)
        let payload = try JSONDecoder().decode(
            CloudKitLearningGoalPayload.self,
            from: try #require(record.encryptedValues[.payload] as? Data)
        )
        return (record, payload)
    }

    /// Apply a fetched team record the way the shared database's engine does.
    @discardableResult
    private static func applyAsTeammate(_ record: CKRecord, to store: KnowledgeStore) throws -> CloudKitAppliedRecord {
        try CloudKitRecordMapper.applyFetched(
            record: record,
            descriptor: try CloudKitRecordMapper.descriptor(for: record),
            home: CloudKitZoneHome(zoneID: record.recordID.zoneID, scope: .shared),
            to: store
        )
    }

    private static func reviewStates(_ goal: LearningGoalRecord) -> [String: String] {
        Dictionary(uniqueKeysWithValues: goal.items.map { ($0.sourceID, $0.reviewState ?? "nil") })
    }

    /// Bug report 2026-10-02: a team notebook's approval state is shared
    /// notebook state, not progress. Builds before schema 152 blanked it with
    /// the progress, and nil reads as approved, so every teammate received a
    /// pending suggestion and a rejected tombstone as an approved source.
    @Test("A team Notebook's record carries each item's approval and none of the member's progress, and a teammate reads it as sent")
    func teamNotebookRoundTripKeepsApproval() throws {
        let sharer = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(sharer)
        try sharer.saveLearningGoalRecord(Self.teamNotebook(teamID: team.id, lastQuizDate: "2026-10-01"))

        let (record, payload) = try Self.outboundTeamNotebook(sharer, team: team)
        #expect(Self.reviewStates(payload.goal) == [
            "src-approved": "approved",
            "src-legacy": "nil",
            "src-pending": "pending",
            "src-rejected": "rejected",
        ])
        // Membership, order and discovery evidence are the team's too.
        #expect(payload.goal.items.first { $0.sourceID == "src-pending" }?.origin == LearningGoalItemOrigin.discovered.rawValue)
        #expect(payload.goal.items.first { $0.sourceID == "src-pending" }?.relevance == 0.8)
        #expect(payload.goal.items.first { $0.sourceID == "src-approved" }?.sequence == 1)
        // What this member did with the notebook is not.
        #expect(payload.goal.items.allSatisfy {
            $0.completedAt == nil && $0.lastQuizzedAt == nil && $0.quizCount == nil && $0.lastScore == nil
        })
        #expect(payload.goal.lastQuizDate == nil)

        // The sharer's own row keeps its progress.
        let held = try #require(try sharer.loadLearningGoal("team-proj"))
        #expect(held.items.first { $0.sourceID == "src-approved" }?.completedAt != nil)

        // A teammate's Mac reads the notebook as the sharer has it.
        let teammate = try KnowledgeStore(inMemory: true)
        _ = try Self.makeTeam(teammate, role: .member)
        try teammate.clearAllPendingSyncChanges()
        try Self.applyAsTeammate(record, to: teammate)
        let received = try #require(try teammate.loadLearningGoal("team-proj"))
        #expect(received.teamID == team.id)
        #expect(Self.reviewStates(received) == Self.reviewStates(payload.goal))
        #expect(Set(received.items.filter(\.isApproved).map(\.sourceID)) == ["src-approved", "src-legacy"])
        #expect(received.items.filter(\.isPendingApproval).map(\.sourceID) == ["src-pending"])
        #expect(received.items.allSatisfy { $0.completedAt == nil && $0.quizCount == nil })
        #expect(try teammate.pendingSyncChanges().isEmpty, "an inbound apply queues nothing")
    }

    @Test("An inbound team Notebook sets each item's approval from the record and puts back this member's progress")
    func inboundTeamNotebookFollowsApprovalKeepsProgress() throws {
        let sharer = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(sharer)
        try sharer.saveLearningGoalRecord(Self.teamNotebook(teamID: team.id))
        let (firstRecord, _) = try Self.outboundTeamNotebook(sharer, team: team)

        let teammate = try KnowledgeStore(inMemory: true)
        _ = try Self.makeTeam(teammate, role: .member)
        try Self.applyAsTeammate(firstRecord, to: teammate)
        // The teammate reads and is quizzed on two sources, and holds a stale
        // view of two verdicts (what builds before 152 left behind: their own
        // value restored over every inbound record).
        try teammate.execForTesting("""
            UPDATE learning_goal_items
            SET completed_at = 3000, last_quizzed_at = 4000, quiz_count = 5, last_score = 0.6
            WHERE goal_id = 'team-proj' AND source_id IN ('src-approved', 'src-pending')
        """)
        try teammate.execForTesting("UPDATE learning_goal_items SET review_state = 'approved' WHERE goal_id = 'team-proj' AND source_id = 'src-pending'")
        try teammate.execForTesting("UPDATE learning_goal_items SET review_state = NULL WHERE goal_id = 'team-proj' AND source_id = 'src-rejected'")
        try teammate.clearAllPendingSyncChanges()

        // On the sharer's Mac a source is removed from the notebook and the
        // suggestion stays a suggestion.
        try sharer.clearAllPendingSyncChanges()
        try sharer.setCompanionItemReviewState(goalID: "team-proj", sourceIDs: ["src-approved"], state: .rejected)
        let (record, payload) = try Self.outboundTeamNotebook(sharer, team: team)
        #expect(payload.goal.items.first { $0.sourceID == "src-approved" }?.reviewState == LearningGoalItemReviewState.rejected.rawValue)

        try Self.applyAsTeammate(record, to: teammate)
        let received = try #require(try teammate.loadLearningGoal("team-proj"))
        // Approval follows the record.
        #expect(Self.reviewStates(received) == [
            "src-approved": "rejected",
            "src-legacy": "nil",
            "src-pending": "pending",
            "src-rejected": "rejected",
        ])
        #expect(received.items.filter(\.isApproved).map(\.sourceID) == ["src-legacy"])
        // Progress is the member's own and survives the apply.
        for sourceID in ["src-approved", "src-pending"] {
            let item = try #require(received.items.first { $0.sourceID == sourceID })
            #expect(item.completedAt == Date(timeIntervalSinceReferenceDate: 3_000), Comment(rawValue: sourceID))
            #expect(item.lastQuizzedAt == Date(timeIntervalSinceReferenceDate: 4_000), Comment(rawValue: sourceID))
            #expect(item.quizCount == 5, Comment(rawValue: sourceID))
            #expect(item.lastScore == 0.6, Comment(rawValue: sourceID))
        }
        #expect(received.items.first { $0.sourceID == "src-legacy" }?.completedAt == nil)
        #expect(received.teamID == team.id)
        #expect(try teammate.pendingSyncChanges().isEmpty, "an inbound apply queues nothing")
    }

    @Test("A chat shared with a team is a transcript with the learner's grading stripped")
    func chatSnapshot() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        try store.saveSource(Self.readySource(id: "src-1", url: "https://example.com/1", title: "One", content: "Text one for the chat snapshot."))
        _ = try store.copySourceIntoTeam(sourceID: "src-1", teamID: team.id) { $0 }
        let session = CloudKitReviewSessionPayload(
            id: "chat-own",
            topic: "Calcium influx",
            startedAt: Date(timeIntervalSinceReferenceDate: 100),
            endedAt: Date(timeIntervalSinceReferenceDate: 200),
            status: "completed",
            overallScore: 0.8,
            summary: "We covered the influx model.",
            sourceIDs: ["src-1"],
            cardIDs: [],
            exchangeCount: 1,
            goalID: nil,
            exchanges: [
                CloudKitReviewExchangePayload(
                    id: "ex-1",
                    sessionID: "chat-own",
                    sequenceNumber: 1,
                    question: "What drives the influx?",
                    userAnswer: "The uniporter.",
                    evaluation: "Right, with the gradient as the driver.",
                    score: 0.9,
                    sourceRefs: ["src-1"],
                    knowledgeNote: "MCU",
                    answeredAt: Date(timeIntervalSinceReferenceDate: 150),
                    contextContent: "the passage they were reading",
                    ideaCoverage: "[]",
                    rating: "liked",
                    ratingReason: "clear",
                    ratingField: "evaluation",
                    ratedAt: Date(timeIntervalSinceReferenceDate: 160)
                ),
            ],
            kind: ReviewSessionKind.chat.rawValue
        )
        try store.saveReviewSessionRecord(session)

        let copyID = try store.snapshotChatIntoTeam(sessionID: "chat-own", teamID: team.id, notebookID: nil)
        #expect(copyID == TeamContentIdentity.chatSnapshotID(teamID: team.id, originalSessionID: "chat-own"))

        let snapshot = try #require(try store.loadReviewSessionForSync(copyID))
        #expect(snapshot.teamID == team.id)
        #expect(snapshot.status == "completed")
        #expect(snapshot.overallScore == nil)
        #expect(snapshot.topic == "Calcium influx")
        #expect(snapshot.sourceIDs == [TeamContentIdentity.sourceID(teamID: team.id, url: "https://example.com/1")])
        #expect(snapshot.exchanges.count == 1)
        let exchange = try #require(snapshot.exchanges.first)
        #expect(exchange.question == "What drives the influx?")
        #expect(exchange.userAnswer == "The uniporter.")
        #expect(exchange.evaluation == "Right, with the gradient as the driver.")
        #expect(exchange.score == nil)
        #expect(exchange.contextContent == nil)
        #expect(exchange.rating == nil)
        #expect(exchange.ratingReason == nil)
        #expect(exchange.ideaCoverage == nil)

        // The original keeps everything.
        let original = try #require(try store.loadReviewSessionForSync("chat-own"))
        #expect(original.teamID == nil)
        #expect(original.overallScore == 0.8)
        #expect(original.exchanges.first?.score == 0.9)
        #expect(original.exchanges.first?.rating == "liked")

        let links = try store.loadReviewSessionLinks()
        #expect(links.first { $0.id == copyID }?.teamID == team.id)
        #expect(links.first { $0.id == copyID }?.isTeamSnapshot == true)
        #expect(links.first { $0.id == "chat-own" }?.teamID == nil)

        let change = try #require(try store.pendingSyncChanges().first { $0.logicalKey == copyID })
        #expect(change.home == team.home)
    }

    /// A chat the learner wrote in, filed under a Notebook, the way the app records one.
    private static func saveChat(
        _ store: KnowledgeStore,
        id: String,
        notebookID: String?,
        sourceIDs: [String] = [],
        kind: ReviewSessionKind? = nil,
        overallScore: Double? = nil,
        exchanges: Int = 1
    ) throws {
        let turns = (0..<exchanges).map { index in
            CloudKitReviewExchangePayload(
                id: "\(id)-ex-\(index + 1)",
                sessionID: id,
                sequenceNumber: index + 1,
                question: "Question \(index + 1)",
                userAnswer: "Answer \(index + 1)",
                evaluation: "Reply \(index + 1)",
                score: nil,
                sourceRefs: sourceIDs,
                knowledgeNote: nil,
                answeredAt: Date(timeIntervalSinceReferenceDate: 100 + Double(index)),
                contextContent: nil
            )
        }
        try store.saveReviewSessionRecord(CloudKitReviewSessionPayload(
            id: id,
            topic: "Chat \(id)",
            startedAt: Date(timeIntervalSinceReferenceDate: 50),
            endedAt: nil,
            status: "active",
            overallScore: overallScore,
            summary: nil,
            sourceIDs: sourceIDs,
            cardIDs: [],
            exchangeCount: turns.count,
            goalID: notebookID,
            exchanges: turns,
            kind: kind?.rawValue
        ))
    }

    private static func saveNotebook(_ store: KnowledgeStore, id: String, sourceIDs: [String], parentNotebookID: String? = nil) throws {
        try store.saveLearningGoalRecord(LearningGoalRecord(
            id: id,
            title: "Notebook \(id)",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: Date(),
            updatedAt: Date(),
            status: "active",
            items: sourceIDs.enumerated().map { index, sourceID in
                LearningGoalItem(id: "\(id)-item-\(index + 1)", goalID: id, sourceID: sourceID, addedAt: Date(), sequence: Double(index + 1))
            },
            kind: LearningGoalRecord.companionKind,
            parentNotebookID: parentNotebookID
        ))
    }

    @Test("Sharing a Notebook carries its chats as transcripts under the team copy, and leaves reviews behind")
    func copyNotebookIntoTeamCarriesChats() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        try store.saveSource(Self.readySource(id: "src-1", url: "https://example.com/1", title: "One", content: "Text one for the chats that travel."))
        try Self.saveNotebook(store, id: "proj-own", sourceIDs: ["src-1"])
        try Self.saveChat(store, id: "chat-a", notebookID: "proj-own", sourceIDs: ["src-1"])
        try Self.saveChat(store, id: "chat-graded", notebookID: "proj-own", overallScore: 0.7)
        try Self.saveChat(store, id: "chat-review", notebookID: "proj-own", kind: .review)
        try Self.saveChat(store, id: "chat-empty", notebookID: "proj-own", exchanges: 0)
        try Self.saveChat(store, id: MemoryReviewSession.sessionID(for: Date()), notebookID: "proj-own", kind: .memory)
        try Self.saveChat(store, id: "chat-loose", notebookID: nil)
        #expect(try store.teamShareableChatIDs(notebookID: "proj-own") == ["chat-a"])

        let copyID = try store.copyNotebookIntoTeam(
            notebookID: "proj-own", teamID: team.id, includeSources: true, includeDocs: false,
            fileCopy: { $0 }, artifactCopy: { _, _ in nil }
        )
        let snapshotID = TeamContentIdentity.chatSnapshotID(teamID: team.id, originalSessionID: "chat-a")
        let snapshot = try #require(try store.loadReviewSessionForSync(snapshotID))
        #expect(snapshot.teamID == team.id)
        #expect(snapshot.goalID == copyID)
        #expect(snapshot.exchanges.count == 1)
        #expect(snapshot.sourceIDs == [TeamContentIdentity.sourceID(teamID: team.id, url: "https://example.com/1")])
        // Dated by its last turn, not by when the copy was made.
        #expect(snapshot.endedAt == Date(timeIntervalSinceReferenceDate: 100))
        let teamChats = try store.loadReviewSessionLinks().filter { $0.teamID == team.id }
        #expect(teamChats.map(\.id) == [snapshotID])
        #expect(try store.pendingSyncChanges().first { $0.logicalKey == snapshotID }?.home == team.home)

        // The learner can leave the chats out.
        let quiet = try Self.makeTeam(store, id: "team-quiet", name: "Quiet")
        _ = try store.copyNotebookIntoTeam(
            notebookID: "proj-own", teamID: quiet.id, includeSources: true, includeDocs: false, includeChats: false,
            fileCopy: { $0 }, artifactCopy: { _, _ in nil }
        )
        #expect(try store.loadReviewSessionLinks().filter { $0.teamID == quiet.id }.isEmpty)
    }

    @Test("Sources added to a shared Notebook follow it into the team, and only there")
    func sourcesFollowSharedNotebook() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        for index in 1...4 {
            try store.saveSource(Self.readySource(id: "src-\(index)", url: "https://example.com/\(index)", title: "\(index)", content: "Text \(index) for the follow-on."))
        }
        try Self.saveNotebook(store, id: "proj-own", sourceIDs: ["src-1"])
        try Self.saveNotebook(store, id: "proj-private", sourceIDs: ["src-1"])
        let copyID = try store.copyNotebookIntoTeam(
            notebookID: "proj-own", teamID: team.id, includeSources: true, includeDocs: false,
            fileCopy: { $0 }, artifactCopy: { _, _ in nil }
        )
        #expect(try store.teamsHoldingNotebook("proj-own").map(\.id) == [team.id])
        #expect(try store.teamsHoldingNotebook("proj-private").isEmpty)
        try store.clearAllPendingSyncChanges()

        // An approved addition travels; a suggestion still awaiting a verdict does not.
        _ = try store.addCompanionSeedSources(goalID: "proj-own", sourceIDs: ["src-2"])
        _ = try store.addDiscoveredCompanionSources(goalID: "proj-own", discovered: [(sourceID: "src-3", relevance: 0.9)])
        var copied: [String] = []
        let changed = try store.propagateNotebookSourcesToTeams(notebookID: "proj-own", sourceIDs: ["src-2", "src-3"]) { path, teamID in
            copied.append("\(teamID):\(path)")
            return path
        }
        #expect(changed == [team.id])
        let copy = try #require(try store.loadLearningGoal(copyID))
        #expect(Set(copy.items.map(\.sourceID)) == [
            TeamContentIdentity.sourceID(teamID: team.id, url: "https://example.com/1"),
            TeamContentIdentity.sourceID(teamID: team.id, url: "https://example.com/2"),
        ])
        #expect(try store.loadActiveSources(teamID: team.id).count == 2)
        #expect(try store.pendingSyncChanges().first { $0.logicalKey == copyID }?.home == team.home)
        // The original is exactly what the learner made it.
        #expect(try store.loadLearningGoal("proj-own")?.items.count == 3)

        // Adding to a Notebook no team holds does nothing; so does adding what the copy has.
        _ = try store.addCompanionSeedSources(goalID: "proj-private", sourceIDs: ["src-2"])
        #expect(try store.propagateNotebookSourcesToTeams(notebookID: "proj-private", sourceIDs: ["src-2"]) { path, _ in path }.isEmpty)
        #expect(try store.propagateNotebookSourcesToTeams(notebookID: "proj-own", sourceIDs: ["src-2"]) { path, _ in path }.isEmpty)
        #expect(try store.loadLearningGoal(copyID)?.items.count == 2)

        // A team that turned read-only takes nothing more.
        let readOnly = try Self.makeTeam(store, id: "team-ro", name: "Read-only", role: .member, permission: .readOnly)
        try store.withoutSyncTracking {
            try store.saveLearningGoalRecord(LearningGoalRecord(
                id: TeamContentIdentity.notebookID(teamID: readOnly.id, originalNotebookID: "proj-own"),
                title: "Theirs", startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
                createdAt: Date(), updatedAt: Date(), status: "active", items: [],
                kind: LearningGoalRecord.companionKind, teamID: readOnly.id
            ))
        }
        #expect(try store.teamsHoldingNotebook("proj-own").map(\.id) == [team.id])
        _ = try store.addCompanionSeedSources(goalID: "proj-own", sourceIDs: ["src-4"])
        #expect(try store.propagateNotebookSourcesToTeams(notebookID: "proj-own", sourceIDs: ["src-4"]) { path, _ in path } == [team.id])
        #expect(try store.loadActiveSources(teamID: readOnly.id).isEmpty)
    }

    @Test("A Goal nested under a shared Notebook follows it, and passes its sources up to the Notebook's copy")
    func nestedGoalFollowsSharedNotebook() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        try store.saveSource(Self.readySource(id: "src-1", url: "https://example.com/1", title: "One", content: "Text one for the nested goal."))
        try store.saveSource(Self.readySource(id: "src-2", url: "https://example.com/2", title: "Two", content: "Text two for the nested goal."))
        try Self.saveNotebook(store, id: "proj-own", sourceIDs: ["src-1"])
        let copyID = try store.copyNotebookIntoTeam(
            notebookID: "proj-own", teamID: team.id, includeSources: true, includeDocs: false,
            fileCopy: { $0 }, artifactCopy: { _, _ in nil }
        )

        try Self.saveNotebook(store, id: "goal-child", sourceIDs: ["src-2"], parentNotebookID: "proj-own")
        #expect(try store.propagateNestedGoalToTeams(goalID: "goal-child") { path, _ in path } == [team.id])
        let childCopy = try #require(try store.loadLearningGoal(TeamContentIdentity.notebookID(teamID: team.id, originalNotebookID: "goal-child")))
        #expect(childCopy.teamID == team.id)
        #expect(childCopy.parentNotebookID == copyID)
        #expect(childCopy.items.map(\.sourceID) == [TeamContentIdentity.sourceID(teamID: team.id, url: "https://example.com/2")])
        // Once there, it is not copied again.
        #expect(try store.propagateNestedGoalToTeams(goalID: "goal-child") { path, _ in path }.isEmpty)

        // Adding to the Goal reaches the Goal's copy and, through the parent link, the Notebook's.
        _ = try store.addCompanionSeedSources(goalID: "goal-child", sourceIDs: ["src-1"])
        #expect(try store.propagateNotebookSourcesToTeams(notebookID: "goal-child", sourceIDs: ["src-1"]) { path, _ in path } == [team.id])
        #expect(try store.loadLearningGoal(childCopy.id)?.items.count == 2)
        #expect(try store.loadLearningGoal(copyID)?.items.count == 1)
    }

    @Test("A Doc filed under a shared Notebook is owed to the team until its copy is filed there")
    func docFollowsSharedNotebook() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        try Self.saveNotebook(store, id: "proj-own", sourceIDs: [])
        try Self.saveNotebook(store, id: "proj-private", sourceIDs: [])
        let copyID = try store.copyNotebookIntoTeam(
            notebookID: "proj-own", teamID: team.id, includeSources: false, includeDocs: false,
            fileCopy: { $0 }, artifactCopy: { _, _ in nil }
        )
        let now = Date()
        try store.saveArtifactRecord(ArtifactRecord(
            id: "doc-1", title: "Synthesis", homeNotebookID: "proj-own", linkedNotebookIDs: ["proj-own", "proj-private"],
            isDraft: false, teamID: nil, createdAt: now, updatedAt: now
        ))
        try store.saveArtifactRecord(ArtifactRecord(
            id: "doc-loose", title: "Loose", homeNotebookID: nil, linkedNotebookIDs: ["proj-private"],
            isDraft: false, teamID: nil, createdAt: now, updatedAt: now
        ))

        let pending = try store.teamNotebooksAwaitingDoc(artifactID: "doc-1")
        #expect(pending.map(\.team.id) == [team.id])
        #expect(pending.first?.teamNotebookIDs == [copyID])
        #expect(try store.teamNotebooksAwaitingDoc(artifactID: "doc-loose").isEmpty)

        _ = try store.copyArtifactRowIntoTeam(artifactID: "doc-1", teamID: team.id, linkedTeamNotebookIDs: [copyID], fileCopy: { $0 })
        #expect(try store.teamNotebooksAwaitingDoc(artifactID: "doc-1").isEmpty)
        let docCopy = try #require(try store.loadArtifact(TeamContentIdentity.artifactID(teamID: team.id, originalArtifactID: "doc-1")))
        #expect(docCopy.linkedNotebookIDs == [copyID])
        #expect(docCopy.teamID == team.id)
    }

    @Test("A site or animation filed under a shared Notebook is not owed to the team as a Markdown stub; a Google Doc still is")
    func linkedPagesDoNotFollowSharedNotebookAsDocs() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        try Self.saveNotebook(store, id: "proj-own", sourceIDs: [])
        _ = try store.copyNotebookIntoTeam(
            notebookID: "proj-own", teamID: team.id, includeSources: false, includeDocs: false,
            fileCopy: { $0 }, artifactCopy: { _, _ in nil }
        )
        let now = Date()
        try store.saveArtifactRecord(ArtifactRecord(
            id: "site-1", title: "Mitochondrial Therapeutics Atlas", homeNotebookID: "proj-own", linkedNotebookIDs: ["proj-own"],
            linkedURL: "foreverlm-site://site-1/", createdAt: now, updatedAt: now
        ))
        try store.saveArtifactRecord(ArtifactRecord(
            id: "anim-1", title: "Electrons running backwards", homeNotebookID: "proj-own", linkedNotebookIDs: ["proj-own"],
            linkedURL: "foreverlm-site://anim-1/", kind: .animation, createdAt: now, updatedAt: now
        ))
        try store.saveArtifactRecord(ArtifactRecord(
            id: "claude-1", title: "Sketch", homeNotebookID: "proj-own", linkedNotebookIDs: ["proj-own"],
            linkedURL: "https://claude.ai/public/artifacts/0b9168b2-98c0-4b51-9e4d-f794910e085c", createdAt: now, updatedAt: now
        ))
        try store.saveArtifactRecord(ArtifactRecord(
            id: "gdoc-1", title: "Mito company ideas", homeNotebookID: "proj-own", linkedNotebookIDs: ["proj-own"],
            linkedURL: "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcdEF/edit", createdAt: now, updatedAt: now
        ))
        try store.saveArtifactRecord(ArtifactRecord(
            id: "doc-plain", title: "Synthesis", homeNotebookID: "proj-own", linkedNotebookIDs: ["proj-own"],
            createdAt: now, updatedAt: now
        ))

        #expect(try store.teamNotebooksAwaitingDoc(artifactID: "site-1").isEmpty)
        #expect(try store.teamNotebooksAwaitingDoc(artifactID: "anim-1").isEmpty)
        #expect(try store.teamNotebooksAwaitingDoc(artifactID: "claude-1").isEmpty)
        #expect(try store.teamNotebooksAwaitingDoc(artifactID: "gdoc-1").map(\.team.id) == [team.id])
        #expect(try store.teamNotebooksAwaitingDoc(artifactID: "doc-plain").map(\.team.id) == [team.id])
    }

    @Test("A page shared with a team is the page: address and kind kept, one copy per address however often the page is relinked")
    func linkedPageSharesAsThePage() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        let now = Date()
        let url = "https://mitochondria.learner-1234.chatgpt.site/"
        try store.saveArtifactRecord(ArtifactRecord(
            id: "site-1", title: "Mitochondrial Therapeutics Atlas", homeNotebookID: nil, linkedNotebookIDs: [],
            linkedURL: url, createdAt: now, updatedAt: now
        ))
        let copyID = try store.copyArtifactRowIntoTeam(artifactID: "site-1", teamID: team.id, linkedTeamNotebookIDs: [], fileCopy: { $0 }).id
        #expect(copyID == TeamContentIdentity.linkedPageArtifactID(teamID: team.id, url: url))
        let copy = try #require(try store.loadArtifact(copyID))
        #expect(copy.linkedURL == url)
        #expect(copy.teamID == team.id)
        #expect(copy.section == .sites)
        #expect(try store.teamsHoldingArtifact("site-1").map(\.id) == [team.id])

        // The page linked again under a new record at the same address: the
        // one team entry is updated, not joined by a second.
        try store.saveArtifactRecord(ArtifactRecord(
            id: "site-2", title: "Mitochondrial Therapeutics Atlas, revised", homeNotebookID: nil, linkedNotebookIDs: [],
            linkedURL: url, createdAt: now, updatedAt: now
        ))
        #expect(try store.copyArtifactRowIntoTeam(artifactID: "site-2", teamID: team.id, linkedTeamNotebookIDs: [], fileCopy: { $0 }).id == copyID)
        #expect(try store.loadArtifacts().filter { $0.teamID == team.id }.count == 1)
        #expect(try store.loadArtifact(copyID)?.title == "Mitochondrial Therapeutics Atlas, revised")
        #expect(try store.teamsHoldingArtifact("site-2").map(\.id) == [team.id])

        // An animation keeps its kind and its section; a Markdown Doc is still
        // keyed by its record.
        try store.saveArtifactRecord(ArtifactRecord(
            id: "anim-1", title: "Electrons running backwards", homeNotebookID: nil, linkedNotebookIDs: [],
            linkedURL: "foreverlm-site://anim-1/", kind: .animation, createdAt: now, updatedAt: now
        ))
        let animationCopyID = try store.copyArtifactRowIntoTeam(artifactID: "anim-1", teamID: team.id, linkedTeamNotebookIDs: [], fileCopy: { $0 }).id
        let animationCopy = try #require(try store.loadArtifact(animationCopyID))
        #expect(animationCopy.kind == .animation)
        #expect(animationCopy.section == .animations)
        try store.saveArtifactRecord(ArtifactRecord(
            id: "doc-1", title: "Synthesis", homeNotebookID: nil, linkedNotebookIDs: [], createdAt: now, updatedAt: now
        ))
        #expect(try store.copyArtifactRowIntoTeam(artifactID: "doc-1", teamID: team.id, linkedTeamNotebookIDs: [], fileCopy: { $0 }).id
            == TeamContentIdentity.artifactID(teamID: team.id, originalArtifactID: "doc-1"))
    }

    @Test("An artifact's sources travel into the team with it, and the copy names the team's copies")
    func artifactSourcesTravelWithIt() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        var paper = Self.readySource(
            id: "src-paper", url: "https://doi.org/10.1038/s41586-026-1", title: "The paper",
            content: "Enough text to count as a readable source for the copy."
        )
        paper.sourceType = .book
        paper.localFilePath = "Books/the-book.epub"
        try store.saveSource(paper)
        try store.saveSource(Self.readySource(
            id: "src-video", url: "https://www.youtube.com/watch?v=abc123", title: "The talk",
            content: "Enough text to count as a readable source for the copy."
        ))
        let now = Date()
        try store.saveArtifactRecord(ArtifactRecord(
            id: "anim-1", title: "Electrons running backwards", homeNotebookID: nil, linkedNotebookIDs: [],
            linkedURL: "foreverlm-site://anim-1/", kind: .animation,
            sourceIDs: ["src-paper", "src-video", "src-gone"], createdAt: now, updatedAt: now
        ))

        var copiedPaths: [String] = []
        let result = try store.copyArtifactRowIntoTeam(artifactID: "anim-1", teamID: team.id, linkedTeamNotebookIDs: []) { path in
            // The store hands the file's path resolved on this Mac; the copy
            // gets the team folder's path back, as `copyFileIntoTeam` does.
            copiedPaths.append(path)
            return "Teams/team-1/Books/the-book.epub"
        }
        let paperCopyID = TeamContentIdentity.sourceID(teamID: team.id, url: paper.url)
        let videoCopyID = TeamContentIdentity.sourceID(teamID: team.id, url: "https://www.youtube.com/watch?v=abc123")

        // The copy points at the team's sources, never at the learner's rows,
        // and an id no library holds is left out rather than carried as a
        // dangling reference.
        let copy = try #require(try store.loadArtifact(result.id))
        #expect(copy.sourceIDs == [paperCopyID, videoCopyID].sorted())
        #expect(Set(try store.loadActiveSources(teamID: team.id).map(\.id)) == [paperCopyID, videoCopyID])
        #expect(try store.loadActiveSources(teamID: team.id).first { $0.id == paperCopyID }?.localFilePath?.hasSuffix("Teams/team-1/Books/the-book.epub") == true)
        #expect(copiedPaths.count == 1 && copiedPaths[0].hasSuffix("Books/the-book.epub"), "the file travels with the book; the video has none")
        #expect(try store.loadActiveSources().map(\.id).sorted() == ["src-paper", "src-video"], "My Library is untouched")

        // What travelled, and what could not.
        #expect(result.carriedSources.linked.map(\.originalID).sorted() == ["src-paper", "src-video"])
        #expect(result.carriedSources.linked.first { $0.originalID == "src-paper" }?.teamCopyID == paperCopyID)
        #expect(result.carriedSources.cited.isEmpty)
        #expect(result.carriedSources.failed.map(\.originalID) == ["src-gone"])
        #expect(result.carriedSources.count == 2)

        // Sharing again finds the team holding both: nothing travels twice,
        // no file is copied again, and the copy still resolves.
        let again = try store.copyArtifactRowIntoTeam(artifactID: "anim-1", teamID: team.id, linkedTeamNotebookIDs: []) { path in
            copiedPaths.append(path)
            return path
        }
        #expect(again.id == result.id)
        #expect(again.carriedSources.linked.isEmpty)
        #expect(copiedPaths.count == 1)
        #expect(try store.loadArtifact(again.id)?.sourceIDs == [paperCopyID, videoCopyID].sorted())
        #expect(try store.loadActiveSources(teamID: team.id).count == 2)

        // A record already in the team keeps the team ids it has.
        try store.saveArtifactRecord(ArtifactRecord(
            id: "team-anim", title: "Made in the team", homeNotebookID: nil, linkedNotebookIDs: [],
            linkedURL: "foreverlm-site://made-in-team/", teamID: team.id, kind: .animation,
            sourceIDs: [paperCopyID], createdAt: now, updatedAt: now
        ))
        let mapped = store.carrySourcesIntoTeam([paperCopyID, "src-video"], teamID: team.id) { $0 }
        #expect(mapped.sourceIDs == [paperCopyID, videoCopyID].sorted())
        #expect(mapped.carried.linked.isEmpty)
        #expect(mapped.carried.failed.isEmpty)
    }

    @Test("A Doc following a shared Notebook carries its sources into the team too")
    func docFollowingSharedNotebookCarriesSources() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        try store.saveSource(Self.readySource(
            id: "src-grounding", url: "https://example.com/grounding", title: "Grounding",
            content: "Enough text to count as a readable source for the copy."
        ))
        try Self.saveNotebook(store, id: "proj-own", sourceIDs: [])
        let now = Date()
        try store.saveArtifactRecord(ArtifactRecord(
            id: "doc-grounded", title: "Synthesis", homeNotebookID: "proj-own", linkedNotebookIDs: ["proj-own"],
            sourceIDs: ["src-grounding"], createdAt: now, updatedAt: now
        ))

        // The Notebook share's Doc copy is the same row copy the initial share
        // uses; here it stands in for StorageService.shareArtifact.
        var carried: [ArtifactTeamCopy] = []
        let teamNotebookID = try store.copyNotebookIntoTeam(
            notebookID: "proj-own", teamID: team.id, includeSources: true, includeDocs: true,
            fileCopy: { $0 },
            artifactCopy: { artifactID, teamNotebookID in
                let copy = try store.copyArtifactRowIntoTeam(
                    artifactID: artifactID, teamID: team.id, linkedTeamNotebookIDs: [teamNotebookID], fileCopy: { $0 }
                )
                carried.append(copy)
                return copy.id
            }
        )
        let groundingCopyID = TeamContentIdentity.sourceID(teamID: team.id, url: "https://example.com/grounding")
        #expect(carried.count == 1)
        #expect(carried.first?.carriedSources.linked.map(\.teamCopyID) == [groundingCopyID])
        let docCopy = try #require(try store.loadArtifact(TeamContentIdentity.artifactID(teamID: team.id, originalArtifactID: "doc-grounded")))
        #expect(docCopy.linkedNotebookIDs == [teamNotebookID])
        #expect(docCopy.sourceIDs == [groundingCopyID])
        #expect(try store.loadActiveSources(teamID: team.id).map(\.id) == [groundingCopyID], "the Notebook had no sources of its own; the Doc's came along")
        #expect(try store.teamNotebooksAwaitingDoc(artifactID: "doc-grounded").isEmpty)
    }

    @Test("A chat under a shared Notebook keeps its team transcript current as it grows")
    func chatFollowsSharedNotebook() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        try Self.saveNotebook(store, id: "proj-own", sourceIDs: [])
        try Self.saveNotebook(store, id: "proj-private", sourceIDs: [])
        let copyID = try store.copyNotebookIntoTeam(
            notebookID: "proj-own", teamID: team.id, includeSources: false, includeDocs: false,
            fileCopy: { $0 }, artifactCopy: { _, _ in nil }
        )

        // Started after the share, so nothing has copied it yet.
        try Self.saveChat(store, id: "chat-later", notebookID: "proj-own")
        try Self.saveChat(store, id: "chat-private", notebookID: "proj-private")
        try Self.saveChat(store, id: "chat-loose", notebookID: nil)
        #expect(try store.teamShareableChatNotebookID(sessionID: "chat-later") == "proj-own")
        #expect(try store.teamShareableChatNotebookID(sessionID: "chat-loose") == nil)
        #expect(try store.propagateChatToTeams(sessionID: "chat-private").isEmpty)
        #expect(try store.propagateChatToTeams(sessionID: "chat-loose").isEmpty)
        #expect(try store.propagateChatToTeams(sessionID: "chat-later") == [team.id])

        let snapshotID = TeamContentIdentity.chatSnapshotID(teamID: team.id, originalSessionID: "chat-later")
        #expect(try store.loadReviewSessionForSync(snapshotID)?.goalID == copyID)
        #expect(try store.loadReviewSessionForSync(snapshotID)?.exchanges.count == 1)

        // The next turn rewrites the same transcript.
        _ = try store.addReviewPrompt(sessionID: "chat-later", question: "And the gradient?", sourceRefs: [])
        try store.clearAllPendingSyncChanges()
        #expect(try store.propagateChatToTeams(sessionID: "chat-later") == [team.id])
        let refreshed = try #require(try store.loadReviewSessionForSync(snapshotID))
        #expect(refreshed.exchanges.count == 2)
        #expect(refreshed.exchanges.last?.question == "And the gradient?")
        #expect(try store.loadReviewSessionLinks().filter { $0.teamID == team.id }.count == 1)
        #expect(try store.pendingSyncChanges().first { $0.logicalKey == snapshotID }?.home == team.home)
    }

    @Test("Tasks follow their Notebook's team, and a delete tombstones in the same zone")
    func notebookTasks() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        let ownNotebook = try store.createLearningGoal(title: "Own", startAt: Date(), endAt: Date().addingTimeInterval(86_400), sourceIDs: [])
        let teamNotebookID = try store.copyNotebookIntoTeam(
            notebookID: ownNotebook.id, teamID: team.id, includeSources: false, includeDocs: false,
            fileCopy: { $0 }, artifactCopy: { _, _ in nil }
        )

        let task = NotebookTaskRecord(
            id: "task-1",
            notebookID: teamNotebookID,
            title: "Read the influx paper",
            notes: "Focus on figure 3",
            status: .todo,
            assigneeRecordName: "_member-a",
            assigneeDisplayName: "Ada",
            dueAt: Date(timeIntervalSinceReferenceDate: 5_000)
        )
        try store.saveNotebookTask(task)
        let saved = try #require(try store.loadNotebookTask("task-1"))
        #expect(saved.teamID == team.id)
        #expect(saved.assigneeDisplayName == "Ada")
        #expect(saved.completedAt == nil)
        #expect(try store.loadNotebookTasks(notebookID: teamNotebookID).map(\.id) == ["task-1"])
        #expect(try store.loadNotebookTasks(teamID: team.id).map(\.id) == ["task-1"])
        #expect(try store.resolveRecordHome(entity: .notebookTask, logicalKey: "task-1") == team.home)
        let saveChange = try #require(try store.pendingSyncChanges().first { $0.entity == .notebookTask && $0.logicalKey == "task-1" })
        #expect(saveChange.home == team.home)
        #expect(saveChange.operation == .save)

        let record = try #require(try CloudKitRecordMapper.makeRecord(for: saveChange, store: store))
        #expect(record.recordType == "ProjectTask")
        let payload = try JSONDecoder().decode(CloudKitNotebookTaskPayload.self, from: try #require(record.encryptedValues[.payload] as? Data))
        #expect(payload.task.title == "Read the influx paper")
        #expect(payload.task.teamID == team.id)

        // Done stamps a completion; reopening clears it.
        var done = saved
        done.status = .done
        try store.saveNotebookTask(done)
        #expect(try store.loadNotebookTask("task-1")?.completedAt != nil)
        var reopened = done
        reopened.status = .doing
        try store.saveNotebookTask(reopened)
        #expect(try store.loadNotebookTask("task-1")?.completedAt == nil)

        // A task on a personal Notebook stays in the learner's own zone.
        try store.saveNotebookTask(NotebookTaskRecord(id: "task-own", notebookID: ownNotebook.id, title: "Mine"))
        #expect(try store.loadNotebookTask("task-own")?.teamID == nil)
        #expect(try store.pendingSyncChanges().first { $0.logicalKey == "task-own" }?.home == .knowledge)

        try store.deleteNotebookTask("task-1")
        #expect(try store.loadNotebookTask("task-1") == nil)
        let tombstone = try #require(try store.pendingSyncChanges().first { $0.entity == .notebookTask && $0.logicalKey == "task-1" })
        #expect(tombstone.operation == .delete)
        #expect(tombstone.home == team.home)
    }

    @Test("A share request lives in the team zone, is answered with the holder's copy, and dies with the team")
    func shareRequests() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        try store.saveSource(Self.readySource(id: "src-held", url: "https://www.nature.com/articles/s41586-026-1", title: "Held", content: "A paper only this library holds."))

        let request = ShareRequestRecord(
            id: "req-1", teamID: team.id, url: "https://www.nature.com/articles/s41586-026-1?utm_source=slack",
            title: "Held", artifactID: "doc-1", requestedByRecordName: "_member-a", requestedByDisplayName: "Ada"
        )
        try store.saveShareRequest(request)
        let saved = try #require(try store.loadShareRequest("req-1"))
        #expect(saved.isOpen)
        #expect(saved.requestedByDisplayName == "Ada")
        #expect(try store.loadShareRequests(teamID: team.id).map(\.id) == ["req-1"])
        #expect(try store.loadShareRequests(teamID: team.id, status: .fulfilled).isEmpty)
        #expect(try store.loadOpenShareRequests().map(\.id) == ["req-1"])
        #expect(try store.openShareRequest(teamID: team.id, url: request.url)?.id == "req-1")
        #expect(try store.openShareRequest(teamID: team.id, url: "https://example.org/other") == nil)

        // Homed in the team zone, and shaped for CloudKit like a task.
        #expect(try store.resolveRecordHome(entity: .shareRequest, logicalKey: "req-1") == team.home)
        let saveChange = try #require(try store.pendingSyncChanges().first { $0.entity == .shareRequest && $0.logicalKey == "req-1" })
        #expect(saveChange.home == team.home)
        let record = try #require(try CloudKitRecordMapper.makeRecord(for: saveChange, store: store))
        #expect(record.recordType == "ShareRequest")
        let payload = try JSONDecoder().decode(CloudKitShareRequestPayload.self, from: try #require(record.encryptedValues[.payload] as? Data))
        #expect(payload.request.url == request.url)
        #expect(payload.request.teamID == team.id)

        // The holder's library answers the card's address the way the card matched it.
        #expect(store.activeSourceID(forReferenceURL: request.url, teamID: nil) == "src-held")
        #expect(store.activeSourceID(forReferenceURL: request.url, teamID: team.id) == nil)
        let copyID = try store.copySourceIntoTeam(sourceID: "src-held", teamID: team.id) { $0 }
        var fulfilled = saved
        fulfilled.status = .fulfilled
        fulfilled.fulfilledSourceID = copyID
        fulfilled.resolvedByDisplayName = "Robin"
        fulfilled.resolvedAt = Date()
        try store.saveShareRequest(fulfilled)
        #expect(try store.loadShareRequest("req-1")?.status == .fulfilled)
        #expect(try store.loadOpenShareRequests().isEmpty)
        #expect(try store.openShareRequest(teamID: team.id, url: request.url) == nil)
        #expect(store.activeSourceID(forReferenceURL: request.url, teamID: team.id) == copyID)

        // A record from another member arrives without touching the queue.
        try store.withoutSyncTracking {
            try store.saveShareRequestRecord(ShareRequestRecord(id: "req-2", teamID: team.id, url: "https://example.org/two"))
        }
        #expect(try store.loadShareRequests(teamID: team.id).count == 2)
        #expect(try store.pendingSyncChanges().contains { $0.logicalKey == "req-2" } == false)

        // Deleting the team takes its requests with it.
        try store.deleteShareRequest("req-2")
        let tombstone = try #require(try store.pendingSyncChanges().first { $0.entity == .shareRequest && $0.logicalKey == "req-2" })
        #expect(tombstone.operation == .delete)
        #expect(tombstone.home == team.home)
        try store.removeTeamLocally(team.id)
        #expect(try store.loadShareRequests(teamID: team.id).isEmpty)
    }

    @Test("A read-only team refuses every write into it")
    func readOnlyTeam() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store, role: .member, permission: .readOnly)
        try store.saveSource(Self.readySource(id: "src-1", url: "https://example.com/1", title: "One", content: "Text one for the read-only test."))
        #expect(throws: (any Error).self) {
            try store.copySourceIntoTeam(sourceID: "src-1", teamID: team.id) { $0 }
        }
        // A team Notebook that arrived from the owner cannot take a task from a
        // read-only member either: the queue refuses the save.
        try store.withoutSyncTracking {
            try store.saveLearningGoalRecord(LearningGoalRecord(
                id: "proj-team", title: "Theirs", startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
                createdAt: Date(), updatedAt: Date(), status: "active", items: [],
                kind: LearningGoalRecord.companionKind, teamID: team.id
            ))
        }
        #expect(throws: (any Error).self) {
            try store.saveNotebookTask(NotebookTaskRecord(id: "t", notebookID: "proj-team", title: "Nope"))
        }
        #expect(try store.loadNotebookTask("t") == nil)
        #expect(try store.loadActiveSources().map(\.id) == ["src-1"])
    }

    @Test("Removing a team takes its copies and bookkeeping, and nothing of the learner's own")
    func removeTeamLocally() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        try store.saveSource(Self.readySource(id: "src-1", url: "https://example.com/1", title: "One", content: "Text one for the removal test."))
        let ownNotebook = try store.createLearningGoal(title: "Own", startAt: Date(), endAt: Date().addingTimeInterval(86_400), sourceIDs: ["src-1"])
        let teamNotebookID = try store.copyNotebookIntoTeam(
            notebookID: ownNotebook.id, teamID: team.id, includeSources: true, includeDocs: false,
            fileCopy: { $0 }, artifactCopy: { _, _ in nil }
        )
        try store.saveNotebookTask(NotebookTaskRecord(id: "task-1", notebookID: teamNotebookID, title: "Do it"))
        try store.replaceTeamMembers(teamID: team.id, members: [
            TeamMemberRecord(userRecordName: "_me", teamID: team.id, displayName: "Me", email: nil, role: .owner, permission: .readWrite, acceptanceStatus: "accepted", isCurrentUser: true, updatedAt: Date()),
        ])
        #expect(try store.loadTeamMembers(teamID: team.id).count == 1)
        #expect(try store.loadActiveSources(teamID: team.id).count == 1)
        #expect(try store.pendingSyncChanges().contains { $0.home == team.home })

        try store.removeTeamLocally(team.id)

        #expect(try store.loadTeam(team.id) == nil)
        #expect(try store.loadTeamMembers(teamID: team.id).isEmpty)
        #expect(try store.loadActiveSources(teamID: team.id).isEmpty)
        #expect(try store.loadLearningGoal(teamNotebookID) == nil)
        #expect(try store.loadNotebookTask("task-1") == nil)
        #expect(!(try store.pendingSyncChanges().contains { $0.home == team.home }))
        #expect(try store.loadSyncMetadata(entity: .learningGoal, logicalKey: teamNotebookID) == nil)

        // My Library is exactly as it was.
        #expect(try store.loadActiveSources().map(\.id) == ["src-1"])
        #expect(try store.loadLearningGoal(ownNotebook.id)?.items.count == 1)
        #expect(try store.pendingSyncChanges().contains { $0.logicalKey == ownNotebook.id })
    }

    // MARK: Courses (docs/teams-design.md, decision 21)

    private static let courseReadingPages = 3...5

    /// A course of My Library with two lectures: a lecture video with a
    /// practice quiz whose question shows a frame of it, a textbook reading of
    /// three pages, a lesson sheet filed under the course, a lecture whose one
    /// item is archived, and an assistant's checkpoint under an id of its own.
    /// The learner hid the course.
    private static func seedCourse(_ store: KnowledgeStore) throws {
        try store.saveSource(readySource(id: "src-video", url: "https://www.youtube.com/watch?v=abc123", title: "Lecture 1", content: "What the first lecture says."))
        try store.saveSource(readySource(id: "src-chapter", url: "https://example.com/book/chapter-2", title: "Chapter 2", content: "The chapter's text."))
        var lesson = StudioArticle(
            url: "foreverlm://course/course-own/lesson/1",
            title: "Lesson sheet",
            sourceType: .course,
            discoveryOrigin: .manual,
            parentGroup: "course-own",
            id: "src-lesson"
        )
        lesson.content = "The lesson sheet's text."
        lesson.wordCount = 4
        lesson.state = .ready
        lesson.courseSortIndex = 2
        try store.saveSource(lesson)
        var archived = readySource(id: "src-archived", url: "https://example.com/gone", title: "Gone", content: "Archived text.")
        archived.status = .archived
        archived.archivedAt = Date()
        try store.saveSource(archived)

        try store.saveCourseGroup(name: "course-own", metadata: CourseMetadata(courseCode: "BIO 101", title: "Bioelectricity", isHidden: true))
        let unit = SourceUnit(
            id: TextbookReading.unitID(sourceID: "src-chapter", pages: courseReadingPages),
            sourceId: "src-chapter",
            kind: TextbookReading.unitKind,
            locator: TextbookReading.locator(courseReadingPages),
            title: "Membranes"
        )
        try store.saveSourceUnit(unit)
        try store.saveCourseOutline(
            courseName: "course-own",
            lectures: [
                CourseSession(id: "lec-1", courseName: "course-own", number: 1, title: "Voltage"),
                CourseSession(id: "lec-2", courseName: "course-own", number: 2, title: "Gap junctions"),
            ],
            items: [
                CourseLectureItem(id: "item-video", lectureId: "lec-1", sourceId: "src-video", role: .video, sortIndex: 0),
                CourseLectureItem(
                    id: TextbookReading.itemID(lectureID: "lec-1", sourceID: "src-chapter", pages: courseReadingPages),
                    lectureId: "lec-1",
                    sourceId: "src-chapter",
                    sourceUnitId: unit.id,
                    role: .reading,
                    sortIndex: 1
                ),
                CourseLectureItem(id: "item-archived", lectureId: "lec-2", sourceId: "src-archived", role: .video, sortIndex: 0),
            ]
        )
        let question = CourseQuizQuestion(
            id: CourseQuizPlanning.questionID(sourceID: "src-video", question: "Why does voltage matter?"),
            sourceID: "src-video",
            firstLine: 1,
            lastLine: 3,
            startSeconds: 40,
            question: "Why does voltage matter?",
            answer: "It patterns the tissue.",
            keyPoints: ["patterning"],
            quote: nil,
            picture: CourseQuizPicture(
                reference: SourceImageReference(sourceID: "src-video", location: .moment(42)),
                caption: "The slide",
                placement: .answer
            )
        )
        let now = Date()
        try store.saveCourseQuiz(CourseQuiz(
            id: CourseQuizPlanning.practiceID(courseID: "course-own", lectureID: "lec-1"),
            courseID: "course-own",
            kind: .practice,
            title: "Voltage and form",
            lectureIDs: ["lec-1"],
            afterLectureID: "lec-1",
            questions: [question],
            author: .foreverlm,
            createdAt: now,
            updatedAt: now
        ))
        try store.saveCourseQuiz(CourseQuiz(
            id: "quiz-assistant",
            courseID: "course-own",
            kind: .checkpoint,
            title: "Checkpoint",
            lectureIDs: ["lec-1", "lec-2"],
            afterLectureID: "lec-2",
            questions: [],
            author: .assistant,
            createdAt: now,
            updatedAt: now
        ))
    }

    @Test("Sharing a course copies its whole path into the team, every source it names with it, and leaves the original alone")
    func copyCourseIntoTeam() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        try Self.seedCourse(store)
        try store.clearAllPendingSyncChanges()

        let copy = try store.copyCourseIntoTeam(courseID: "course-own", teamID: team.id) { "Teams/team-1/\($0)" }
        let courseID = TeamContentIdentity.courseID(teamID: team.id, originalCourseID: "course-own")
        #expect(copy.id == courseID)
        #expect(copy.itemsLeftOut == 0, "an archived source is out of the path, not a failure")
        #expect(copy.carriedSources.failed.isEmpty)
        #expect(copy.carriedSources.linked.count == 3)

        func teamSource(_ url: String) -> String { TeamContentIdentity.sourceID(teamID: team.id, url: url) }
        let video = teamSource("https://www.youtube.com/watch?v=abc123")
        let chapter = teamSource("https://example.com/book/chapter-2")
        let lesson = teamSource("foreverlm://course/course-own/lesson/1")
        let lecture1 = TeamContentIdentity.coursePartID(teamID: team.id, part: "lecture", originalID: "lec-1")
        let lecture2 = TeamContentIdentity.coursePartID(teamID: team.id, part: "lecture", originalID: "lec-2")

        // The course is the team's, not hidden, with the original's metadata.
        #expect(try store.courseTeamID(courseID) == team.id)
        #expect(try store.loadCourseTeamIDs() == [courseID: team.id])
        let metadata = try #require(try store.loadCourseGroups()[courseID])
        #expect(metadata.title == "Bioelectricity")
        #expect(metadata.courseCode == "BIO 101")
        #expect(!metadata.isHidden, "hiding the original was the learner's own")

        // The path, on the team's rows.
        let lectures = try store.loadCourseLectures().filter { $0.courseName == courseID }
        #expect(lectures.map(\.id) == [lecture1, lecture2])
        #expect(lectures.map(\.title) == ["Voltage", "Gap junctions"])
        let items = try store.loadCourseLectureItems().filter { $0.lectureId == lecture1 || $0.lectureId == lecture2 }
        #expect(items.count == 2, "the archived lecture item stays behind")
        let videoItem = try #require(items.first { $0.role == .video })
        #expect(videoItem.sourceId == video)
        let reading = try #require(items.first { $0.role == .reading })
        #expect(reading.sourceId == chapter)
        #expect(reading.id == TextbookReading.itemID(lectureID: lecture1, sourceID: chapter, pages: Self.courseReadingPages))
        #expect(reading.sourceUnitId == TextbookReading.unitID(sourceID: chapter, pages: Self.courseReadingPages))
        let unitID = try #require(reading.sourceUnitId)
        let unit = try #require(try store.loadSourceUnits(ids: [unitID]).first)
        #expect(unit.sourceId == chapter)
        #expect(unit.locator == TextbookReading.locator(Self.courseReadingPages))

        // Every source the path names is the team's; the lesson files under the team's course.
        let teamSources = Set(try store.loadActiveSources(teamID: team.id).map(\.id))
        #expect(teamSources == [video, chapter, lesson])
        let lessonCopy = try #require(try store.loadSourceWithoutContent(lesson))
        #expect(lessonCopy.parentGroup == courseID)
        #expect(lessonCopy.courseSortIndex == 2)
        #expect(try store.sourceIDsForCourse(courseID).contains(lesson))

        // Quizzes: the ladder's by the ladder's rule over the team's ids, an
        // assistant's under a team-scoped id; questions and pictures on the team's rows.
        let quizzes = try store.loadCourseQuizzes(courseID: courseID)
        let practice = try #require(quizzes.first { $0.kind == .practice })
        #expect(practice.id == CourseQuizPlanning.practiceID(courseID: courseID, lectureID: lecture1))
        #expect(practice.lectureIDs == [lecture1])
        #expect(practice.afterLectureID == lecture1)
        let question = try #require(practice.questions.first)
        #expect(question.sourceID == video)
        #expect(question.id == CourseQuizPlanning.questionID(sourceID: video, question: "Why does voltage matter?"))
        #expect(question.picture?.reference?.sourceID == video)
        #expect(question.picture?.reference?.location == .moment(42))
        #expect(question.picture?.placement == .answer)
        let checkpoint = try #require(quizzes.first { $0.kind == .checkpoint })
        #expect(checkpoint.id == TeamContentIdentity.coursePartID(teamID: team.id, part: "quiz", originalID: "quiz-assistant"))
        #expect(checkpoint.lectureIDs == [lecture1, lecture2])

        // The course record is homed in the team's zone and carries no member's hidden flag.
        #expect(try store.resolveRecordHome(entity: .course, logicalKey: courseID) == team.home)
        #expect(try store.resolveRecordHome(entity: .course, logicalKey: "course-own") == .knowledge)
        try store.execForTesting("UPDATE courses SET is_hidden = 1 WHERE id = '\(courseID)'")
        let courseChange = try #require(try store.pendingSyncChanges().first { $0.entity == .course && $0.logicalKey == courseID })
        #expect(courseChange.home == team.home)
        let record = try #require(try CloudKitRecordMapper.makeRecord(for: courseChange, store: store))
        #expect(record.recordID.zoneID == team.home.zoneID)
        let payload = try JSONDecoder().decode(
            CloudKitCoursePayload.self,
            from: try #require(record.encryptedValues[.payload] as? Data)
        )
        #expect(!payload.isHidden)
        #expect(payload.lectures.count == 2)
        #expect(payload.quizzes?.count == 2)
        #expect(!(try store.pendingSyncChanges().contains { $0.logicalKey == "course-own" }))

        // The original is exactly as it was.
        #expect(try store.courseTeamID("course-own") == nil)
        #expect(try store.loadCourseGroups()["course-own"]?.isHidden == true)
        #expect(try store.loadCourseLectures().filter { $0.courseName == "course-own" }.map(\.id) == ["lec-1", "lec-2"])
        #expect(try store.loadCourseQuizzes(courseID: "course-own").count == 2)
        #expect(Set(try store.loadActiveSources().map(\.id)) == ["src-video", "src-chapter", "src-lesson"])
        #expect(try store.teamsHoldingCourse("course-own").map(\.id) == [team.id])
    }

    @Test("Sharing a course again updates the one copy and keeps a teammate's quiz")
    func copyCourseIntoTeamAgain() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        try Self.seedCourse(store)
        let courseID = try store.copyCourseIntoTeam(courseID: "course-own", teamID: team.id) { $0 }.id
        let now = Date()
        try store.saveCourseQuiz(CourseQuiz(
            id: "quiz-teammate", courseID: courseID, kind: .test, title: "Teammate's test",
            lectureIDs: [], afterLectureID: nil, questions: [], author: .assistant, createdAt: now, updatedAt: now
        ))
        try store.saveCourseLecture(CourseSession(id: "lec-1", courseName: "course-own", number: 1, title: "Voltage, revised"))

        let again = try store.copyCourseIntoTeam(courseID: "course-own", teamID: team.id) { $0 }
        #expect(again.id == courseID)
        #expect(again.carriedSources.linked.isEmpty, "the team already held every source")
        #expect(try store.loadCourseTeamIDs().count == 1)
        let lectures = try store.loadCourseLectures().filter { $0.courseName == courseID }
        #expect(lectures.first?.title == "Voltage, revised")
        let quizIDs = Set(try store.loadCourseQuizzes(courseID: courseID).map(\.id))
        #expect(quizIDs.contains("quiz-teammate"))
        #expect(quizIDs.count == 3)
        #expect(try store.loadActiveSources(teamID: team.id).count == 3)

        // Removing the team takes its course, and leaves the learner's.
        try store.removeTeamLocally(team.id)
        #expect(try store.loadCourseGroups()[courseID] == nil)
        #expect(try store.loadCourseQuizzes(courseID: courseID).isEmpty)
        #expect(try store.loadCourseGroups()["course-own"] != nil)
        #expect(try store.loadCourseLectures().filter { $0.courseName == "course-own" }.count == 2)
    }

    @Test("Hiding a team's course is the member's own: nothing queues, a read-only member can do it, and an inbound apply keeps it")
    func teamCourseHiddenIsPerMember() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        try Self.seedCourse(store)
        let courseID = try store.copyCourseIntoTeam(courseID: "course-own", teamID: team.id) { $0 }.id
        try store.clearAllPendingSyncChanges()

        var metadata = try #require(try store.loadCourseGroups()[courseID])
        metadata.isHidden = true
        try store.saveCourseGroup(name: courseID, metadata: metadata)
        #expect(try store.loadCourseGroups()[courseID]?.isHidden == true)
        #expect(!(try store.pendingSyncChanges().contains { $0.entity == .course }))

        // A rename is the team's, and queues for its zone.
        metadata.title = "Bioelectricity, for the team"
        try store.saveCourseGroup(name: courseID, metadata: metadata)
        #expect(try store.pendingSyncChanges().first { $0.entity == .course }?.home == team.home)

        // An inbound Course record carries no hidden flag; this member's stays.
        let snapshot = try #require(try store.captureMemberState(entity: .course, logicalKey: courseID))
        try store.execForTesting("UPDATE courses SET is_hidden = 0 WHERE id = '\(courseID)'")
        try store.restoreMemberState(snapshot)
        #expect(try store.loadCourseGroups()[courseID]?.isHidden == true)

        // A read-only member hides a team's course; changing it is refused.
        let readOnly = try Self.makeTeam(store, id: "team-ro", name: "Theirs", role: .member, permission: .readOnly)
        try store.withoutSyncTracking {
            try store.saveCourseGroup(name: "course-theirs", metadata: CourseMetadata(title: "Theirs"))
            try store.stampTeam(entity: .course, logicalKey: "course-theirs", teamID: readOnly.id)
        }
        try store.saveCourseGroup(name: "course-theirs", metadata: CourseMetadata(title: "Theirs", isHidden: true))
        #expect(try store.loadCourseGroups()["course-theirs"]?.isHidden == true)
        #expect(throws: (any Error).self) {
            try store.saveCourseGroup(name: "course-theirs", metadata: CourseMetadata(title: "Mine now", isHidden: true))
        }
        #expect(try store.courseTeamID("course-theirs") == readOnly.id, "an upsert keeps the course's team")
    }

    @Test("A team's course files a member's own source as the team's copy, and refuses one the team does not hold")
    func teamCourseFilesTeamRows() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        try Self.seedCourse(store)
        let courseID = try store.copyCourseIntoTeam(courseID: "course-own", teamID: team.id) { $0 }.id
        let lecture2 = TeamContentIdentity.coursePartID(teamID: team.id, part: "lecture", originalID: "lec-2")
        try store.saveSource(Self.readySource(id: "src-new", url: "https://example.com/new", title: "New", content: "A new source of the member's own."))

        #expect(throws: (any Error).self) {
            try store.saveCourseLectureItem(CourseLectureItem(id: "item-new", lectureId: lecture2, sourceId: "src-new", role: .notes, sortIndex: 1))
        }
        #expect(!(try store.loadCourseLectureItems().contains { $0.id == "item-new" }))

        let teamCopy = try store.copySourceIntoTeam(sourceID: "src-new", teamID: team.id) { $0 }
        try store.saveCourseLectureItem(CourseLectureItem(id: "item-new", lectureId: lecture2, sourceId: "src-new", role: .notes, sortIndex: 1))
        #expect(try store.loadCourseLectureItems().first { $0.id == "item-new" }?.sourceId == teamCopy)

        // A whole outline naming own rows the team holds lands on the team's rows, once each.
        let lectures = try store.loadCourseLectures().filter { $0.courseName == courseID }
        try store.saveCourseOutline(courseName: courseID, lectures: lectures, items: [
            CourseLectureItem(id: "o-1", lectureId: lecture2, sourceId: "src-video", role: .video, sortIndex: 0),
            CourseLectureItem(id: "o-2", lectureId: lecture2, sourceId: TeamContentIdentity.sourceID(teamID: team.id, url: "https://www.youtube.com/watch?v=abc123"), role: .video, sortIndex: 1),
        ])
        let outline = try store.loadCourseLectureItems().filter { $0.lectureId == lecture2 }
        #expect(outline.map(\.sourceId) == [TeamContentIdentity.sourceID(teamID: team.id, url: "https://www.youtube.com/watch?v=abc123")])

        // A course of My Library files the learner's own rows as they are.
        try store.saveCourseLectureItem(CourseLectureItem(id: "item-own", lectureId: "lec-2", sourceId: "src-new", role: .notes, sortIndex: 5))
        #expect(try store.loadCourseLectureItems().first { $0.id == "item-own" }?.sourceId == "src-new")
    }

    @Test("Team rows round-trip, and the team's own record is queued for its zone by the owner only")
    func teamRows() throws {
        let store = try KnowledgeStore(inMemory: true)
        let owned = try Self.makeTeam(store, id: "owned", name: "Owned")
        let joined = try Self.makeTeam(store, id: "joined", name: "Joined", role: .member, permission: .readWrite)

        #expect(try store.loadTeams().map(\.id) == ["joined", "owned"])
        #expect(try store.loadTeam("owned")?.home == owned.home)
        #expect(try store.loadTeam("joined")?.home.scope == .shared)
        #expect(try store.loadTeam("joined")?.home.ownerRecordName == "_owner-record")

        let pending = try store.pendingSyncChanges().filter { $0.entity == .team }
        #expect(pending.map(\.logicalKey) == ["owned"])
        #expect(pending.first?.home == owned.home)
        let record = try #require(try CloudKitRecordMapper.makeRecord(for: pending[0], store: store))
        #expect(record.recordType == "Team")
        #expect(record.recordID.zoneID.zoneName == "Team-owned")

        try store.renameTeam("owned", name: "  Renamed  ")
        #expect(try store.loadTeam("owned")?.name == "Renamed")

        // A member learns the name from the owner's record; the zone decides the role.
        try store.upsertTeamFromZone(
            CloudKitTeamPayload(id: "joined", name: "Joined, properly", createdAt: joined.createdAt, updatedAt: Date()),
            home: joined.home,
            permission: nil
        )
        #expect(try store.loadTeam("joined")?.name == "Joined, properly")
        #expect(try store.loadTeam("joined")?.role == .member)
        try store.upsertTeamFromZone(
            CloudKitTeamPayload(id: "fresh", name: "Fresh", createdAt: Date(), updatedAt: Date()),
            home: CloudKitZoneHome(scope: .privateScope, zoneName: "Team-fresh", ownerRecordName: nil),
            permission: nil
        )
        #expect(try store.loadTeam("fresh")?.role == .owner)
        #expect(try store.loadTeam("fresh")?.permission == .readWrite)

        // Stamping from the zone wins over whatever a payload said.
        try store.saveSource(Self.readySource(id: "src-1", url: "https://example.com/1", title: "One", content: "Text one for the stamp test."))
        try store.stampTeam(entity: .source, logicalKey: "src-1", teamID: "owned")
        #expect(try store.loadSourceWithoutContent("src-1")?.teamID == "owned")
        #expect(try store.loadActiveSources().isEmpty)
        #expect(try store.loadActiveSources(teamID: "owned").count == 1)
    }

    @Test("Engine state is kept per database scope")
    func engineStatePerScope() throws {
        let store = try KnowledgeStore(inMemory: true)
        #expect(try store.loadSyncEngineState(scope: .privateScope) == nil)
        #expect(try store.loadSyncEngineState(scope: .shared) == nil)
        try store.saveSyncEngineState(nil, scope: .shared)
        var rows = -1
        try store.query("SELECT COUNT(*) FROM sync_engine_states WHERE scope = 'shared'") { stmt in
            rows = Int(sqlite3_column_int64(stmt, 0))
        }
        #expect(rows == 1)
    }

    @Test("A record's zone survives the bookkeeping round trip")
    func bookkeepingRoundTrip() throws {
        let store = try KnowledgeStore(inMemory: true)
        let home = CloudKitZoneHome(zoneID: CKRecordZone.ID(zoneName: "Team-x", ownerName: "_someone"), scope: .shared)
        let name = CloudKitRecordMapper.recordName(for: .source, logicalKey: "src-shared")
        try store.saveSyncMetadata(CloudKitSyncMetadata(
            entity: .source, logicalKey: "src-shared", recordName: name,
            systemFieldsData: nil, userModificationDate: Date(), isDeleted: false, home: home
        ))
        #expect(try store.loadSyncMetadata(entity: .source, logicalKey: "src-shared")?.home == home)
        #expect(try store.loadSyncMetadata(recordName: name)?.home == home)
        #expect(try store.syncRecordNames(home: home) == [name])

        try store.quarantineSyncConflict(CloudKitSyncConflict(
            entity: .source, logicalKey: "src-shared", recordName: name, reason: "test",
            localModificationDate: Date(), serverModificationDate: Date(), detectedAt: Date(),
            serverPayload: nil, serverSystemFields: nil, home: home
        ))
        #expect(try store.loadSyncConflict(recordName: name)?.home == home)
        #expect(try store.loadSyncConflicts().first?.home == home)

        try store.clearSyncBookkeeping(home: home)
        #expect(try store.loadSyncMetadata(recordName: name) == nil)
        #expect(try store.loadSyncConflict(recordName: name) == nil)
    }

    @Test("PROBE what this Mac would show")
    func probeAccountName() {
        let account = MacAccountUser.fullName
        let row = CloudKitSyncEngine.memberDisplayName(
            nameComponents: nil, email: nil, isCurrentUser: true, accountName: account
        )
        print("PROBE account=\(account ?? "nil") rosterRow=\(row) initials=\(TeamMemberRecord.initials(for: row))")
        #expect(!row.isEmpty)
    }

    @Test("The roster falls back to the account name before it says \"You\"")
    func currentMemberShowsTheAccountName() {
        var mine = PersonNameComponents()
        mine.givenName = "Ada"
        mine.familyName = "Lovelace"

        // CloudKit's own name for a participant always wins.
        #expect(CloudKitSyncEngine.memberDisplayName(
            nameComponents: mine, email: "ada@example.com",
            isCurrentUser: true, accountName: "Someone Else"
        ) == "Ada Lovelace")

        // The signed-in account arrives nameless: CloudKit never names it.
        #expect(CloudKitSyncEngine.memberDisplayName(
            nameComponents: nil, email: nil,
            isCurrentUser: true, accountName: "Ada Lovelace"
        ) == "Ada Lovelace")
        #expect(CloudKitSyncEngine.memberDisplayName(
            nameComponents: nil, email: "ada@example.com",
            isCurrentUser: true, accountName: "Ada Lovelace"
        ) == "Ada Lovelace")

        // No account name to stand in, and the placeholder is all that is left.
        #expect(CloudKitSyncEngine.memberDisplayName(
            nameComponents: nil, email: nil,
            isCurrentUser: true, accountName: "   "
        ) == "You")
        #expect(CloudKitSyncEngine.memberDisplayName(
            nameComponents: nil, email: "ada@example.com",
            isCurrentUser: true, accountName: nil
        ) == "ada@example.com")

        // Another member's row never borrows this Mac's account name.
        #expect(CloudKitSyncEngine.memberDisplayName(
            nameComponents: nil, email: "grace@example.com",
            isCurrentUser: false, accountName: "Ada Lovelace"
        ) == "grace@example.com")
        #expect(CloudKitSyncEngine.memberDisplayName(
            nameComponents: nil, email: nil,
            isCurrentUser: false, accountName: "Ada Lovelace"
        ) == "Member")
    }
}
