import SwiftUI

/// Add to Notebook ▸ and Remove from <Notebook>: the two items a made
/// thing's menu carries for the notebooks it lives in (shell stage 4;
/// docs/notebooks-design.md, "Homing"). The submenu lists the open library's
/// notebooks that take new things, those holding most of the thing's sources
/// first under Suggested (`NotebookMembership.suggestions`), then the rest by
/// title; a notebook the thing lives in already is offered as Remove instead.
/// Each choice is one learner act on one record; nothing is filed in bulk.
///
/// Used by the cards of the home's Docs tab (a Doc or Site), a picture's row
/// in a notebook's Studio (Add to Notebook moves it) and an Idea's row. A course has its own menu items (`CourseNotebookMenuItems`):
/// it lives in no notebook, and a notebook only follows it.
struct NotebookFilingMenuItems: View {
    @Environment(StudioViewModel.self) private var vm
    /// What the suggestions are read from: the thing's sources.
    let sourceIDs: [String]
    /// The notebooks of the open library the thing is filed in, read when
    /// the menu is drawn rather than for every card on every pass.
    let livesIn: () -> Set<String>
    let add: (String) -> Void
    /// Nil where the thing cannot be taken out from this menu.
    var remove: ((String) -> Void)?

    var body: some View {
        if !vm.isActiveLibraryReadOnly {
            let livesIn = livesIn()
            let livingIn = vm.notebooks
                .filter { livesIn.contains($0.id) }
                .sorted(by: NotebooksHomeSort.titleOrder)
            let choices = vm.notebookChoices(forSourceIDs: sourceIDs, livesIn: livesIn)
            let suggested = choices.filter(\.isSuggested)
            let rest = choices.filter { !$0.isSuggested }
            Menu {
                if !suggested.isEmpty {
                    Section("Suggested") {
                        ForEach(suggested) { choice in
                            Button(NotebookTitle(choice.title).text) { add(choice.notebookID) }
                        }
                    }
                }
                if !suggested.isEmpty, !rest.isEmpty { Divider() }
                ForEach(rest) { choice in
                    Button(NotebookTitle(choice.title).text) { add(choice.notebookID) }
                }
            } label: {
                Label("Add to Notebook", systemImage: "folder.badge.plus")
            }
            .disabled(choices.isEmpty)
            if let remove {
                ForEach(livingIn) { notebook in
                    Button("Remove from \(NotebookTitle(notebook.title).text)", systemImage: "folder.badge.minus") {
                        remove(notebook.id)
                    }
                }
            }
        }
    }
}

// MARK: - A notebook from a chat

/// A chat a notebook is being made from (product owner, 2026-10-03: "imagine i
/// just start in regular chat exploring some ideas and then we can turn it
/// into a notebook"): asked from the chat's notebook picker, its ⋯ menu or
/// its row in the rail.
struct NotebookFromChatRequest: Identifiable, Equatable {
    /// The chat's session id.
    let id: String
    /// The chat's title, empty while it has none.
    let title: String
    /// What the open chat holds beyond its record (`ReviewSessionManager`'s
    /// attached and loaded sources); empty for a chat asked from a list.
    var openChatSourceIDs: [String] = []

    init(sessionID: String, title: String, openChatSourceIDs: [String] = []) {
        id = sessionID
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // The placeholders a chat shows before it has a title are not one.
        self.title = ["New chat", "Untitled chat"].contains(trimmed) ? "" : trimmed
        self.openChatSourceIDs = openChatSourceIDs
    }
}

extension View {
    /// New Notebook from This Chat: the notebook made from the chat at once,
    /// with no form, opened in `window` with the chat in it
    /// (`StudioViewModel.createNotebook(fromChat:)`). ForeverLM names it from
    /// the chat (`NotebookNaming`).
    func newNotebookFromChat(
        _ request: Binding<NotebookFromChatRequest?>,
        vm: StudioViewModel,
        window: StudioWindowState?
    ) -> some View {
        onChange(of: request.wrappedValue) { _, asked in
            guard let asked else { return }
            request.wrappedValue = nil
            Task {
                await vm.createNotebook(
                    fromChat: asked.id,
                    openChatSourceIDs: asked.openChatSourceIDs,
                    in: window ?? vm.activeWindowState
                )
            }
        }
    }
}

/// A notebook's chats as menu items: New Chat, then every one of its chats
/// in the rail's order, the one on screen ticked (`notebookChats`); a menu
/// taller than the screen scrolls. The notebook window's icon rail and its
/// chat's header both offer it, since the rail no longer lists a notebook's
/// chats under its folder there. A chat opens in this window, in its
/// notebook (`requestResumeReviewSession`).
struct NotebookChatsMenuItems: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    let notebookID: String
    /// The chat on screen, ticked.
    let currentSessionID: String?

    var body: some View {
        Button("New Chat", systemImage: "square.and.pencil") {
            vm.inWindow(windowState) { vm.requestNewChat() }
        }
        let chats = vm.notebookChats(notebookID: notebookID)
        if !chats.isEmpty {
            Divider()
            ForEach(chats) { chat in
                Toggle(
                    chat.title.isEmpty ? "Untitled chat" : chat.title,
                    isOn: Binding(
                        get: { chat.id == currentSessionID },
                        set: { _ in
                            guard chat.id != currentSessionID else { return }
                            vm.inWindow(windowState) { vm.requestResumeReviewSession(chat.id) }
                        }
                    )
                )
            }
        }
    }
}

/// In Notebooks: every notebook of the open library that holds a source
/// (`notebooksHolding(_:)`), by title, each opening that notebook. On a
/// source's own menus only — the Library's row menu and the Reader's ⋯ —
/// never on the row itself (product owner, 2026-10-03: "maybe no need to show by
/// default in which notebook a source exists"). Nothing at all when no
/// notebook holds it.
///
/// A click opens the notebook in `windowState`, the window the menu is in;
/// a pop-out Reader belongs to no Studio window and passes nil, and the
/// notebook opens in the Studio window used last, brought forward.
struct SourceNotebooksMenuSection: View {
    @Environment(StudioViewModel.self) private var vm
    /// The Sources-list id of the source (`canonicalSourceID`).
    let rowID: String
    let windowState: StudioWindowState?

    var body: some View {
        let notebooks = vm.notebooksHolding(rowID)
        if !notebooks.isEmpty {
            Section("In Notebooks") {
                ForEach(notebooks, id: \.notebookID) { notebook in
                    let title = NotebookTitle(notebook.title)
                    Button("\(title.displayIcon)  \(title.text)") { open(notebook.notebookID) }
                        .help("Open \(title.text)")
                }
            }
        }
    }

    private func open(_ notebookID: String) {
        let destination = windowState ?? vm.activeWindowState
        withAnimation(.easeInOut(duration: 0.22)) {
            vm.inWindow(destination) { vm.openNotebookInReader(notebookID) }
        }
        if windowState == nil {
            StudioWorkspaceWindowCoordinator.shared.bringToFront(destination)
        }
    }
}
