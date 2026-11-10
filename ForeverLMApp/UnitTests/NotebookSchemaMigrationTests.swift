import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// The retired word for a notebook ("project") still read where a device or an old payload kept it:
/// a saved window or tab layout still reopens, and a payload saved before
/// the rename reads with this build's keys. Schema 164's storage rename itself went with schema 174's
/// floor.
@Suite("Notebook schema migration", .serialized)
struct NotebookSchemaMigrationTests {
    @Test("A window snapshot written before the rename still reopens its notebook, and a saved Projects tab shows the Space")
    func savedLayoutsStillRead() throws {
        let old = Data(#"{"projectID":"nb-7","showsChat":true,"sourcesCollapsed":false}"#.utf8)
        let workspace = try JSONDecoder().decode(NotebookWorkspace.self, from: old)
        #expect(workspace.notebookID == "nb-7")
        let reencoded = String(decoding: try JSONEncoder().encode(workspace), as: UTF8.self)
        #expect(reencoded.contains("\"notebookID\":\"nb-7\""))
        #expect(!reencoded.contains("projectID"))

        let groups = try #require(StudioCenterTabGroups.fromPersisted(["chat|projects*|reader"]))
        let tabs = groups.groups.flatMap(\.tabs)
        #expect(tabs.contains(.artifacts))
        #expect(groups.groups[0].activeTab == .artifacts, "the retired tab was the active one")
    }

    @Test("A payload saved in iCloud before the rename reads with this build's keys, and nothing else in it changes")
    func retiredPayloadKeys() throws {
        let saved = Data(#"{"goal":{"id":"nb-1","parentProjectID":"nb-0","relatedProjectIDs":["nb-2"],"title":"My project notes","projection":"kept"},"artifact":{"homeProjectID":"nb-1","homeNotebookID":"nb-9"},"byID":{"project-1":1}}"#.utf8)
        let current = RetiredNotebookWording.currentPayload(saved)
        let object = try #require(try JSONSerialization.jsonObject(with: current) as? [String: Any])
        let goal = try #require(object["goal"] as? [String: Any])
        #expect(goal["parentNotebookID"] as? String == "nb-0")
        #expect(goal["relatedNotebookIDs"] as? [String] == ["nb-2"])
        #expect(goal["parentProjectID"] == nil)
        #expect(goal["title"] as? String == "My project notes", "values never change")
        #expect(goal["projection"] as? String == "kept")
        // A key already under its current name wins over its retired twin.
        let artifact = try #require(object["artifact"] as? [String: Any])
        #expect(artifact["homeNotebookID"] as? String == "nb-9")
        #expect(artifact.count == 1)
        #expect((object["byID"] as? [String: Any])?["project-1"] as? Int == 1, "a key that is not an identifier is data")
        let fresh = Data(#"{"goal":{"parentNotebookID":"nb-0"}}"#.utf8)
        #expect(RetiredNotebookWording.currentPayload(fresh) == fresh, "a current payload is returned byte for byte")

        // The kind values an Idea's links and a Direction's home were saved under.
        let kinds = try JSONDecoder().decode([IdeaLinkKind].self, from: Data(#"["project","notebook","goal"]"#.utf8))
        #expect(kinds == [.notebook, .notebook, .goal])
        #expect(try JSONDecoder().decode(DirectionHomeKind.self, from: Data(#""project""#.utf8)) == .notebook)
        #expect(String(decoding: try JSONEncoder().encode([IdeaLinkKind.notebook]), as: UTF8.self) == #"["notebook"]"#)
    }
}
