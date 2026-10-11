import Foundation
import Testing
@testable import ForeverLM

// Add to Chat and the card acts (docs/knowledge-map-design.md, "Add to Chat and the
// chips", "Menus and the inspector"): the canvas as a chat's context, its chips,
// the paragraph the model reads, Add to Chat's routes, and which of the card
// acts a selection takes.

private func node(
    _ ref: String,
    kind: String,
    title: String,
    sub: String = "",
    detail: [String] = [],
    quote: String? = nil,
    caption: String? = nil
) -> KnowledgeMapNode {
    KnowledgeMapNode(
        ref: ref, kind: kind, type: kind, title: title, sub: sub, detail: detail, shore: "",
        quote: quote, caption: caption
    )
}

private func card(_ ref: String, kind: String? = nil, title: String = "A card", words: String = "") -> KnowledgeMapChatCard {
    KnowledgeMapChatCard(ref: ref, kind: kind ?? String(ref.split(separator: ":")[0]), title: title, words: words)
}

@Suite("What a card says when it is added to a chat")
struct KnowledgeMapChatCardWordsTests {
    @Test("An Idea's words are its note, and an Idea with none says nothing beyond its title")
    func idea() {
        let withNote = node("idea:a", kind: "idea", title: "Is it real?", sub: "Two lines\nof note.")
        #expect(KnowledgeMapChatCard.words(of: withNote, annotation: nil) == "Two lines of note.")
        let bare = node("idea:b", kind: "idea", title: "Bare", sub: KnowledgeMapAddSearch.noteLessIdeaLine)
        #expect(KnowledgeMapChatCard.words(of: bare, annotation: nil).isEmpty)
        #expect(KnowledgeMapChatCard.words(of: withNote, annotation: "Ignored").hasPrefix("Two lines"), "an Idea takes no annotation")
    }

    @Test("A card says its annotation first; a source with none says nothing")
    func annotation() {
        let paper = node("source:p", kind: "source", title: "A paper", sub: "Zara Holt · 2024 · Nature")
        #expect(KnowledgeMapChatCard.words(of: paper, annotation: nil).isEmpty)
        #expect(KnowledgeMapChatCard.words(of: paper, annotation: "  Start\nhere. ") == "Start here.")
    }

    @Test("A clip gives its quote or caption, the learner's note and where it came from; a page its paper and number")
    func clipAndPage() {
        let passage = node("clip:c", kind: "clip", title: "p. 4 · A paper", sub: "A paper · p. 4", detail: ["Key step"], quote: "The cells fused.")
        #expect(KnowledgeMapChatCard.words(of: passage, annotation: "Why") == "Why \u{201C}The cells fused.\u{201D} Key step From A paper · p. 4.")
        let figure = node("clip:f", kind: "clip", title: "Figure 2", sub: "A paper · p. 7", caption: "Fig. 2 | Fusion.")
        #expect(KnowledgeMapChatCard.words(of: figure, annotation: nil) == "Fig. 2 | Fusion. From A paper · p. 7.")
        let page = node("page:p:3", kind: "page", title: "Page 3", sub: "A paper")
        #expect(KnowledgeMapChatCard.words(of: page, annotation: nil) == "Page 3 of A paper.")
    }

    @Test("A chat says its first line; a picture its name")
    func chatAndPicture() {
        let chat = node("chat:s", kind: "chat", title: "Fusion questions", sub: "Asked what fuses first.")
        #expect(KnowledgeMapChatCard.words(of: chat, annotation: nil) == "Asked what fuses first.")
        let picture = node("picture:i", kind: "picture", title: "Cell diagram")
        #expect(KnowledgeMapChatCard.words(of: picture, annotation: nil) == "Cell diagram")
    }

    @Test("Words are one line of at most 600 characters, cut with an ellipsis")
    func capped() {
        let long = node("idea:l", kind: "idea", title: "Long", sub: String(repeating: "word ", count: 400))
        let words = KnowledgeMapChatCard.words(of: long, annotation: nil)
        #expect(words.count == KnowledgeMapChatCard.wordsLimit)
        #expect(words.hasSuffix("\u{2026}") && !words.contains("\n"))
        let exact = node("idea:e", kind: "idea", title: "Exact", sub: String(repeating: "x", count: 600))
        #expect(KnowledgeMapChatCard.words(of: exact, annotation: nil).count == 600, "600 characters fit whole")
    }

    @Test("A source card and a page card each bring a paper; the rest bring none")
    func librarySource() {
        #expect(card("source:p").librarySourceID == "p")
        #expect(card("page:p:3").librarySourceID == "p")
        #expect(card("idea:i").librarySourceID == nil)
        #expect(card("clip:c").librarySourceID == nil)
    }
}

@Suite("The cards a chat holds")
struct KnowledgeMapChatContextTests {
    @Test("Cards follow in the order added; one added again keeps its place and takes the newer words")
    func adding() {
        var context = KnowledgeMapChatContext(canvasID: "cnv-1", name: "Fusion", cards: [])
        #expect(context.add([card("idea:a"), card("source:p")]) == 0)
        #expect(context.add([card("idea:b"), card("idea:a", words: "newer")]) == 0)
        #expect(context.cards.map(\.ref) == ["idea:a", "source:p", "idea:b"])
        #expect(context.cards[0].words == "newer")
        context.remove("source:p")
        #expect(context.cards.map(\.ref) == ["idea:a", "idea:b"])
    }

    @Test("A chat holds 24 cards and says how many it left out")
    func limit() {
        var context = KnowledgeMapChatContext(canvasID: "cnv-1", name: "Fusion", cards: [])
        let thirty = (0..<30).map { card("idea:\($0)") }
        #expect(context.add(thirty) == 6)
        #expect(context.cards.count == KnowledgeMapChatContext.cardLimit)
        #expect(context.cards.last?.ref == "idea:23")
        #expect(context.add([card("idea:0", words: "again")]) == 0, "a card held already is not left out")
    }

    @Test("A question among the cards offers Break Into Questions; an Idea without one does not")
    func holdsQuestion() {
        let plain = KnowledgeMapChatContext(canvasID: "c", name: "n", cards: [card("idea:a", title: "A claim"), card("source:p", title: "Why?")])
        #expect(!plain.holdsQuestion, "only an Idea is a question")
        let asked = KnowledgeMapChatContext(canvasID: "c", name: "n", cards: [card("idea:a", title: "What fuses first?")])
        #expect(asked.holdsQuestion)
    }
}

@Suite("The chips over the composer")
struct KnowledgeMapChatChipsTests {
    private func cards(_ count: Int) -> [KnowledgeMapChatCard] { (0..<count).map { card("idea:\($0)") } }

    @Test("Up to six cards each get a chip; past six the sixth chip is +N and the rest wait behind it")
    func overflow() {
        for count in [0, 1, 6] {
            let split = KnowledgeMapChatChips.split(cards(count))
            #expect(split.shown.count == count && split.overflow.isEmpty)
        }
        let seven = KnowledgeMapChatChips.split(cards(7))
        #expect(seven.shown.map(\.ref) == (0..<5).map { "idea:\($0)" })
        #expect(seven.overflow.map(\.ref) == ["idea:5", "idea:6"])
        let full = KnowledgeMapChatChips.split(cards(KnowledgeMapChatContext.cardLimit))
        #expect(full.shown.count == 5 && full.overflow.count == 19)
    }

    @Test("A chip's title is cut at 24 characters, ellipsis included")
    func title() {
        #expect(KnowledgeMapChatChips.title(of: card("idea:a", title: "Short")) == "Short")
        #expect(KnowledgeMapChatChips.title(of: card("idea:a", title: String(repeating: "a", count: 24))).count == 24)
        let cut = KnowledgeMapChatChips.title(of: card("idea:a", title: String(repeating: "b", count: 40)))
        #expect(cut.count == 24 && cut.hasSuffix("\u{2026}"))
    }

    @Test("The in-context pill leaves out the sources and Docs a chip shows")
    func pill() {
        let shown = [card("source:a"), card("doc:d1"), card("idea:i"), card("page:b:2")]
        #expect(KnowledgeMapChatChips.pillCount(loadedSourceIDs: ["a", "b", "c"], docIDs: ["d1", "d2"], cards: shown) == 3, "b (a page's paper), c and d2 remain")
        #expect(KnowledgeMapChatChips.pillCount(loadedSourceIDs: ["a"], docIDs: ["d1"], cards: shown) == 0)
        #expect(KnowledgeMapChatChips.pillCount(loadedSourceIDs: ["a"], docIDs: ["d1"], cards: []) == 2, "no chips, every item counts")
        // A card taken away leaves its source behind to be counted.
        #expect(KnowledgeMapChatChips.pillCount(loadedSourceIDs: ["a"], docIDs: [], cards: [card("idea:i")]) == 1)
        #expect(KnowledgeMapChatChips.sourceIDs(shownBy: shown) == ["a"])
        #expect(KnowledgeMapChatChips.docIDs(shownBy: shown) == ["d1"])
    }
}

@MainActor
@Suite("The paragraph the model reads about the canvas")
struct KnowledgeMapChatInstructionTests {
    private let context = KnowledgeMapChatContext(canvasID: "cnv-42", name: "Fusion  map", cards: [
        card("idea:a", title: "What fuses first?", words: "The note."),
        card("source:p", title: "A paper"),
        card("picture:i", title: "Cell diagram", words: "Cell diagram"),
    ])

    @Test("It names the canvas and each card by item_id, kind, title and words, and points at get_knowledge_map")
    func text() {
        let text = context.instruction(canReadCanvas: true)
        #expect(text.contains("\u{201C}Fusion map\u{201D} (canvas_id: cnv-42)"))
        #expect(text.contains("- idea \u{201C}What fuses first?\u{201D} (item_id: idea:a): The note."))
        #expect(text.contains("- source \u{201C}A paper\u{201D} (item_id: source:p)\n- picture"), "no words, no colon")
        #expect(text.contains("(item_id: picture:i)\n</canvas_cards>"), "a picture's name is its title, not said twice")
        #expect(text.contains("get_knowledge_map"))
    }

    @Test("A chat without the tool is told the rest cannot be read, not invited to call it")
    func withoutTool() {
        let text = context.instruction(canReadCanvas: false)
        #expect(!text.contains("get_knowledge_map"))
        #expect(text.contains("cannot be read in this chat"))
    }

    @Test("The canvas alone, with no card, still says the chat was opened from it")
    func noCards() {
        let text = KnowledgeMapChatContext(canvasID: "cnv-1", name: "Fusion", cards: []).instruction(canReadCanvas: true)
        #expect(text.contains("opened this chat from it"))
        #expect(!text.contains("<canvas_cards>"))
    }

    @Test("The session's prompt carries it only while the chat holds a canvas context")
    func sessionPrompt() {
        let tool = ReviewSessionManager.AppToolDefinition(name: "get_knowledge_map", description: "x", inputSchemaJSON: "{}")
        let with = ReviewSessionManager.canvasContextPromptForTesting(context: context, appTools: [tool])
        #expect(with.contains("canvas_id: cnv-42") && with.contains("Call get_knowledge_map"))
        #expect(ReviewSessionManager.canvasContextPromptForTesting(context: context).contains("cannot be read in this chat"))
        #expect(ReviewSessionManager.canvasContextPromptForTesting(context: nil).isEmpty)
    }

    @Test("Cards added to a chat follow its own, replace them for another canvas, and come out one at a time")
    func manager() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeMapChatManager_\(UUID().uuidString)", isDirectory: true)
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: root))
        #expect(manager.canvasContext == nil)
        manager.addCanvasCards(canvasID: "cnv-1", name: "One", cards: [card("idea:a")], replacing: false)
        manager.addCanvasCards(canvasID: "cnv-1", name: "One again", cards: [card("idea:b")], replacing: false)
        #expect(manager.canvasContext?.cards.map(\.ref) == ["idea:a", "idea:b"] && manager.canvasContext?.name == "One again")
        manager.addCanvasCards(canvasID: "cnv-2", name: "Two", cards: [card("idea:c")], replacing: false)
        #expect(manager.canvasContext?.canvasID == "cnv-2" && manager.canvasContext?.cards.map(\.ref) == ["idea:c"], "another canvas starts over")
        manager.addCanvasCards(canvasID: "cnv-2", name: "Two", cards: [card("idea:d")], replacing: true)
        #expect(manager.canvasContext?.cards.map(\.ref) == ["idea:d"])
        manager.removeCanvasCard("idea:d")
        #expect(manager.canvasContext?.cards.isEmpty == true, "the canvas chip stays with no cards")
        manager.removeCanvasContext()
        #expect(manager.canvasContext == nil)
        manager.addCanvasCards(canvasID: "cnv-1", name: "One", cards: [card("idea:a")], replacing: true)
        manager.endSession()
        #expect(manager.canvasContext == nil, "a new chat starts with none")
    }
}

@MainActor
@Suite("Add to Chat and Ask in Chat, on the view model")
struct KnowledgeMapAddToChatTests {
    private func withViewModel(_ body: (StudioViewModel) throws -> Void) throws {
        let suiteName = "KnowledgeMapAddToChatTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeMapAddToChat_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: defaults)) {
            try PageSpaceRows.$overrideDefaults.withValue(.init(defaults: defaults)) {
                let vm = StudioViewModel(storageService: StorageService(storeRoot: root), observeCloudKitChanges: false)
                func paper(_ id: String) -> StudioArticle {
                    StudioArticle(url: "https://example.com/\(id)", title: "Paper \(id)", sourceType: .paper, id: id)
                }
                let papers = [paper("p"), paper("q")]
                let ideas = [IdeaRecord(id: "a", title: "What fuses first?", notes: "Fusion order\nis unknown."), IdeaRecord(id: "b", title: "A claim")]
                vm.knowledgeMap.rebuildContent(
                    articles: papers, ideas: ideas, notebooks: [], chats: [], artifacts: [], firstHighlights: [:],
                    pages: [KnowledgeMapPageCard(ref: "page:q:2", aspect: nil)]
                )
                vm.knowledgeMap.place([(ref: "idea:a", x: 0, y: 0), (ref: "source:p", x: 300, y: 0)])
                try body(vm)
            }
        }
    }

    @Test("The cards of a selection, in order, each once, from what the canvas holds, at most 24")
    func cards() throws {
        try withViewModel { vm in
            let cards = vm.knowledgeMapChatCards(["source:p", "idea:a", "source:p", "idea:gone", "idea:b"])
            #expect(cards.map(\.ref) == ["source:p", "idea:a", "idea:b"])
            #expect(cards[1].words == "Fusion order is unknown." && cards[1].kind == "idea" && cards[0].title == "Paper p")
            #expect(vm.knowledgeMapChatSourceIDs(cards) == ["p"])
            let page = vm.knowledgeMapChatCards(["page:q:2", "source:q", "page:q:3"])
            #expect(page.map(\.ref) == ["page:q:2", "source:q"])
            #expect(vm.knowledgeMapChatSourceIDs(page) == ["q"], "a page and its paper bring the paper once")
            #expect(page[0].words == "Page 2 of Paper q.")
        }
    }

    @Test("Ask in Chat opens a fresh chat with the cards as its context, replacing, and types nothing")
    func askInChat() throws {
        try withViewModel { vm in
            vm.requestChatAboutKnowledgeMapSelection(["source:p", "idea:a"])
            let handOff = try #require(vm.pendingChatCanvasCards)
            #expect(handOff.replaces && handOff.cards.map(\.ref) == ["source:p", "idea:a"])
            #expect(handOff.canvasID == vm.knowledgeMap.mapID && handOff.windowID == vm.activeWindowState.id)
            #expect(vm.pendingReviewChatDraft == nil, "nothing typed")
            #expect(vm.reviewChatResetRequestID != nil, "a fresh chat")
        }
    }

    @Test("Add to Chat with no chat beside the canvas opens one with the cards; with one visible, they join it")
    func addToChat() throws {
        try withViewModel { vm in
            let window = vm.activeWindowState
            window.centerTabGroups = StudioCenterTabGroups(groups: [.init(tabs: [.reader, .chat], activeTab: .reader)])
            vm.addKnowledgeMapCardsToChat(["idea:a"], in: window)
            let fresh = try #require(vm.pendingChatCanvasCards)
            #expect(!fresh.replaces && fresh.cards.map(\.ref) == ["idea:a"])
            #expect(vm.reviewChatResetRequestID != nil && vm.pendingReviewChatDraft == nil)
            #expect(!vm.pendingReviewChatCanvasQuestions.isEmpty, "the canvas's suggested questions are offered")

            vm.pendingChatCanvasCards = nil
            vm.reviewChatResetRequestID = nil
            window.centerTabGroups = StudioCenterTabGroups(groups: [
                .init(tabs: [.reader], activeTab: .reader), .init(tabs: [.chat], activeTab: .chat),
            ])
            vm.addKnowledgeMapCardsToChat(["idea:b"], in: window)
            #expect(vm.pendingChatCanvasCards?.cards.map(\.ref) == ["idea:b"])
            #expect(vm.reviewChatResetRequestID == nil, "the open chat is not reset")

            vm.pendingChatCanvasCards = nil
            vm.addKnowledgeMapCardsToChat(["idea:gone"], in: window)
            #expect(vm.pendingChatCanvasCards == nil, "nothing the canvas holds, nothing to add")
        }
    }
}

@Suite("Which card acts a selection takes")
struct KnowledgeMapCardActionsTests {
    private func card(
        _ ref: String,
        kind: String = "source",
        placed: Bool = true,
        question: Bool = false,
        pdf: Bool = true,
        page: Int? = nil,
        pageCount: Int? = nil,
        plain: Bool = false,
        answered: Bool = false,
        annotated: Bool = false
    ) -> KnowledgeMapCardActions.Card {
        .init(ref: ref, kind: kind, isPlaced: placed, isQuestion: question, hasPDF: pdf, page: page, pageCount: pageCount, isPlain: plain, isAnswered: answered, hasAnnotation: annotated)
    }

    @Test("Show Page for papers with a PDF here, Show as Card once every one shows a page, only the others when mixed")
    func face() {
        #expect(KnowledgeMapCardActions(cards: [card("source:a"), card("source:b")]).face == .showPage(["source:a", "source:b"]))
        #expect(KnowledgeMapCardActions(cards: [card("source:a", page: 2), card("source:b", page: 1)]).face == .showAsCard(["source:a", "source:b"]))
        #expect(KnowledgeMapCardActions(cards: [card("source:a", page: 2), card("source:b")]).face == .showPage(["source:b"]))
        #expect(KnowledgeMapCardActions(cards: [card("source:a"), card("idea:i", kind: "idea")]).face == nil, "an Idea cannot show a page")
        #expect(KnowledgeMapCardActions(cards: [card("source:a", pdf: false, page: 3)]).face == nil, "no PDF here: the usual face")
        #expect(KnowledgeMapCardActions(cards: [card("source:a", placed: false)]).face == nil)
        #expect(KnowledgeMapCardActions(cards: []).face == nil)
    }

    @Test("Next and Previous Page for one page face, stopping at its ends")
    func pageTurn() {
        let first = KnowledgeMapCardActions(cards: [card("source:a", page: 1, pageCount: 5)]).pageTurn
        #expect(first == .init(ref: "source:a", page: 1, pageCount: 5, canGoBack: false, canGoForward: true))
        let last = KnowledgeMapCardActions(cards: [card("source:a", page: 5, pageCount: 5)]).pageTurn
        #expect(last?.canGoBack == true && last?.canGoForward == false)
        let unknown = KnowledgeMapCardActions(cards: [card("source:a", page: 3)]).pageTurn
        #expect(unknown?.pageCount == nil && unknown?.canGoForward == true, "the PDF not read yet: forward is allowed")
        #expect(KnowledgeMapCardActions(cards: [card("source:a")]).pageTurn == nil, "the usual face has no pages to turn")
        #expect(KnowledgeMapCardActions(cards: [card("source:a", page: 1), card("source:b", page: 1)]).pageTurn == nil, "one card at a time")
    }

    @Test("Annotate for one card that is not an Idea, Edit Annotation once it has words")
    func annotation() {
        #expect(KnowledgeMapCardActions(cards: [card("source:a")]).annotation == .init(ref: "source:a", isEdit: false))
        #expect(KnowledgeMapCardActions(cards: [card("clip:c", kind: "clip", annotated: true)]).annotation == .init(ref: "clip:c", isEdit: true))
        #expect(KnowledgeMapCardActions(cards: [card("idea:i", kind: "idea")]).annotation == nil, "an Idea's note holds its words")
        #expect(KnowledgeMapCardActions(cards: [card("source:a"), card("source:b")]).annotation == nil)
    }

    @Test("Show as Words for Ideas not drawn as words; Show as Note once all are")
    func words() {
        let mixed = KnowledgeMapCardActions(cards: [card("idea:a", kind: "idea", plain: true), card("idea:b", kind: "idea")])
        #expect(mixed.words == .showAsWords(["idea:b"]))
        let all = KnowledgeMapCardActions(cards: [card("idea:a", kind: "idea", plain: true), card("idea:b", kind: "idea", plain: true)])
        #expect(all.words == .showAsNote(["idea:a", "idea:b"]))
        #expect(KnowledgeMapCardActions(cards: [card("idea:a", kind: "idea"), card("source:p")]).words == nil)
    }

    @Test("Mark Answered for questions only; Mark Open once every one is answered")
    func answered() {
        let open = KnowledgeMapCardActions(cards: [card("idea:a", kind: "idea", question: true), card("idea:b", kind: "idea", question: true, answered: true)])
        #expect(open.answered == .markAnswered(["idea:a"]))
        let done = KnowledgeMapCardActions(cards: [card("idea:a", kind: "idea", question: true, answered: true)])
        #expect(done.answered == .markOpen(["idea:a"]))
        #expect(KnowledgeMapCardActions(cards: [card("idea:a", kind: "idea", question: true), card("idea:b", kind: "idea")]).answered == nil, "a claim is not a question")
    }

    @Test("A selection with a card not placed on the canvas takes none of them")
    func unplaced() {
        let actions = KnowledgeMapCardActions(cards: [card("idea:a", kind: "idea", question: true), card("idea:b", kind: "idea", placed: false)])
        #expect(actions.words == nil && actions.answered == nil && actions.face == nil && actions.annotation == nil)
    }
}
