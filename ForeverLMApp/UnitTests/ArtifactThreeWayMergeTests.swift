import Foundation
import Testing
@testable import ForeverLM

/// Two team members editing one Doc at once: what merges on its own and what
/// is left for the writer to settle.
@Suite("Artifact three-way merge")
struct ArtifactThreeWayMergeTests {
    private let base = """
    # Landscape

    Intro paragraph.

    ## Mechanism

    Line about the mechanism.

    ## Evidence

    Line about the evidence.
    """

    @Test("Edits to different paragraphs merge on their own")
    func disjointEditsMerge() {
        let mine = base.replacingOccurrences(of: "Intro paragraph.", with: "Intro paragraph, sharpened.")
        let theirs = base.replacingOccurrences(of: "Line about the evidence.", with: "Line about the evidence, with a citation.")
        let expected = base
            .replacingOccurrences(of: "Intro paragraph.", with: "Intro paragraph, sharpened.")
            .replacingOccurrences(of: "Line about the evidence.", with: "Line about the evidence, with a citation.")
        #expect(ArtifactThreeWayMerge.merge(base: base, mine: mine, theirs: theirs) == .merged(expected))
    }

    @Test("An insertion on one side and a deletion far away on the other both land")
    func insertionAndDeletionMerge() {
        let mine = base.replacingOccurrences(of: "# Landscape\n", with: "# Landscape\n\nA new deck line.\n")
        let theirs = base.replacingOccurrences(of: "\n## Evidence\n\nLine about the evidence.", with: "")
        let expected = mine.replacingOccurrences(of: "\n## Evidence\n\nLine about the evidence.", with: "")
        #expect(ArtifactThreeWayMerge.merge(base: base, mine: mine, theirs: theirs) == .merged(expected))
    }

    @Test("The same line changed on both sides is a conflict")
    func sameLineConflicts() {
        let mine = base.replacingOccurrences(of: "Intro paragraph.", with: "Intro paragraph, mine.")
        let theirs = base.replacingOccurrences(of: "Intro paragraph.", with: "Intro paragraph, theirs.")
        #expect(ArtifactThreeWayMerge.merge(base: base, mine: mine, theirs: theirs) == .conflict)
    }

    @Test("Two different insertions at the same place are a conflict")
    func sameInsertionPointConflicts() {
        let mine = base.replacingOccurrences(of: "## Mechanism\n", with: "## Mechanism\n\nMine first.\n")
        let theirs = base.replacingOccurrences(of: "## Mechanism\n", with: "## Mechanism\n\nTheirs first.\n")
        #expect(ArtifactThreeWayMerge.merge(base: base, mine: mine, theirs: theirs) == .conflict)
    }

    @Test("An insertion at the edge of the other side's change is a conflict")
    func adjacentChangeConflicts() {
        let mine = base.replacingOccurrences(of: "Line about the mechanism.", with: "")
        let theirs = base.replacingOccurrences(of: "Line about the mechanism.", with: "Line about the mechanism.\nA second line about it.")
        #expect(ArtifactThreeWayMerge.merge(base: base, mine: mine, theirs: theirs) == .conflict)
    }

    @Test("Identical changes on both sides are one change")
    func identicalChangesMergeOnce() {
        let both = base.replacingOccurrences(of: "Intro paragraph.", with: "Intro paragraph, agreed.")
        #expect(ArtifactThreeWayMerge.merge(base: base, mine: both, theirs: both) == .merged(both))
        let theirsMore = both.replacingOccurrences(of: "Line about the evidence.", with: "Evidence, extended.")
        #expect(ArtifactThreeWayMerge.merge(base: base, mine: both, theirs: theirsMore) == .merged(theirsMore))
    }

    @Test("A side that did not change yields to the other")
    func unchangedSideYields() {
        let theirs = base + "\n\n## Assessment\n\nPromising."
        #expect(ArtifactThreeWayMerge.merge(base: base, mine: base, theirs: theirs) == .merged(theirs))
        #expect(ArtifactThreeWayMerge.merge(base: base, mine: theirs, theirs: base) == .merged(theirs))
    }

    @Test("Trailing newlines and blank lines survive the merge")
    func trailingNewlinePreserved() {
        let baseText = "a\n\nb\n\nc\n"
        let mine = "a1\n\nb\n\nc\n"
        let theirs = "a\n\nb\n\nc1\n"
        #expect(ArtifactThreeWayMerge.merge(base: baseText, mine: mine, theirs: theirs) == .merged("a1\n\nb\n\nc1\n"))
    }

    @Test("Hunks describe the base ranges an edit replaces")
    func hunkShapes() {
        let baseLines = ArtifactThreeWayMerge.lines("a\nb\nc\nd")
        let replaced = ArtifactThreeWayMerge.hunks(from: baseLines, to: ArtifactThreeWayMerge.lines("a\nB\nc\nd"))
        #expect(replaced == [.init(baseStart: 1, baseEnd: 2, replacement: ["B"])])
        let inserted = ArtifactThreeWayMerge.hunks(from: baseLines, to: ArtifactThreeWayMerge.lines("a\nb\nx\ny\nc\nd"))
        #expect(inserted == [.init(baseStart: 2, baseEnd: 2, replacement: ["x", "y"])])
        let deleted = ArtifactThreeWayMerge.hunks(from: baseLines, to: ArtifactThreeWayMerge.lines("a\nd"))
        #expect(deleted == [.init(baseStart: 1, baseEnd: 3, replacement: [])])
        #expect(ArtifactThreeWayMerge.hunks(from: baseLines, to: baseLines) == [])
    }

    @Test("A long report with local edits on each side still merges quickly")
    func longDocumentMerges() {
        let paragraphs = (0..<3_000).map { "Paragraph \($0) says something about company \($0 % 40)." }
        let baseText = paragraphs.joined(separator: "\n\n")
        let mine = baseText.replacingOccurrences(of: "Paragraph 12 says", with: "Paragraph 12 now says")
        let theirs = baseText.replacingOccurrences(of: "Paragraph 2900 says", with: "Paragraph 2900 finally says")
        let started = Date()
        let outcome = ArtifactThreeWayMerge.merge(base: baseText, mine: mine, theirs: theirs)
        #expect(Date().timeIntervalSince(started) < 1)
        let expected = mine.replacingOccurrences(of: "Paragraph 2900 says", with: "Paragraph 2900 finally says")
        #expect(outcome == .merged(expected))
    }
}
