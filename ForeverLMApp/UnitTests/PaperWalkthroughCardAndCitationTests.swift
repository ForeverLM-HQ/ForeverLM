// Walkthrough figure mention, card picture and cited work tests.

import Foundation
import PDFKit
import SQLite3
import Testing
@testable import ForeverLM

// MARK: - Figure mentions

@Suite("Walkthrough figure mention")
struct PaperFigureMentionTests {

    @Test("A citation's panels are read as papers print them: glued, bracketed, listed, ranged, in one case; an article 'a' is not a panel")
    func panelsCited() {
        let text = """
        Sodium rose within minutes (Fig. 1a–c). Pressure fell with PAB (Fig. 1(d)). Both were repeated in Figs. 1E and F. \
        In Fig. 1G, a decrease followed. Figure 12 is not this figure. See Fig. 1 for the design.
        """
        #expect(PaperFigureMention.sentence(citing: "Figure 1", panel: "b", in: text) == "Sodium rose within minutes (Fig. 1a–c).")
        #expect(PaperFigureMention.sentence(citing: "Figure 1", panel: "D", in: text) == "Pressure fell with PAB (Fig. 1(d)).")
        #expect(PaperFigureMention.sentence(citing: "Figure 1", panel: "f", in: text) == "Both were repeated in Figs. 1E and F.")
        #expect(PaperFigureMention.sentence(citing: "Figure 1", panel: "g", in: text) == "In Fig. 1G, a decrease followed.")
        // No sentence cites h: the figure's own citation stands in.
        #expect(PaperFigureMention.sentence(citing: "Figure 1", panel: "h", in: text) == "See Fig. 1 for the design.")
        // The figure itself: the first citation.
        #expect(PaperFigureMention.sentence(citing: "Figure 1", panel: nil, in: text) == "Sodium rose within minutes (Fig. 1a–c).")
        #expect(PaperFigureMention.sentence(citing: "Figure 12", panel: nil, in: text) == "Figure 12 is not this figure.")
        #expect(PaperFigureMention.sentence(citing: "Extended Data Figure 1", panel: nil, in: text) == nil)
        // "a" after a comma is the article, not panel a, unless the list closes on it.
        let article = "In Fig. 1G, a decrease followed. Panel a is in Fig. 1a. Then Fig. 1B, A and C together."
        #expect(PaperFigureMention.sentence(citing: "Figure 1", panel: "a", in: article) == "Panel a is in Fig. 1a.")
        // A list keeps one case: "1B, A" is B and A; "1G, a" is G alone.
        #expect(PaperFigureMention.sentence(citing: "Figure 1", panel: "c", in: article) == "Then Fig. 1B, A and C together.")
        #expect(PaperFigureMention.sentence(citing: "Figure 1", panel: "a", in: "See Fig. 1B, A and C.") == "See Fig. 1B, A and C.")
    }

    @Test("Sentences end at a stop before a capital, and not at an abbreviation, an initial, a decimal or a citation")
    func sentences() {
        let text = """
        Cells were treated as in ref. 12 and Smith et al. (2019). ATP fell by 40% (p < 0.05). J. Doe measured it. \
        The U.S. data agree. Fig. 3 shows it; see e.g. Figure 4. Is that all? Yes.
        """
        #expect(PaperFigureMention.sentences(in: text) == [
            "Cells were treated as in ref. 12 and Smith et al. (2019).",
            "ATP fell by 40% (p < 0.05).",
            "J. Doe measured it.",
            "The U.S. data agree.",
            "Fig. 3 shows it; see e.g. Figure 4.",
            "Is that all?",
            "Yes.",
        ])
        // A word the column broke closes up; a hyphen before a capital stays; a sentence over the length is passed over.
        let broken = "Sleep depri-\nvation raised Na+-\nATPase activity (Fig. 2a).\nThe rest follows."
        #expect(PaperFigureMention.sentence(citing: "Figure 2", panel: "a", in: broken) == "Sleep deprivation raised Na+-ATPase activity (Fig. 2a).")
        let long = (0..<130).map { _ in "word" }.joined(separator: " ") + " (Fig. 2a). Short one (Fig. 2a)."
        #expect(PaperFigureMention.sentence(citing: "Figure 2", panel: "a", in: long) == "Short one (Fig. 2a).")
        #expect(PaperFigureMention.sentence(citing: "Figure 2", panel: "a", in: "") == nil)
        #expect(PaperFigureMention.sentence(citing: "Figure", panel: "a", in: "Fig. 2a") == nil)
    }
}

// MARK: - Schema 131: lessons become walkthroughs

// MARK: - Card pictures and animation cards

@Suite("Walkthrough card pictures")
struct PaperWalkthroughCardPictureTests {
    private func walk(_ steps: [PaperWalkthroughStep], chapters: [PaperWalkthroughChapter]? = nil, subject: PaperWalkthrough.Subject = .source) -> PaperWalkthrough {
        PaperWalkthrough(sourceID: "s", sourceSHA256: "sha", subject: subject, title: "W", steps: steps, chapters: chapters, author: .app)
    }

    @Test("A step's animation is dealt as a card of its own: after the points and before the question, after a question step's question, never on an animation walk")
    func animationHasItsOwnCard() {
        let quiz = PaperWalkthroughQuiz(question: "Where does the charge go?", answer: "Into ΔpH.", keyPoints: ["ΔpH"])
        let explained = PaperWalkthroughStep(
            id: "a", kind: .explain, title: "The pump", body: "",
            animationHTML: "<html></html>", quiz: quiz,
            beats: [PaperWalkthroughBeat(text: "One."), PaperWalkthroughBeat(text: "Two.")]
        )
        let asked = PaperWalkthroughStep(id: "b", kind: .quiz, title: "Guess", body: "", animationHTML: "<html></html>", quiz: quiz)
        let plain = PaperWalkthroughStep(id: "c", kind: .explain, title: "Plain", body: "Words.")
        let source = walk([explained, asked, plain])
        #expect(source.playableBeats(of: explained).map(\.kind) == [.point, .point, .animation, .question])
        #expect(source.playableBeats(of: asked).map(\.kind) == [.question, .animation])
        #expect(source.playableBeats(of: plain).map(\.kind) == [.point])
        #expect(source.cardCount == 4 + 2 + 1)
        let animationWalk = walk([explained], subject: .animation)
        #expect(animationWalk.playableBeats(of: explained).map(\.kind) == [.point, .point, .question])
    }

    @Test("A card shows the figure its step outlines, else its own picture, else the one before it in its chapter — and borrowing stops at the chapter")
    func picturesAreSharedWithinAChapter() {
        let figure = PaperWalkthroughStep(id: "1", kind: .figure, title: "F", body: "b", anchor: PaperWalkthroughAnchor(figureLabel: "Figure 2", panelLabel: "a", passage: nil, pageNumber: 4))
        let after = PaperWalkthroughStep(id: "2", kind: .explain, title: "E", body: "b", anchor: PaperWalkthroughAnchor(passage: "some words"))
        let named = PaperWalkthroughStep(id: "3", kind: .explain, title: "N", body: "b", picture: PaperWalkthroughPicture(figureLabel: "Figure 1"))
        let drawn = PaperWalkthroughStep(id: "4", kind: .explain, title: "D", body: "b", picture: PaperWalkthroughPicture(brief: "A pump.", imageID: "0123abcd-0000"))
        let waiting = PaperWalkthroughStep(id: "5", kind: .explain, title: "W", body: "b", picture: PaperWalkthroughPicture(brief: "Not drawn yet."))
        let opening = PaperWalkthroughStep(id: "6", kind: .explain, title: "O", body: "b")
        let lonely = PaperWalkthroughStep(id: "7", kind: .explain, title: "L", body: "b")
        let later = PaperWalkthroughStep(id: "8", kind: .figure, title: "G", body: "b", anchor: PaperWalkthroughAnchor(figureLabel: "Figure 3"))
        let chapters = [
            PaperWalkthroughChapter(id: "c1", title: "One", claim: "x", stepIDs: ["1", "2", "3", "4", "5"]),
            PaperWalkthroughChapter(id: "c2", title: "Two", claim: "y", stepIDs: ["6", "8"]),
            PaperWalkthroughChapter(id: "c3", title: "Three", claim: "z", stepIDs: ["7"]),
        ]
        let w = walk([figure, after, named, drawn, waiting, opening, lonely, later], chapters: chapters)
        #expect(w.cardPicture(of: figure) == .anchoredFigure)
        // The passage step borrows the figure step's panel, without its page anchor's passage.
        #expect(w.cardPicture(of: after) == .figure(PaperWalkthroughAnchor(figureLabel: "Figure 2", panelLabel: "a", pageNumber: 4)))
        #expect(w.cardPicture(of: named) == .figure(PaperWalkthroughAnchor(figureLabel: "Figure 1")))
        #expect(w.cardPicture(of: drawn) == .drawn(imageID: "0123abcd-0000", brief: "A pump."))
        // An undrawn brief borrows meanwhile.
        #expect(w.cardPicture(of: waiting) == .drawn(imageID: "0123abcd-0000", brief: "A pump."))
        #expect(w.stepsAwaitingPicture.map(\.id) == ["5"])
        // A chapter's opening step borrows forward within its chapter.
        #expect(w.cardPicture(of: opening) == .figure(PaperWalkthroughAnchor(figureLabel: "Figure 3")))
        // A chapter with no picture lends none and borrows none.
        #expect(w.cardPicture(of: lonely) == nil)
        #expect(walk([after], subject: .animation).cardPicture(of: after) == nil)
    }

    @Test("A picture is checked as an anchor is: its figure against the index, dropped on a figure step, refused on a text source, and its image id by shape")
    func picturesAreValidated() throws {
        var own = step(.figure, title: "Own", figure: "Figure 2", panel: "a")
        own.picture = PaperWalkthroughPicture(figureLabel: "Figure 1")
        var shown = step(.explain, title: "Shown")
        shown.picture = PaperWalkthroughPicture(figureLabel: "Fig. 1", panelLabel: "b", brief: "ignored beside a figure")
        var invented = step(.explain, title: "Invented")
        invented.picture = PaperWalkthroughPicture(figureLabel: "Figure 9")
        var briefed = step(.explain, title: "Briefed")
        briefed.picture = PaperWalkthroughPicture(brief: "Electrons pile up.", imageID: "NOT AN ID")
        let outcome = try PaperWalkthroughValidation.walkthrough(
            title: "Walk", steps: [own, shown, invented, briefed],
            sourceID: "src", sourceSHA256: "sha", figures: figures, text: paperText, author: .assistant
        )
        let steps = outcome.walkthrough.steps
        #expect(steps[0].picture == nil)
        #expect(steps[1].picture == PaperWalkthroughPicture(figureLabel: "Figure 1", panelLabel: "b"))
        #expect(steps[2].picture == nil)
        #expect(steps[3].picture == PaperWalkthroughPicture(brief: "Electrons pile up."))
        #expect(outcome.warnings.contains { $0.contains("Figure 9") })
        #expect(outcome.warnings.contains { $0.contains("not an image id") })

        let text = try PaperWalkthroughValidation.walkthrough(
            title: "Walk", steps: [shown, briefed],
            sourceID: "src", sourceSHA256: "sha", figures: [], allowsFigureAnchors: false, text: paperText, author: .assistant
        )
        #expect(text.walkthrough.steps[0].picture == PaperWalkthroughPicture(brief: "ignored beside a figure"))
        #expect(text.warnings.contains { $0.contains("has no figures") })
    }

    @Test("A draft's picture decodes leniently, round-trips on the record, and a record without one encodes as before")
    func pictureCoding() throws {
        let json = """
        {"title": "T", "steps": [
          {"kind": "explain", "title": "A", "beats": ["x"], "picture": {"brief": ["What it shows.", "Labels."]}},
          {"kind": "explain", "title": "B", "beats": ["y"], "picture": {"figure_label": "Figure 1", "panel_label": "a"}},
          {"kind": "explain", "title": "C", "beats": ["z"], "picture": 3}
        ]}
        """
        let draft = try JSONDecoder().decode(PaperWalkthroughDraft.self, from: Data(json.utf8))
        #expect(draft.steps.map(\.picture) == [
            PaperWalkthroughPicture(brief: "What it shows. Labels."),
            PaperWalkthroughPicture(figureLabel: "Figure 1", panelLabel: "a"),
            nil,
        ])
        let pictured = PaperWalkthroughStep(id: "1", kind: .explain, title: "T", body: "b", picture: PaperWalkthroughPicture(brief: "B", imageID: "0123abcd-0000"))
        let record = walk([pictured, PaperWalkthroughStep(id: "2", kind: .explain, title: "U", body: "c")])
        let encoded = try PaperWalkthroughCoding.json(record)
        #expect(encoded.contains("\"image_id\":\"0123abcd-0000\""))
        #expect(try PaperWalkthroughCoding.walkthrough(fromJSON: encoded).steps == record.steps)
        #expect(!(try PaperWalkthroughCoding.json(walk([PaperWalkthroughStep(id: "2", kind: .explain, title: "U", body: "c")]))).contains("picture"))
    }

    @Test("The run draws each waiting brief once, shares a drawing between steps whose briefs read the same, and saves after each")
    func runDrawsPictures() async throws {
        let one = PaperWalkthroughStep(id: "1", kind: .explain, title: "One", body: "b", picture: PaperWalkthroughPicture(brief: "A pump."))
        let same = PaperWalkthroughStep(id: "2", kind: .explain, title: "Same", body: "b", picture: PaperWalkthroughPicture(brief: "a  PUMP."))
        let other = PaperWalkthroughStep(id: "3", kind: .explain, title: "Other", body: "b", picture: PaperWalkthroughPicture(brief: "A gradient."))
        var walkthrough = walk([one, same, other])
        let drawn = Counter()
        let saves = Counter()
        let failures = try await PaperWalkthroughWriting.drawPictures(
            in: &walkthrough,
            illustrate: { _ in
                let n = await drawn.increment()
                return "0000000\(n)-aaaa"
            },
            save: { _ in _ = await saves.increment() },
            onStage: nil,
            onStepsSaved: nil
        )
        #expect(failures.isEmpty)
        #expect(await drawn.value == 2)
        #expect(await saves.value == 3)
        #expect(walkthrough.steps.map(\.picture?.imageID) == ["00000001-aaaa", "00000001-aaaa", "00000002-aaaa"])
        #expect(walkthrough.stepsAwaitingPicture.isEmpty)
    }

    @Test("The writer is asked for a picture on every card that outlines no figure, and never on a question")
    func writerAsksForPictures() {
        let prompt = Prompts.walkthroughWriter
        #expect(prompt.contains("Every card shows a picture above its point"))
        #expect(prompt.contains("give a quiz step no \"picture\""))
        #expect(prompt.contains("\"picture\": {\"brief\": \"...\"}"))
        let text = PaperWalkthroughWriting.picturePrompt(
            summary: PaperWalkthroughSourceSummary(id: "s", subject: .paper, allowsFigureAnchors: true, title: "MitoSpace", sourceType: "paper"),
            step: PaperWalkthroughStep(id: "1", kind: .explain, title: "Movies", body: "", beats: [PaperWalkthroughBeat(text: "40,000 movies.")], picture: PaperWalkthroughPicture(brief: "A grid of cells."))
        )
        #expect(text.contains("A grid of cells."))
        #expect(text.contains("40,000 movies."))
        #expect(text.contains("Invent no data"))
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}

// MARK: - Cited works

/// A step's cited works (walkthrough-design.md, "2026-09-30: a card shows
/// the work it cites"): what the record keeps, what the validator lets
/// through, what the tutor reads, and how a card finds the work.
@Suite("Walkthrough cited works")
struct PaperWalkthroughCitationTests {

    @Test("A step's cited works round-trip through the record's JSON, and a step without them encodes as it did")
    func roundTrip() throws {
        var cited = step(.explain, title: "The mapmaker", body: "Lerchner argues.")
        cited.id = "s1"
        cited.cites = [
            PaperWalkthroughCitation(title: "The Abstraction Fallacy", authors: "Alexander Lerchner", year: "2026", venue: "PhilArchive", kind: .paper, url: "https://example.org/abstraction-fallacy"),
            PaperWalkthroughCitation(title: "Life Itself", authors: "Robert Rosen", kind: .book, sourceID: "src_rosen"),
        ]
        let data = try JSONEncoder().encode(cited)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"cites\""))
        #expect(json.contains("\"source_id\""))
        let back = try JSONDecoder().decode(PaperWalkthroughStep.self, from: data)
        #expect(back.cites == cited.cites)

        var plain = step(.explain)
        plain.id = "s2"
        #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("cites"))
    }

    @Test("A numeric year reads as its digits, an unknown kind as none, and a malformed list loses only the citations")
    func tolerantDecoding() throws {
        let json = #"{"kind": "explain", "title": "T", "beats": ["x"], "cites": [{"title": "What Is Life?", "authors": "Erwin Schrödinger", "year": 1944, "kind": "monograph"}]}"#
        let draft = try JSONDecoder().decode(PaperWalkthroughDraft.Step.self, from: Data(json.utf8))
        #expect(draft.cites.first?.title == "What Is Life?")
        #expect(draft.cites.first?.year == "1944")
        #expect(draft.cites.first?.kind == nil)
        #expect(PaperWalkthroughValidation.steps(from: PaperWalkthroughDraft(title: "T", steps: [draft])).first?.cites == draft.cites)

        let broken = #"{"kind": "explain", "title": "T", "beats": ["x"], "cites": "Lerchner 2026"}"#
        let kept = try JSONDecoder().decode(PaperWalkthroughDraft.Step.self, from: Data(broken.utf8))
        #expect(kept.title == "T")
        #expect(kept.cites.isEmpty)

        let stored = #"{"id": "s", "kind": "explain", "title": "T", "body": "b", "cites": 3}"#
        #expect(try JSONDecoder().decode(PaperWalkthroughStep.self, from: Data(stored.utf8)).cites.isEmpty)
    }

    @Test("Validation keeps titled works, reads a DOI in its spellings and a library link, drops the walked source and a repeat, and keeps three")
    func validation() throws {
        var cited = step(.explain, title: "Cited", body: "Some words.")
        cited.id = "cited"
        cited.cites = [
            PaperWalkthroughCitation(title: "  The   Abstraction Fallacy ", authors: " Alexander Lerchner ", doi: "https://doi.org/10.5555/ABC.123"),
            PaperWalkthroughCitation(title: "The Abstraction Fallacy, again", doi: "doi:10.5555/abc.123"),
            PaperWalkthroughCitation(title: "", url: "https://example.com/untitled"),
            PaperWalkthroughCitation(title: "Life Itself", url: "https://doi.org/10.7312/rose07564"),
            PaperWalkthroughCitation(title: "The walk's own source", sourceID: "src"),
            PaperWalkthroughCitation(title: "In the library", url: "foreverlm://source/src_held"),
            PaperWalkthroughCitation(title: "Bad address", doi: "not a doi", url: "ftp://example.com/x"),
            PaperWalkthroughCitation(title: "A fifth work", url: "https://example.com/fifth"),
        ]
        let outcome = try PaperWalkthroughValidation.walkthrough(
            title: "Walk", steps: [cited, step(.explain, title: "Two")],
            sourceID: "src", sourceSHA256: "sha", figures: figures, text: paperText, author: .assistant
        )
        let cites = try #require(outcome.walkthrough.steps.first?.cites)
        #expect(cites.map(\.title) == ["The Abstraction Fallacy", "Life Itself", "In the library"])
        #expect(cites[0].doi == "10.5555/abc.123")
        #expect(cites[0].authors == "Alexander Lerchner")
        #expect(cites[1].doi == "10.7312/rose07564")
        #expect(cites[1].url == nil)
        #expect(cites[2].sourceID == "src_held")
        #expect(cites[2].url == nil)
        #expect(outcome.walkthrough.steps[1].cites.isEmpty)
        #expect(outcome.warnings.contains { $0.contains("no title") })
        #expect(outcome.warnings.contains { $0.contains("walks through") })
        #expect(outcome.warnings.contains { $0.contains("not a DOI") })
        #expect(outcome.warnings.contains { $0.contains("not a web address") })
        #expect(outcome.warnings.contains { $0.contains("cites 5 works") })
    }

    @Test("A cited work's address, byline, identity, reference line and Scholar search")
    func presentation() throws {
        let paper = PaperWalkthroughCitation(
            title: "Metabolism–Repair systems",
            authors: "Hofmeyr J-HS; Cornish-Bowden A; Rohwer J",
            year: "2021",
            venue: "Interface Focus",
            doi: "10.1098/rsfs.2020.0077"
        )
        #expect(paper.address?.absoluteString == "https://doi.org/10.1098/rsfs.2020.0077")
        #expect(paper.byline == "Hofmeyr J-HS et al. · Interface Focus · 2021")
        #expect(paper.identityKey == "doi:10.1098/rsfs.2020.0077")
        #expect(paper.referenceLine == "Hofmeyr J-HS, Cornish-Bowden A, Rohwer J. Metabolism–Repair systems. Interface Focus. 2021. doi:10.1098/rsfs.2020.0077")
        #expect(PaperWalkthroughCitation(title: "X", authors: "A; B").byline == "A & B")
        #expect(PaperWalkthroughCitation(title: "X").byline == nil)

        let named = PaperWalkthroughCitation(title: "What Is Life?", authors: "Erwin Schrödinger", year: "1944", kind: .book)
        #expect(named.address == nil)
        #expect(named.identityKey == "title:what is life")
        #expect(named.referenceLine == "Erwin Schrödinger. What Is Life? 1944")
        let search = try #require(named.scholarSearchURL)
        #expect(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "\"What Is Life?\" Erwin Schrödinger")
        #expect(PaperWalkthroughCitation.eyebrow(kind: .book) == "Cited book")
        #expect(PaperWalkthroughCitation.eyebrow(kind: nil) == "Cited work")

        let page = PaperWalkthroughCitation(title: "A post", url: "https://example.com/post")
        #expect(page.identityKey == "url:https://example.com/post")
        #expect(PaperWalkthroughCitation(title: "A post", url: "javascript:alert(1)").address == nil)
    }

    @Test("A step's turn tells the tutor what its card cites")
    func tutorReadsTheCitation() {
        var cited = step(.explain, title: "The mapmaker", body: "Lerchner argues.")
        cited.cites = [PaperWalkthroughCitation(title: "The Abstraction Fallacy", authors: "Alexander Lerchner", year: "2026")]
        let text = WalkthroughStepComposer.markdown(
            step: cited,
            marker: WalkthroughStepTurn.Marker(sourceID: "src", stepID: "s1", index: 0, count: 3),
            lens: nil
        )
        #expect(text.contains("*Cites:* Alexander Lerchner. The Abstraction Fallacy. 2026"))
        #expect(!WalkthroughStepComposer.markdown(
            step: step(.explain),
            marker: WalkthroughStepTurn.Marker(sourceID: "src", stepID: "s2", index: 1, count: 3),
            lens: nil
        ).contains("Cites:"))
    }

    @Test("A card finds the work among the walked source's recorded cited papers by DOI, address, or an exact distinctive title")
    func recordedCitedPaperMatch() {
        let rows = [
            VideoCitedPaper(sourceID: "src", title: "Metabolism-Repair Systems Revisited", doi: "10.1/abc", url: "https://doi.org/10.1/abc", status: .pending),
            VideoCitedPaper(
                sourceID: "src",
                title: "Anticipatory Systems: Philosophical, Mathematical and Methodological Foundations",
                url: "https://link.springer.com/book/10.1007/978-1-4614-1269-4",
                status: .imported,
                importedSourceID: "src_rosen"
            ),
            VideoCitedPaper(sourceID: "src", title: "Introduction", status: .unresolved),
        ]
        #expect(StudioViewModel.recordedCitedPaper(matching: PaperWalkthroughCitation(title: "anything", doi: "10.1/ABC"), in: rows)?.id == rows[0].id)
        #expect(StudioViewModel.recordedCitedPaper(
            matching: PaperWalkthroughCitation(title: "x", url: "https://link.springer.com/book/10.1007/978-1-4614-1269-4"),
            in: rows
        )?.id == rows[1].id)
        #expect(StudioViewModel.recordedCitedPaper(
            matching: PaperWalkthroughCitation(title: "Anticipatory systems — philosophical, mathematical and methodological foundations"),
            in: rows
        )?.id == rows[1].id)
        // Too short a title names nothing.
        #expect(StudioViewModel.recordedCitedPaper(matching: PaperWalkthroughCitation(title: "Introduction"), in: rows) == nil)
        // A citation with an address of its own is never matched by its title.
        #expect(StudioViewModel.recordedCitedPaper(
            matching: PaperWalkthroughCitation(title: "Metabolism-Repair Systems Revisited", url: "https://example.com/other"),
            in: rows
        ) == nil)

        #expect(StudioViewModel.isDistinctiveCitedTitle("the abstraction fallacy"))
        #expect(!StudioViewModel.isDistinctiveCitedTitle("life itself"))
        #expect(StudioViewModel.soleSource(titled: "the abstraction fallacy why ai", among: [(id: "a", title: "The Abstraction Fallacy: why AI"), (id: "b", title: "Other")]) == "a")
        #expect(StudioViewModel.soleSource(titled: "same title said here", among: [(id: "a", title: "Same title said here"), (id: "b", title: "Same Title, Said Here")]) == nil)
    }
}
