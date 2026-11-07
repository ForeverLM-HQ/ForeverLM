import Foundation
import Testing
@testable import ForeverLM

/// The notebook a Studio window holds: the pure model (`NotebookWorkspace`),
/// its routing table and its decoding across builds.
@Suite("Notebook workspace")
struct NotebookWorkspaceTests {

    // MARK: - Routing

    @Test("Chat is the chat, readable surfaces take the document slot, the rest leave the notebook")
    func routeTable() {
        let expected: [StudioCenterTab: NotebookRoute] = [
            .chat: .chat,
            .secondaryChat: .document(.secondChat),
            .reader: .document(.reader),
            .notepad: .document(.docs),
            .sites: .document(.sites),
            .animations: .document(.animations),
            .browser: .document(.browser),
            // Memory spans every notebook and is narrowed to one inside it.
            .memory: .document(.memory),
            // The Space, the full-window Library, the Canvas (the whole
            // library's plane) and the Atlas (a place like it) leave it.
            .library: .leave,
            .knowledgeMap: .leave,
            .atlas: .leave,
            .activity: .leave,
            .activityLog: .leave,
            .tasks: .leave,
            .goals: .leave,
            .ideas: .leave,
            .videos: .leave,
            .artifacts: .leave,
            .courses: .leave,
            // Plugins are the app's, as the Library is.
            .plugins: .leave,
        ]
        // Every tab has an answer here, so a new tab cannot slip past the table.
        #expect(Set(expected.keys) == Set(StudioCenterTab.allCases))
        for tab in StudioCenterTab.allCases {
            #expect(NotebookWorkspace.route(tab, coursePageID: nil) == expected[tab], "\(tab)")
        }
    }

    @Test("Courses opens in the notebook only with a course page")
    func coursesRouteFollowsThePage() {
        #expect(NotebookWorkspace.route(.courses, coursePageID: "course-1") == .document(.coursePage))
        #expect(NotebookWorkspace.route(.courses, coursePageID: nil) == .leave)
        // The page matters to Courses alone.
        #expect(NotebookWorkspace.route(.reader, coursePageID: "course-1") == .document(.reader))
        #expect(NotebookWorkspace.route(.artifacts, coursePageID: "course-1") == .leave)
    }

    @Test("Each document's tab routes back to it, so a window reports what its slot shows")
    func documentsAndTheirTabsAgree() {
        for document in NotebookDocument.allCases {
            guard let tab = document.centerTab else {
                // Card practice and a picture from the chat: no center tab
                // routes to either.
                #expect(document == .flashcards || document == .picture, "\(document) has no tab")
                continue
            }
            #expect(NotebookWorkspace.route(tab, coursePageID: "course-1") == .document(document), "\(document)")
        }
        #expect(NotebookDocument.secondChat.isChat)
        #expect(!NotebookDocument.reader.isChat)
    }

    @Test("Following each tab's route: Chat comes on screen, a document takes the slot, the rest leave")
    func followingEveryTab() {
        let start = NotebookWorkspace(notebookID: "bio", document: .docs, showsChat: false, sourcesCollapsed: true)
        for tab in StudioCenterTab.allCases {
            for page in [nil, "course-1"] as [String?] {
                let route = NotebookWorkspace.route(tab, coursePageID: page)
                let next = start.following(route)
                switch route {
                case .chat:
                    #expect(next?.showsChat == true)
                    #expect(next?.document == .docs, "the slot keeps its document")
                case .document(let document):
                    #expect(next?.document == document, "\(tab)")
                    #expect(next?.showsChat == false, "a document never hides or shows the chat")
                    #expect(next?.visibleTabs.contains(tab) == true, "\(tab)")
                case .leave:
                    #expect(next == nil, "\(tab)")
                }
                // Following a route is never a change to the arrangement.
                #expect(next.map(\.sourcesCollapsed) ?? true)
            }
        }
    }

    @Test("Closing a tab empties the slot that shows it, or hides Chat, and nothing else")
    func closingEveryTab() {
        let start = NotebookWorkspace(notebookID: "bio", document: .reader)
        for tab in StudioCenterTab.allCases {
            let next = start.closing(tab)
            switch tab {
            case .chat:
                #expect(next == NotebookWorkspace(notebookID: "bio", document: .reader, showsChat: false))
            case .reader:
                #expect(next == NotebookWorkspace(notebookID: "bio"))
            default:
                #expect(next == start, "\(tab) is not on screen here")
            }
        }
        #expect(NotebookWorkspace(notebookID: "bio", document: .secondChat).closing(.secondaryChat).document == nil)
        #expect(NotebookWorkspace(notebookID: "bio", document: .coursePage).closing(.courses).document == nil)
    }

    @Test("Revealing beside a companion keeps the chat, and the requested tab wins the one slot")
    func revealingBesideACompanion() {
        let bare = NotebookWorkspace(notebookID: "bio", showsChat: false)
        // A Reader beside the chat: both on screen.
        #expect(bare.revealing(.reader, beside: .chat, coursePageID: nil)
            == NotebookWorkspace(notebookID: "bio", document: .reader))
        // Chat beside a Doc: the Doc takes the slot, the chat shows.
        #expect(bare.revealing(.chat, beside: .notepad, coursePageID: nil)
            == NotebookWorkspace(notebookID: "bio", document: .docs))
        // A Doc's source chip with Chat showing: the Reader takes the one
        // slot, and remembers the Doc for its Back to.
        let docOpen = NotebookWorkspace(notebookID: "bio", document: .docs)
        #expect(docOpen.revealing(.reader, beside: .notepad, coursePageID: nil)
            == NotebookWorkspace(notebookID: "bio", document: .reader, slotTabs: [.docs, .reader], returnDocument: .docs))
        // A companion with no place here is passed over.
        #expect(bare.revealing(.chat, beside: .goals, coursePageID: nil)
            == NotebookWorkspace(notebookID: "bio"))
        // A tab with no place here leaves the notebook.
        #expect(docOpen.revealing(.activity, beside: .chat, coursePageID: nil) == nil)
    }

    @Test("A link never closes what it was read in: with Chat hidden the Reader opens in the chat's place")
    func linkOpensBesideTheDocumentItCameFrom() {
        // A Doc alone, Chat hidden: its source chip puts the Reader beside it.
        let docAlone = NotebookWorkspace(notebookID: "bio", document: .docs, showsChat: false)
        let readerBesideDoc = NotebookWorkspace(notebookID: "bio", document: .docs, leadingDocument: .reader, showsChat: false)
        #expect(docAlone.revealing(.reader, beside: .notepad, coursePageID: nil) == readerBesideDoc)
        // The same from a second chat in the slot.
        let secondChatAlone = NotebookWorkspace(notebookID: "bio", document: .secondChat, showsChat: false)
        #expect(secondChatAlone.revealing(.reader, beside: .secondaryChat, coursePageID: nil)
            == NotebookWorkspace(notebookID: "bio", document: .secondChat, leadingDocument: .reader, showsChat: false))
        // A second link from the Doc navigates the Reader where it stands.
        #expect(readerBesideDoc.revealing(.reader, beside: .notepad, coursePageID: nil) == readerBesideDoc)
        #expect(readerBesideDoc.following(.document(.reader)) == readerBesideDoc)
        // From the Reader in the chat's place, a Doc takes the slot.
        let readerBesideSite = NotebookWorkspace(notebookID: "bio", document: .sites, leadingDocument: .reader, showsChat: false)
        // The Site stays open behind the Doc as a tab.
        #expect(readerBesideSite.revealing(.notepad, beside: .reader, coursePageID: nil)
            == NotebookWorkspace(
                notebookID: "bio", document: .docs, slotTabs: [.sites, .docs],
                leadingDocument: .reader, showsChat: false
            ))
        #expect(readerBesideDoc.visibleTabs == [.reader, .notepad])
        #expect(readerBesideDoc.centerPaneCount == 2)
        #expect(readerBesideDoc.visibleDocuments == [.reader, .docs])

        // Chat coming back takes its place; the Reader moves into the slot,
        // with the Doc behind its Back to.
        let chatBack = NotebookWorkspace(notebookID: "bio", document: .reader, slotTabs: [.docs, .reader], returnDocument: .docs)
        #expect(readerBesideDoc.following(.chat) == chatBack)
        #expect(readerBesideDoc.revealing(.chat, beside: .reader, coursePageID: nil) == chatBack)
        // Back to restores the Doc and forgets it.
        #expect(chatBack.returning() == NotebookWorkspace(notebookID: "bio", document: .docs))
        #expect(NotebookWorkspace(notebookID: "bio", document: .reader).returning()
            == NotebookWorkspace(notebookID: "bio", document: .reader), "nothing to go back to")

        // The Reader's × in the chat's place leaves the Doc; the slot's ×
        // shows the Doc, its neighbour, and forgets what it would have gone
        // back to.
        #expect(readerBesideDoc.closing(.reader) == docAlone)
        #expect(chatBack.closing(.reader) == NotebookWorkspace(notebookID: "bio", document: .docs))
        // Anything but the Reader taking the slot forgets the Back to; the
        // Doc and the Reader stay open behind it as tabs.
        #expect(chatBack.following(.document(.browser))
            == NotebookWorkspace(notebookID: "bio", document: .browser, slotTabs: [.docs, .reader, .browser]))
    }

    @Test("Documents opened in the slot stay open as tabs, and the strip shows for one too")
    func slotKeepsDocumentsAsTabs() throws {
        let bare = NotebookWorkspace(notebookID: "bio")
        let reader = try #require(bare.following(.document(.reader)))
        #expect(reader.slotTabStrip == [.reader])
        #expect(reader.slotShowsTabStrip, "a lone document draws its tab, as every pane does")

        let withDocs = try #require(reader.following(.document(.docs)))
        #expect(withDocs.document == .docs)
        #expect(withDocs.slotTabStrip == [.reader, .docs])
        #expect(withDocs.slotShowsTabStrip)
        // A click on an open tab brings it forward where it is.
        let backToReader = try #require(withDocs.following(.document(.reader)))
        #expect(backToReader.document == .reader)
        #expect(backToReader.slotTabStrip == [.reader, .docs], "tab order does not move")
        // Opening a third adds it at the end.
        let three = try #require(backToReader.following(.document(.browser)))
        #expect(three.slotTabStrip == [.reader, .docs, .browser])
    }

    @Test("A tabbed notebook is an arrangement: it survives a relaunch and an older snapshot reads as untabbed")
    func tabbedNotebook() throws {
        let fresh = NotebookWorkspace(notebookID: "bio")
        #expect(!fresh.tabbed)
        let tabbed = NotebookWorkspace(notebookID: "bio", document: .reader, tabbed: true)
        // The arrangement stays, the moment (the document) goes.
        #expect(tabbed.persisted.tabbed)
        #expect(tabbed.persisted.document == nil)
        let data = try JSONEncoder().encode(tabbed)
        #expect(try JSONDecoder().decode(NotebookWorkspace.self, from: data).tabbed)
        // A snapshot an earlier build wrote names no such key.
        let older = Data(#"{"notebookID":"bio","showsChat":true}"#.utf8)
        #expect(try JSONDecoder().decode(NotebookWorkspace.self, from: older).tabbed == false)
    }

    @Test("A tabbed notebook's center is the window's panes, so its minimum is theirs")
    func tabbedCenterMinimum() {
        let tabbed = NotebookWorkspace(notebookID: "bio", tabbed: true)
        #expect(NotebookWorkspaceSizing.centerMinimumWidth(for: tabbed, panesMinimum: 900) == 900)
        // Without the panes' minimum, one chat's width.
        #expect(
            NotebookWorkspaceSizing.centerMinimumWidth(for: tabbed)
                == StudioCenterTabGroupSizing.minimumChatContentWidth
        )
        // The slot's rule is unchanged for an ordinary notebook.
        let ordinary = NotebookWorkspace(notebookID: "bio")
        #expect(NotebookWorkspaceSizing.centerMinimumWidth(for: ordinary, panesMinimum: 900) != 900)
    }

    @Test("A slot tab dragged to a side stands beside the other document with the chat kept, and Chat hiding then returning makes them tabs again")
    func splittingTheSlot() throws {
        var pair = NotebookWorkspace(notebookID: "bio")
        for document in [NotebookDocument.reader, .docs] {
            pair = try #require(pair.following(.document(document)))
        }
        // Notes dragged to the right: the video leads, the notes take the slot,
        // and the chat stays as the third pane.
        let right = try #require(pair.splittingSlot(moving: .notepad, toTrailing: true))
        #expect(right.showsChat)
        #expect(right.leadingDocument == .reader)
        #expect(right.splitDocument == .reader)
        #expect(right.document == .docs)
        #expect(right.slotTabStrip == [.docs] && right.slotShowsTabStrip)
        #expect(right.visibleDocuments == [.reader, .docs])
        #expect(right.centerPaneCount == 3)
        // Notes dragged to the left.
        let left = try #require(pair.splittingSlot(moving: .notepad, toTrailing: false))
        #expect(left.splitDocument == .docs)
        #expect(left.document == .reader)
        // A third tab stays a tab of the slot's own strip.
        let three = try #require(pair.following(.document(.browser)))
        let withThird = try #require(three.splittingSlot(moving: .notepad, toTrailing: true))
        #expect(withThird.leadingDocument == .browser)
        #expect(withThird.slotTabStrip == [.reader, .docs])
        // Asking for the chat while it shows leaves the split alone.
        let still = try #require(right.following(.chat))
        #expect(still == right)
        // A split again sends the document that stood there back to the slot.
        let again = try #require(withThird.splittingSlot(moving: .reader, toTrailing: true))
        #expect(Set(again.slotTabStrip + [again.leadingDocument].compactMap { $0 }) == [.reader, .docs, .browser])
        // The chat hides: the split stands in its place, as a document asked
        // from the slot with the chat hidden does. Chat coming back moves the
        // leading document into the slot.
        let hidden = right.closing(.chat)
        #expect(!hidden.showsChat && hidden.splitDocument == nil && hidden.visibleDocuments == [.reader, .docs])
        let back = try #require(hidden.following(.chat))
        #expect(back.showsChat && back.leadingDocument == nil)
        #expect(Set(back.slotTabStrip) == [.reader, .docs])
        // The slot's document closing leaves the split's in its place.
        let closedSlot = right.closing(.notepad)
        #expect(closedSlot.document == .reader && closedSlot.leadingDocument == nil && closedSlot.showsChat)
        #expect(right.closingSlot().document == .reader)
        // Closing the split's document keeps the slot and the chat.
        let closedSplit = right.closing(.reader)
        #expect(closedSplit.leadingDocument == nil && closedSplit.document == .docs && closedSplit.showsChat)
        // Nothing to split with one document, or for a tab the slot lacks.
        let lone = NotebookWorkspace(notebookID: "bio", document: .reader)
        #expect(lone.splittingSlot(moving: .reader, toTrailing: true) == nil)
        #expect(pair.splittingSlot(moving: .browser, toTrailing: true) == nil)
    }

    @Test("Three panes — the split document, the slot's and the chat — share the center, each at its minimum or more")
    func threePaneLayout() throws {
        typealias Sizing = NotebookWorkspaceSizing
        var pair = NotebookWorkspace(notebookID: "bio")
        for document in [NotebookDocument.reader, .docs] {
            pair = try #require(pair.following(.document(document)))
        }
        let split = try #require(pair.splittingSlot(moving: .notepad, toTrailing: true))
        let chatMinimum = StudioCenterTabGroupSizing.minimumChatContentWidth
        let needed = 2 * Sizing.documentMinimumWidth + chatMinimum + 2 * Sizing.dividerWidth
        #expect(Sizing.centerMinimumWidth(for: split) == needed)

        let wide = Sizing.centerLayout(for: split, centerWidth: 1_600, leadingFraction: 0.5)
        #expect(wide.splitDocument == .reader && wide.showsSplitDivider && wide.showsDivider)
        let chat = try #require(wide.leadingWidth)
        let document = try #require(wide.documentWidth)
        let splitWidth = try #require(wide.splitWidth)
        #expect(abs(chat + document + splitWidth + 2 * Sizing.dividerWidth - 1_600) < 0.5)
        #expect(splitWidth >= Sizing.documentMinimumWidth)
        #expect(document >= Sizing.documentMinimumWidth)
        #expect(chat >= chatMinimum)

        // The chat hidden: the two documents, no split divider.
        let hidden = Sizing.centerLayout(for: split.closing(.chat), centerWidth: 1_600, leadingFraction: 0.5)
        #expect(hidden.splitDocument == nil && hidden.leadingDocument == .reader && !hidden.showsSplitDivider)
    }

    @Test("Closing a slot tab shows its right neighbour, else its left, and the last one empties the slot")
    func closingSlotTabs() {
        var three = NotebookWorkspace(notebookID: "bio")
        for document in [NotebookDocument.reader, .docs, .browser] {
            three = three.following(.document(document))!
        }
        // The active tab last in the strip: its left neighbour shows.
        let closedBrowser = three.closing(.browser)
        #expect(closedBrowser.document == .docs)
        #expect(closedBrowser.slotTabStrip == [.reader, .docs])
        // A middle tab closing shows the one to its right.
        let docsActive = three.following(.document(.docs))!
        let closedDocs = docsActive.closing(.notepad)
        #expect(closedDocs.document == .browser)
        #expect(closedDocs.slotTabStrip == [.reader, .browser])
        // An inactive tab closes without moving the active one.
        let closedReader = docsActive.closing(.reader)
        #expect(closedReader.document == .docs)
        #expect(closedReader.slotTabStrip == [.docs, .browser])
        // Down to one tab the strip goes, and the slot is the plain
        // workspace again; closing it empties the slot.
        let lone = closedReader.closing(.browser)
        #expect(lone == NotebookWorkspace(notebookID: "bio", document: .docs))
        #expect(lone.closing(.notepad) == NotebookWorkspace(notebookID: "bio"))
        // The slot's own × closes every tab.
        #expect(three.closingSlot() == NotebookWorkspace(notebookID: "bio"))
    }

    @Test("Slot tabs are a moment: a relaunch reopens the notebook with an empty slot")
    func slotTabsAreNotPersisted() {
        var workspace = NotebookWorkspace(notebookID: "bio")
        for document in [NotebookDocument.reader, .docs] {
            workspace = workspace.following(.document(document))!
        }
        #expect(workspace.persisted == NotebookWorkspace(notebookID: "bio"))
    }

    @Test("What the center shows, as tabs and panes")
    func visibleTabsAndPanes() {
        #expect(NotebookWorkspace(notebookID: "bio").visibleTabs == [.chat])
        #expect(NotebookWorkspace(notebookID: "bio").centerPaneCount == 1)
        #expect(NotebookWorkspace(notebookID: "bio", document: .browser).visibleTabs == [.chat, .browser])
        #expect(NotebookWorkspace(notebookID: "bio", document: .browser).centerPaneCount == 2)
        #expect(NotebookWorkspace(notebookID: "bio", document: .flashcards, showsChat: false).visibleTabs.isEmpty)
        #expect(NotebookWorkspace(notebookID: "bio", showsChat: false).centerPaneCount == 0)
    }

    @Test("A chat's home is its notebook, or the notebook its Goal draws on, or the library")
    func chatHome() {
        let notebooks: Set<String> = ["bio", "neuro"]
        let parents = ["goal-1": "bio", "goal-orphan": "archived"]
        #expect(NotebookWorkspace.home(ofChatFiledUnder: "bio", notebookIDs: notebooks, parentNotebookByGoalID: parents) == "bio")
        #expect(NotebookWorkspace.home(ofChatFiledUnder: "goal-1", notebookIDs: notebooks, parentNotebookByGoalID: parents) == "bio")
        #expect(NotebookWorkspace.home(ofChatFiledUnder: "goal-orphan", notebookIDs: notebooks, parentNotebookByGoalID: parents) == nil)
        #expect(NotebookWorkspace.home(ofChatFiledUnder: "archived", notebookIDs: notebooks, parentNotebookByGoalID: parents) == nil)
        #expect(NotebookWorkspace.home(ofChatFiledUnder: nil, notebookIDs: notebooks, parentNotebookByGoalID: parents) == nil)
        #expect(NotebookWorkspace.home(ofChatFiledUnder: "", notebookIDs: notebooks, parentNotebookByGoalID: parents) == nil)
    }

    // MARK: - Opening and persisting

    @Test("Reopening the open notebook keeps its arrangement; another notebook starts fresh")
    func openingKeepsOnlyTheSameNotebook() {
        let arranged = NotebookWorkspace(
            notebookID: "bio",
            document: .docs,
            showsChat: false,
            sourcesCollapsed: true,
            studioCollapsed: true
        )
        #expect(NotebookWorkspace.opening("bio", over: arranged) == arranged)
        #expect(NotebookWorkspace.opening("neuro", over: arranged) == NotebookWorkspace(notebookID: "neuro"))
        #expect(NotebookWorkspace.opening("bio", over: nil) == NotebookWorkspace(notebookID: "bio"))
    }

    @Test("A fresh notebook shows its chat with both columns open, its Studio beside it")
    func freshWorkspace() {
        let fresh = NotebookWorkspace(notebookID: "bio")
        #expect(fresh.document == nil)
        #expect(fresh.leadingDocument == nil)
        #expect(fresh.returnDocument == nil)
        #expect(fresh.showsChat)
        #expect(!fresh.sourcesCollapsed)
        #expect(!fresh.studioCollapsed)
    }

    @Test("A window builds 175 and 176 kept on Library or About reopens on the Studio, folded as it was")
    func olderFacesDecode() throws {
        for face in ["studio", "library", "about", "audio"] {
            let decoded = try JSONDecoder().decode(
                NotebookWorkspace.self,
                from: Data(#"{"notebookID":"bio","trailing":"\#(face)","trailingCollapsed":true}"#.utf8)
            )
            #expect(decoded == NotebookWorkspace(notebookID: "bio", studioCollapsed: true), "the fold is the Studio's; the face is not read")
        }
        // The fold keeps the key those builds wrote, so going back to one
        // still reads it; the face they no longer need is not written.
        let encoded = try JSONEncoder().encode(NotebookWorkspace(notebookID: "bio", studioCollapsed: true))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["trailingCollapsed"] as? Bool == true)
        #expect(object["trailing"] == nil)
        #expect(object["studioCollapsed"] == nil)
    }

    @Test("What is kept leaves out the moments — the documents and the Back to — and nothing else")
    func persistedDropsOnlyTheMoments() {
        let arranged = NotebookWorkspace(
            notebookID: "bio",
            document: .docs,
            leadingDocument: .reader,
            returnDocument: .sites,
            showsChat: false,
            sourcesCollapsed: true,
            studioCollapsed: true
        )
        var expected = arranged
        expected.document = nil
        expected.leadingDocument = nil
        expected.returnDocument = nil
        #expect(arranged.persisted == expected)
        #expect(arranged.persisted.persisted == expected)
    }

    @Test("The document stands left of the chat by default, until the learner swaps them, and a lone pane has no side")
    func documentLeadsTheChat() throws {
        let beside = NotebookWorkspace(notebookID: "bio", document: .reader)
        #expect(beside.documentLeads, "Reader left of the chat is the default")
        #expect(beside.documentPrecedesChat)

        var swapped = beside
        swapped.documentLeads.toggle()
        #expect(!swapped.documentPrecedesChat)

        #expect(!NotebookWorkspace(notebookID: "bio").documentPrecedesChat, "no document, no side")
        #expect(!NotebookWorkspace(notebookID: "bio", document: .reader, showsChat: false).documentPrecedesChat)

        // The order is an arrangement: it survives `persisted` and a round
        // trip, and a snapshot an older build wrote reads as the default.
        #expect(!swapped.persisted.documentLeads)
        let data = try JSONEncoder().encode(swapped)
        #expect(try JSONDecoder().decode(NotebookWorkspace.self, from: data).documentLeads == false)
        let older = Data(#"{"notebookID":"bio","showsChat":true,"sourcesCollapsed":false,"trailingCollapsed":false}"#.utf8)
        #expect(try JSONDecoder().decode(NotebookWorkspace.self, from: older).documentLeads)
    }

    // MARK: - Decoding across builds

    @Test("A workspace round-trips through JSON")
    func roundTrip() throws {
        let arranged = NotebookWorkspace(
            notebookID: "bio",
            document: .coursePage,
            showsChat: false,
            sourcesCollapsed: true,
            studioCollapsed: true
        )
        let data = try JSONEncoder().encode(arranged)
        #expect(try JSONDecoder().decode(NotebookWorkspace.self, from: data) == arranged)

        let bare = try JSONEncoder().encode(NotebookWorkspace(notebookID: "bio"))
        let object = try #require(JSONSerialization.jsonObject(with: bare) as? [String: Any])
        #expect(object["document"] == nil, "no document, no key")
    }

    @Test("Keys an older build did not write take a fresh workspace's values")
    func missingKeysDecodeFresh() throws {
        let decoded = try JSONDecoder().decode(
            NotebookWorkspace.self,
            from: Data(#"{"notebookID":"bio"}"#.utf8)
        )
        #expect(decoded == NotebookWorkspace(notebookID: "bio"))

        let partial = try JSONDecoder().decode(
            NotebookWorkspace.self,
            from: Data(#"{"notebookID":"bio","sourcesCollapsed":true}"#.utf8)
        )
        #expect(partial == NotebookWorkspace(notebookID: "bio", sourcesCollapsed: true))
    }

    @Test("A document this build does not know still reopens the notebook")
    func unknownValuesDecodeLeniently() throws {
        let decoded = try JSONDecoder().decode(
            NotebookWorkspace.self,
            from: Data(#"{"notebookID":"bio","document":"mindMap","trailingCollapsed":true}"#.utf8)
        )
        #expect(decoded.notebookID == "bio")
        #expect(decoded.document == nil)
        #expect(decoded.studioCollapsed)

        // A chat on screen has the chat's place to itself, whatever was written.
        let crossed = try JSONDecoder().decode(
            NotebookWorkspace.self,
            from: Data(#"{"notebookID":"bio","showsChat":true,"leadingDocument":"reader"}"#.utf8)
        )
        #expect(crossed.leadingDocument == nil)
    }

    @Test("A workspace that names no notebook is not a workspace")
    func notebookIDIsRequired() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(NotebookWorkspace.self, from: Data(#"{"showsChat":true}"#.utf8))
        }
    }
}

/// The notebook belongs to the window: two windows hold two notebooks, a
/// change reaches only that window's scene snapshot, and the app-wide
/// `workbenchNotebookID` reads whichever window it acts in.
@Suite("Window-owned notebooks")
@MainActor
struct WindowNotebookTests {

    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// An active notebook of the library `teamID` names (nil: My Library).
    private static func notebook(_ id: String, title: String, teamID: String?) -> LearningGoalRecord {
        LearningGoalRecord(
            id: id,
            title: title,
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now,
            updatedAt: now,
            status: LearningGoalStatus.active.rawValue,
            items: [],
            kind: LearningGoalRecord.companionKind,
            teamID: teamID
        )
    }

    private func makeViewModel() -> StudioViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowNotebookTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StudioViewModel(storageService: StorageService(storeRoot: root))
    }

    private static let templateKeys = [
        "studio.centerTabGroups.v1",
        "studio.navigationRailVisible",
    ]

    /// The layout template every new window starts from, and MCP's active
    /// Notebook, which opening a notebook must leave alone: the unit host's
    /// defaults are the real ones, so each test puts them back.
    private func capturingSharedDefaults() -> () -> Void {
        let template = Self.templateKeys.map { UserDefaults.standard.object(forKey: $0) }
        let activeNotebookID = ActiveNotebookPreference.notebookID
        return {
            for (key, value) in zip(Self.templateKeys, template) {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            ActiveNotebookPreference.notebookID = activeNotebookID
        }
    }

    private func templateValues() -> [String] {
        Self.templateKeys.map { String(describing: UserDefaults.standard.object(forKey: $0)) }
    }

    @Test("A notebook's chats, for its Chats menus and guide, are those filed in it, in the rail's order, and never another's")
    func notebookChatsListsItsOwn() {
        let vm = makeViewModel()
        vm.learningGoals = [
            Self.notebook("bio", title: "Bioenergetics", teamID: vm.activeTeamID),
            Self.notebook("neuro", title: "Neuroscience", teamID: vm.activeTeamID),
        ]
        vm.reviewSessionLinks = [
            ReviewSessionRecord(id: "bio-new", title: "Complex I", createdAt: Self.now, status: "completed", sourceIDs: [], goalID: "bio"),
            ReviewSessionRecord(id: "neuro-1", title: "Synapses", createdAt: Self.now, status: "completed", sourceIDs: [], goalID: "neuro"),
            ReviewSessionRecord(id: "loose", title: "Unfiled", createdAt: Self.now, status: "completed", sourceIDs: []),
            ReviewSessionRecord(id: "bio-old", title: "ATP synthase", createdAt: Self.now.addingTimeInterval(-60), status: "completed", sourceIDs: [], goalID: "bio"),
        ]
        let chats = vm.notebookChats(notebookID: "bio")
        #expect(Set(chats.map(\.id)) == ["bio-new", "bio-old"])
        #expect(chats.map(\.id) == vm.reviewSessionGroups(for: [vm.notebook(id: "bio")!]).byNotebookID["bio"]?.map(\.id),
                "the rail's own order")
        #expect(vm.notebookChats(notebookID: "missing").isEmpty)
    }

    @Test("The guide's All chats search narrows by title, ignoring case and accents, and keeps the order")
    func allChatsSearchNarrowsByTitle() {
        let chats = [
            NotebookChatGuide.RecentChat(id: "a", title: "Alzheimer’s and Blood Flow", date: Self.now),
            NotebookChatGuide.RecentChat(id: "b", title: "Ontogeny of microglia", date: Self.now),
            NotebookChatGuide.RecentChat(id: "c", title: "Reprogramming Microglia", date: Self.now),
        ]
        #expect(NotebookChatGuide.chats(chats, matching: "").map(\.id) == ["a", "b", "c"])
        #expect(NotebookChatGuide.chats(chats, matching: "  ").map(\.id) == ["a", "b", "c"])
        #expect(NotebookChatGuide.chats(chats, matching: "MICROGLIA").map(\.id) == ["b", "c"])
        #expect(NotebookChatGuide.chats(chats, matching: " alzheimer ").map(\.id) == ["a"])
        #expect(NotebookChatGuide.chats(chats, matching: "ontogény").map(\.id) == ["b"])
        #expect(NotebookChatGuide.chats(chats, matching: "thyroid").isEmpty)
    }

    @Test("Two windows hold two notebooks, and each reads and closes its own")
    func twoWindowsHoldTwoNotebooks() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let vm = makeViewModel()
        // Both in whichever library the test host has open, so the marks count.
        vm.learningGoals = [
            Self.notebook("bio", title: "Bioenergetics", teamID: vm.activeTeamID),
            Self.notebook("neuro", title: "Neuroscience", teamID: vm.activeTeamID),
        ]
        let left = StudioWindowState()
        let right = StudioWindowState()

        StudioWindowDestination.notebook("bio").open(in: left, vm: vm)
        #expect(vm.activeNotebookId == "bio", "the active Notebook, a preference on this Mac, follows the notebook opened")
        StudioWindowDestination.notebook("neuro").open(in: right, vm: vm)
        #expect(vm.activeNotebookId == "neuro")

        #expect(left.NotebookID == "bio")
        #expect(right.NotebookID == "neuro")
        #expect(vm.inWindow(left) { vm.workbenchNotebookID } == "bio")
        #expect(vm.inWindow(right) { vm.workbenchNotebookID } == "neuro")
        #expect(vm.inWindow(left) { vm.railScopedNotebook?.id } == "bio")
        #expect(vm.railScopedNotebook(in: right)?.id == "neuro")
        #expect(vm.sidebarNotebook(in: left)?.title == "Bioenergetics")
        #expect(vm.sidebarNotebook(in: right)?.title == "Neuroscience")
        // The view model's own fallback window opened nothing.
        #expect(vm.workbenchNotebookID == nil)

        // A second click on the open folder closes it in that window only.
        vm.inWindow(left) { vm.toggleNotebookInReader("bio") }
        #expect(left.NotebookID == nil)
        #expect(right.NotebookID == "neuro")

        // Each window keeps its own notebook through its scene snapshot.
        #expect(StudioWindowState(snapshot: right.snapshot).NotebookID == "neuro")
        #expect(StudioWindowState(snapshot: left.snapshot).NotebookID == nil)
    }

    @Test("Opening a notebook advances only the window's scene snapshot, never the template")
    func openingWritesOnlyTheSceneSnapshot() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let window = StudioWindowState()
        let template = templateValues()
        let revision = window.persistenceRevision

        window.NotebookID = "bio"
        #expect(window.persistenceRevision == revision + 1)
        #expect(templateValues() == template)

        // Reopening it is no change; neither is a document, which is a
        // moment the snapshot does not keep.
        window.NotebookID = "bio"
        window.notebook?.document = .reader
        #expect(window.persistenceRevision == revision + 1)
        #expect(window.snapshot.notebook == NotebookWorkspace(notebookID: "bio"))

        // The arrangement is kept, so changing it is a change.
        window.notebook?.sourcesCollapsed = true
        #expect(window.persistenceRevision == revision + 2)

        window.NotebookID = nil
        #expect(window.persistenceRevision == revision + 3)
        #expect(templateValues() == template)

        // A brand-new window starts from the template, which never holds a
        // notebook.
        window.NotebookID = "bio"
        #expect(StudioWindowState().notebook == nil)
    }

    @Test("Archiving or merging a notebook reaches every window that holds it")
    func everyWindowFollowsArchiveAndMerge() {
        let vm = makeViewModel()
        let registered = StudioWindowState()
        let unrelated = StudioWindowState()
        StudioWindowRegistry.shared.register(registered)
        StudioWindowRegistry.shared.register(unrelated)
        defer {
            StudioWindowRegistry.shared.unregister(registered)
            StudioWindowRegistry.shared.unregister(unrelated)
        }

        registered.NotebookID = "old"
        unrelated.NotebookID = "other"
        vm.workbenchNotebookID = "old"
        vm.moveNotebookInEveryWindow("old", to: "survivor")
        #expect(registered.NotebookID == "survivor")
        #expect(vm.workbenchNotebookID == "survivor")
        #expect(unrelated.NotebookID == "other")

        vm.closeNotebookInEveryWindow("survivor")
        #expect(registered.notebook == nil)
        #expect(vm.workbenchNotebookID == nil)
        #expect(unrelated.NotebookID == "other")
    }

    @Test("MCP is told each window's notebook and which window is frontmost, as they change")
    func windowsPublishTheirNotebooksToMCP() {
        // Other suites register windows too, so this reads only its own.
        let first = StudioWindowState()
        let second = StudioWindowState()
        let firstID = "nb-\(UUID().uuidString)"
        let secondID = "nb-\(UUID().uuidString)"
        func published(_ notebookID: String) -> MCPAppWindows.Window? {
            MCPAppWindows.current.first { $0.notebookID == notebookID }
        }
        StudioWindowRegistry.shared.register(first)
        StudioWindowRegistry.shared.register(second)
        defer {
            StudioWindowRegistry.shared.unregister(first)
            StudioWindowRegistry.shared.unregister(second)
        }

        first.NotebookID = firstID
        second.NotebookID = secondID
        StudioWindowRegistry.shared.activate(second)
        #expect(published(secondID)?.isFrontmost == true)
        #expect(published(firstID)?.isFrontmost == false)
        #expect(MCPAppWindows.current.first?.notebookID == secondID)

        StudioWindowRegistry.shared.activate(first)
        #expect(published(firstID)?.isFrontmost == true)
        #expect(published(secondID)?.isFrontmost == false)

        // Leaving the notebook, and closing the window, both reach MCP.
        second.NotebookID = nil
        #expect(published(secondID) == nil)
        StudioWindowRegistry.shared.unregister(first)
        #expect(published(firstID) == nil)

        // A window no registry holds publishes nothing.
        let loose = StudioWindowState()
        let looseID = "nb-\(UUID().uuidString)"
        loose.NotebookID = looseID
        #expect(published(looseID) == nil)
    }

    @Test("In a notebook the window's sidebar toggle folds and shows the Sources column, and touches nothing else")
    func sidebarToggleFoldsSources() {
        let window = StudioWindowState()
        window.NotebookID = "bio"
        #expect(window.sidebarToggleReadsShown(spaceSidebarHidden: false))

        #expect(window.setSidebarShownFromToggle(false) == nil, "the Space sidebar's preference stays as it is")
        #expect(window.notebook?.sourcesCollapsed == true)
        #expect(!window.sidebarToggleReadsShown(spaceSidebarHidden: false))

        window.notebook?.sourcesCollapsed = false
        window.notebook?.sourcesExpanded = true
        _ = window.setSidebarShownFromToggle(false)
        #expect(window.notebook?.sourcesExpanded == false, "folded, the column keeps no search's list")

        #expect(window.setSidebarShownFromToggle(true) == nil)
        #expect(window.notebook?.sourcesCollapsed == false)
    }
}

/// The router: every center-tab entry point, asked of a window that holds a
/// notebook, lands in the notebook's chat or document slot, or leaves the
/// notebook for panes left exactly as they were.
@Suite("Notebook routing")
@MainActor
struct NotebookRoutingTests {

    private func makeViewModel() -> StudioViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookRoutingTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StudioViewModel(storageService: StorageService(storeRoot: root))
    }

    private static let templateKeys = [
        "studio.centerTabGroups.v1",
        "studio.navigationRailVisible",
    ]

    /// The unit host's defaults are the real ones: a pane change in the
    /// library underneath writes the template, so each test puts it back.
    private func capturingTemplate() -> () -> Void {
        let template = Self.templateKeys.map { UserDefaults.standard.object(forKey: $0) }
        return {
            for (key, value) in zip(Self.templateKeys, template) {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
    }

    /// A window holding `workspace` over the default panes, so what the
    /// developer's own template holds (pins, a third pane) cannot change
    /// what a request does underneath.
    private func notebookWindow(_ workspace: NotebookWorkspace = NotebookWorkspace(notebookID: "bio")) -> StudioWindowState {
        let window = StudioWindowState()
        window.centerTabGroups = .defaultLayout
        window.notebook = workspace
        return window
    }

    @Test("Activating each tab lands it in the chat or the document slot, or leaves the notebook")
    func activateRoutesEveryTab() {
        let restore = capturingTemplate()
        defer { restore() }
        let vm = makeViewModel()
        for tab in StudioCenterTab.allCases {
            for page in [nil, "course-1"] as [String?] {
                let window = notebookWindow(NotebookWorkspace(notebookID: "bio", showsChat: false))
                window.coursePageID = page
                let panes = window.centerTabGroups
                vm.activateCenterTab(tab, in: window)
                switch NotebookWorkspace.route(tab, coursePageID: page) {
                case .chat:
                    #expect(window.notebook?.showsChat == true)
                    #expect(window.centerTabGroups == panes, "the panes underneath stay as they were")
                case .document(let document):
                    #expect(window.notebook?.document == document, "\(tab)")
                    #expect(window.centerTabGroups == panes, "\(tab)")
                case .leave:
                    #expect(window.notebook == nil, "\(tab) leaves the notebook")
                    #expect(vm.visibleCenterTabs(in: window).contains(tab), "\(tab) opens in the panes")
                }
            }
        }
    }

    @Test("A window holding a notebook reports what its center shows")
    func visibleTabsComeFromTheNotebook() {
        let vm = makeViewModel()
        let window = notebookWindow(NotebookWorkspace(notebookID: "bio", document: .reader))
        #expect(vm.visibleCenterTabs(in: window) == [.chat, .reader])
        #expect(vm.inWindow(window) { vm.activeCenterTabs } == [.chat, .reader])
        #expect(vm.inWindow(window) { vm.showAssistantOverlay })
        window.notebook?.showsChat = false
        #expect(!vm.inWindow(window) { vm.showAssistantOverlay })
    }

    @Test("× closes the slot it is on, and a lone chat hides")
    func closeSlots() {
        let restore = capturingTemplate()
        defer { restore() }
        let vm = makeViewModel()
        let window = notebookWindow(NotebookWorkspace(notebookID: "bio", document: .reader))
        let panes = window.centerTabGroups

        // A tab's × in a notebook closes its slot; the panes underneath stay.
        vm.closeCenterTab(.reader, in: window)
        #expect(window.notebook == NotebookWorkspace(notebookID: "bio"))
        #expect(window.centerTabGroups == panes, "the panes underneath stay as they were")
        window.notebook = NotebookWorkspace(notebookID: "bio", document: .reader)

        vm.dismissCenterSurface(.reader, in: window)
        #expect(window.notebook == NotebookWorkspace(notebookID: "bio"))

        vm.dismissCenterSurface(.chat, in: window)
        #expect(window.notebook?.showsChat == false, "the center shows the notebook's overview")

        // A tab the notebook does not show is not on screen to hide.
        vm.deactivateCenterTab(.activity, in: window)
        #expect(window.notebook?.notebookID == "bio")
        #expect(window.centerTabGroups == panes)
    }

    @Test("A second chat takes the document slot and its × gives it back")
    func secondChatTakesTheSlot() {
        let restore = capturingTemplate()
        defer { restore() }
        let vm = makeViewModel()
        let window = notebookWindow()
        let panes = window.centerTabGroups
        vm.inWindow(window) { vm.openSecondaryChatPane(atLeadingEdge: false) }
        #expect(window.notebook?.document == .secondChat)
        #expect(window.notebook?.showsChat == true)
        vm.dismissSecondaryChatPane(in: window)
        #expect(window.notebook?.document == nil)
        #expect(window.centerTabGroups == panes)
    }

    @Test("Reveals keep Chat and the document side by side")
    func revealsKeepThePair() {
        let restore = capturingTemplate()
        defer { restore() }
        let vm = makeViewModel()
        let window = notebookWindow(NotebookWorkspace(notebookID: "bio", showsChat: false))
        let panes = window.centerTabGroups

        // A passage handed to Chat from the Reader: both on screen.
        vm.inWindow(window) { vm.revealChat(beside: .reader) }
        #expect(window.notebook == NotebookWorkspace(notebookID: "bio", document: .reader))

        // A Doc's source chip: the Reader replaces the Doc.
        window.notebook?.document = .docs
        vm.revealCenterTab(.reader, beside: .notepad, in: window)
        #expect(window.notebook?.document == .reader)

        // A Sources row: the Reader opens in the slot, and a hidden chat
        // stays hidden.
        window.notebook = NotebookWorkspace(notebookID: "bio", showsChat: false)
        vm.clearReaderSurfaces(in: window)
        #expect(window.notebook == NotebookWorkspace(notebookID: "bio", document: .reader, showsChat: false))

        // Open beside, from the rail or a menu.
        vm.inWindow(window) { vm.openCenterTabBeside(.browser) }
        #expect(window.notebook?.document == .browser)
        #expect(window.centerTabGroups == panes)

        // A tab with no place here, asked beside the chat, leaves the notebook.
        vm.revealCenterTab(.goals, beside: .chat, in: window)
        #expect(window.notebook == nil)
    }

    @Test("A notebook's Docs open in its document slot, never in the panes underneath")
    func notebookDocsOpenInTheSlot() {
        let restore = capturingTemplate()
        defer { restore() }
        let vm = makeViewModel()
        let window = notebookWindow()
        // A Notebooks pane underneath at the cap is what the Notebook page's
        // placement rearranges; a notebook must not reach it.
        window.centerTabGroups = StudioCenterTabGroups.fromPersisted(["chat*", "reader|notebooks*"]) ?? .defaultLayout
        let panes = window.centerTabGroups
        vm.inWindow(window) { vm.openArtifactsBeside(notebookID: "bio") }
        #expect(window.notebook?.document == .docs)
        #expect(window.artifactCanvasNotebookID == "bio", "the window's own Docs are the notebook's")
        #expect(vm.artifactCanvasNotebookID == nil, "another window's Docs keep every doc")
        #expect(window.centerTabGroups == panes)
    }

    @Test("The course list leaves the notebook for the Artifacts index's Courses; one course's page opens in its slot")
    func coursesRouteByPage() {
        let restore = capturingTemplate()
        defer { restore() }
        let vm = makeViewModel()
        let window = notebookWindow()
        vm.openCourse("course-1", in: window)
        #expect(window.notebook?.document == .coursePage)
        // The list of every course is the home's Courses tab: the library's,
        // so it leaves the notebook.
        vm.openCoursesInReader(in: window)
        #expect(window.notebook == nil)
        #expect(vm.visibleCenterTabs(in: window).contains(.courses))
        #expect(window.coursePageID == nil)
    }

    @Test("Placing a tab at an edge lands it in the notebook, never in the panes or the template")
    func placeAtEdgeRoutesIntoTheNotebook() {
        let restore = capturingTemplate()
        defer { restore() }
        let vm = makeViewModel()
        let window = notebookWindow()
        let panes = window.centerTabGroups
        let template = UserDefaults.standard.object(forKey: "studio.centerTabGroups.v1").map { String(describing: $0) }

        vm.placeCenterTabAtEdge(.notepad, leading: false, in: window)
        #expect(window.notebook?.document == .docs)
        #expect(window.centerTabGroups == panes)
        #expect(UserDefaults.standard.object(forKey: "studio.centerTabGroups.v1").map { String(describing: $0) } == template)

        // A tab with no place here leaves the notebook first.
        vm.placeCenterTabAtEdge(.activity, leading: true, in: window)
        #expect(window.notebook == nil)
    }

    @Test("A request the notebook takes leaves Voice; the chat keeps a memory review's focus")
    func notebookRequestsLeaveVoice() {
        let restore = capturingTemplate()
        defer { restore() }
        let vm = makeViewModel()
        let window = notebookWindow()

        window.isVoiceWorkspacePresented = true
        vm.clearReaderSurfaces(in: window)
        #expect(window.notebook?.document == .reader)
        #expect(!window.isVoiceWorkspacePresented)

        window.isVoiceWorkspacePresented = true
        vm.inWindow(window) { vm.openArtifactsBeside(notebookID: "bio") }
        #expect(window.notebook?.document == .docs)
        #expect(!window.isVoiceWorkspacePresented)

        // The chat a memory review runs in is the one request that keeps it.
        window.memoryReviewFocusSessionID = "memory-2026-10-01"
        #expect(vm.routeIntoNotebook(.chat, in: window))
        #expect(window.memoryReviewFocusSessionID == "memory-2026-10-01")
        window.memoryReviewFocusSessionID = nil
    }

    @Test("A Doc's link opens the Reader beside it with Chat hidden; with Chat showing it offers Back to the Doc")
    func linksFromADocKeepTheDoc() {
        let restore = capturingTemplate()
        defer { restore() }
        let vm = makeViewModel()
        let window = notebookWindow(NotebookWorkspace(notebookID: "bio", document: .docs, showsChat: false))

        // The source chip's route: reveal beside the Doc, then show the Reader.
        vm.revealCenterTab(.reader, beside: .notepad, in: window)
        vm.clearReaderSurfaces(keeping: .notepad, in: window)
        #expect(window.notebook == NotebookWorkspace(notebookID: "bio", document: .docs, leadingDocument: .reader, showsChat: false))
        #expect(vm.visibleCenterTabs(in: window) == [.reader, .notepad])

        // With Chat showing, the Reader takes the slot and Back to restores it.
        window.notebook = NotebookWorkspace(notebookID: "bio", document: .docs)
        vm.revealCenterTab(.reader, beside: .notepad, in: window)
        #expect(window.notebook?.document == .reader)
        #expect(window.notebook?.returnDocument == .docs)
        #expect(vm.notebookReturnTitle(in: window) == StudioCenterTab.notepad.title)
        vm.returnInNotebook(in: window)
        #expect(window.notebook == NotebookWorkspace(notebookID: "bio", document: .docs))
        #expect(vm.notebookReturnTitle(in: window) == nil)
    }

    @Test("A second click on the open notebook's folder closes it, and its panes come back as they were")
    func toggleClosesTheNotebook() {
        let restore = capturingTemplate()
        defer { restore() }
        let vm = makeViewModel()
        let window = StudioWindowState()
        window.centerTabGroups = .defaultLayout
        let panes = window.centerTabGroups
        vm.inWindow(window) { vm.toggleNotebookInReader("bio") }
        #expect(window.NotebookID == "bio")
        vm.inWindow(window) { vm.toggleNotebookInReader("bio") }
        #expect(window.notebook == nil)
        #expect(window.centerTabGroups == panes)
    }
}

/// The Add sources sheet's field, its ticks, Add all and Upload PDF, the
/// boxes, the Sources column's drops, and the workspace's layout and sizing.
@Suite("Notebook Add sources and layout helpers")
struct NotebookAddSourcesTests {
    @Test("The Sources field offers Library and Web; Return runs the selected search")
    func sourcesSearchSubmission() {
        #expect(NotebookSourcesSearchScope.submission(scope: .library, query: "") == nil)
        #expect(NotebookSourcesSearchScope.submission(scope: .library, query: "   ") == nil)
        #expect(NotebookSourcesSearchScope.submission(scope: .web, query: "   ") == .web, "Web with no words searches the notebook's subject")
        #expect(NotebookSourcesSearchScope.submission(scope: .papers, query: "") == .papers)
        #expect(NotebookSourcesSearchScope.submission(scope: .library, query: "mootha") == nil, "Library searches only the library; Return never reaches the web from it")
        #expect(NotebookSourcesSearchScope.submission(scope: .web, query: "mootha") == .web)
        #expect(NotebookSourcesSearchScope.submission(scope: .papers, query: "mootha") == .papers)
        #expect(NotebookSourcesSearchScope.primaryScopes.map(\.title) == ["Library", "Web"])
        #expect(NotebookSourcesSearchScope.library.discoveryMode == nil, "the library answers as you type")
    }

    @Test("A results card says what it found and how much the library already holds")
    func discoveryCardText() {
        func row(_ id: String, _ holding: NotebookDiscoveryRow.Holding = .new) -> NotebookDiscoveryRow {
            NotebookDiscoveryRow(id: id, url: "https://\(id).org/", title: id, kind: .paper, site: "\(id).org", holding: holding)
        }
        let rows = [row("a"), row("b", .inLibrary(sourceID: "b")), row("c", .inNotebook(sourceID: "c")), row("d")]
        #expect(NotebookDiscoveryCardText.headline(mode: .web, rows: rows) == "4 on the web · 2 in your library")
        #expect(NotebookDiscoveryCardText.headline(mode: .papers, rows: [row("a")]) == "1 in PubMed")
        #expect(NotebookDiscoveryCardText.headline(mode: .web, rows: []) == "Nothing found on the web")
        #expect(NotebookDiscoveryCardText.moreTitle(rowCount: 10, shown: 3) == "7 more")
        #expect(NotebookDiscoveryCardText.moreTitle(rowCount: 3, shown: 3) == "Review")
    }

    @Test("A search's whole list widens Sources and narrows Studio, and is a moment no snapshot keeps")
    func expandedSourcesColumn() throws {
        typealias Sizing = NotebookWorkspaceSizing
        let expanded = NotebookWorkspace(notebookID: "bio", sourcesExpanded: true)
        let widths = Sizing.columnWidths(for: expanded, totalWidth: 1_250)
        #expect(widths.sources == Sizing.expandedSourcesWidth)
        #expect(widths.studio == Sizing.sideMinimumWidth)
        #expect(widths.center >= Sizing.centerMinimumWidth(for: expanded))
        #expect(Sizing.minimumWidth(for: expanded) == Sizing.minimumWidth(for: NotebookWorkspace(notebookID: "bio")),
                "the list asks for room, never for a fold")

        // Folded, the column shows no list, whatever the flag says.
        var folded = expanded
        folded.sourcesCollapsed = true
        #expect(Sizing.columnWidths(for: folded, totalWidth: 1_250).sources == 0, "a folded Sources column leaves the window")

        #expect(!expanded.persisted.sourcesExpanded)
        let decoded = try JSONDecoder().decode(NotebookWorkspace.self, from: JSONEncoder().encode(expanded))
        #expect(!decoded.sourcesExpanded)
    }

    @Test("The field reads an address as a link and anything else as words to search")
    func fieldIntent() {
        #expect(NotebookSourcePicking.intent(of: "") == .empty)
        #expect(NotebookSourcePicking.intent(of: "   ") == .empty)
        #expect(NotebookSourcePicking.intent(of: "https://example.com/paper") == .link("https://example.com/paper"))
        #expect(NotebookSourcePicking.intent(of: "  http://example.org/a  ") == .link("http://example.org/a"))
        #expect(NotebookSourcePicking.intent(of: "10.1038/s41586-020-2649-2") == .link("https://doi.org/10.1038/s41586-020-2649-2"))
        #expect(NotebookSourcePicking.intent(of: "doi:10.1126/science.abc1234") == .link("https://doi.org/10.1126/science.abc1234"))
        #expect(NotebookSourcePicking.intent(of: "mitochondrial transplantation") == .search("mitochondrial transplantation"))
        #expect(NotebookSourcePicking.intent(of: "https://example.com two words") == .search("https://example.com two words"))
        #expect(NotebookSourcePicking.intent(of: "localhost") == .search("localhost"))
    }

    @Test("Ticks count only rows still on offer, and added rows leave the list")
    func picking() {
        var picking = NotebookSourcePicking()
        let results = ["a", "b", "c"]
        #expect(picking.selectAllState(in: results) == .unchecked)
        picking.toggle("b")
        #expect(picking.selection(in: results) == ["b"])
        #expect(picking.selectAllState(in: results) == .mixed)
        picking.toggleAll(in: results)
        #expect(picking.selection(in: results) == ["a", "b", "c"])
        #expect(picking.selectAllState(in: results) == .checked)
        picking.toggleAll(in: results)
        #expect(picking.selection(in: results).isEmpty)

        picking.toggle("a")
        picking.toggle("c")
        picking.markAdded(["a"])
        #expect(picking.offered(results) == ["b", "c"])
        #expect(picking.selection(in: results) == ["c"])
        // A new search that no longer lists a ticked row does not count it.
        #expect(picking.selection(in: ["b"]).isEmpty)
        #expect(NotebookSourcePicking.addTitle(count: 0) == "Add")
        #expect(NotebookSourcePicking.addTitle(count: 3) == "Add 3")
    }

    @Test("A box is checked, partly checked or not, and nothing to tick reads unchecked")
    func tickState() {
        #expect(NotebookTickState.of(ticked: 0, total: 0) == .unchecked)
        #expect(NotebookTickState.of(ticked: 0, total: 4) == .unchecked)
        #expect(NotebookTickState.of(ticked: 2, total: 4) == .mixed)
        #expect(NotebookTickState.of(ticked: 4, total: 4) == .checked)
        #expect(NotebookTickState.checked.symbolName == "checkmark.square.fill")
        #expect(NotebookTickState.mixed.symbolName == "minus.square.fill")
        #expect(NotebookTickState.unchecked.symbolName == "square")
    }

    @Test("Add all says how many it takes, and asks first above ten")
    func addAll() {
        #expect(NotebookSourcePicking.addAllTitle(count: 23) == "Add all 23")
        #expect(!NotebookSourcePicking.addAllNeedsConfirmation(count: 10))
        #expect(NotebookSourcePicking.addAllNeedsConfirmation(count: 11))
        #expect(NotebookSourcePicking.addAllConfirmationTitle(count: 23, notebookTitle: "Bio")
            == "Add 23 sources to \u{201C}Bio\u{201D}?")
    }

    @Test("Upload PDF says one file's outcome, or how many of several landed")
    func uploadToast() {
        typealias Outcome = StudioViewModel.NotebookImportOutcome
        let added = Outcome(sourceID: "a", library: .added, membership: .added)
        let held = Outcome(sourceID: "b", library: .alreadyHeld, membership: .added)
        let failed = Outcome(library: .failed("x.pdf: unreadable"), membership: .none)
        #expect(NotebookSourcePicking.uploadToast([], notebookTitle: "Bio") == nil)
        #expect(NotebookSourcePicking.uploadToast([added], notebookTitle: "Bio")
            == StudioViewModel.notebookImportToast(added, notebookTitle: "Bio"))
        #expect(NotebookSourcePicking.uploadToast([added, held], notebookTitle: "Bio")
            == "Added 2 PDFs to \u{201C}Bio\u{201D}")
        #expect(NotebookSourcePicking.uploadToast([added, failed], notebookTitle: "Bio")
            == "Added 1 of 2 PDFs to \u{201C}Bio\u{201D}. x.pdf: unreadable")
    }

    @Test("A drop on the Sources column: the app's rows join, files alone import as papers where the notebook takes them")
    func sourcesColumnDrop() {
        // A paper's row offers its file to Finder too; it is still a row.
        #expect(NotebookSourcesDrop.kind(carriesSources: true, carriesFiles: true, acceptsPDFs: true) == .sources)
        #expect(NotebookSourcesDrop.kind(carriesSources: false, carriesFiles: true, acceptsPDFs: true) == .pdfs)
        #expect(NotebookSourcesDrop.kind(carriesSources: false, carriesFiles: true, acceptsPDFs: false) == .none)
        #expect(NotebookSourcesDrop.kind(carriesSources: false, carriesFiles: false, acceptsPDFs: true) == .none)
    }

    @Test("A dropped file's URL is read from what Finder and other apps hand over, and only a PDF is taken")
    func droppedFileURLs() {
        let pdf = URL(fileURLWithPath: "/tmp/Paper One.pdf")
        #expect(PaperFileDrop.fileURL(fromLoadedItem: pdf.dataRepresentation) == pdf)
        #expect(PaperFileDrop.fileURL(fromLoadedItem: pdf as NSURL) == pdf)
        #expect(PaperFileDrop.fileURL(fromLoadedItem: pdf.absoluteString) == pdf)
        #expect(PaperFileDrop.fileURL(fromLoadedItem: "/tmp/Paper One.pdf") == pdf)
        #expect(PaperFileDrop.fileURL(fromLoadedItem: pdf) == pdf)
        #expect(PaperFileDrop.fileURL(fromLoadedItem: nil) == nil)
        #expect(PaperFileDrop.isPDFFile(pdf))
        #expect(PaperFileDrop.isPDFFile(URL(fileURLWithPath: "/tmp/SCAN.PDF")))
        #expect(!PaperFileDrop.isPDFFile(URL(fileURLWithPath: "/tmp/notes.txt")))
        #expect(!PaperFileDrop.isPDFFile(URL(string: "https://example.com/paper.pdf")))
        #expect(!PaperFileDrop.isPDFFile(nil))
    }

    @Test("A notebook window's rail highlights its chat while it shows, and the second chat in the slot")
    func railHighlightsFollowTheNotebook() {
        let showing = NotebookWorkspace(notebookID: "bio", document: .secondChat)
        #expect(StudioNavigationRail.highlightedSessionIDs(primary: "one", comparison: "two", notebook: showing) == ["one", "two"])
        let hidden = NotebookWorkspace(notebookID: "bio", document: .reader, showsChat: false)
        #expect(StudioNavigationRail.highlightedSessionIDs(primary: "one", comparison: "two", notebook: hidden).isEmpty)
        #expect(StudioNavigationRail.highlightedSessionIDs(
            primary: "one", comparison: nil, notebook: hidden, chatPoppedOut: true
        ) == ["one"])
    }

    @Test("The workspace's minimum width is its two side columns and its center's panes")
    func sizing() {
        typealias Sizing = NotebookWorkspaceSizing
        let chatOnly = NotebookWorkspace(notebookID: "bio")
        let pair = NotebookWorkspace(notebookID: "bio", document: .reader)
        let folded = NotebookWorkspace(notebookID: "bio", document: .reader, sourcesCollapsed: true)
        let chatWidth = StudioCenterTabGroupSizing.minimumChatContentWidth
        let side = Sizing.sideMinimumWidth + Sizing.separatorWidth
        #expect(Sizing.minimumWidth(for: chatOnly) == side + chatWidth + side)
        #expect(Sizing.minimumWidth(for: chatOnly, studioShows: false) == side + chatWidth, "an immersive video has Studio step aside")
        #expect(Sizing.centerMinimumWidth(for: pair) == chatWidth + Sizing.dividerWidth + Sizing.documentMinimumWidth)
        #expect(Sizing.minimumWidth(for: folded) == Sizing.centerMinimumWidth(for: pair) + side,
                "a folded Sources column takes no strip and no separator")
        let foldedWidths = Sizing.columnWidths(for: folded, totalWidth: 1_250)
        #expect(foldedWidths.sources == 0)

        // Studio folded leaves the window too: no strip, no separator.
        var bothFolded = folded
        bothFolded.studioCollapsed = true
        let bare = Sizing.columnWidths(for: bothFolded, totalWidth: 1_250)
        #expect(bare.sources == 0 && bare.studio == 0 && bare.center == 1_250)
        #expect(Sizing.minimumWidth(for: bothFolded) == Sizing.centerMinimumWidth(for: pair))
        #expect(foldedWidths.center + foldedWidths.studio + Sizing.separatorWidth == 1_250)
        #expect(Sizing.centerMinimumWidth(for: NotebookWorkspace(notebookID: "bio", showsChat: false)) == chatWidth)

        let widths = Sizing.paneWidths(
            centerWidth: 1_000,
            leadingFraction: 0.1,
            leadingMinimum: chatWidth,
            documentMinimum: Sizing.documentMinimumWidth
        )
        #expect(widths.leading == chatWidth, "the chat keeps its minimum while there is room")
        #expect(widths.leading + widths.document + Sizing.dividerWidth == 1_000)
        #expect(Sizing.sideWidth(totalWidth: 400) == Sizing.sideMinimumWidth)
        #expect(Sizing.sideWidth(totalWidth: 4_000) == Sizing.sideMaximumWidth)
        #expect(Sizing.sideWidth(totalWidth: 1_250) == 300, "a quarter, less a little, at the product owner's window beside the rail's strip")

        // The Reader standing in the chat's place needs a document's width.
        let readerBesideDoc = NotebookWorkspace(notebookID: "bio", document: .docs, leadingDocument: .reader, showsChat: false)
        #expect(Sizing.centerMinimumWidth(for: readerBesideDoc)
            == Sizing.documentMinimumWidth * 2 + Sizing.dividerWidth)
    }

    @Test("Sources and Studio take their shares, a folded one nothing, and the center the rest")
    func columnWidths() {
        typealias Sizing = NotebookWorkspaceSizing
        let separators = Sizing.separatorWidth * 2

        // Chat alone, 1,250 points: Gemini's quarter · half · quarter.
        let chatOnly = Sizing.columnWidths(for: NotebookWorkspace(notebookID: "bio"), totalWidth: 1_250)
        #expect(chatOnly.sources == 300 && chatOnly.studio == 300)
        #expect(chatOnly.sources + chatOnly.center + chatOnly.studio + separators == 1_250)

        // A paper open with Sources folded: no column, Studio stays, and the
        // center holds the chat and the Reader side by side.
        let reading = NotebookWorkspace(notebookID: "bio", document: .reader, sourcesCollapsed: true)
        let readingWidths = Sizing.columnWidths(for: reading, totalWidth: 1_250)
        #expect(readingWidths.sources == 0)
        #expect(readingWidths.studio == 300)
        #expect(readingWidths.center >= Sizing.centerMinimumWidth(for: reading))

        // Where the shares would leave the center short, the open columns
        // give it back down to their minimum, Studio first.
        let tight = Sizing.minimumWidth(for: reading) + 4
        let tightWidths = Sizing.columnWidths(for: reading, totalWidth: tight)
        #expect(tightWidths.center >= Sizing.centerMinimumWidth(for: reading), "never clipped at the shares' widths")
        #expect(tightWidths.studio >= Sizing.sideMinimumWidth)
        // Folded Sources leaves with its separator: only Studio's remains.
        #expect(abs(tightWidths.sources + tightWidths.center + tightWidths.studio + Sizing.separatorWidth - tight) < 0.001)

        // Studio stepping aside for an immersive video takes no width.
        let immersive = Sizing.columnWidths(for: NotebookWorkspace(notebookID: "bio"), totalWidth: 1_250, studioShows: false)
        #expect(immersive.studio == 0)
        #expect(abs(immersive.sources + immersive.center + Sizing.separatorWidth - 1_250) < 0.001)
    }

    @Test("A dragged Sources column keeps its width within bounds, narrows Studio before the chat, and stays on this Mac")
    func draggedSourcesColumn() {
        typealias Sizing = NotebookWorkspaceSizing
        let separators = Sizing.separatorWidth * 2
        let notebook = NotebookWorkspace(notebookID: "bio")

        // A drag moves the edge by the pointer, within 260…560.
        #expect(Sizing.draggedSourcesWidth(startWidth: 300, translation: 80) == 380)
        #expect(Sizing.draggedSourcesWidth(startWidth: 300, translation: 1_000) == Sizing.sourcesMaximumWidth)
        #expect(Sizing.draggedSourcesWidth(startWidth: 300, translation: -1_000) == Sizing.sideMinimumWidth)
        #expect(Sizing.sourcesMaximumWidth > Sizing.sideMaximumWidth, "a drag reaches past the share's cap")

        // Never dragged, the column takes its share; dragged, its own width,
        // and the Studio keeps its share while the center has room.
        #expect(Sizing.columnWidths(for: notebook, totalWidth: 1_250, sourcesPreferredWidth: nil).sources == 300)
        let dragged = Sizing.columnWidths(for: notebook, totalWidth: 1_250, sourcesPreferredWidth: 420)
        #expect(dragged.sources == 420 && dragged.studio == 300)
        #expect(dragged.sources + dragged.center + dragged.studio + separators == 1_250)
        // A kept width out of bounds (another display, an older build) is
        // brought back within them.
        #expect(Sizing.columnWidths(for: notebook, totalWidth: 1_250, sourcesPreferredWidth: 90).sources == Sizing.sideMinimumWidth)
        #expect(Sizing.columnWidths(for: notebook, totalWidth: 2_400, sourcesPreferredWidth: 900).sources == Sizing.sourcesMaximumWidth)

        // Dragged wide in a window too narrow for it: Studio gives its room
        // first, then Sources, and the chat keeps its minimum.
        let tight = Sizing.minimumWidth(for: notebook) + 100
        let wide = Sizing.columnWidths(for: notebook, totalWidth: tight, sourcesPreferredWidth: Sizing.sourcesMaximumWidth)
        #expect(wide.studio == Sizing.sideMinimumWidth)
        #expect(wide.center >= Sizing.centerMinimumWidth(for: notebook))
        #expect(wide.sources == Sizing.sideMinimumWidth + 100)
        #expect(abs(wide.sources + wide.center + wide.studio + separators - tight) < 0.001)

        // Folded, Sources has no width; a search's whole list still gets
        // its widened width, or the learner's when that is wider.
        var folded = notebook
        folded.sourcesCollapsed = true
        #expect(Sizing.columnWidths(for: folded, totalWidth: 1_250, sourcesPreferredWidth: 420).sources == 0)
        let searching = NotebookWorkspace(notebookID: "bio", sourcesExpanded: true)
        #expect(Sizing.columnWidths(for: searching, totalWidth: 1_400, sourcesPreferredWidth: 300).sources == Sizing.expandedSourcesWidth)
        #expect(Sizing.columnWidths(for: searching, totalWidth: 1_400, sourcesPreferredWidth: 520).sources == 520)

        // What a drag keeps is the column as it shows once the center has its
        // room, never the search's widened list.
        #expect(Sizing.settledSourcesWidth(for: notebook, totalWidth: 1_250, draggedWidth: 420) == 420)
        #expect(Sizing.settledSourcesWidth(for: searching, totalWidth: 1_400, draggedWidth: 300) == 300)
        #expect(Sizing.settledSourcesWidth(for: notebook, totalWidth: tight, draggedWidth: Sizing.sourcesMaximumWidth)
            == Sizing.sideMinimumWidth + 100)

        // The minimum the folds and the rail judge by is the column's own,
        // whatever width was dragged.
        #expect(Sizing.sourcesFootprint(for: notebook) == Sizing.sideMinimumWidth + Sizing.separatorWidth)

        // Absolute points, so this Mac's alone, declared with a reason.
        #expect(!SyncedPreferenceKeys.isSynced(Sizing.sourcesWidthPreferenceKey))
        #expect(SyncedPreferenceKeys.excluded[Sizing.sourcesWidthPreferenceKey] != nil)
    }

    @Test("The center gives each pane its own place: the chat or the document in its place, the divider, the slot, the overview")
    func centerLayout() {
        typealias Sizing = NotebookWorkspaceSizing

        let pair = Sizing.centerLayout(
            for: NotebookWorkspace(notebookID: "bio", document: .reader),
            centerWidth: 1_000,
            leadingFraction: 0.5
        )
        #expect(pair.leadingDocument == nil, "the chat leads")
        #expect(pair.showsDivider)
        #expect(!pair.showsOverview)
        #expect((pair.leadingWidth ?? 0) + (pair.documentWidth ?? 0) + Sizing.dividerWidth == 1_000)

        // Chat alone, and the Reader alone, take the whole center in their
        // own places: the chat's never moves when the slot fills or empties.
        #expect(Sizing.centerLayout(for: NotebookWorkspace(notebookID: "bio"), centerWidth: 800, leadingFraction: 0.5)
            == NotebookCenterLayout(leadingWidth: 800, leadingDocument: nil, documentWidth: nil))
        #expect(Sizing.centerLayout(
            for: NotebookWorkspace(notebookID: "bio", document: .reader, showsChat: false),
            centerWidth: 800,
            leadingFraction: 0.5
        ) == NotebookCenterLayout(leadingWidth: nil, leadingDocument: nil, documentWidth: 800))
        let overview = Sizing.centerLayout(
            for: NotebookWorkspace(notebookID: "bio", showsChat: false),
            centerWidth: 800,
            leadingFraction: 0.5
        )
        #expect(overview.showsOverview)
        #expect(!overview.showsDivider)

        // The Reader in the chat's place beside a Doc.
        let besideDoc = Sizing.centerLayout(
            for: NotebookWorkspace(notebookID: "bio", document: .docs, leadingDocument: .reader, showsChat: false),
            centerWidth: 1_000,
            leadingFraction: 0.1
        )
        #expect(besideDoc.leadingDocument == .reader)
        #expect(besideDoc.leadingWidth == Sizing.documentMinimumWidth, "the Reader keeps a document's minimum")
        #expect(besideDoc.showsDivider)
        // A chat on screen leads even if a stale document names the place.
        #expect(Sizing.centerLayout(
            for: NotebookWorkspace(notebookID: "bio", leadingDocument: .reader),
            centerWidth: 800,
            leadingFraction: 0.5
        ).leadingDocument == nil)
    }

    @Test("A narrow window folds Sources away, then Studio to its strip, for the center's sake alone, and never the rail")
    func roomMaking() {
        typealias Sizing = NotebookWorkspaceSizing
        let pair = NotebookWorkspace(notebookID: "bio", document: .reader)
        let needed = Sizing.minimumWidth(for: pair)
        let sourcesSaving = Sizing.sideMinimumWidth + Sizing.separatorWidth

        let roomy = Sizing.folds(for: pair, totalWidth: needed + 50)
        #expect(!roomy.sources && !roomy.studio)

        let tight = Sizing.folds(for: pair, totalWidth: needed - 10)
        #expect(tight.sources && !tight.studio, "Sources goes first; Studio stays on screen")

        let narrow = Sizing.folds(for: pair, totalWidth: needed - sourcesSaving - 10)
        #expect(narrow.sources && narrow.studio)

        // The product owner's 1,302-point window with the rail as its 52-point strip:
        // a paper beside the chat folds Sources and keeps Studio.
        let wide = Sizing.folds(for: pair, totalWidth: 1_302 - 52)
        #expect(wide.sources && !wide.studio)

        // Folded already, nothing more to fold: the pass never reaches for
        // the rail, whose visibility is a synced preference.
        var folded = pair
        folded.sourcesCollapsed = true
        folded.studioCollapsed = true
        let none = Sizing.folds(for: folded, totalWidth: 300)
        #expect(!none.sources && !none.studio)

        // Studio stepping aside for an immersive video is not folded.
        let immersive = Sizing.folds(for: pair, totalWidth: 300, studioShows: false)
        #expect(immersive.sources && !immersive.studio)
    }
}
