import Foundation
import Testing
@testable import ForeverLM

#if os(macOS)

@Suite("MCP source audio tools")
struct MCPSourceAudioToolsTests {
    private func makeStore() throws -> (MCPDataStore, String) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_audio_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir.appendingPathComponent("knowledge.db").path
        let store = MCPDataStore(dbPath: dbPath)
        _ = try store.knowledgeStore()
        return (store, tmpDir.path)
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func seed(
        _ store: MCPDataStore,
        id: String,
        title: String,
        type: StudioSourceType,
        group: String? = nil,
        sortIndex: Int? = nil,
        content: String? = "Some readable narration text for \(UUID().uuidString)."
    ) throws {
        var article = StudioArticle(
            url: "https://example.com/\(id)",
            title: title,
            sourceType: type,
            parentGroup: group,
            id: id
        )
        article.state = .ready
        article.content = content
        article.courseSortIndex = sortIndex
        try store.knowledgeStore().saveSource(article)
    }

    @Test("the three audio tools are registered with the right impact hints")
    func toolsAreRegistered() throws {
        let names = Set(MCPToolRegistry.shared.tools.map(\.name))
        #expect(names.contains("generate_source_audio"))
        #expect(names.contains("get_source_audio_status"))
        #expect(names.contains("cancel_source_audio_generation"))

        let generate = MCPToolRegistry.annotations(for: "generate_source_audio")
        #expect(generate["readOnlyHint"] as? Bool == false)
        #expect(generate["destructiveHint"] as? Bool == false)
        // It sends narration to a metered provider.
        #expect(generate["openWorldHint"] as? Bool == true)

        let status = MCPToolRegistry.annotations(for: "get_source_audio_status")
        #expect(status["readOnlyHint"] as? Bool == true)

        let cancel = MCPToolRegistry.annotations(for: "cancel_source_audio_generation")
        #expect(cancel["readOnlyHint"] as? Bool == false)
        #expect(cancel["destructiveHint"] as? Bool == false)

        let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "generate_source_audio" })
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == Set([
            "source_ids", "book_ids", "source_types", "confirm_cost",
            "allow_unsupported_languages", "approved_spend_usd",
        ]))
    }

    @Test("source types are validated and audio-native types are refused by name")
    func sourceTypeParsing() throws {
        #expect(try MCPDataStore.audioGenerationSourceTypes(from: ["book", "Book ", "article"]) == [.book, .article])
        // The schema advertises `x_post`; the model spells it `xPost`. Both are
        // the same family, and neither may be refused as unknown.
        #expect(try MCPDataStore.audioGenerationSourceTypes(from: ["x_post", "xPost"]) == [.xPost])
        #expect(throws: MCPError.self) { try MCPDataStore.audioGenerationSourceTypes(from: ["slack"]) }
        #expect(throws: MCPError.self) { try MCPDataStore.audioGenerationSourceTypes(from: ["podcast"]) }
        #expect(throws: MCPError.self) { try MCPDataStore.audioGenerationSourceTypes(from: ["video"]) }
        #expect(throws: MCPError.self) { try MCPDataStore.audioGenerationSourceTypes(from: ["novel"]) }
    }

    @Test("a call that selects nothing is refused before touching the library")
    func emptySelectionIsRefused() async throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        await #expect(throws: MCPError.self) {
            try await store.generateSourceAudio(
                sourceIDs: [" "], bookIDs: [], sourceTypeNames: [],
                confirmCost: false, allowUnsupportedLanguages: false
            )
        }
    }

    @Test("a book expands to its chapters in reading order and every book means every book")
    func bookExpansion() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        try seed(store, id: "ch2", title: "Chapter 2", type: .book, group: "book-a", sortIndex: 2)
        try seed(store, id: "ch1", title: "Chapter 1", type: .book, group: "book-a", sortIndex: 1)
        try seed(store, id: "ch3", title: "Chapter 3", type: .book, group: "book-a", sortIndex: 3)
        try seed(store, id: "other1", title: "Only chapter", type: .book, group: "book-b", sortIndex: 1)
        try seed(store, id: "art", title: "An article", type: .article)

        let plan = try store.planSourceAudioGeneration(
            sourceIDs: [],
            bookIDs: ["book-a"],
            sourceTypes: [],
            activeSourceIDs: ["ch3"],
            hasCachedAudio: { $0 == "ch2" }
        )
        #expect(plan.pending.map(\.id) == ["ch1"])
        #expect(plan.alreadyReady.map(\.id) == ["ch2"])
        #expect(plan.alreadyActive.map(\.id) == ["ch3"])
        #expect(plan.skipped.isEmpty)
        #expect(plan.characterCounts["ch1"] != nil)
        #expect(plan.unsizedCount == 0)

        let everyBook = try store.planSourceAudioGeneration(
            sourceIDs: [],
            bookIDs: [],
            sourceTypes: [.book],
            activeSourceIDs: [],
            hasCachedAudio: { _ in false }
        )
        #expect(everyBook.pending.map(\.id) == ["ch1", "ch2", "ch3", "other1"])

        // Explicit sources come first, in the caller's order, and are not
        // repeated when a later selector covers them again.
        let mixed = try store.planSourceAudioGeneration(
            sourceIDs: ["art", "ch3"],
            bookIDs: ["book-a"],
            sourceTypes: [.article],
            activeSourceIDs: [],
            hasCachedAudio: { _ in false }
        )
        #expect(mixed.pending.map(\.id) == ["art", "ch3", "ch1", "ch2"])
    }

    @Test("unknown sources and books are named in the error")
    func unknownSelectionsAreNamed() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        try seed(store, id: "ch1", title: "Chapter 1", type: .book, group: "book-a", sortIndex: 1)

        #expect(throws: MCPError.self) {
            try store.planSourceAudioGeneration(
                sourceIDs: ["nope"], bookIDs: [], sourceTypes: [], activeSourceIDs: [],
                hasCachedAudio: { _ in false }
            )
        }
        do {
            _ = try store.planSourceAudioGeneration(
                sourceIDs: [], bookIDs: ["book-z"], sourceTypes: [], activeSourceIDs: [],
                hasCachedAudio: { _ in false }
            )
            Issue.record("expected an error for an unknown book")
        } catch {
            #expect(error.localizedDescription.contains("book-z"))
        }
    }

    @Test("a source text-to-speech cannot narrate is skipped with a reason instead of failing the batch")
    func unnarratableSourceIsSkipped() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        // A podcast has its own audio; naming it explicitly is a skip, not an error.
        try seed(store, id: "pod", title: "Episode", type: .podcast)
        try seed(store, id: "full", title: "Full", type: .article)

        let plan = try store.planSourceAudioGeneration(
            sourceIDs: ["pod", "full"], bookIDs: [], sourceTypes: [], activeSourceIDs: [],
            hasCachedAudio: { _ in false }
        )
        #expect(plan.pending.map(\.id) == ["full"])
        #expect(plan.skipped.map(\.sourceID) == ["pod"])
        #expect(plan.skipped.first?.reason.contains("own audio") == true)
    }

    @Test("status and cancel answer for an idle queue")
    func idleQueueStatusAndCancel() async throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        try seed(store, id: "art", title: "An article", type: .article)

        let status = try await store.getSourceAudioStatus(sourceIDs: ["art", "missing"])
        let payload = try #require(JSONSerialization.jsonObject(with: Data(status.utf8)) as? [String: Any])
        let sources = try #require(payload["sources"] as? [[String: Any]])
        #expect(sources.count == 2)
        #expect(sources[0]["found"] as? Bool == true)
        #expect(sources[0]["has_audio"] as? Bool == false)
        #expect(sources[1]["found"] as? Bool == false)

        await #expect(throws: MCPError.self) {
            try await store.cancelSourceAudioGeneration(sourceIDs: [], all: false)
        }
        let cancelled = try await store.cancelSourceAudioGeneration(sourceIDs: ["art"], all: false)
        let cancelPayload = try #require(JSONSerialization.jsonObject(with: Data(cancelled.utf8)) as? [String: Any])
        #expect(cancelPayload["cancelled_count"] as? Int == 0)
        #expect(cancelPayload["not_active_source_ids"] as? [String] == ["art"])
    }
}

#endif
