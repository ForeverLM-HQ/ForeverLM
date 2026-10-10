import Foundation
import Testing
@testable import ForeverLM

/// `list_open_panes`: the chat looking at what is open beside it, so "figure
/// 2D" with a paper in the Reader means that paper.
@Suite("Chat open panes")
struct ChatOpenPanesTests {
    private static let paperID = "src-na-heart"

    /// The product owner's 2026-09-22 window: the chat on the left, a Nature paper on
    /// page 3 in the Reader on the right, a Doc loaded behind it.
    private static let readingBesideChat = ChatOpenPanes(windows: [
        .init(isChatsWindow: true, panes: [
            .init(onScreen: .init(name: "Chat", contents: [.chat(title: "New chat", isThisChat: true)])),
            .init(
                onScreen: .init(name: "Reader", contents: [.source(
                    id: paperID,
                    title: "Elevated Na is a dynamic and reversible modulator of mitochondrial metabolism in the heart",
                    kind: "paper",
                    position: "page 3 of 15"
                )]),
                behind: [.init(name: "Pages", contents: [.artifact(id: "doc-1", title: "Sodium notes")])]
            ),
        ]),
    ])

    @Test("The paper in the Reader beside the chat is named with its source_id and page")
    func readerSourceIsNamed() {
        let text = Self.readingBesideChat.text
        #expect(text.contains("The window this chat is in:"))
        #expect(text.contains("- Left pane, on screen: Chat — this conversation."))
        #expect(text.contains("- Right pane, on screen: Reader — paper “Elevated Na is a dynamic"))
        #expect(text.contains("(source_id: \(Self.paperID)), page 3 of 15."))
        #expect(text.contains("  - Behind it: Pages — “Sodium notes” (artifact_id: doc-1)."))
        #expect(text.contains("inspect_paper_figure"))
        #expect(Self.readingBesideChat.sourceIDs == [Self.paperID])
    }

    @Test("The chat's own window is listed first, and a source there comes first")
    func chatsWindowComesFirst() {
        let other = ChatOpenPanes.Window(isChatsWindow: false, panes: [
            .init(onScreen: .init(name: "Reader", contents: [.source(id: "src-other", title: "Other", kind: "book chapter", position: nil)])),
        ])
        let panes = ChatOpenPanes(windows: [other] + Self.readingBesideChat.windows)
        let text = panes.text
        let chats = text.range(of: "The window this chat is in:")!
        let another = text.range(of: "Another ForeverLM window:")!
        #expect(chats.lowerBound < another.lowerBound)
        #expect(text.contains("- The only pane, on screen: Reader — book chapter “Other” (source_id: src-other)."))
        #expect(panes.sourceIDs == [Self.paperID, "src-other"])
    }

    @Test("Panes that show only lists say so, and add no source advice")
    func listsOnly() {
        let panes = ChatOpenPanes(windows: [
            .init(isChatsWindow: true, panes: [
                .init(onScreen: .init(name: "Chat", contents: [.chat(title: "New chat", isThisChat: true)])),
                .init(onScreen: .init(name: "Goals")),
            ]),
        ])
        #expect(panes.text.contains("- Right pane, on screen: Goals."))
        #expect(!panes.text.contains("source_id"))
        #expect(ChatOpenPanes(windows: []).text.hasPrefix("No ForeverLM window"))
    }

    @Test("Only what is drawn in the chat's own window counts as on screen beside it")
    func onScreenInChatsWindow() {
        // The product owner's 2026-09-24 screens: the article in the Reader beside the
        // chat, the paper's walkthrough in a window on the other display.
        let other = ChatOpenPanes.Window(isChatsWindow: false, panes: [
            .init(onScreen: .init(name: "Reader", contents: [.source(id: "src-4d", title: "4D spatiotemporal landscape", kind: "paper", position: nil)])),
        ])
        let chats = ChatOpenPanes.Window(
            isChatsWindow: true,
            panes: [
                .init(onScreen: .init(name: "Chat", contents: [.chat(title: "New chat", isThisChat: true)])),
                .init(
                    onScreen: .init(name: "Reader", contents: [.source(id: "src-ask-not", title: "Ask not", kind: "article", position: nil)]),
                    behind: [.init(name: "Reader", contents: [.source(id: "src-behind", title: "Behind", kind: "paper", position: nil)])]
                ),
            ],
            alsoOnScreen: [.source(id: "src-second-reader", title: "Second", kind: "book chapter", position: nil)]
        )
        let panes = ChatOpenPanes(windows: [other, chats])
        #expect(panes.sourcesOnScreenInChatsWindow == [
            .init(id: "src-ask-not", title: "Ask not", kind: "article"),
            .init(id: "src-second-reader", title: "Second", kind: "book chapter"),
        ])
        #expect(ChatOpenPanes(windows: [other]).sourcesOnScreenInChatsWindow.isEmpty)
    }

    @Test("The tool rides a chat shown in a window, and not a manager without one")
    @MainActor
    func offeredOnlyWithAWindow() {
        let withWindow = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: false, appTools: [], hasSynthesisContext: false,
            openPanes: Self.readingBesideChat
        )
        let spec = withWindow.first { $0.name == "list_open_panes" }
        #expect(spec != nil)
        #expect(spec?.inputSchema["type"] as? String == "object")
        #expect(spec?.description.contains("figure 2D") == true)

        let withoutWindow = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: false, appTools: [], hasSynthesisContext: false
        )
        #expect(!withoutWindow.contains { $0.name == "list_open_panes" })
    }
}

/// A video playing or paused beside the chat: the window's snapshot carries
/// its playhead into every message the learner sends there.
@Suite("Chat open panes: a video's playhead")
struct ChatOpenPanesVideoPlayheadTests {
    private static let talk = ChatOpenPanes(windows: [
        .init(
            isChatsWindow: true,
            panes: [
                .init(onScreen: .init(name: "Chat", contents: [.chat(title: "New chat", isThisChat: true)])),
                .init(onScreen: .init(name: "Reader", contents: [.source(
                    id: "src-talk",
                    title: "Finbow's Mitochondrial Cristae",
                    kind: "video",
                    position: "paused at 26:51"
                )])),
            ],
            videoPlayheads: ["src-talk": .init(seconds: 1611.6, isPlaying: false)]
        ),
        .init(
            isChatsWindow: false,
            panes: [.init(onScreen: .init(name: "Reader", contents: [.source(
                id: "src-other", title: "Another talk", kind: "video", position: "playing at 1:00"
            )]))],
            videoPlayheads: ["src-other": .init(seconds: 60, isPlaying: true)]
        ),
    ])

    @Test("The video in the chat's window carries its moment; another window's video is not on screen here")
    func playheadRidesTheMessage() {
        let shown = Self.talk.sourcesOnScreenInChatsWindow
        #expect(shown.map(\.id) == ["src-talk"])
        #expect(shown.first?.moment == ChatContextAdditions.VideoMoment(at: 1611, playing: false))
        #expect(Self.talk.text.contains("(source_id: src-talk), paused at 26:51."))
    }

    @Test("A source with no playhead is on screen without a moment")
    func noPlayheadNoMoment() {
        let panes = ChatOpenPanes(windows: [.init(isChatsWindow: true, panes: [
            .init(onScreen: .init(name: "Reader", contents: [.source(id: "p1", title: "A paper", kind: "paper", position: "page 2 of 9")])),
        ])])
        #expect(panes.sourcesOnScreenInChatsWindow.first?.moment == nil)
    }
}
