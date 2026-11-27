import Foundation
import Testing
@testable import ForeverLM

/// The id a team Doc's draft had while members still took drafts (before live team Pages,
/// docs/teams-design.md): one a member took then stays hidden by it. How a body arriving from
/// another Mac merges is `Sync/DocBodyMergeTests`.
@Suite("Team Doc drafts")
struct ArtifactServerMergeTests {

    @Test("A draft of a team Doc has a deterministic hidden id")
    func draftIdentity() {
        let draft = TeamContentIdentity.draftArtifactID(teamID: "team-1", teamArtifactID: "doc_abc")
        #expect(TeamContentIdentity.isDraftArtifactID(draft))
        #expect(draft == TeamContentIdentity.draftArtifactID(teamID: "team-1", teamArtifactID: "doc_abc"))
        #expect(draft != TeamContentIdentity.draftArtifactID(teamID: "team-2", teamArtifactID: "doc_abc"))
        #expect(!TeamContentIdentity.isDraftArtifactID("doc_abc"))
    }
}
