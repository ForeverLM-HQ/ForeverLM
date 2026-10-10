import Foundation
import Testing
@testable import ForeverLM

/// A learner turn folds when it is a paste rather than a question: past the
/// line or character threshold, never at it. The fold is what keeps SwiftUI's
/// selection overlay off an 11 KB transcript (the 2026-09-17 hang), so the
/// thresholds and the preview it shows are pinned here.
@Suite("Chat Long User Message")
struct ChatLongUserMessageTests {
    @Test func aQuestionDoesNotFold() {
        #expect(!ChatLongUserMessage.isLong("Can you quiz me on the paper we read yesterday?"))
        #expect(!ChatLongUserMessage.isLong(""))
    }

    @Test func aShortListStaysOneBubble() {
        let lines = (1...ChatLongUserMessage.lineThreshold).map { "point \($0)" }
        #expect(!ChatLongUserMessage.isLong(lines.joined(separator: "\n")))
    }

    @Test func oneLineOverTheThresholdFolds() {
        let lines = (1...(ChatLongUserMessage.lineThreshold + 1)).map { "[11:55:\($0 % 60)] said \($0)" }
        #expect(ChatLongUserMessage.isLong(lines.joined(separator: "\n")))
    }

    @Test func aWallOfProseFoldsWithoutNewlines() {
        let prose = String(repeating: "word ", count: ChatLongUserMessage.characterThreshold / 5 + 1)
        #expect(!prose.contains("\n"))
        #expect(ChatLongUserMessage.isLong(prose))
    }

    @Test func lineCountIgnoresSurroundingWhitespaceAndKeepsInnerBlankLines() {
        #expect(ChatLongUserMessage.lineCount("") == 0)
        #expect(ChatLongUserMessage.lineCount("  \n\n") == 0)
        #expect(ChatLongUserMessage.lineCount("one") == 1)
        #expect(ChatLongUserMessage.lineCount("\n# Title\n\n## Transcript\n\n[11:55:24] one\n") == 5)
    }

    @Test func previewShowsTheFirstNonEmptyLines() {
        let text = """
        # Weekly lab sync - 2026/09/17 11:55

        ## Transcript

        [11:55:24] one
        [11:55:26] two
        [11:55:29] three
        [11:55:31] four
        [11:55:45] five
        """
        let expected = [
            "# Weekly lab sync - 2026/09/17 11:55",
            "## Transcript",
            "[11:55:24] one",
            "[11:55:26] two",
            "[11:55:29] three",
            "[11:55:31] four",
        ].joined(separator: "\n")
        #expect(ChatLongUserMessage.previewLineCount == 6)
        #expect(ChatLongUserMessage.preview(text) == expected)
    }

    @Test func summaryReadsAsACount() {
        #expect(ChatLongUserMessage.summary(lineCount: 1) == "1 line")
        #expect(ChatLongUserMessage.summary(lineCount: 166) == "166 lines")
    }
}
