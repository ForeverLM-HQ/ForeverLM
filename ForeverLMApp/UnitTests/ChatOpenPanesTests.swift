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

    @Test("What is drawn in any window counts as on screen, the chat's own window first; tabs behind do not")
    func onScreenInChatsWindow() {
        // The article in the Reader beside the chat, and the paper in a second window
        // on the other display: both are open (product owner, 2026-10-16).
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
        #expect(panes.sourcesOnScreen == [
            .init(id: "src-ask-not", title: "Ask not", kind: "article"),
            .init(id: "src-second-reader", title: "Second", kind: "book chapter"),
            .init(id: "src-4d", title: "4D spatiotemporal landscape", kind: "paper"),
        ])
        #expect(ChatOpenPanes(windows: [other]).sourcesOnScreen.map(\.id) == ["src-4d"])
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
        let shown = Self.talk.sourcesOnScreen
        #expect(shown.map(\.id) == ["src-talk"])
        #expect(shown.first?.moment == ChatContextAdditions.VideoMoment(at: 1611, playing: false))
        #expect(Self.talk.text.contains("(source_id: src-talk), paused at 26:51."))
    }

    @Test("A source with no playhead is on screen without a moment")
    func noPlayheadNoMoment() {
        let panes = ChatOpenPanes(windows: [.init(isChatsWindow: true, panes: [
            .init(onScreen: .init(name: "Reader", contents: [.source(id: "p1", title: "A paper", kind: "paper", position: "page 2 of 9")])),
        ])])
        #expect(panes.sourcesOnScreen.first?.moment == nil)
    }
}

/// The × on an open source's chip over the composer: the chat stops seeing
/// that source while it stays open (2026-10-13).
@Suite("Chat open panes: a source left out of the chat")
struct ChatOpenPanesLeftOutTests {
    /// A talk playing beside the chat, a paper in a second Reader, and the
    /// same talk loaded behind a Page in another window.
    private static let window = ChatOpenPanes(windows: [
        .init(
            isChatsWindow: true,
            panes: [
                .init(onScreen: .init(name: "Chat", contents: [.chat(title: "New chat", isThisChat: true)])),
                .init(onScreen: .init(name: "Reader", contents: [.source(
                    id: "src-talk", title: "Origins of the eukaryotic cell", kind: "video", position: "playing at 39:54"
                )])),
            ],
            alsoOnScreen: [.source(id: "src-paper", title: "An archaeal origin of eukaryotes", kind: "paper", position: nil)],
            videoPlayheads: ["src-talk": .init(seconds: 2394, isPlaying: true)]
        ),
        .init(isChatsWindow: false, panes: [.init(
            onScreen: .init(name: "Pages", contents: [.artifact(id: "doc-1", title: "Notes")]),
            behind: [.init(name: "Reader", contents: [.source(id: "src-talk", title: "Origins of the eukaryotic cell", kind: "video", position: nil)])]
        )]),
    ])

    @Test("A left-out video is not on screen, has no moment and is not listed; the rest stays")
    func leftOutVideoGoesEverywhere() {
        let panes = Self.window.leavingOut(["src-talk"])
        #expect(panes.sourcesOnScreen.map(\.id) == ["src-paper"])
        #expect(panes.windows[0].videoPlayheads.isEmpty)
        #expect(!panes.text.contains("src-talk"))
        #expect(panes.text.contains("- Right pane, on screen: Reader."))
        #expect(panes.text.contains("(source_id: src-paper)"))
        // The other window's tab held only the talk, so it is no longer listed behind the Page.
        #expect(panes.windows[1].panes[0].behind.isEmpty)
        #expect(panes.text.contains("“Notes” (artifact_id: doc-1)"))
    }

    @Test("Leaving nothing out changes nothing")
    func nothingLeftOut() {
        #expect(Self.window.leavingOut([]) == Self.window)
        #expect(Self.window.leavingOut(["src-not-open"]).sourcesOnScreen == Self.window.sourcesOnScreen)
    }

    @Test("A left-out source stays out while it is open, comes back once it has left the window, and a new chat starts with none left out")
    @MainActor
    func leftOutLastsWhileOpen() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatOpenPanesLeftOut_\(UUID().uuidString)", isDirectory: true)
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: root))
        manager.leaveOutOnScreenSource("src-talk")
        manager.leaveOutOnScreenSource("src-paper")
        manager.keepOnScreenSourcesLeftOut(within: ["src-talk", "src-paper"])
        #expect(manager.onScreenSourcesLeftOut == ["src-talk", "src-paper"])
        manager.keepOnScreenSourcesLeftOut(within: ["src-talk"])
        #expect(manager.onScreenSourcesLeftOut == ["src-talk"], "the closed paper is forgotten")
        manager.endSession()
        #expect(manager.onScreenSourcesLeftOut.isEmpty)
    }

    // MARK: - The card the Memory pane has in front of the learner

    private static let card = ChatContextAdditions.CardOnScreen(
        id: "card-1",
        question: "What persists despite organ loss?",
        answer: "Spatial information persists in tissue.",
        why: ["The paper states it."],
        sourceID: "src-aging",
        sourceTitle: "Aging as a Loss of Goal-Directedness",
        place: "To Check, 1 of 170",
        answerShown: true
    )

    private static let cardBesideChat = ChatOpenPanes(windows: [
        .init(isChatsWindow: true, panes: [
            .init(onScreen: .init(name: "Chat", contents: [.chat(title: "New chat", isThisChat: true)])),
            .init(onScreen: .init(name: "Memory, To Check", contents: [.card(card)])),
        ]),
    ])

    @Test("The card in the Memory pane beside the chat is named whole by list_open_panes")
    func cardIsNamed() {
        let text = Self.cardBesideChat.text
        #expect(text.contains("- Right pane, on screen: Memory, To Check — the flashcard “What persists despite organ loss?” (card_id: card-1)"))
        #expect(text.contains("answer: “Spatial information persists in tissue.”"))
        #expect(Self.cardBesideChat.cardOnScreen == Self.card)
        #expect(Self.cardBesideChat.sourcesOnScreen.isEmpty, "a card is not a library source")
    }

    @Test("A card in another window is the chat's card too")
    func cardInAnotherWindow() {
        let panes = ChatOpenPanes(windows: [
            .init(isChatsWindow: true, panes: [.init(onScreen: .init(name: "Chat", contents: [.chat(title: "New chat", isThisChat: true)]))]),
            .init(isChatsWindow: false, panes: [.init(onScreen: .init(name: "Memory, To Check", contents: [.card(Self.card)]))]),
        ])
        #expect(panes.cardOnScreen == Self.card)
    }

    @Test("Every message carries the card in its mark, and the framing says what it is")
    func cardRidesBesideTheMessage() throws {
        let stored = try #require(ChatContextAdditions.contextContent(nil, onScreen: [], card: Self.card))
        let parsed = ChatContextAdditions.parse(contextContent: stored)
        #expect(parsed.card == Self.card)
        #expect(parsed.remainder == nil)
        let framing = try #require(ChatContextAdditions.cardFraming(parsed.card))
        #expect(framing.contains("Question: What persists despite organ loss?"))
        #expect(framing.contains("Answer: Spatial information persists in tissue."))
        #expect(framing.contains("(source_id: src-aging)"))
        #expect(framing.contains("answer was on screen"))
        var asking = Self.card
        asking.answerShown = false
        #expect(try #require(ChatContextAdditions.cardFraming(asking)).contains("do not hand over the answer"))
        #expect(ChatContextAdditions.cardFraming(nil) == nil)
        // "What does this say exactly? Open that in Reader", asked of a reply about a
        // paper, was read as the card beside the chat (product owner, 2026-10-15).
        #expect(framing.contains("answered from the conversation and the card together"))
        #expect(!framing.contains("or \"it\" means this card"))
    }

    @Test("The card's pictures ride with it, and the framing says how to add one")
    func cardCarriesItsPictures() throws {
        var pictured = Self.card
        pictured.backImages = ["![Figure 1](foreverlm://source-image/src-aging/p1)"]
        let stored = try #require(ChatContextAdditions.contextContent(nil, onScreen: [], card: pictured))
        #expect(ChatContextAdditions.parse(contextContent: stored).card == pictured)
        let framing = try #require(ChatContextAdditions.cardFraming(pictured))
        #expect(framing.contains("Pictures on the answer: ![Figure 1](foreverlm://source-image/src-aging/p1)"))
        #expect(!framing.contains("Pictures on the question"))
        #expect(framing.contains("update_card with this card_id and back_images"))
        #expect(ChatContextAdditions.CardOnScreen(id: "c", question: "q", answer: "a", place: "p", answerShown: false, backImages: []).backImages == nil,
                "no pictures is left out of the mark, so a stored message keeps its bytes")
    }

    @Test("Filling in a video's moment keeps the card in the mark")
    func completingMomentsKeepsTheCard() throws {
        let video = ChatContextAdditions.OnScreen(
            id: "src-talk", title: "Talk", kind: "video",
            moment: .init(at: 10, playing: false)
        )
        let stored = try #require(ChatContextAdditions.contextContent("quoted", onScreen: [video], card: Self.card))
        let completed = ChatContextAdditions.contextContent(
            stored, completingMoments: ["src-talk": .init(at: 10, playing: false, said: "words")]
        )
        let parsed = ChatContextAdditions.parse(contextContent: completed)
        #expect(parsed.card == Self.card)
        #expect(parsed.onScreen.first?.moment?.said == "words")
        #expect(parsed.remainder == "quoted")
    }

    @Test("The card chip's × leaves the card out of what the chat is told, by its id")
    func cardCanBeLeftOut() {
        let kept = Self.cardBesideChat.leavingOut([Self.card.id])
        #expect(kept.cardOnScreen == nil)
        #expect(!kept.text.contains("card-1"))
        #expect(Self.cardBesideChat.leavingOut(["src-other"]).cardOnScreen == Self.card)
    }
}
