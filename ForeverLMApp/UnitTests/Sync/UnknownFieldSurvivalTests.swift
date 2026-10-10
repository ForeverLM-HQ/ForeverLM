import Foundation
import Testing
@testable import ForeverLM

/// Version skew (§6.5, D31): a client writes by patching the raw payload it holds, so every field,
/// map key, set element, stamp and top-level key a newer client wrote survives its write.
@Suite("Unknown field survival")
struct UnknownFieldSurvivalTests {
    /// A Notebook as a newer client wrote it: an unknown field, unknown keys inside a known map and
    /// set, an unknown enum value, and an unknown top-level key.
    static let raw = #"""
    {"env":1,"type":"Notebook","id":"nb1","rev":7,"saltID":"3fa9c2d1","future":{"kept":[1,2]},
     "fields":{"title":"Cells","status":"hibernating","futureField":{"deep":[true,null]},
               "researchQuestions":{"q1":{"text":"Why?","futureKey":3}},"relatedNotebookIDs":{"nbX":true}},
     "stamps":{"title":"L1759400000000.0000.m7x2c2aa","status":"L1759400000000.0000.m7x2c2aa",
               "futureField":"S1759400000000.0000.m7x2c2aa","researchQuestions":{"q1":"L1759400000000.0000.m7x2c2aa"},
               "relatedNotebookIDs":{"nbX":"L1759400000000.0000.m7x2c2aa"}}}
    """#

    static let stamp = SyncStamp("L1759400009000.0000.k3f7ab2q")!

    @Test("A patch of known fields leaves every unknown field, key, element, stamp and top-level key as it was")
    func patchKeepsWhatItDoesNotKnow() throws {
        let original = try SyncEnvelope(storedPayload: Data(Self.raw.utf8))
        var patched = original
        try patched.apply(RecordPatch(.notebook, id: "nb1", changes: [
            "title": .value("Cells, revised"),
            "researchQuestions": .elements(["q2": ["text": "How?"]]),
            "relatedNotebookIDs": .elements(["nbY": true]),
        ])) { _, _, _ in Self.stamp }
        #expect(patched.fields["futureField"] == original.fields["futureField"])
        #expect(patched.stamps["futureField"] == original.stamps["futureField"])
        #expect(patched.fields["status"] == "hibernating")
        #expect(patched.fields["researchQuestions"]?["q1"] == ["text": "Why?", "futureKey": 3])
        #expect(patched.fields["researchQuestions"]?["q2"] == ["text": "How?"])
        #expect(patched.fields["relatedNotebookIDs"] == ["nbX": true, "nbY": true])
        #expect(patched.extra == ["future": ["kept": [1, 2]]])
        #expect(patched.rev == SyncSchema.schemaRevision)
        // Through the bytes and back, nothing is lost either.
        let reread = try SyncEnvelope(storedPayload: try patched.storedPayload())
        #expect(reread == patched)
    }

    @Test("A merge keeps the server's unknown fields and keys, and a client with an older view keeps them through its write")
    func mergeKeepsWhatItDoesNotKnow() throws {
        let server = try SyncEnvelope(storedPayload: Data(Self.raw.utf8))
        // An older client's base is the record without the newer fields; its edit is to the title only.
        var base = server
        base.fields["futureField"] = nil
        base.stamps["futureField"] = nil
        var local = base
        try local.apply(RecordPatch(.notebook, id: "nb1", changes: ["title": .value("Renamed")])) { _, _, _ in Self.stamp }
        let merged = FieldMerge.merge(server: server, local: local, base: base).merged
        #expect(merged.fields["title"] == "Renamed")
        #expect(merged.fields["futureField"] == server.fields["futureField"])
        #expect(merged.fields["status"] == "hibernating")
        #expect(merged.extra == server.extra)
    }

    @Test("A record of a type this build does not know reads and writes back unchanged")
    func unknownType() throws {
        let raw = #"{"env":1,"type":"Hologram","id":"h1","rev":9,"saltID":"3fa9c2d1","fields":{"depth":3},"stamps":{"depth":"L1759400000000.0000.m7x2c2aa"}}"#
        let envelope = try SyncEnvelope(storedPayload: Data(raw.utf8))
        #expect(envelope.recordType == nil)
        #expect(try SyncJSON(parsing: try envelope.storedPayload()) == (try SyncJSON(parsing: Data(raw.utf8))))
    }

    @Test("A patch cannot write a field this build does not know")
    func noUnknownWrites() throws {
        var envelope = try SyncEnvelope(storedPayload: Data(Self.raw.utf8))
        #expect(throws: RecordPatchError.unknownField("futureField")) {
            try envelope.apply(RecordPatch(.notebook, id: "nb1", changes: ["futureField": .value(1)])) { _, _, _ in Self.stamp }
        }
    }
}
