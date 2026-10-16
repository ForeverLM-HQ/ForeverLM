import SwiftUI

// MARK: - The Home place

/// Home, Codex's first icon (product owner, 2026-10-16: "similar to codex we
/// should have a home page with all the chats", and, of the first sketch,
/// "not just the new chat at the top"; then "so maybe chats shouldn't be under
/// spaces"). The strip's first row opens it: every chat the learner has, in a
/// notebook or in none, as one list under the place-chrome head, with New Chat
/// as its one dark pill, so the chats are reachable from anywhere without a
/// chat being open beside them. The Space listed them from 2026-10-10 until
/// then; it lists none now.
///
/// The list is the Space's list view over the chats (`SpaceBrowseView` at
/// `SpaceDestination.chats`), so a row's menu, Rename, Move to Notebook ▸,
/// Hide and Delete…, its search, and its filter by notebook are the same
/// there as they were. A place like the Library: a pane with its ×, Open
/// Beside, Open in Other Window and a drag, with the card to itself (no
/// sidebar beside it); it leaves a notebook the way the Library does.
struct HomePane: View {
    @State private var searchText = ""

    var body: some View {
        SpaceBrowseView(
            destination: .chats,
            showsPlaceMenu: false,
            searchText: $searchText,
            searchFocusRequest: 0,
            onSelectPlace: { _ in },
            onOpen: { _ in },
            onNewPage: {},
            onLink: { _ in },
            onNewSpace: {}
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .studioCenterTabCloseChrome(for: .home)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Home")
        .accessibilityIdentifier("home.pane")
    }
}

extension StudioViewModel {
    /// The Home place in `window` (the window in scope when nil): the strip's
    /// Home row. A window holding a notebook leaves it the way it does for the
    /// Library (`.home` routes `.leave`), and the notebook's row brings it back.
    func openHomePlace(in window: StudioWindowState? = nil) {
        activateCenterTab(.home, in: window ?? activeWindowState)
    }
}
