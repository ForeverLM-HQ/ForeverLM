import Foundation
import Testing
@testable import ForeverLM

/// A team's copy of a source taken before the source's fetch landed (an MCP `add_source` without
/// `content` into a team notebook, a link dropped on one) takes the fetched text when it lands, on
/// every path, because every fetch ends in `StorageService.saveSource`
/// (docs/notebooks-design.md, "Sharing a notebook"; docs/teams-design.md, generation 2).
@Suite("A team copy takes its source's fetched text")
struct TeamCopyFetchRefreshTests {
    private static let url = "https://example.org/cristae"

    private static func team(_ id: String, permission: TeamPermission = .readWrite) -> TeamRecord {
        let now = Date()
        return TeamRecord(
            id: id, name: id, role: permission == .readWrite ? .owner : .member, permission: permission,
            zoneScope: permission == .readWrite ? .privateScope : .shared, zoneName: TeamRecord.zoneName(forTeamID: id),
            zoneOwnerRecordName: permission == .readWrite ? nil : "_owner-record", shareRecordName: nil, shareURL: nil,
            createdAt: now, joinedAt: now, updatedAt: now
        )
    }

    /// The source as an import saves it: queued, no text yet.
    private static func fetching(id: String = "src-own") -> StudioArticle {
        var article = StudioArticle(url: url, title: "On cristae", sourceType: .article, discoveryOrigin: .manual, id: id)
        article.domain = "example.org"
        article.state = .queued
        return article
    }

    private static func landed(_ article: StudioArticle, text: String = "The inner membrane folds into cristae.") -> StudioArticle {
        var ready = article
        ready.content = text
        ready.wordCount = text.split(separator: " ").count
        ready.state = .ready
        return ready
    }

    @Test("The fetch landing on the source refreshes the team's waiting copy, through StorageService.saveSource")
    func fetchLandingRefreshesTheCopy() async throws {
        let storage = try StorageService(inMemory: true)
        let store = try await storage.notebookFilesKnowledgeStore()
        try store.saveTeam(Self.team("team-1"))
        let source = Self.fetching()
        try await storage.saveSource(source)
        let copyID = try store.copySourceIntoTeam(sourceID: source.id, teamID: "team-1") { $0 }
        #expect(try store.loadSourceWithoutContent(copyID)?.state != .ready, "a copy taken mid-fetch has no text")
        #expect(try store.teamCopiesAwaitingText(ofSource: source.id).isEmpty, "nothing to take while the source is still fetching")

        try await storage.saveSource(Self.landed(source))

        let copy = try #require(try store.loadSourceWithoutContent(copyID))
        #expect(copy.state == .ready)
        #expect(copy.teamID == "team-1")
        #expect(try store.loadSourceContent(copyID) == "The inner membrane folds into cristae.")
        #expect(try store.loadActiveSources(teamID: "team-1").count == 1, "the copy is refreshed, not doubled")
        #expect(try store.teamCopiesAwaitingText(ofSource: source.id).isEmpty)
    }

    @Test("A ready copy, a read-only team's copy and a source still fetching are left alone")
    func onlyWaitingEditableCopiesWithTextRefresh() async throws {
        let storage = try StorageService(inMemory: true)
        let store = try await storage.notebookFilesKnowledgeStore()
        try store.saveTeam(Self.team("team-1"))
        // The other team's copy arrives while the learner may still edit it; then the team turns read-only.
        try store.saveTeam(Self.team("team-ro"))
        let source = Self.fetching()
        try await storage.saveSource(source)
        let copyID = try store.copySourceIntoTeam(sourceID: source.id, teamID: "team-1") { $0 }

        // A read-only team never takes a write, however its copy stands.
        var theirs = Self.fetching(id: try store.teamSourceCopyID(teamID: "team-ro", url: Self.url))
        theirs.teamID = "team-ro"
        try store.saveSource(theirs)
        try store.saveTeam(Self.team("team-ro", permission: .readOnly))

        // Still fetching: nothing would make the copy ready, so nothing is copied. (A source never becomes
        // ready without stored text; the store refuses that save.)
        #expect(try store.teamCopiesAwaitingText(ofSource: source.id).isEmpty)

        try await storage.saveSource(Self.landed(source))
        #expect(try store.loadSourceWithoutContent(copyID)?.state == .ready)
        #expect(try store.loadSourceWithoutContent(theirs.id)?.state != .ready, "a read-only team's copy is not written")

        // A later change of the source's text leaves the team's ready copy as its team has it.
        try await storage.saveSource(Self.landed(source, text: "A rewritten text the team never asked for."))
        #expect(try store.loadSourceContent(copyID) == "The inner membrane folds into cristae.")
    }

    @Test("A library with no team pays one lookup and copies nothing")
    func noTeamNoCopy() async throws {
        let storage = try StorageService(inMemory: true)
        let store = try await storage.notebookFilesKnowledgeStore()
        try await storage.saveSource(Self.landed(Self.fetching()))
        #expect(try store.teamCopiesAwaitingText(ofSource: "src-own").isEmpty)
        #expect(try store.loadActiveSources().map(\.id) == ["src-own"])
    }
}
