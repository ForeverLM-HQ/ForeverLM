import Foundation
import Testing
@testable import ForeverLM

/// `NotebookMembership`: the one rule for what belongs to a notebook
/// (docs/notebooks-design.md, "Homing"). A filed thing by its home and links,
/// a Goal's filing counting for the Goal's Notebook; a derived thing by its
/// source, a team copy standing for the learner's own row.
@Suite("Notebook membership")
struct NotebookMembershipTests {
    private let day = Date(timeIntervalSince1970: 1_790_000_000)

    private func artifact(home: String?, links: [String] = [], sources: [String] = []) -> ArtifactRecord {
        ArtifactRecord(
            id: UUID().uuidString,
            title: "Doc",
            homeNotebookID: home,
            linkedNotebookIDs: links,
            sourceIDs: sources,
            createdAt: day,
            updatedAt: day
        )
    }

    @Test("A filed thing belongs to the notebooks its home and links name, and to a Goal's Notebook")
    func filedThings() {
        let notebook = NotebookMembership(
            notebookID: "proj-a",
            memberSourceIDs: ["src-1"],
            goalParents: ["goal-in-a": "proj-a", "goal-in-b": "proj-b"]
        )
        #expect(notebook.containsFiled(["proj-a"]))
        #expect(notebook.containsFiled([nil, "proj-b", "proj-a"]))
        #expect(notebook.containsFiled(["goal-in-a"]), "filed under a Goal nested in the notebook")
        #expect(!notebook.containsFiled(["goal-in-b"]))
        #expect(!notebook.containsFiled([nil]), "no home is no notebook")
        #expect(!notebook.containsFiled([]))

        #expect(notebook.contains(artifact(home: "proj-a")))
        #expect(notebook.contains(artifact(home: nil, links: ["proj-c", "proj-a"])))
        #expect(!notebook.contains(artifact(home: "proj-b", links: ["proj-c"])))
        // Citing the notebook's source earns a filed thing nothing.
        #expect(!notebook.contains(artifact(home: nil, sources: ["src-1"])))
    }

    @Test("A filed thing names each notebook once, its home first, even when it links its own home")
    func filedNotebooksOnce() {
        #expect(NotebookMembership.filingNotebookIDs(of: artifact(home: "proj-a", links: ["proj-a", "proj-b", "proj-b"])) == ["proj-a", "proj-b"])
        #expect(NotebookMembership.filingNotebookIDs(of: artifact(home: nil, links: ["proj-b", "proj-b"])) == [nil, "proj-b"])
        #expect(NotebookMembership.filingNotebookIDs(of: artifact(home: nil)) == [nil], "no home is still said as no home")
    }

    @Test("An Idea is filed through its notebook and Goal links only")
    func ideas() {
        let notebook = NotebookMembership(notebookID: "proj-a", memberSourceIDs: [], goalParents: ["goal-1": "proj-a"])
        let byNotebook = IdeaRecord(title: "A", links: [IdeaLink(kind: .notebook, targetID: "proj-a")])
        let byGoal = IdeaRecord(title: "B", links: [IdeaLink(kind: .goal, targetID: "goal-1")])
        let bySourceOnly = IdeaRecord(title: "C", links: [IdeaLink(kind: .source, targetID: "proj-a")])
        #expect(notebook.contains(byNotebook))
        #expect(notebook.contains(byGoal))
        #expect(!notebook.contains(bySourceOnly), "a source link is not a filing, whatever its id")
        #expect(NotebookMembership.filingNotebookIDs(of: bySourceOnly).isEmpty)
    }

    @Test("A course lives in no notebook: it is tied to every notebook that follows it, and to no other")
    func courses() {
        let notebook = NotebookMembership(notebookID: "proj-a", memberSourceIDs: [])
        #expect(notebook.containsCourse(followedBy: ["proj-a"]))
        #expect(notebook.containsCourse(followedBy: ["proj-b", "proj-a"]), "one of several followers")
        #expect(!notebook.containsCourse(followedBy: ["proj-b"]))
        #expect(!notebook.containsCourse(followedBy: []))
    }

    @Test("A derived thing belongs to every notebook holding its source, a team copy included")
    func derivedThings() {
        let personal = NotebookMembership(notebookID: "proj-a", memberSourceIDs: ["src-own", "src-2"])
        #expect(personal.containsDerived(sourceID: "src-own"))
        #expect(!personal.containsDerived(sourceID: "src-elsewhere"))
        #expect(personal.containsDerived(anyOf: ["src-x", "src-2"]))
        #expect(!personal.containsDerived(anyOf: [String]()))

        // A team notebook holds the team's copy; the walkthrough rides the
        // learner's own row at the same address.
        let team = NotebookMembership(
            notebookID: "team-proj",
            memberSourceIDs: ["src-team-copy"],
            sourceAliases: ["src-team-copy": "src-own"]
        )
        #expect(team.sourceIDs == ["src-own"], "pool ids are folded into the learner's rows")
        #expect(team.containsDerived(sourceID: "src-own"))
        #expect(team.containsDerived(sourceID: "src-team-copy"), "the copy's own id answers too")
        #expect(!team.containsDerived(sourceID: "src-2"))
    }

    @Test("The two rules on their own are what the screen-record scope asks")
    func screenRecordScopeAgrees() {
        #expect(NotebookMembership.isFiled(in: "proj", notebookIDs: [nil, "proj"]))
        #expect(!NotebookMembership.isFiled(in: nil, notebookIDs: ["proj"]), "a scope with no notebook holds nothing filed")
        #expect(NotebookMembership.filingNotebookIDs(["goal", nil], goalParents: ["goal": "proj"]) == ["goal", nil, "proj", nil])
        #expect(NotebookMembership.isDerived(sourceID: "copy", from: ["own"], aliases: ["copy": "own"]))

        let cutoff = day
        let scope = ScreenRecordScope(notebookID: "proj", allowedSourceIDs: ["filmed"], cutoff: cutoff)
        let before = cutoff.addingTimeInterval(-60)
        #expect(!scope.allowsItem(createdAt: before, notebookIDs: ["proj"]), "filing never reveals work from before the take")
        #expect(scope.allowsItem(createdAt: before, notebookIDs: ["other"]) == false)
        #expect(!scope.allowsSourceDerived(createdAt: before, sourceID: "filmed"))
        #expect(!scope.allowsSourceDerived(createdAt: before, sourceID: "private"))
    }

    @Test("Suggestions put the notebook holding most of a thing's sources first, then the older")
    func suggestions() {
        let older = day.addingTimeInterval(-86_400)
        let candidates = [
            NotebookMembership.Candidate(notebookID: "few", sourceIDs: ["s1"], createdAt: older),
            NotebookMembership.Candidate(notebookID: "most", sourceIDs: ["s1", "s2", "s3"], createdAt: day),
            NotebookMembership.Candidate(notebookID: "none", sourceIDs: ["s9"], createdAt: older),
            NotebookMembership.Candidate(notebookID: "tie-new", sourceIDs: ["s1", "s2"], createdAt: day),
            NotebookMembership.Candidate(notebookID: "tie-old", sourceIDs: ["s2", "s3"], createdAt: older),
        ]
        let ranked = NotebookMembership.suggestions(for: ["s1", "s2", "s3", "s1"], among: candidates)
        #expect(ranked.map(\.notebookID) == ["most", "tie-old", "tie-new", "few"])
        #expect(ranked.map(\.heldSourceCount) == [3, 2, 2, 1])
        #expect(NotebookMembership.suggestions(for: [], among: candidates).isEmpty)
        #expect(NotebookMembership.suggestions(for: ["s7"], among: candidates).isEmpty, "a notebook holding none is not offered")

        // A team notebook's copy counts for the learner's own source.
        let aliased = NotebookMembership.suggestions(
            for: ["own"],
            among: [.init(notebookID: "team", sourceIDs: ["copy"], createdAt: day)],
            aliases: ["copy": "own"]
        )
        #expect(aliased.map(\.notebookID) == ["team"])
    }

    @Test("A course notebook's id is fixed by the course, so two Macs make one notebook")
    func courseNotebookID() {
        let id = TeamContentIdentity.courseNotebookID(courseID: "course-1")
        #expect(id.hasPrefix("proj_"))
        #expect(id == TeamContentIdentity.courseNotebookID(courseID: "course-1"))
        #expect(id != TeamContentIdentity.courseNotebookID(courseID: "course-2"))
        #expect(id != TeamContentIdentity.assignmentsNotebookID(teamID: "course-1"))
    }
}
