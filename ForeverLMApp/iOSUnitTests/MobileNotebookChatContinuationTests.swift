import Foundation
import XCTest
@testable import ForeverLM

/// A saved notebook chat continued on the phone (docs/notebooks-design.md,
/// "iPhone") is the same chat: its session id, its transcript as the history
/// the next turn is asked under, the sources it read, and nothing written
/// until a reply arrives.
@MainActor
final class MobileNotebookChatContinuationTests: XCTestCase {
    private func source(_ id: String, title: String) -> MobileCloudSource {
        MobileCloudSource(
            id: id,
            title: title,
            subtitle: nil,
            sourceType: "paper",
            dateAdded: Date(timeIntervalSinceReferenceDate: 0),
            hasAudio: false,
            isArchived: false
        )
    }

    private let notebook = MobileCloudNotebook(
        id: "p1",
        title: "Cardiac sodium",
        instructions: nil,
        sourceIDs: ["s1", "s2"],
        isArchived: false,
        updatedAt: Date(timeIntervalSinceReferenceDate: 0)
    )

    private func message(_ role: MobileChatMessage.Role, _ text: String) -> MobileChatMessage {
        MobileChatMessage(id: UUID(), role: role, content: text, isStreaming: false)
    }

    func testAContinuedChatKeepsItsSessionTranscriptAndSources() {
        let ouabain = source("s1", title: "Ouabain paper")
        let textbook = source("s2", title: "Textbook")
        let context = MobileNotebookChatContext(
            notebook: notebook,
            loaded: [.init(source: ouabain, text: "The pump stops.")],
            notLoaded: [.init(source: textbook, reason: .textUnavailable)]
        )
        let history = [message(.user, "Why does sodium rise?"), message(.assistant, "The pump stops.")]
        let chat = MobileChatViewModel(
            continuing: "mac-chat-1",
            messages: history,
            source: ouabain,
            notebook: context,
            missingSourceCount: 1
        )

        XCTAssertEqual(chat.sessionID, "mac-chat-1", "the same saved chat, never a new one")
        XCTAssertEqual(chat.messages.map(\.content), ["Why does sodium rise?", "The pump stops."])
        XCTAssertEqual(chat.notebook?.id, "p1")
        XCTAssertEqual(chat.notebookContext?.loaded.map(\.source.id), ["s1"])
        XCTAssertEqual(chat.continuation?.missingSourceCount, 1)
        XCTAssertEqual(chat.draft, "", "opening a chat sends nothing")
        XCTAssertNil(chat.modelOverride)
        #if DEBUG
        XCTAssertTrue(chat.recordedExchangesForTesting.isEmpty, "opening is a read: nothing to save until a reply")
        #endif

        chat.draft = "And calcium?"
        XCTAssertTrue(chat.canSend)

        let sitting = chat.continuation?.sitting
        let again = MobileChatViewModel(
            continuing: "mac-chat-1",
            messages: history,
            source: ouabain,
            notebook: context,
            missingSourceCount: 1
        )
        XCTAssertNotEqual(again.continuation?.sitting, sitting, "each sitting's turns keep ids of their own")

        let fresh = MobileChatViewModel(notebook: context, initialPrompt: "Hi")
        XCTAssertNil(fresh?.continuation, "a new chat is not a continuation")
        XCTAssertNotEqual(fresh?.sessionID, "mac-chat-1")
        XCTAssertTrue(fresh?.sessionID.hasPrefix("ios-") == true)
    }

    func testAContinuedChatWithNothingLoadedShowsAndCannotBeSent() {
        let textbook = source("s2", title: "Textbook")
        let context = MobileNotebookChatContext(
            notebook: notebook,
            loaded: [],
            notLoaded: [.init(source: textbook, reason: .textUnavailable)]
        )
        let chat = MobileChatViewModel(
            continuing: "ios-abc",
            messages: [message(.user, "Hi"), message(.assistant, "Hello.")],
            source: textbook,
            notebook: context,
            missingSourceCount: 0
        )
        chat.draft = "Still there?"
        XCTAssertFalse(chat.canSend, "with no source's text on the phone there is nothing to read")
        chat.send()
        XCTAssertEqual(chat.messages.count, 2, "nothing was sent")
        XCTAssertNotNil(chat.errorMessage)
    }

    /// A Mac reply can draw a visualization, a fenced block of HTML the Mac
    /// runs; continued here, it reads as one line, never as the program.
    func testAMacVisualizationReadsAsOneLine() {
        let reply = "Decay:\n\n```visualization\n<div>x</div>\n<script>let y = `${1}`</script>\n```\n\nAfter."
        XCTAssertEqual(
            MobileChatViewModel.replacingVisualizations(in: reply),
            "Decay:\n\n\(MobileChatViewModel.visualizationStandIn)\n\nAfter."
        )
        // Still streaming: the rest of the reply is the block.
        XCTAssertEqual(
            MobileChatViewModel.replacingVisualizations(in: "Open:\n~~~ Visualization\n<div>half"),
            "Open:\n\(MobileChatViewModel.visualizationStandIn)"
        )
        // Inside another code block it is that block's text.
        let quoted = "````markdown\n```visualization\n<b>x</b>\n```\n````"
        XCTAssertEqual(MobileChatViewModel.replacingVisualizations(in: quoted), quoted)
    }
}
