import Foundation
import Testing
@testable import ForeverLM

/// A notebook's outputs, the Studio column's list (`NotebookOutputs`): which
/// records are filed in it, which derived things its sources give it, how
/// the list is ordered, and the words its rows say.
@Suite("Notebook outputs")
struct NotebookOutputsTests {

    private static let day: TimeInterval = 86_400
    private static let base = Date(timeIntervalSince1970: 1_790_000_000)

    private static func at(_ days: Double) -> Date {
        base.addingTimeInterval(days * day)
    }

    /// A record made `made` days after the base and edited `edited` days
    /// after it, filed by `home` and `links`.
    private static func record(
        _ id: String,
        title: String? = nil,
        home: String? = nil,
        links: [String] = [],
        linkedURL: String? = nil,
        kind: ArtifactKind? = nil,
        sourceIDs: [String] = [],
        archived: Bool = false,
        hidden: Bool = false,
        teamID: String? = nil,
        made: Double = 0,
        edited: Double? = nil
    ) -> ArtifactRecord {
        ArtifactRecord(
            id: id,
            title: title ?? id,
            homeNotebookID: home,
            linkedNotebookIDs: links,
            linkedURL: linkedURL,
            teamID: teamID,
            archivedAt: archived ? at(made) : nil,
            hiddenAt: hidden ? at(made) : nil,
            kind: kind,
            sourceIDs: sourceIDs,
            createdAt: at(made),
            updatedAt: at(edited ?? made)
        )
    }

    private static let claudeArtifact = "https://claude.ai/code/artifact/0b2c1f0e-aaaa-bbbb-cccc-0123456789ab"
    private static let googleDoc = "https://docs.google.com/document/d/abc123/edit"

    // MARK: - Membership

    @Test("A record is filed by its home or by a link, and only in that notebook")
    func filedByHomeOrLink() {
        let homed = Self.record("homed", home: "bio")
        let linked = Self.record("linked", links: ["bio"])
        let both = Self.record("both", home: "bio", links: ["bio", "neuro"])
        let elsewhere = Self.record("elsewhere", home: "neuro", links: ["neuro"])
        let unfiled = Self.record("unfiled")
        #expect(NotebookOutputs.isFiled(homed, in: "bio"), "a home whose link an older build trimmed still counts")
        #expect(NotebookOutputs.isFiled(linked, in: "bio"))
        #expect(NotebookOutputs.isFiled(both, in: "bio"))
        #expect(NotebookOutputs.isFiled(both, in: "neuro"), "one record can be in several notebooks")
        #expect(!NotebookOutputs.isFiled(elsewhere, in: "bio"))
        #expect(!NotebookOutputs.isFiled(unfiled, in: "bio"))
    }

    @Test("Archived, hidden and a member's private draft are never listed")
    func listedRecordsOnly() {
        #expect(NotebookOutputs.isListed(Self.record("doc", home: "bio")))
        #expect(!NotebookOutputs.isListed(Self.record("archived", home: "bio", archived: true)))
        #expect(!NotebookOutputs.isListed(Self.record("hidden", home: "bio", hidden: true)))
        #expect(!NotebookOutputs.isListed(Self.record("draft_abc", home: "bio")))

        let outputs = NotebookOutputs.outputs(in: "bio", memberSourceIDs: [], records: [
            Self.record("doc", links: ["bio"]),
            Self.record("archived", links: ["bio"], archived: true),
            Self.record("hidden", links: ["bio"], hidden: true),
            Self.record("draft_member", links: ["bio"]),
            Self.record("other-notebook", links: ["neuro"]),
        ])
        #expect(outputs.map(\.targetID) == ["doc"])
    }

    @Test("Each record takes its kind: an overview by its kind or the library's word, then by its section")
    func recordKinds() {
        let outputs = NotebookOutputs.outputs(
            in: "bio",
            memberSourceIDs: [],
            records: [
                Self.record("doc", links: ["bio"], made: 1),
                Self.record("google", links: ["bio"], linkedURL: Self.googleDoc, made: 2),
                Self.record("site", links: ["bio"], linkedURL: Self.claudeArtifact, made: 3),
                Self.record("animation", links: ["bio"], kind: .animation, made: 4),
                Self.record("overview", home: "bio", links: ["bio"], kind: .audioOverview, sourceIDs: ["s1", "s2"], made: 5),
                Self.record("overview-saved-by-an-older-build", links: ["bio"], made: 6),
            ],
            audioOverviewIDs: ["overview-saved-by-an-older-build"]
        )
        let kinds = Dictionary(uniqueKeysWithValues: outputs.map { ($0.targetID, $0.kind) })
        #expect(kinds == [
            "doc": .doc,
            "google": .doc,
            "site": .site,
            "animation": .animation,
            "overview": .audioOverview,
            "overview-saved-by-an-older-build": .audioOverview,
        ])
        let site = outputs.first { $0.targetID == "site" }
        #expect(site?.linkedKind == .claudeArtifact)
        #expect(site?.symbolName == LinkedPageKind.claudeArtifact.symbolName)
        #expect(outputs.first { $0.targetID == "overview" }?.sourceIDs == ["s1", "s2"])
    }

    @Test("A walkthrough or explainer shows where its source is a member, in every notebook that holds it")
    func derivedFromMemberSources() {
        let walks = [
            NotebookOutputs.Walkthrough(sourceID: "member", title: "Walk of member", date: Self.at(2)),
            NotebookOutputs.Walkthrough(sourceID: "stranger", title: "Walk of stranger", date: Self.at(3)),
        ]
        let explainers = [
            NotebookOutputs.Explainer(id: "explainer-1", explainedSourceID: "member", title: "Explainer: member", date: Self.at(4)),
            NotebookOutputs.Explainer(id: "explainer-2", explainedSourceID: "stranger", title: "Explainer: stranger", date: Self.at(5)),
        ]
        let bio = NotebookOutputs.outputs(
            in: "bio", memberSourceIDs: ["member"], records: [], walkthroughs: walks, explainers: explainers
        )
        #expect(bio.map(\.id) == ["explainer:explainer-1", "walkthrough:member"])
        #expect(bio.first { $0.kind == .walkthrough }?.sourceIDs == ["member"])
        #expect(bio.first { $0.kind == .explainer }?.sourceIDs == ["member"], "an explainer is made from the source it explains")

        let neuro = NotebookOutputs.outputs(
            in: "neuro", memberSourceIDs: ["member", "stranger"], records: [], walkthroughs: walks, explainers: explainers
        )
        #expect(neuro.count == 4, "the same walk and explainer show in a second notebook holding the source")
        #expect(NotebookOutputs.isDerived(fromSource: "member", memberSourceIDs: ["member"]))
        #expect(!NotebookOutputs.isDerived(fromSource: "stranger", memberSourceIDs: ["member"]))
    }

    @Test("A course shows while the notebook follows it")
    func coursesItFollows() {
        let courses = [
            NotebookOutputs.Course(id: "Aging", title: "Systems Aging", sourceIDs: ["l1", "l2"], date: Self.at(1)),
            NotebookOutputs.Course(id: "CS336", title: "Language Models", sourceIDs: ["l3"], date: Self.at(2)),
        ]
        let outputs = NotebookOutputs.outputs(
            in: "bio", memberSourceIDs: [], records: [], courses: courses, linkedCourseIDs: ["Aging"]
        )
        #expect(outputs.map(\.id) == ["course:Aging"])
        #expect(outputs.first?.title == "Systems Aging")
        #expect(outputs.first?.sourceIDs == ["l1", "l2"])
        #expect(NotebookOutputs.isCourseFiled("Aging", linkedCourseIDs: ["Aging"]))
        #expect(!NotebookOutputs.isCourseFiled("CS336", linkedCourseIDs: ["Aging"]))
    }

    @Test("An overview being written leads, only in its own notebook, and once saved it is listed once")
    func pendingRuns() {
        let runs = [
            NotebookOutputs.Run(id: "run-bio", notebookID: "bio", title: "Bioenergetics", startedAt: Self.at(1)),
            NotebookOutputs.Run(id: "run-neuro", notebookID: "neuro", title: "Neuroscience", startedAt: Self.at(9)),
            NotebookOutputs.Run(id: "saved", notebookID: "bio", title: "Bioenergetics", startedAt: Self.at(1)),
        ]
        let outputs = NotebookOutputs.outputs(
            in: "bio",
            memberSourceIDs: [],
            records: [
                Self.record("newer-doc", links: ["bio"], made: 5),
                Self.record("saved", home: "bio", links: ["bio"], kind: .audioOverview, made: 2),
            ],
            runs: runs
        )
        #expect(outputs.map(\.id) == ["audioOverview:run-bio", "doc:newer-doc", "audioOverview:saved"])
        #expect(outputs.first?.isPending == true, "a run leads even beside a newer record")
        #expect(outputs.last?.isPending == false, "the saved record stands in for its run")
        #expect(NotebookOutputs.isRun(runs[0], for: "bio"))
        #expect(!NotebookOutputs.isRun(runs[1], for: "bio"))
    }

    // MARK: - Ordering

    @Test("Newest first by when each was made, not edited; undated last; ties by title, then id")
    func ordering() {
        let outputs = NotebookOutputs.outputs(
            in: "bio",
            memberSourceIDs: ["s1"],
            records: [
                // Made first and edited last: an edit never moves it up.
                Self.record("old-but-edited", links: ["bio"], made: 1, edited: 30),
                Self.record("newest", links: ["bio"], made: 10),
                Self.record("b-tie", title: "Beta", links: ["bio"], made: 5),
                Self.record("a-tie", title: "Alpha", links: ["bio"], made: 5),
            ],
            courses: [NotebookOutputs.Course(id: "undated", title: "Course with no sources here", sourceIDs: [], date: nil)],
            linkedCourseIDs: ["undated"],
            walkthroughs: [NotebookOutputs.Walkthrough(sourceID: "s1", title: "Walk", date: Self.at(7))]
        )
        #expect(outputs.map(\.targetID) == ["newest", "s1", "a-tie", "b-tie", "old-but-edited", "undated"])

        // The order never depends on the input's order.
        let reversed = NotebookOutputs.ordered(outputs.reversed())
        #expect(reversed.map(\.id) == outputs.map(\.id))
    }

    @Test("Each output is listed once")
    func uniqueIDs() {
        let duplicate = Self.record("doc", home: "bio", links: ["bio"])
        let outputs = NotebookOutputs.outputs(in: "bio", memberSourceIDs: [], records: [duplicate, duplicate])
        #expect(outputs.count == 1)
        #expect(Set(outputs.map(\.id)).count == outputs.count)
    }

    // MARK: - Words

    @Test("A row says how many sources, or nothing for none")
    func sourcesLabel() {
        #expect(NotebookOutputs.sourcesLabel(count: 0) == nil)
        #expect(NotebookOutputs.sourcesLabel(count: 1) == "1 source")
        #expect(NotebookOutputs.sourcesLabel(count: 12) == "12 sources")
    }

    @Test("The recipe says what it was made from and the words it was made to")
    func recipe() {
        #expect(NotebookOutputs.recipe(sourceCount: 3, instruction: "Questions for Thursday's call")
            == "Made from 3 sources · Questions for Thursday's call")
        #expect(NotebookOutputs.recipe(sourceCount: 1, instruction: nil) == "Made from 1 source")
        #expect(NotebookOutputs.recipe(sourceCount: 0, instruction: "  A briefing  ") == "A briefing")
        #expect(NotebookOutputs.recipe(sourceCount: 0, instruction: "   ") == nil)
        #expect(NotebookOutputs.recipe(sourceCount: 0, instruction: nil) == nil)
    }

    @Test("A video shows where the notebook holds it as a source, and nowhere else")
    func videoOverviewsAreMemberSources() {
        let videos = [
            NotebookOutputs.VideoOverview(sourceID: "held", title: "Unlocking SLC25A34 Switch", date: Self.at(2)),
            NotebookOutputs.VideoOverview(sourceID: "library-only", title: "Someone else's film", date: Self.at(3)),
        ]
        let bio = NotebookOutputs.outputs(in: "bio", memberSourceIDs: ["held"], records: [], videoOverviews: videos)
        #expect(bio.map(\.id) == ["videoOverview:held"])
        #expect(bio.first?.kindLabel == "Video overview")
        #expect(bio.first?.title == "Unlocking SLC25A34 Switch")
        let neuro = NotebookOutputs.outputs(in: "neuro", memberSourceIDs: [], records: [], videoOverviews: videos)
        #expect(neuro.isEmpty)
    }

    private static func deck(_ sourceID: String, _ cards: [(at: Double, requested: Bool, origin: MemoryCardOrigin?)]) -> MemoryCardDraftDeck {
        MemoryCardDraftDeck(
            deckID: MemoryCard.draftDeckID(sourceID: sourceID),
            sourceID: sourceID,
            deck: FlashcardDeck(title: sourceID, cards: cards.enumerated().map { index, card in
                Flashcard(
                    id: "\(sourceID)-\(index)", front: "Q", back: "A", sourceID: sourceID,
                    draftedAt: at(card.at), origin: card.origin, isRequested: card.requested
                )
            })
        )
    }

    @Test("A Make Cards run is the requested cards ForeverLM drafted at one time on the notebook's sources, newest first")
    func cardRuns() {
        let decks = [
            Self.deck("a", [(1, true, .drafted), (1, true, nil), (3, true, .drafted), (2, false, .drafted)]),
            Self.deck("b", [(1, true, .drafted), (4, true, .assistant)]),
            Self.deck("elsewhere", [(1, true, .drafted), (5, true, .drafted)]),
        ]
        let runs = NotebookOutputs.cardRuns(decks, memberSourceIDs: ["a", "b"])
        #expect(runs.map(\.draftedAt) == [Self.at(3), Self.at(1)], "background drafts, an assistant's cards and other sources' runs are no runs here")
        #expect(runs.map(\.cardCount) == [1, 3])
        #expect(runs.last?.sourceIDs == ["a", "b"])

        let outputs = NotebookOutputs.outputs(in: "nb", memberSourceIDs: ["a", "b"], records: [], cardRuns: runs)
        #expect(outputs.map(\.kind) == [.cards, .cards])
        #expect(outputs.first?.cardCount == 1)
        #expect(outputs.last?.sourceIDs == ["a", "b"])
        #expect(outputs.last?.title == "Cards")
        #expect(NotebookOutputs.cardRunLine(cardCount: 3, sourceCount: 2) == "3 drafted from 2 sources")
        #expect(NotebookOutputs.cardRunLine(cardCount: 1, sourceCount: 1) == "1 drafted from 1 source")
        #expect(NotebookOutputs.cardRunLine(cardCount: 4, sourceCount: 0) == "4 drafted")
    }

    @Test("A picture is the notebook's output when it lives in that notebook, by its date among the rest")
    func pictures() {
        let pictures = [
            NotebookOutputs.Picture(imageID: "p1", notebookID: "nb", title: "Cristae", date: Self.at(2)),
            NotebookOutputs.Picture(imageID: "p2", notebookID: "other", title: "Elsewhere", date: Self.at(3)),
            NotebookOutputs.Picture(imageID: "p3", notebookID: nil, title: "Loose", date: Self.at(4)),
        ]
        let outputs = NotebookOutputs.outputs(
            in: "nb", memberSourceIDs: [], records: [Self.record("doc", home: "nb", made: 1)], pictures: pictures
        )
        #expect(outputs.map(\.id) == ["picture:p1", "doc:doc"])
        #expect(outputs.first?.kindLabel == "Picture")
    }

    @Test("A source's narration shows in every notebook holding the source, and nowhere else")
    func narrations() {
        // The product owner, 2026-10-06: the one-off things are "more one off per
        // notebook" — a narration is listed in a notebook's Studio alone.
        let narrations = [
            NotebookOutputs.Narration(sourceID: "member", title: "Cristae remodelling", date: Self.at(3)),
            NotebookOutputs.Narration(sourceID: "stranger", title: "Elsewhere", date: Self.at(4)),
        ]
        let bio = NotebookOutputs.outputs(
            in: "bio",
            memberSourceIDs: ["member"],
            records: [Self.record("doc", home: "bio", made: 1)],
            narrations: narrations
        )
        #expect(bio.map(\.id) == ["narration:member", "doc:doc"])
        #expect(bio.first?.kindLabel == "Narration")
        #expect(bio.first?.sourceIDs == ["member"], "a narration is made from the source it reads")

        let neuro = NotebookOutputs.outputs(
            in: "neuro", memberSourceIDs: ["member", "stranger"], records: [], narrations: narrations
        )
        #expect(neuro.map(\.id) == ["narration:stranger", "narration:member"])
    }

    @Test("Every kind leads with a glyph and a word")
    func glyphsAndWords() {
        for kind in NotebookOutput.Kind.allCases {
            let output = NotebookOutput(kind: kind, targetID: "x", title: "X", sourceIDs: [], date: nil)
            #expect(!output.symbolName.isEmpty, "\(kind)")
            #expect(!output.kindLabel.isEmpty, "\(kind)")
        }
        let course = NotebookOutput(kind: .course, targetID: "c", title: "C", sourceIDs: [], date: nil)
        #expect(course.symbolName == "graduationcap", "the Courses rail row's mark")
        #expect(course.id == "course:c")
    }
}
