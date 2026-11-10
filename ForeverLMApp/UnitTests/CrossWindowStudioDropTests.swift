// The cross-window Studio drop and docs fresh chat navigation tests.

import Testing
import Foundation
import UniformTypeIdentifiers
import AppKit
import SQLite3
@testable import ForeverLM

@Suite("Cross-window Studio Drops")
@MainActor
struct CrossWindowStudioDropTests {
    @Test("A pane drop changes the destination window only")
    func paneDropUsesDestinationWindow() {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(
                tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts],
                activeTab: .chat
            ),
        ])
        let sourceLayout = vm.centerTabGroups
        let destination = StudioWindowState(snapshot: .init(
            centerTabGroups: ["chat|reader*|tasks|notepad|notebooks"],
            navigationRailVisible: true
        ))

        vm.placeCenterTabAtEdge(.notepad, leading: false, in: destination)

        #expect(vm.centerTabGroups == sourceLayout)
        #expect(destination.centerTabGroups.groups.count == 2)
        #expect(destination.centerTabGroups.groups.last == .init(tabs: [.notepad], activeTab: .notepad))
    }

    @Test("A window place dragged from another window comes in as itself, or as a side copy beside this window's own")
    func arrivingPlaceKeepsWhatTheWindowShows() {
        let chatShut = StudioCenterTabGroups(groups: [
            .init(tabs: StudioCenterTab.permanentTabs, activeTab: .reader),
        ])
        #expect(chatShut.arrivingPlace(for: .chat) == .chat)
        #expect(chatShut.arrivingPlace(for: .secondaryChat) == .chat)
        #expect(chatShut.arrivingPlace(for: .reader) == .secondaryReader)
        #expect(chatShut.arrivingPlace(for: .secondaryBrowser) == .browser)
        #expect(chatShut.arrivingPlace(for: .tasks) == .tasks)
        #expect(chatShut.arrivingPlace(for: .notepad) == .notepad)
    }

    @Test("A tab from another window joins the strip it is dropped on, where it was dropped")
    func tabFromAnotherWindowJoinsTheStrip() throws {
        let layout = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader], activeTab: .chat, openTabs: [.chat, .reader]),
            .init(tabs: StudioCenterTab.permanentTabs.filter { ![.chat, .reader].contains($0) }, activeTab: .artifacts),
        ])

        // A once-per-window place parked in the other pane moves in, before
        // the tab it was dropped on.
        let tasks = try #require(layout.receiving(.tasks, inPaneAt: 0, at: 1))
        #expect(tasks.groups[0].openTabs == [.chat, .tasks, .reader])
        #expect(tasks.groups[0].activeTab == .tasks)
        #expect(!tasks.groups[1].tabs.contains(.tasks))

        // A side copy is a tab of this pane alone, at the strip's end.
        let side = try #require(layout.receiving(.secondaryChat, inPaneAt: 1, at: .max))
        #expect(side.groups[1].openTabs.last == .secondaryChat)
        #expect(side.groups[1].activeTab == .secondaryChat)
        #expect(side.groups[0].openTabs == [.chat, .reader])

        // The Space, open alone in its pane, leaves that pane, which dissolves
        // into the pane it was dropped on with what it had parked.
        let space = try #require(layout.receiving(.artifacts, inPaneAt: 0, at: .max))
        #expect(space.groups.count == 1)
        #expect(space.groups[0].activeTab == .artifacts)
        #expect(Set(space.groups[0].tabs) == Set(StudioCenterTab.permanentTabs))

        #expect(layout.receiving(.tasks, inPaneAt: 5, at: 0) == nil)
    }

    @Test("A tab dragged to another window opens there and closes in the window it left")
    func tabMovesBetweenWindows() throws {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let right = StudioWindowState()
        right.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: StudioCenterTab.permanentTabs, activeTab: .tasks, openTabs: [.artifacts, .tasks]),
        ])
        let left = StudioWindowState()
        left.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: StudioCenterTab.permanentTabs, activeTab: .artifacts),
        ])
        let rightPane = try #require(right.centerTabGroups.groups.first?.id)

        vm.moveCenterTab(.tasks, fromGroup: rightPane, of: right, arriving: .strip(group: 0, position: .max), in: left)

        #expect(left.centerTabGroups.groups[0].openTabs == [.artifacts, .tasks])
        #expect(left.centerTabGroups.groups[0].activeTab == .tasks)
        #expect(left.focusedGroupID == left.centerTabGroups.groups[0].id)
        #expect(right.centerTabGroups.groups[0].openTabs == [.artifacts])
        #expect(right.centerTabGroups.groups[0].activeTab == .artifacts)

        // At an edge it is a pane of its own.
        vm.moveCenterTab(.tasks, fromGroup: left.centerTabGroups.groups[0].id, of: left, arriving: .edge(leading: true), in: right)
        #expect(right.centerTabGroups.groups.map(\.activeTab) == [.tasks, .artifacts])
        #expect(left.centerTabGroups.groups[0].openTabs == [.artifacts])

        // Dropped back on the window it is in, nothing moves.
        let before = right.centerTabGroups
        vm.moveCenterTab(.tasks, fromGroup: right.centerTabGroups.groups[0].id, of: right, arriving: .edge(leading: false), in: right)
        #expect(right.centerTabGroups == before)
    }

    @Test("Dragging the Library, which fills the window, to an edge docks it and gives the rest to Chat")
    func libraryFillingTheWindowDocksAtAnEdge() {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let window = StudioWindowState(snapshot: .init(
            centerTabGroups: StudioCenterTabGroups(groups: [
                .init(tabs: StudioCenterTab.permanentTabs, activeTab: .library),
            ]).persistedRepresentation,
            navigationRailVisible: true
        ))

        vm.placeCenterTabAtEdge(.library, leading: false, in: window)

        #expect(window.centerTabGroups.groups.map(\.activeTab) == [.chat, .library])
        #expect(window.centerTabGroups.groups.last?.tabs == [.library])

        // Dropped on the other edge, the docked pane moves across.
        vm.placeCenterTabAtEdge(.library, leading: true, in: window)
        #expect(window.centerTabGroups.groups.map(\.activeTab) == [.library, .chat])
    }

    @Test("A source drop changes the destination Reader only")
    func sourceDropUsesDestinationReader() async {
        let source = StudioWindowState()
        source.readerArticleID = "source-on-right-display"
        let destination = StudioWindowState()
        let vm = makeViewModel()

        await vm.selectArticle("source-on-left-display", in: destination)

        #expect(source.readerArticleID == "source-on-right-display")
        #expect(destination.readerArticleID == "source-on-left-display")
    }

    @Test("A chat opening a paper beside itself opens it in the chat's window only, not in the key window too")
    func sourceBesideChatStaysInTheChatsWindow() async {
        let vm = makeViewModel()
        let paper = makeArticle(url: "/tmp/oocyte-paper.pdf", title: "Oocytes keep ROS low", sourceType: .paper)
        vm.articles = [paper]
        // The key window still renders the app-wide selection: it has never
        // chosen a source of its own.
        let keyWindow = vm.activeWindowState
        let chatWindow = StudioWindowState(snapshot: .init(
            centerTabGroups: ["chat*|reader|tasks|notepad|notebooks"],
            navigationRailVisible: true
        ))

        let opened = await vm.openSourceBesideChat(paper.id, beside: .chat, in: chatWindow)

        #expect(opened)
        #expect(chatWindow.readerArticleID == paper.id)
        #expect(chatWindow.centerTabGroups.groups.map(\.activeTab) == [.chat, .reader])
        #expect(keyWindow !== chatWindow)
        #expect(keyWindow.readerArticleID != paper.id)
    }

    @Test("A chat pointing at a passage flashes it in its own window's Reader, not in another window showing the same paper")
    func chatPassageStaysInTheChatsWindow() {
        let vm = makeViewModel()
        let chatWindow = StudioWindowState(snapshot: .init(
            centerTabGroups: ["reader*", "chat*"],
            navigationRailVisible: true
        ))
        let otherWindow = StudioWindowState(snapshot: .init(
            centerTabGroups: ["chat*", "reader*"],
            navigationRailVisible: true
        ))
        let paperID = "oocyte-paper"

        vm.applyWalkthroughReaderFocus(.flash(passage: "measured using a Seahorse XFe96 Analyser", sourceID: paperID), in: chatWindow)

        #expect(vm.readerPassageTarget?.windowID == chatWindow.id)
        let otherReader = ReaderPassageTargetTracker()
        otherReader.readerWindowID = otherWindow.id
        #expect(otherReader.pending(for: paperID, in: vm) == nil)
        let chatReader = ReaderPassageTargetTracker()
        chatReader.readerWindowID = chatWindow.id
        #expect(chatReader.pending(for: paperID, in: vm)?.passage == "measured using a Seahorse XFe96 Analyser")
        // A Reader in no Studio window (popped out) still answers it.
        #expect(ReaderPassageTargetTracker().pending(for: paperID, in: vm) != nil)

        // A moment and an outline go the same way, and the other window's
        // chat clearing its outline leaves this one's up.
        vm.applyWalkthroughReaderFocus(.moment(seconds: 42, sourceID: paperID), in: chatWindow)
        #expect(vm.readerTimeTarget?.windowID == chatWindow.id)
        vm.applyWalkthroughReaderFocus(.outline(.page(pageIndex: 3), stepID: "focus", sourceID: paperID), in: chatWindow)
        #expect(vm.readerWalkthroughFocus?.windowID == chatWindow.id)
        vm.applyWalkthroughReaderFocus(.clear, in: otherWindow)
        #expect(vm.readerWalkthroughFocus != nil)
        vm.applyWalkthroughReaderFocus(.clear, in: chatWindow)
        #expect(vm.readerWalkthroughFocus == nil)
    }

    @Test("A Reader request reaches only its window's Reader; one naming no window, or a Reader in none, still meet")
    func readerRequestWindowRule() {
        let a = UUID(), b = UUID()
        #expect(ReaderRequestWindow.reaches(a, readerIn: a))
        #expect(!ReaderRequestWindow.reaches(a, readerIn: b))
        #expect(ReaderRequestWindow.reaches(nil, readerIn: b))
        #expect(ReaderRequestWindow.reaches(a, readerIn: nil))
    }

    @Test("The Docs index and a doc reveal name the window they were asked in, so another window's Doc stays open")
    func docsIndexAndRevealStayInTheirWindow() {
        let leftDisplay = StudioWindowState(snapshot: .init(
            centerTabGroups: ["chat|reader|tasks|activity|activityLog|notepad*|sites|browser|videos|notebooks"],
            navigationRailVisible: true
        ))
        let rightDisplay = StudioWindowState(snapshot: .init(
            centerTabGroups: ["chat*|reader|tasks|activity|activityLog|notepad|sites|browser|videos|notebooks"],
            navigationRailVisible: true
        ))
        let vm = makeViewModel()

        // Docs clicked in the right-hand window: that window shows the index,
        // and the request says so; the left window's canvas is not addressed.
        vm.openNotepadInReader(in: rightDisplay)
        #expect(vm.artifactIndexRequest?.windowID == rightDisplay.id)
        #expect(vm.artifactIndexRequest?.windowID != leftDisplay.id)
        #expect(rightDisplay.centerTabGroups.groups.contains { $0.activeTab == .notepad })

        vm.openSitesInReader(in: leftDisplay)
        #expect(vm.artifactIndexRequest?.section == .sites)
        #expect(vm.artifactIndexRequest?.windowID == leftDisplay.id)

        // A doc revealed for one window carries that window; a second reveal is
        // a distinct request even for the same doc and window.
        vm.revealArtifact("doc-1", in: rightDisplay)
        let first = vm.artifactRevealRequest
        #expect(first?.windowID == rightDisplay.id)
        #expect(first?.artifactID == "doc-1")
        vm.revealArtifact("doc-1", in: rightDisplay)
        #expect(vm.artifactRevealRequest != first)

        // With no window named, the request is for the window the click was
        // made in — the active one — never for every window.
        vm.openNotepadInReader()
        #expect(vm.artifactIndexRequest?.windowID == vm.activeWindowState.id)
    }

    @Test("a web citation opens beside Chat without entering the library")
    func webCitationIsTransientUntilSaved() async throws {
        let destination = StudioWindowState(snapshot: .init(
            centerTabGroups: ["chat*|reader|tasks|notepad|notebooks"],
            navigationRailVisible: true
        ))
        let vm = makeViewModel()
        let initialSourceIDs = vm.articles.map(\.id)
        let url = try #require(URL(string: "https://example.com/paper.pdf?utm_source=research"))

        vm.openWebCitationInReader(url, title: "Primary research", in: destination)

        let page = try #require(destination.externalReaderPage)
        #expect(page.url == url)
        #expect(page.title == "Primary research")
        #expect(page.article.sourceType == .paper)
        #expect(vm.articles.map(\.id) == initialSourceIDs)
        #expect(destination.centerTabGroups.groups.count == 2)
        #expect(destination.centerTabGroups.groups.map(\.activeTab) == [.chat, .reader])

        await vm.selectArticle("saved-source", in: destination)
        #expect(destination.externalReaderPage == nil)
        #expect(destination.readerArticleID == "saved-source")
    }

    @Test("reader history returns from an unsaved web citation to its saved source")
    func externalCitationBackState() throws {
        let window = StudioWindowState()
        window.readerArticleID = "saved-source"
        let url = try #require(URL(string: "https://example.com/research"))
        window.externalReaderPage = StudioExternalReaderPage(url: url, title: "Research")

        #expect(window.readerArticleID == "saved-source")
        #expect(window.readerBackStack.isEmpty)
        window.externalReaderPage = nil
        #expect(window.readerArticleID == "saved-source")
    }

    @Test("Reader source history belongs to its Studio window")
    func readerHistoryIsPerWindow() {
        let first = StudioWindowState()
        let second = StudioWindowState()

        first.readerArticleID = "article-a"
        first.readerArticleID = "paper-b"
        second.readerArticleID = "transcript-c"

        #expect(first.readerBackStack == ["article-a"])
        #expect(second.readerBackStack.isEmpty)
        #expect(first.navigateReaderBack(where: { _ in true }) == "article-a")
        #expect(first.readerArticleID == "article-a")
        #expect(first.readerBackStack.isEmpty)
        #expect(second.readerArticleID == "transcript-c")
    }

    @Test("Reader Back retires missing sources and does not loop")
    func readerHistorySkipsUnavailableSources() {
        let window = StudioWindowState()
        window.readerArticleID = "article-a"
        window.readerArticleID = "removed-paper"
        window.readerArticleID = "chapter-c"

        #expect(window.readerBackStack == ["article-a", "removed-paper"])
        #expect(window.navigateReaderBack(where: { $0 == "article-a" }) == "article-a")
        #expect(window.readerArticleID == "article-a")
        #expect(window.readerBackStack.isEmpty)
        #expect(window.navigateReaderBack(where: { _ in true }) == nil)
    }

    @Test("Sending a source to another window reveals only that window's Reader")
    func activatingATabTargetsTheDestinationWindow() {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .chat),
        ])
        let sourceLayout = vm.centerTabGroups
        let destination = StudioWindowState(snapshot: .init(
            centerTabGroups: ["chat*|reader|tasks|notepad|notebooks"],
            navigationRailVisible: true
        ))

        vm.activateCenterTab(.reader, in: destination)

        #expect(vm.centerTabGroups == sourceLayout)
        #expect(destination.centerTabGroups.groups.map(\.activeTab) == [.reader])
    }

    @Test("Sending a source elsewhere leaves this window on what it was reading")
    func openingInAnotherWindowPinsTheActingWindow() async {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let reading = makeArticle(url: "https://example.com/reading", title: "Being read")
        // Content on the row keeps selectArticle from fetching
        // https://example.com for real: this test is about where the
        // selection lands, not about fetching.
        let sent = makeArticle(url: "https://example.com/sent", title: "Sent away").with(content: "Sent away, already read.")
        vm.articles = [reading, sent]
        // The acting window shows its source the legacy way: no local choice of
        // its own, so it renders whatever the global selection points at.
        let acting = StudioWindowState()
        vm.selectedArticleId = reading.id
        let other = StudioWindowState()

        StudioOtherWindowTargets.open(sent.id, in: other, from: acting, vm: vm)
        await vm.selectArticle(sent.id, in: other)

        #expect(acting.readerArticleID == reading.id)
        #expect(other.readerArticleID == sent.id)
    }

    @Test("Sending the source this window is reading empties its Reader, one Back away")
    func openingInAnotherWindowClosesTheSourceHere() async {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let sent = makeArticle(url: "https://example.com/sent", title: "Sent away").with(content: "Sent away, already read.")
        vm.articles = [sent]
        // The acting window has never navigated on its own, so what it shows is
        // the global selection — the case the Reader's own menu is opened from.
        let acting = StudioWindowState()
        vm.selectedArticleId = sent.id
        let other = StudioWindowState()

        StudioOtherWindowTargets.open(sent.id, in: other, from: acting, vm: vm)
        await vm.selectArticle(sent.id, in: other)

        #expect(acting.readerSourceID(fallingBackTo: vm.selectedArticleId) == nil)
        #expect(acting.readerBackStack == [sent.id])
        #expect(other.readerArticleID == sent.id)
    }

    @Test("Sending the source this window is reading closes its Reader pane")
    func openingInAnotherWindowClosesTheReaderPaneHere() async {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let sent = makeArticle(url: "https://example.com/sent", title: "Sent away").with(content: "Sent away, already read.")
        vm.articles = [sent]
        let acting = StudioWindowState()
        acting.readerArticleID = sent.id
        // The Reader is a split pane beside Chat, the layout in which "make
        // room" means something: the pane folds into its neighbour rather than
        // staying behind on "Continue reading".
        acting.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(
                tabs: [.reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts],
                activeTab: .reader
            ),
        ])
        let other = StudioWindowState()

        StudioOtherWindowTargets.open(sent.id, in: other, from: acting, vm: vm)
        await vm.selectArticle(sent.id, in: other)

        #expect(acting.readerArticleID == nil)
        #expect(acting.centerTabGroups.groups.count == 1)
        #expect(acting.centerTabGroups.groups[0].activeTab == .chat)
        #expect(acting.centerTabGroups.groups[0].tabs.contains(.reader))
        #expect(other.readerArticleID == sent.id)
    }

    @Test("Sending a source from the sidebar leaves a pane that was not showing the Reader alone")
    func openingInAnotherWindowKeepsAPaneShowingSomethingElse() async {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let sent = makeArticle(url: "https://example.com/sent", title: "Sent away").with(content: "Sent away, already read.")
        vm.articles = [sent]
        let acting = StudioWindowState()
        acting.readerArticleID = sent.id
        // The Reader holds the source but Docs is on screen in its pane; the
        // learner is looking at Docs, so that pane stays.
        let layout = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(
                tabs: [.reader, .tasks, .activity, .activityLog, .goals, .ideas, .notepad, .sites, .browser, .videos, .animations, .artifacts, .courses, .memory, .knowledgeMap, .atlas, .library, .plugins],
                activeTab: .notepad
            ),
        ])
        acting.centerTabGroups = layout
        let other = StudioWindowState()

        StudioOtherWindowTargets.open(sent.id, in: other, from: acting, vm: vm)
        await vm.selectArticle(sent.id, in: other)

        #expect(acting.readerArticleID == nil)
        #expect(acting.centerTabGroups == layout)
    }

    @Test("Other-window targets exclude this window and are named by screen position")
    func otherWindowTargetsAreOrderedAndLabelled() {
        let vm = makeViewModel()
        let paper = makeArticle(
            url: "https://example.com/mitochondrial-transplantation",
            title: "Mitochondrial Transplantation",
            sourceType: .paper
        )
        vm.articles = [paper]

        let current = StudioWindowState()
        current.workspacePlacement = placement(displayIndex: 0, x: 0.5)
        let left = StudioWindowState()
        left.workspacePlacement = placement(displayIndex: 0, x: 0.0)
        let secondDisplay = StudioWindowState()
        secondDisplay.workspacePlacement = placement(displayIndex: 1, x: 0.0)
        secondDisplay.readerArticleID = paper.id

        let targets = StudioOtherWindowTargets.targets(
            among: [secondDisplay, current, left],
            excluding: current,
            vm: vm
        )

        // Window 2 is missing by design: it is the window the menu was opened
        // in, and its number still reflects where it sits on screen.
        #expect(targets.map(\.label) == ["Window 1", "Window 3 — Mitochondrial Transplantation"])
        #expect(targets.map(\.state.id) == [left.id, secondDisplay.id])
    }

    @Test("A doc sent to another window opens Docs there, not here")
    func docOpensInTheTargetWindow() {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let acting = StudioWindowState()
        let other = StudioWindowState()

        StudioWindowDestination.doc("doc-1").open(in: other, vm: vm)

        #expect(other.centerTabGroups.groups.contains { $0.activeTab == .notepad })
        #expect(acting.centerTabGroups.groups.contains { $0.activeTab == .notepad } == false)
        #expect(vm.artifactRevealRequest?.artifactID == "doc-1")
    }

    @Test("A site comes forward in Sites, a doc in Docs, and each rail row asks its own index")
    func sitesAndDocsAreSeparateSections() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        let now = Date()
        vm.artifacts = [
            ArtifactRecord(id: "doc-1", title: "Notes", homeNotebookID: nil, linkedNotebookIDs: [], createdAt: now, updatedAt: now),
            ArtifactRecord(
                id: "gdoc-1", title: "Shared plan", homeNotebookID: nil, linkedNotebookIDs: [],
                linkedURL: "https://docs.google.com/document/d/1abcDEFghiJKLmnoPQRstuVWxyz0123456789/edit",
                createdAt: now, updatedAt: now
            ),
            ArtifactRecord(
                id: "site-1", title: "TechBio", homeNotebookID: nil, linkedNotebookIDs: [],
                linkedURL: "https://techbio.learner-1234.chatgpt.site/",
                createdAt: now, updatedAt: now
            ),
        ]
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .chat),
        ])

        // The rail's Sites row lands on the Sites index and leaves Docs alone.
        vm.openSitesInReader()
        #expect(vm.activeCenterTabs.contains(.sites))
        #expect(!vm.activeCenterTabs.contains(.notepad))
        #expect(vm.artifactIndexRequest?.section == .sites)
        vm.openNotepadInReader()
        #expect(vm.activeCenterTabs.contains(.notepad))
        #expect(vm.artifactIndexRequest?.section == .docs)

        // A record comes forward in the section its link puts it in.
        #expect(vm.artifactSection(of: "doc-1") == .docs)
        #expect(vm.artifactSection(of: "gdoc-1") == .docs)
        #expect(vm.artifactSection(of: "site-1") == .sites)
        #expect(vm.artifactSection(of: "unknown") == .docs)

        vm.revealArtifact("site-1")
        #expect(vm.activeCenterTabs.contains(.sites))
        #expect(vm.artifactRevealRequest?.artifactID == "site-1")
        #expect(vm.artifactRevealRequest?.section == .sites)

        vm.revealArtifact("gdoc-1")
        #expect(vm.activeCenterTabs.contains(.notepad))
        #expect(vm.artifactRevealRequest?.artifactID == "gdoc-1")
        #expect(vm.artifactRevealRequest?.section == .docs)

        // A Markdown doc stays a Doc while it has a page on foreverlm.com
        // (product owner, 2026-09-10: "published docs stay in docs"); the published
        // projection never moves a record between sections.
        let page = PublishedDocStatus(
            docID: "doc-1", url: URL(string: "https://foreverlm.com/share/notes")!, slug: "notes",
            title: "Notes", publishedAt: now, updatedAt: now, isProtected: false, password: nil
        )
        vm.publishedDocStatuses["doc-1"] = page
        #expect(vm.artifactSection(of: "doc-1") == .docs)
        vm.revealArtifact("doc-1")
        #expect(vm.activeCenterTabs.contains(.notepad))
        #expect(vm.artifactRevealRequest?.section == .docs)
        vm.publishedDocStatuses["gdoc-1"] = page
        #expect(vm.artifactSection(of: "gdoc-1") == .docs)
        vm.publishedDocStatuses.removeValue(forKey: "doc-1")
        #expect(vm.artifactSection(of: "doc-1") == .docs)
    }

    @Test("Sites sent to another window opens there, not here")
    func sitesOpensInTheTargetWindow() {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let acting = StudioWindowState()
        let other = StudioWindowState()

        StudioWindowDestination.sites.open(in: other, vm: vm)

        #expect(other.centerTabGroups.groups.contains { $0.activeTab == .sites })
        #expect(acting.centerTabGroups.groups.contains { $0.activeTab == .sites } == false)
        #expect(StudioWindowDestination.sites.noun == "Sites")
    }

    @Test("A Notebook sent to another window opens its notebook there, over panes left as they were")
    func notebookOpensInTheTargetWindow() {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let acting = StudioWindowState()
        let other = StudioWindowState()
        // Two panes, set here rather than read from the stored template: a
        // notebook opens in the window's own tabs, and a window of two panes
        // or more keeps them as arranged.
        other.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.artifacts, .chat], activeTab: .artifacts),
            .init(tabs: [.reader], activeTab: .reader),
        ])
        let actingPanes = acting.centerTabGroups
        let otherPanes = other.centerTabGroups

        StudioWindowDestination.notebook("notebook-1").open(in: other, vm: vm)

        // The notebook belongs to the window it was sent to, and the open
        // notebook read in that window is it; the acting window holds none
        // and keeps its panes. The panes underneath are not rearranged, and
        // each shows what it showed.
        #expect(vm.inWindow(other) { vm.workbenchNotebookID } == "notebook-1")
        #expect(other.NotebookID == "notebook-1")
        #expect(acting.NotebookID == nil)
        #expect(other.centerTabGroups == otherPanes)
        #expect(vm.visibleCenterTabs(in: other) == [.artifacts, .reader])
        #expect(acting.centerTabGroups == actingPanes)

        // A window of one pane not showing the chat opens the notebook on its
        // conversation, what it showed staying one of its tabs.
        let single = StudioWindowState()
        single.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.artifacts, .chat], activeTab: .artifacts),
        ])
        StudioWindowDestination.notebook("notebook-1").open(in: single, vm: vm)
        #expect(single.NotebookID == "notebook-1")
        #expect(vm.visibleCenterTabs(in: single) == [.chat])
        #expect(single.centerTabGroups.groups.first?.tabs.contains(.artifacts) == true)
    }

    @Test("A chat sent to another window is that window's chat request")
    func chatOpensInTheTargetWindow() {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let other = StudioWindowState()

        StudioWindowDestination.chat("session-1").open(in: other, vm: vm)

        // The request token is stamped with the window it was made in, which is
        // what `inWindow` scoping is for: without it the chat would land in
        // whichever window happened to be key.
        #expect(vm.reviewChatTargetWindowID == other.id)
    }

    @Test("A new chat sent to another window is a blank chat request for that window")
    func newChatOpensInTheTargetWindow() {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let other = StudioWindowState()

        StudioWindowDestination.newChat.open(in: other, vm: vm)

        #expect(vm.reviewChatTargetWindowID == other.id)
        #expect(vm.reviewChatResetRequestID != nil)
        #expect(StudioWindowDestination.newChat.noun == "chat")
    }

    @Test("The Docs and Notebooks panes open in the target window without an id")
    func paneDestinationsOpenInTheTargetWindow() {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let acting = StudioWindowState()
        let other = StudioWindowState()

        StudioWindowDestination.docs.open(in: other, vm: vm)
        StudioWindowDestination.artifacts.open(in: other, vm: vm)

        #expect(other.centerTabGroups.groups.contains { $0.activeTab == .artifacts })
        #expect(acting.centerTabGroups.groups.contains { $0.activeTab == .notepad } == false)
        #expect(acting.centerTabGroups.groups.contains { $0.activeTab == .artifacts } == false)
    }

    private func placement(displayIndex: Int, x: Double) -> StudioWindowPlacement {
        StudioWindowPlacement(
            displayIndex: displayIndex,
            normalizedX: x,
            normalizedY: 0,
            normalizedWidth: 0.5,
            normalizedHeight: 1
        )
    }

    @Test("A window's first local selection preserves its displayed legacy source")
    func firstWindowSelectionCapturesLegacySource() async {
        let destination = StudioWindowState()
        let vm = makeViewModel()
        vm.selectedArticleId = "previously-visible-source"

        await vm.selectArticle("new-local-source", in: destination)

        #expect(destination.readerArticleID == "new-local-source")
        #expect(destination.readerBackStack == ["previously-visible-source"])
    }

    @Test("A Sources row click reads in its own window, not the registry's key window")
    func sidebarRowClickReadsInItsOwnWindow() async {
        let clicked = StudioWindowState(snapshot: .init(
            centerTabGroups: ["chat*|reader|tasks|notepad|notebooks"],
            navigationRailVisible: true
        ))
        let vm = makeViewModel()
        let keyWindow = vm.activeWindowState
        let keyWindowLayout = keyWindow.centerTabGroups
        vm.selectedArticleId = "post-already-open"

        await vm.selectArticle("post-clicked-here", in: clicked, revealingReader: true)

        #expect(clicked.readerArticleID == "post-clicked-here")
        #expect(clicked.sidebarSelectedSourceIDs == ["post-clicked-here"])
        #expect(clicked.centerTabGroups.groups.map(\.activeTab) == [.chat, .reader])
        // The window the registry still called key keeps what it was showing.
        #expect(keyWindow.readerArticleID == "post-already-open")
        #expect(keyWindow.centerTabGroups == keyWindowLayout)
    }
}

@Suite("Docs Fresh Chat Navigation")
@MainActor
struct DocsFreshChatNavigationTests {
    @Test("Notepad selection opens a fresh Chat beside Docs")
    func notepadSelectionOpensFreshSplitChat() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.notepad], activeTab: .notepad),
            .init(tabs: [.chat, .reader, .tasks, .artifacts], activeTab: .artifacts),
        ])
        vm.requestNotepadChat(
            noteTitle: "Mitochondria",
            selectedText: "  selected note passage  ",
            sourceIDs: ["source-a", "source-b"],
            artifactID: "artifact-a",
            artifactRevision: "revision-a",
            artifactNotebookID: "notebook-a",
            selectionRange: 4..<25,
            contextExcerpt: "A little context around selected note passage.",
            artifactAttachment: ChatDocAttachment(
                id: "artifact-a",
                title: "Mitochondria",
                revision: "revision-a",
                outline: ["Mitochondria"]
            )
        )

        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.notepad, .chat])
        #expect(vm.reviewChatResetRequestID != nil)
        // The doc's home Notebook frames the chat, and the doc itself rides along.
        #expect(vm.pendingReviewChatNotebookID == "notebook-a")
        #expect(vm.readerSelectionExplanationRequest?.artifactAttachment?.id == "artifact-a")
        #expect(vm.readerSelectionExplanationRequest?.artifactAttachment?.revision == "revision-a")
        #expect(vm.readerSelectionExplanationRequest?.sourceIDs == ["source-a", "source-b"])
        #expect(vm.readerSelectionExplanationRequest?.selectedText == "selected note passage")
        #expect(vm.readerSelectionExplanationRequest?.contextTitle == "Note: Mitochondria")
        #expect(vm.readerSelectionExplanationRequest?.artifactID == "artifact-a")
        #expect(vm.readerSelectionExplanationRequest?.artifactRevision == "revision-a")
        #expect(vm.readerSelectionExplanationRequest?.artifactNotebookID == "notebook-a")
        #expect(vm.readerSelectionExplanationRequest?.selectionRange == 4..<25)
        #expect(
            vm.readerSelectionExplanationRequest?.contextualContent()
                .contains("Exact surrounding excerpt:\n<article_excerpt>") == true
        )
        #expect(vm.readerSelectionExplanationRequest?.contextualContent().contains("Article ID: artifact-a") == true)
        #expect(vm.readerSelectionExplanationRequest?.contextualContent().contains("Full note document") == false)
        #expect(vm.reviewChatFocusRequestID != nil)
    }

    @Test("Docs keeps its pane and an open Chat keeps its side, as beside the Reader")
    func notepadSelectionRevealsChatOnDocsRight() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        // Chat already open on the doc's left: both panes stay where the
        // learner put them. Handing a passage over must not swap them.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .tasks], activeTab: .tasks),
            .init(tabs: [.notepad, .sites, .reader, .activity, .activityLog, .goals, .ideas, .browser, .videos, .animations, .artifacts], activeTab: .notepad),
        ])
        handOffPassage(in: vm)
        #expect(vm.centerTabGroups.groups == [
            .init(tabs: [.chat, .tasks], activeTab: .chat),
            .init(tabs: [.notepad, .sites, .reader, .activity, .activityLog, .goals, .ideas, .browser, .videos, .animations, .artifacts, .courses, .memory, .knowledgeMap, .atlas, .library, .plugins], activeTab: .notepad),
        ])

        // Docs as the sole pane: Chat peels out into a new pane on its right
        // and asks the window for room, the way the Reader's handoff does.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .activityLog, .goals, .ideas, .notepad, .sites, .browser, .videos, .animations, .artifacts], activeTab: .notepad),
        ])
        handOffPassage(in: vm)
        #expect(vm.centerTabGroups.groups == [
            .init(tabs: [.reader, .tasks, .activity, .activityLog, .goals, .ideas, .notepad, .sites, .browser, .videos, .animations, .artifacts, .courses, .memory, .knowledgeMap, .atlas, .library, .plugins], activeTab: .notepad),
            .init(tabs: [.chat], activeTab: .chat),
        ])
        #expect(vm.reviewChatPanelMode == .chat)
        #expect(vm.readerChatSpaceRequestID != nil)
    }

    @Test("Add to Chat brings an open Chat forward in place without starting a fresh conversation")
    func addToChatRevealsChatOnDocsRight() async throws {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        let snapshot = try await vm.createArtifact(
            title: "Mitochondria",
            homeNotebookID: nil,
            linkedNotebookIDs: []
        )
        let resetBefore = vm.reviewChatResetRequestID

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader, .tasks, .activity, .activityLog, .goals, .ideas, .notepad, .sites, .browser, .videos, .animations, .artifacts], activeTab: .notepad),
        ])
        await vm.attachDocToChat(snapshot.artifact.id)

        // Both panes were already open, so neither moves.
        #expect(vm.centerTabGroups.groups == [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader, .tasks, .activity, .activityLog, .goals, .ideas, .notepad, .sites, .browser, .videos, .animations, .artifacts, .courses, .memory, .knowledgeMap, .atlas, .library, .plugins], activeTab: .notepad),
        ])
        #expect(vm.pendingChatDocAttachment?.id == snapshot.artifact.id)
        #expect(vm.reviewChatPanelMode == .chat)
        #expect(vm.reviewChatFocusRequestID != nil)
        // Additive, like a dropped source: the open conversation is kept.
        #expect(vm.reviewChatResetRequestID == resetBefore)
    }

    private func handOffPassage(in vm: StudioViewModel) {
        vm.requestNotepadChat(
            noteTitle: "Mitochondria",
            selectedText: "selected note passage",
            sourceIDs: ["source-a"],
            artifactID: "artifact-a",
            artifactRevision: "revision-a",
            artifactNotebookID: nil,
            selectionRange: nil,
            contextExcerpt: nil
        )
    }
}
