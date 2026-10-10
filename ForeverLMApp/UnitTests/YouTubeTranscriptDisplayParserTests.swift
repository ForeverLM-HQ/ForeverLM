import Testing
@testable import ForeverLM

/// What counts as a speaker transcript, and what a stray colon must not turn into one.
///
/// Both failure modes here are silent — the transcript still renders, just with a margin
/// column full of a repeated placeholder and a clause missing from its body — so they want
/// coverage rather than a look.
@Suite("YouTube Transcript Display Parsing")
struct YouTubeTranscriptDisplayParserTests {

    /// The regression, from a real talk. One sentence in twenty-eight happens to carry a
    /// colon; it was read as a speaker label, which flipped the whole transcript to the
    /// speaker layout, labelled every other row with the placeholder, and — because a
    /// speaker prefix is stripped from the body it introduces — deleted the clause from
    /// the transcript.
    @Test("A sentence with a colon is not a speaker")
    func sentenceWithColonIsNotASpeaker() {
        let content = """
        [0:00] Morning everyone. My name is Kendo from Northwell.

        [2:20] So in this study, 60 pigs were administered a shock to induce cardiac arrest.

        [3:24] Each group receives the respective treatment: elution buffer or isolated mitochondria.

        [4:10] The animals were subsequently observed for 240 minutes.
        """

        let result = YouTubeTranscriptDisplayParser.parse(content)

        #expect(result.layout == .sections)
        #expect(result.segments.count == 4)
        #expect(result.segments.allSatisfy { !$0.hasNamedSpeaker })
        // The clause is still in the transcript, where it was said.
        #expect(result.segments[2].text.hasPrefix("Each group receives the respective treatment:"))
    }

    @Test("Speaker-looking prefixes remain source text")
    func speakerPrefixesRemainSourceText() {
        let content = """
        [0:00] Host: Welcome back to the show.

        [0:30] Student: Thanks for having me.

        [1:10] Host: Let's start with the basics.

        [1:40] Student: Happy to.
        """

        let result = YouTubeTranscriptDisplayParser.parse(content)

        #expect(result.layout == .sections)
        #expect(result.segments.allSatisfy { !$0.hasNamedSpeaker })
        #expect(result.segments[0].text == "Host: Welcome back to the show.")
    }

    /// A lecture whose transcript names its speaker once, in the opening line, is not a
    /// dialogue. Reading it as one hands two hundred rows a speaker column to hold one
    /// name and a hundred and ninety-nine placeholders.
    @Test("One label in a long transcript does not make it diarized")
    func singleLabelDoesNotDiarize() {
        var blocks = ["[0:00] PROFESSOR: Today we are going to talk about metabolism."]
        for index in 1..<40 {
            blocks.append("[\(index):00] And that brings us to the next part of the story.")
        }

        let result = YouTubeTranscriptDisplayParser.parse(blocks.joined(separator: "\n\n"))

        #expect(result.layout == .sections)
        #expect(result.segments.count == 40)
        // Rejected, so it goes back into the sentence rather than being dropped.
        #expect(result.segments[0].text.hasPrefix("PROFESSOR:"))
    }

    /// Long enough to be a clause rather than a name, whatever the coverage.
    @Test("Rejects a clause-length label even when every block carries one")
    func rejectsClauseLengthLabels() {
        let content = """
        [0:00] So what we see is the following: the signal rises and then falls.

        [0:30] Another study examined how people responded to the question: does it last?
        """

        let result = YouTubeTranscriptDisplayParser.parse(content)

        #expect(result.layout == .sections)
        #expect(result.segments.allSatisfy { !$0.hasNamedSpeaker })
    }

    @Test("Does not infer or carry speaker identity")
    func doesNotCarrySpeakerIdentity() {
        let content = """
        [0:00] Host: First question.

        [0:20] Some follow-up in the same turn.

        [0:40] Student: My answer.

        [1:00] Still me, continuing.
        """

        let result = YouTubeTranscriptDisplayParser.parse(content)

        #expect(result.layout == .sections)
        #expect(result.segments.allSatisfy { !$0.hasNamedSpeaker })
        #expect(result.segments[0].text == "Host: First question.")
    }

    @Test("Keeps section headings with the segment they introduce")
    func keepsHeadings() {
        let content = """
        ## Introduction

        [0:00] Morning everyone.

        ## Study Design

        [2:20] So in this study, 60 pigs were used.
        """

        let result = YouTubeTranscriptDisplayParser.parse(content)

        #expect(result.segments.count == 2)
        #expect(result.segments[0].heading == "Introduction")
        #expect(result.segments[0].startTime == "0:00")
        #expect(result.segments[1].heading == "Study Design")
    }

    /// The placeholder is a stand-in for "no speaker was named", so it must never read as
    /// one — that is what the reader keys on to leave the margin out.
    @Test("The placeholder never counts as a named speaker")
    func placeholderIsNotANamedSpeaker() {
        let result = YouTubeTranscriptDisplayParser.parse("[0:00] Just some narration with no speaker.")

        #expect(result.segments.first?.speakerLabel == PodcastTranscriptSegment.unlabeledSpeaker)
        #expect(result.segments.first?.hasNamedSpeaker == false)
    }
}
