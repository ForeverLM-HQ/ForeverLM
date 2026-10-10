import Foundation
import Testing
@testable import ForeverLM

/// The sensemaking shapes' local tables (schema 165, docs/sensemaking-design.md):
/// an Atlas's body, a source's reading levels and a source card's written
/// faces, each written whole and read back whole.
@Suite("Sensemaking store")
struct SensemakingStoreTests {

    @Test("A fresh store has the three tables and is at the current schema")
    func freshStoreHasTheTables() throws {
        let store = try KnowledgeStore(inMemory: true)
        var names: Set<String> = []
        try store.query("SELECT name FROM sqlite_master WHERE type = 'table'") { stmt in
            if let name = store.string(stmt, 0) { names.insert(name) }
        }
        #expect(names.isSuperset(of: ["atlases", "source_levels", "source_faces"]))
        #expect(KnowledgeStore.schemaVersion == 168)
    }

    @Test("An Atlas row is saved, replaced, listed newest first and deleted")
    func atlasRows() throws {
        let store = try KnowledgeStore(inMemory: true)
        let early = Date(timeIntervalSinceReferenceDate: 1_000)
        let late = Date(timeIntervalSinceReferenceDate: 2_000)
        try store.saveAtlasRow(AtlasRow(id: "a1", topic: "Mitophagy", notebookID: nil, scopeJSON: "{}", payloadJSON: "{\"v\":1}", createdAt: early, updatedAt: early))
        try store.saveAtlasRow(AtlasRow(id: "a2", topic: "Membrane potential", notebookID: "nb1", scopeJSON: "{}", payloadJSON: "{}", createdAt: late, updatedAt: late))
        #expect(try store.atlasRows().map(\.id) == ["a2", "a1"])

        try store.saveAtlasRow(AtlasRow(id: "a1", topic: "Mitophagy, PINK1 and Parkin", notebookID: nil, scopeJSON: "{}", payloadJSON: "{\"v\":2}", createdAt: late, updatedAt: Date(timeIntervalSinceReferenceDate: 3_000)))
        let replaced = try #require(try store.atlasRow(id: "a1"))
        #expect(replaced.topic == "Mitophagy, PINK1 and Parkin")
        #expect(replaced.payloadJSON == "{\"v\":2}")
        #expect(replaced.createdAt == early, "a rewrite keeps the day it was made")
        #expect(try store.atlasRows().map(\.id) == ["a1", "a2"])

        try store.deleteAtlasRow(id: "a1")
        #expect(try store.atlasRow(id: "a1") == nil)
        #expect(try store.atlasRows().map(\.id) == ["a2"])
    }

    @Test("Reading levels are kept per source with the text they were written from")
    func sourceLevelsRows() throws {
        let store = try KnowledgeStore(inMemory: true)
        let row = SourceLevelsRow(sourceID: "s1", contentSHA256: "abc", payloadJSON: "{\"gist\":\"x\"}", model: "m", createdAt: Date(timeIntervalSinceReferenceDate: 5))
        try store.saveSourceLevelsRow(row)
        #expect(try store.sourceLevelsRow(sourceID: "s1") == row)
        var newer = row
        newer.contentSHA256 = "def"
        try store.saveSourceLevelsRow(newer)
        #expect(try store.sourceLevelsRow(sourceID: "s1")?.contentSHA256 == "def")
        try store.deleteSourceLevelsRow(sourceID: "s1")
        #expect(try store.sourceLevelsRow(sourceID: "s1") == nil)
    }

    @Test("Written faces round-trip, by source")
    func sourceFacesRows() throws {
        let store = try KnowledgeStore(inMemory: true)
        let at = Date(timeIntervalSinceReferenceDate: 9)
        try store.saveSourceFacesRows([
            SourceFacesRow(sourceID: "s1", fingerprint: "f1", far: "PINK1 marks damage", mid: "PINK1 builds up on depolarized mitochondria.", near: ["Question", "Finding"], model: nil, createdAt: at),
            SourceFacesRow(sourceID: "s2", fingerprint: "f2", far: "Voltage dyes", mid: "TMRM reads membrane potential.", near: [], model: "m", createdAt: at),
        ])
        let all = try store.sourceFacesRows()
        #expect(all.count == 2)
        #expect(all["s1"]?.near == ["Question", "Finding"])
        let some = try store.sourceFacesRows(sourceIDs: ["s2", "missing"])
        #expect(Array(some.keys) == ["s2"])
        #expect(try store.sourceFacesRows(sourceIDs: []).isEmpty)
    }
}
