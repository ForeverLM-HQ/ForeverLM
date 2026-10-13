import Foundation
import Testing
@testable import ForeverLM

/// A quotation copied from a PDF book and pasted into a Page came in as twenty
/// one-line paragraphs: PDFKit writes every printed line as a paragraph of its
/// own. The Pasted Line Joining model says what each break was; what has to
/// hold here is that the host asks only about a paste the editor would send,
/// and takes an answer only when it fits the lines it was about.
@Suite("Pasted Line Joining")
struct PastedLineJoiningTests {
    /// The opening of the quotation from the report, as PDFKit's copy wrote it.
    static let printed = [
        "To judge from all the efforts life scientists make to",
        "gather immense data sets, you might suppose that",
        "their discipline is hampered by lack of information.",
        "Huge international projects exist (and have existed) to",
    ]

    @Test("The editor's question is read as it sends it, and nothing else is a question")
    func requestParsing() {
        let request = PastedLineJoining.Request.parse(["requestID": "paste-1", "lines": Self.printed])
        #expect(request == PastedLineJoining.Request(requestID: "paste-1", lines: Self.printed))

        #expect(PastedLineJoining.Request.parse(["lines": Self.printed]) == nil)
        #expect(PastedLineJoining.Request.parse(["requestID": "", "lines": Self.printed]) == nil)
        #expect(PastedLineJoining.Request.parse(["requestID": "paste-2", "lines": Array(Self.printed.prefix(2))]) == nil)
        #expect(PastedLineJoining.Request.parse(["requestID": "paste-3", "lines": Self.printed + [String(repeating: "x", count: 201)]]) == nil)
        #expect(PastedLineJoining.Request.parse(["requestID": "paste-4", "lines": Array(repeating: "a printed line", count: 401)]) == nil)
        #expect(PastedLineJoining.Request.parse(["requestID": "paste-5", "lines": ["one", 2, "three"] as [Any]]) == nil)
    }

    @Test("The model reads the lines numbered from one")
    func userMessageNumbersLines() {
        #expect(PastedLineJoining.userMessage(["first", "second"]) == "1| first\n2| second")
    }

    @Test("An answer is one known break for each pair of lines, fenced or not")
    func readsAnAnswer() throws {
        let breaks = try PastedLineJoining.breaks(
            from: "```json\n{\"breaks\": [\"space\", \"Space\", \"paragraph\"]}\n```",
            lines: Self.printed
        )
        #expect(breaks == [.space, .space, .paragraph])

        let hyphens = try PastedLineJoining.breaks(
            from: #"{"breaks": ["hyphen_kept", "hyphen_split", "join"]}"#,
            lines: ["a fifty-six-", "year-old man whose informa- ", "tion was", "complete"]
        )
        #expect(hyphens == [.hyphenKept, .hyphenSplit, .join])
    }

    @Test("An answer that does not fit the lines is refused, so it moves on to a backup model")
    func refusesWhatDoesNotFit() {
        #expect(throws: PastedLineJoining.AnswerError.unreadable) {
            try PastedLineJoining.breaks(from: "The lines run on.", lines: Self.printed)
        }
        #expect(throws: PastedLineJoining.AnswerError.wrongCount(expected: 3, got: 2)) {
            try PastedLineJoining.breaks(from: #"{"breaks": ["space", "space"]}"#, lines: Self.printed)
        }
        #expect(throws: PastedLineJoining.AnswerError.unknownBreak("merge")) {
            try PastedLineJoining.breaks(from: #"{"breaks": ["space", "merge", "space"]}"#, lines: Self.printed)
        }
        // Line 1 ends in "to", not a hyphen.
        #expect(throws: PastedLineJoining.AnswerError.hyphenWithoutHyphen(line: 1)) {
            try PastedLineJoining.breaks(from: #"{"breaks": ["hyphen_split", "space", "space"]}"#, lines: Self.printed)
        }
        #expect(throws: PastedLineJoining.AnswerError.joinsEmptyLine(line: 2)) {
            try PastedLineJoining.breaks(from: #"{"breaks": ["space", "paragraph"]}"#, lines: ["a line", "", "another"])
        }
        #expect((try? PastedLineJoining.breaks(from: #"{"breaks": ["paragraph", "paragraph"]}"#, lines: ["a line", "", "another"])) == [.paragraph, .paragraph])
    }

    @Test("Pasted Line Joining is background work on the Background text model, with a model of its own")
    func taskIsBackgroundWork() {
        let task = AITask.pastedLineJoining
        #expect(task.rawValue == "pasted_line_joining")
        #expect(task.usesBackgroundModelDefault)
        #expect(!task.usesMultimodalBackgroundModelDefault)
        #expect(!task.requiresVision)
        #expect(!task.followsChatRoute)
        #expect(task.isBackgroundWork)
        #expect(task.usageNeed == .needed)
        #expect(AIUsageTaskNeed.of(taskKey: "pasted_line_joining") == .needed)
        #expect(AITask.advancedTasks.contains(task))
        #expect(task.sourceType == nil)
        #expect(task.defaultPrompt == Prompts.pastedLineJoining)
        #expect(task.qualificationRole == .background)
        #expect(AIUsageTaskLabel.text(for: "pasted_line_joining") == "Join Pasted Lines")
    }

    @Test("The host tells the editor it joins pasted lines, and answers by request id")
    func hostScripts() {
        #expect(
            ArtifactMarkdownEditorView.Coordinator.joinsPastedLinesScript
                == "window.foreverLMArtifactEditor.setJoinsPastedLines(true);"
        )
        #expect(
            ArtifactMarkdownEditorView.Coordinator.pastedLineJoiningScript(requestID: "paste-1", breaks: [.space, .hyphenSplit, .paragraph])
                == #"window.foreverLMArtifactEditor.completePastedLineJoining("paste-1", ["space", "hyphen_split", "paragraph"]);"#
        )
        #expect(
            ArtifactMarkdownEditorView.Coordinator.forgetPastedLineJoiningScript(requestID: "paste-2")
                == #"window.foreverLMArtifactEditor.forgetPastedLineJoining("paste-2");"#
        )
    }
}
