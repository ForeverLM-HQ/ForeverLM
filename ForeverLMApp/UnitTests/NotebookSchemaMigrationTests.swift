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

    @Test("The kind values an Idea's links and a Direction's home were saved under read as notebook")
    func retiredKindValues() throws {
        let kinds = try JSONDecoder().decode([IdeaLinkKind].self, from: Data(#"["project","notebook","goal"]"#.utf8))
        #expect(kinds == [.notebook, .notebook, .goal])
        #expect(try JSONDecoder().decode(DirectionHomeKind.self, from: Data(#""project""#.utf8)) == .notebook)
        #expect(String(decoding: try JSONEncoder().encode([IdeaLinkKind.notebook]), as: UTF8.self) == #"["notebook"]"#)
    }
}
