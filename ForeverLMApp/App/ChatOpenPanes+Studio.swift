import Foundation

extension ChatOpenPanes {
    /// What every Studio window has open, read off its window state when the
    /// chat asks — never cached, so the answer is the window as it stands.
    ///
    /// `chatWindow` is the window showing the asking chat and
    /// `chatSessionID` that chat's session, so the tool can tell "this
    /// conversation" from a second chat beside it.
    @MainActor
    static func studio(
        chatWindow: StudioWindowState?,
        chatSessionID: String?,
        vm: StudioViewModel
    ) -> ChatOpenPanes {
        var states = StudioWindowRegistry.shared.states
        if let chatWindow, !states.contains(where: { $0 === chatWindow }) {
            states.append(chatWindow)
        }
        let windows = states.map { state in
            window(state, isChatsWindow: state === chatWindow, chatSessionID: chatSessionID, vm: vm)
        }
        return ChatOpenPanes(windows: windows)
    }

    /// The library sources on screen in every window, read the way a message
    /// sent from a chat in `state` reads them: what the chips over that
    /// chat's composer show, so a chip names exactly what the chat is told.
    @MainActor
    static func sourcesOnScreen(chatWindow state: StudioWindowState, vm: StudioViewModel) -> [ChatContextAdditions.OnScreen] {
        studio(chatWindow: state, chatSessionID: nil, vm: vm).sourcesOnScreen
    }

    /// The Studio windows whose screen shows library source `sourceID` right
    /// now, the window the learner last used first. `open_in_app` asks before
    /// it opens a source: one already drawn in a Reader is brought forward,
    /// not opened a second time in another window.
    @MainActor
    static func windows(showing sourceID: String, vm: StudioViewModel) -> [StudioWindowState] {
        let active = StudioWindowRegistry.shared.activeState
        let states = StudioWindowRegistry.shared.states
        let ordered = states.filter { $0 === active } + states.filter { $0 !== active }
        return ordered.filter { state in
            ChatOpenPanes(windows: [window(state, isChatsWindow: true, chatSessionID: nil, vm: vm)])
                .sourcesOnScreen.contains { $0.id == sourceID }
        }
    }

    /// The flashcard a Memory pane in any window has in front of the learner,
    /// read the way a message sent from a chat in `state` reads it: what the
    /// chip over that chat's composer shows.
    @MainActor
    static func cardOnScreen(
        chatWindow state: StudioWindowState,
        vm: StudioViewModel,
        pinned: ChatContextAdditions.CardOnScreen? = nil
    ) -> ChatContextAdditions.CardOnScreen? {
        var panes = studio(chatWindow: state, chatSessionID: nil, vm: vm)
        panes.pinnedCard = pinned
        return panes.cardOnScreen
    }

    @MainActor
    private static func window(
        _ state: StudioWindowState,
        isChatsWindow: Bool,
        chatSessionID: String?,
        vm: StudioViewModel
    ) -> Window {
        var reported = Set<String>()
        func source(_ id: String) -> Content? {
            guard let article = vm.articlesById[id] else { return nil }
            reported.insert(id)
            return .source(
                id: id,
                title: vm.displayTitle(for: article),
                kind: sourceKind(article.sourceType),
                position: state.readerPositionsOnScreen[id]
                    ?? state.videoPlayheadsOnScreen[id]?.positionLabel
            )
        }
        func artifact(_ id: String) -> Content? {
            guard let record = vm.artifacts.first(where: { $0.id == id }) else { return nil }
            reported.insert(id)
            return .artifact(id: id, title: record.title)
        }
        func chatTitle(_ sessionID: String?) -> String {
            guard let sessionID else { return "New chat" }
            let title = vm.reviewSessionLinks.first { $0.id == sessionID }?.title
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? "Untitled chat" : title
        }
        let dockedChatIsAsking = chatSessionID != nil && state.chatSessionID == chatSessionID

        func describedTab(_ tab: StudioCenterTab, isOnScreen: Bool) -> Tab {
            var contents: [Content] = []
            switch tab {
            case .chat:
                guard isOnScreen else { break }
                contents = [.chat(title: chatTitle(state.chatSessionID), isThisChat: dockedChatIsAsking)]
            case .secondaryChat:
                // Its session lives only in the pane's own store. In the
                // asking chat's window, a docked chat that is not asking
                // means this one is.
                guard isOnScreen else { break }
                contents = [.chat(title: "Chat", isThisChat: isChatsWindow && !dockedChatIsAsking)]
            case .reader:
                if let page = state.externalReaderPage {
                    contents = [.webPage(title: page.title, url: page.url.absoluteString)]
                } else if let id = state.readerSourceID(fallingBackTo: vm.selectedArticleId),
                          let shown = source(id) {
                    contents = [shown]
                }
            case .notepad:
                if let id = state.openArtifactID, let shown = artifact(id) {
                    contents = [shown]
                }
            case .browser:
                if let page = BrowserWorkspace.existing(forWindow: state.id)?.activeTab,
                   let url = page.url ?? page.requestedURL {
                    contents = [.webPage(title: page.title, url: url.absoluteString)]
                }
            case .activity, .activityLog:
                guard isOnScreen else { break }
                contents = [.day(DayModel.shared.selectedDate)]
            case .memory:
                // The Memory pane names its section; in To Check it also has
                // one card in front of the learner, which the pane registers
                // while it is mounted.
                let section = state.memoryPaneSection.title
                guard isOnScreen else { break }
                if state.memoryPaneSection == .toCheck, let card = state.memoryCardOnScreen {
                    contents = [.card(card)]
                } else {
                    contents = []
                }
                return Tab(name: "\(tab.title), \(section)", contents: contents)
            case .courses:
                if let courseID = state.coursePageID, vm.allCourseGroupNames.contains(courseID) {
                    contents = [.course(id: courseID, title: vm.courseDisplayName(courseID))]
                }
            default:
                break
            }
            return Tab(name: tab.title, contents: contents)
        }

        // A window holding a notebook draws its panes between the notebook's
        // columns, as a window with none draws them.
        let panes = state.centerTabGroups.groups.map { group in
            Pane(
                onScreen: describedTab(group.activeTab, isOnScreen: true),
                behind: group.tabs
                    .filter { $0 != group.activeTab }
                    .map { describedTab($0, isOnScreen: false) }
                    .filter { !$0.contents.isEmpty }
            )
        }
        // Readers and linked pages the panes above did not account for — a
        // second Reader, a Site shown inside Artifacts — are on screen too.
        let alsoOnScreen = state.readerSourceIDsOnScreen.sorted()
            .filter { !reported.contains($0) }
            .compactMap(source)
            + state.linkedArtifactIDsOnScreen.sorted()
            .filter { !reported.contains($0) }
            .compactMap(artifact)
        // A video Reader registers its playhead only while it is mounted, and
        // only the drawn tab of a pane mounts, so these are the videos in view.
        let videoPlayheads = state.videoPlayheadsOnScreen.filter { reported.contains($0.key) }
        let notebook = state.notebook.flatMap { workspace in
            vm.notebook(id: workspace.notebookID).map { Notebook(id: $0.id, title: $0.title) }
        }
        return Window(
            isChatsWindow: isChatsWindow,
            panes: panes,
            alsoOnScreen: alsoOnScreen,
            videoPlayheads: videoPlayheads,
            notebook: notebook
        )
    }

    private static func sourceKind(_ type: StudioSourceType) -> String {
        switch type {
        case .article, .manual, .unclassified: return "article"
        case .paper: return "paper"
        case .podcast: return "podcast episode"
        case .book: return "book chapter"
        case .course: return "course material"
        case .meeting: return "meeting"
        case .video: return "video"
        case .xPost: return "X post"
        }
    }
}
