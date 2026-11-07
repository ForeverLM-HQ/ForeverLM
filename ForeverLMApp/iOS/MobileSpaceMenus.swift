import SwiftUI
import UniformTypeIdentifiers
import UIKit

// What the Space does to a page from its row and from its own ⋯ (docs/docs-design.md, "The Space",
// "Subpages"): the Mac's page row menu (`SpacePageRowMenuItems`, `PageSpaceMenu`, `PageNestMenuItems`)
// in the Mac's words, each item offered only where the Mac offers it — the learner's own pages pin,
// file in a space and go to Trash; only their own Markdown pages nest; a team's page and a daily note
// keep what applies. The questions the items ask (a name, Delete Forever, Move to Page…) are drawn by
// the screen the item is on (`spaceActions`).

/// The questions and sheets the Space's menus ask for on one screen, and the failures they meet.
@MainActor
@Observable
final class MobileSpaceActions {
    struct Failure: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var renamingPage: MobileSpacePage?
    var pageName = ""
    var renamingSpace: PageSpace?
    var spaceName = ""
    var isNamingNewSpace = false
    var newSpaceName = ""
    /// The pages New Space… from Move to Space ▸ moves into the space it makes.
    @ObservationIgnored var pagesForNewSpace: [String] = []
    var deletingSpace: PageSpace?
    /// What Delete Forever… and Empty Trash… ask about.
    var deletingForever: [MobileSpacePage] = []
    var movingToPage: MobileSpacePage?
    var failure: Failure?

    func beginRename(_ page: MobileSpacePage) {
        pageName = MobileSpacePageTitle.isPlaceholder(page.title) ? "" : page.title
        renamingPage = page
    }

    func beginRenameSpace(_ space: PageSpace) {
        spaceName = space.name
        renamingSpace = space
    }

    func beginNewSpace(moving pageIDs: [String]) {
        newSpaceName = ""
        pagesForNewSpace = pageIDs
        isNamingNewSpace = true
    }

    /// Runs an act; a failure is shown under `title` with the store's sentence.
    func run(_ title: String, _ act: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await act()
            } catch {
                failure = Failure(title: title, message: error.localizedDescription)
            }
        }
    }

    /// **New page**: made at once, untitled, and opened; in `spaceID` while a space is the place, as
    /// the Mac's sidebar files it.
    func newPage(store: MobileSpaceStore, navigation: MobileSpaceNavigation, inSpace spaceID: String?) {
        run("Couldn’t Make the Page") {
            let page = try await store.createPage(title: "", markdown: "", spaceID: spaceID, parentID: nil)
            navigation.openPage(page.id)
        }
    }

    /// **New Subpage**: a page made under `parentID`, in its space, and opened; the parent's subpages
    /// show in the lists.
    func newSubpage(under parentID: String, store: MobileSpaceStore, navigation: MobileSpaceNavigation) {
        run("Couldn’t Make the Page") {
            let page = try await store.createPage(title: "", markdown: "", spaceID: nil, parentID: parentID)
            MobileSpaceExpansion.expand(parentID)
            navigation.openPage(page.id)
        }
    }

    /// The plan of a quarter (`PlanQuarter`), made from its template when the phone holds none, and
    /// opened.
    func openPlan(_ period: PlanQuarter, store: MobileSpaceStore, navigation: MobileSpaceNavigation) {
        run("Couldn’t Open the Plan") {
            let plan = try await store.ensurePlan(period)
            navigation.openPage(plan.id)
        }
    }

    /// The daily note of `dayKey` (`YYYY-MM-DD`, in the learner's calendar as the Mac reads it), made
    /// when the phone holds none, and opened.
    func openDailyNote(_ dayKey: String, store: MobileSpaceStore, navigation: MobileSpaceNavigation) {
        run("Couldn’t Open the Daily Note") {
            let note = try await store.ensureDailyNote(dayKey: dayKey)
            navigation.openPage(note.id)
        }
    }
}

extension View {
    /// The questions `actions` asks on this screen: Rename Page, Rename Space, New Space, Delete Space,
    /// Delete Forever, Move to Page…, and a failure's sentence.
    func spaceActions(_ actions: MobileSpaceActions) -> some View {
        modifier(MobileSpaceActionPresentations(actions: actions))
    }

    /// A page row's long-press menu and swipes: Pin or Unpin from the leading edge, Move to Trash from
    /// the trailing one; in Trash, Restore and Delete Forever….
    func spaceRowActions(_ page: MobileSpacePage) -> some View {
        modifier(MobileSpaceRowActions(page: page))
    }
}

private struct MobileSpaceActionPresentations: ViewModifier {
    @Bindable var actions: MobileSpaceActions

    @Environment(MobileSpaceStore.self) private var store
    @Environment(\.spaceNavigation) private var navigation

    func body(content: Content) -> some View {
        content
            .environment(actions)
            .alert("Rename Page", isPresented: present(\.renamingPage), presenting: actions.renamingPage) { page in
                TextField("Name", text: $actions.pageName)
                    .accessibilityIdentifier("space.renamePage.name")
                Button("Cancel", role: .cancel) {}
                Button("Rename") { renamePage(page) }
                    .disabled(MobileSpaceListing.cleanedTitle(actions.pageName) == nil)
            }
            .alert("Rename Space", isPresented: present(\.renamingSpace), presenting: actions.renamingSpace) { space in
                TextField("Name", text: $actions.spaceName)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    let name = actions.spaceName
                    actions.run("Couldn’t Rename the Space") { try await store.renameSpace(space.id, to: name) }
                }
                .disabled(PageSpaces.cleanedName(actions.spaceName) == nil)
            }
            .alert("New Space", isPresented: $actions.isNamingNewSpace) {
                TextField("Name your space", text: $actions.newSpaceName)
                    .accessibilityIdentifier("space.newSpace.name")
                Button("Cancel", role: .cancel) {}
                Button("Create") { createSpace() }
                    .disabled(PageSpaces.cleanedName(actions.newSpaceName) == nil)
            }
            .confirmationDialog(
                "Delete “\(NotebookTitle(actions.deletingSpace?.name ?? "").text)”?",
                isPresented: present(\.deletingSpace),
                titleVisibility: .visible,
                presenting: actions.deletingSpace
            ) { space in
                Button("Delete Space", role: .destructive) {
                    actions.run("Couldn’t Delete the Space") { try await store.deleteSpace(space.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Its pages stay in All.")
            }
            .confirmationDialog(
                deleteForeverTitle,
                isPresented: Binding(
                    get: { !actions.deletingForever.isEmpty },
                    set: { if !$0 { actions.deletingForever = [] } }
                ),
                titleVisibility: .visible
            ) {
                Button(actions.deletingForever.count == 1 ? "Delete Forever" : "Delete All Forever", role: .destructive) {
                    deleteForever()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can’t be undone. A linked Google Doc or site is only unlinked; the page itself is not touched.")
            }
            .sheet(item: $actions.movingToPage) { page in
                MobileSpaceParentPicker(page: page) { parentID in
                    actions.run("Couldn’t Move the Page") { try await store.setParent(of: page.id, to: parentID) }
                }
                .environment(store)
            }
            .alert(actions.failure?.title ?? "", isPresented: present(\.failure), presenting: actions.failure) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure.message)
            }
    }

    private func present<Value>(_ keyPath: ReferenceWritableKeyPath<MobileSpaceActions, Value?>) -> Binding<Bool> {
        Binding(
            get: { actions[keyPath: keyPath] != nil },
            set: { if !$0 { actions[keyPath: keyPath] = nil } }
        )
    }

    private var deleteForeverTitle: String {
        let pages = actions.deletingForever
        if pages.count == 1, let page = pages.first { return "Delete ‘\(MobileSpacePageTitle.display(page))’ forever?" }
        return "Delete \(pages.count) items forever?"
    }

    private func renamePage(_ page: MobileSpacePage) {
        guard let title = MobileSpaceListing.cleanedTitle(actions.pageName), title != page.title else { return }
        actions.run("Couldn’t Rename the Page") { try await store.rename(page.id, to: title) }
    }

    /// The space is made, then the pages New Space… came from move into it.
    private func createSpace() {
        let name = actions.newSpaceName
        let pageIDs = actions.pagesForNewSpace
        actions.pagesForNewSpace = []
        actions.run("Couldn’t Make the Space") {
            let spaceID = try await store.createSpace(named: name)
            for pageID in pageIDs {
                try await store.move(pageID, toSpace: spaceID)
            }
        }
    }

    private func deleteForever() {
        let pages = actions.deletingForever
        actions.deletingForever = []
        actions.run("Couldn’t Delete") {
            for page in pages {
                try await store.deleteForever(page.id)
                navigation.closePage(page.id)
            }
        }
    }
}

private struct MobileSpaceRowActions: ViewModifier {
    let page: MobileSpacePage

    @Environment(MobileSpaceStore.self) private var store
    @Environment(MobileSpaceActions.self) private var actions
    @Environment(\.spaceNavigation) private var navigation

    func body(content: Content) -> some View {
        content
            .contextMenu {
                MobileSpacePageMenuItems(page: page)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if page.isTrashed {
                    if page.isOwn {
                        Button {
                            actions.run("Couldn’t Restore the Page") { try await store.restore(page.id) }
                        } label: {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.accentColor)
                    }
                } else if MobileSpaceListing.canPin(page) {
                    let pinned = store.organization.isPinned(page.id)
                    Button {
                        actions.run(pinned ? "Couldn’t Unpin the Page" : "Couldn’t Pin the Page") { try await store.setPinned(page.id, !pinned) }
                    } label: {
                        Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
                    }
                    .tint(.orange)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if page.isOwn {
                    if page.isTrashed {
                        // Asks first, so the row stays until the answer.
                        Button {
                            actions.deletingForever = [page]
                        } label: {
                            Label("Delete Forever", systemImage: "trash")
                        }
                        .tint(.red)
                    } else {
                        Button(role: .destructive) {
                            actions.run("Couldn’t Move the Page to Trash") {
                                try await store.moveToTrash(page.id)
                                navigation.closePage(page.id)
                            }
                        } label: {
                            Label("Move to Trash", systemImage: "trash")
                        }
                    }
                }
            }
    }
}

// MARK: - The page's menu

/// The Mac's page row menu on the phone: Rename… · Pin · Move to Space ▸ · New Subpage · Move to Page… ·
/// Remove from Parent | Share… · Copy ▸ · Open in Google Docs | Move to Trash; in Trash, Restore and
/// Delete Forever…. The same items are a row's long-press menu and the open page's ⋯.
struct MobileSpacePageMenuItems: View {
    let page: MobileSpacePage
    /// The open page's own Rename…, which puts the caret in its title; a row asks for the name.
    var onRename: (() -> Void)? = nil

    @Environment(MobileSpaceStore.self) private var store
    @Environment(MobileSpaceActions.self) private var actions
    @Environment(\.spaceNavigation) private var navigation

    var body: some View {
        if page.isTrashed {
            if page.isOwn {
                Button("Restore", systemImage: "arrow.uturn.backward") {
                    actions.run("Couldn’t Restore the Page") { try await store.restore(page.id) }
                }
                .accessibilityIdentifier("space.menu.restore")
                Button("Delete Forever…", systemImage: "trash", role: .destructive) {
                    actions.deletingForever = [page]
                }
                .accessibilityIdentifier("space.menu.deleteForever")
            }
        } else {
            Section {
                if page.isOwn, !page.isDailyNote, !page.isPlan {
                    Button("Rename…", systemImage: "pencil") {
                        if let onRename { onRename() } else { actions.beginRename(page) }
                    }
                    .accessibilityIdentifier("space.menu.rename")
                }
                if MobileSpaceListing.canPin(page) {
                    let pinned = store.organization.isPinned(page.id)
                    Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                        actions.run(pinned ? "Couldn’t Unpin the Page" : "Couldn’t Pin the Page") { try await store.setPinned(page.id, !pinned) }
                    }
                    .accessibilityIdentifier("space.menu.pin")
                }
                if MobileSpaceListing.canFileInSpace(page) {
                    MobileSpaceMoveToSpaceMenu(page: page)
                }
                if MobileSpaceListing.canNest(page) {
                    Button("New Subpage", systemImage: "doc.badge.plus") {
                        actions.newSubpage(under: page.id, store: store, navigation: navigation)
                    }
                    .accessibilityIdentifier("space.menu.newSubpage")
                    Button("Move to Page…", systemImage: "arrow.turn.down.right") {
                        actions.movingToPage = page
                    }
                    .accessibilityIdentifier("space.menu.moveToPage")
                    if MobileSpaceListing.parent(of: page.id, in: store.pages, organization: store.organization) != nil {
                        Button("Remove from Parent", systemImage: "arrow.turn.up.left") {
                            actions.run("Couldn’t Move the Page") { try await store.setParent(of: page.id, to: nil) }
                        }
                        .accessibilityIdentifier("space.menu.removeFromParent")
                    }
                }
            }
            Section {
                if MobileSpacePageMenuItems.hasMarkdown(page) {
                    ShareLink(
                        item: MobilePageMarkdownExport(pageID: page.id, store: store),
                        preview: SharePreview(MobileSpacePageTitle.display(page))
                    ) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                }
                Menu {
                    if MobileSpacePageMenuItems.hasMarkdown(page) {
                        Button("Copy as Markdown", systemImage: "doc.plaintext") {
                            actions.run("Couldn’t Copy the Page") {
                                UIPasteboard.general.string = try await store.body(of: page.id).markdown
                            }
                        }
                    }
                    Button("Copy Link", systemImage: "link") {
                        UIPasteboard.general.string = MobilePageEditorAddress.url(kind: "doc", id: page.id)?.absoluteString
                    }
                    .accessibilityIdentifier("space.menu.copyLink")
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                if let url = MobileSpacePageMenuItems.webAddress(page) {
                    Link(destination: url) {
                        Label(page.spaceKind == .googleDoc ? "Open in Google Docs" : "Open in Browser", systemImage: "safari")
                    }
                }
            }
            if page.isOwn {
                Section {
                    Button("Move to Trash", systemImage: "trash", role: .destructive) {
                        actions.run("Couldn’t Move the Page to Trash") {
                            try await store.moveToTrash(page.id)
                            navigation.closePage(page.id)
                        }
                    }
                    .accessibilityIdentifier("space.menu.moveToTrash")
                }
            }
        }
    }

    /// A page with Markdown of ForeverLM's to give (`SpacePageSharingItems.applies`): not a linked
    /// Google Doc or site.
    static func hasMarkdown(_ page: MobileSpacePage) -> Bool {
        page.linkedURL == nil && (page.spaceKind == .page || page.spaceKind == .reading)
    }

    /// A linked page's address on the web, which opens in the browser; a site the Mac serves itself has
    /// none.
    static func webAddress(_ page: MobileSpacePage) -> URL? {
        guard let linked = page.linkedURL, let url = URL(string: linked),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}

/// **Move to Space ▸**: each space, ticked where the page is; None, out of every space; then New
/// Space…, which asks for a name and moves the page into the space it makes. A page is in one space at
/// a time.
struct MobileSpaceMoveToSpaceMenu: View {
    let page: MobileSpacePage

    @Environment(MobileSpaceStore.self) private var store
    @Environment(MobileSpaceActions.self) private var actions

    var body: some View {
        let current = store.organization.spaceID(ofPage: page.id)
        Menu {
            ForEach(store.organization.spaces) { space in
                Toggle(space.name, isOn: Binding(
                    get: { current == space.id },
                    set: { _ in move(to: space.id) }
                ))
            }
            Toggle("None", isOn: Binding(
                get: { current == nil },
                set: { _ in move(to: nil) }
            ))
            Divider()
            Button("New Space…", systemImage: "plus") {
                actions.beginNewSpace(moving: [page.id])
            }
        } label: {
            Label("Move to Space", systemImage: "square.stack")
        }
        .accessibilityIdentifier("space.menu.moveToSpace")
    }

    private func move(to spaceID: String?) {
        guard spaceID != store.organization.spaceID(ofPage: page.id) else { return }
        actions.run("Couldn’t Move the Page") { try await store.move(page.id, toSpace: spaceID) }
    }
}

// MARK: - Move to Page…

/// **Move to Page…**: a searchable list of the learner's own pages to put a page under, none that
/// would make it its own ancestor (`MobileSpaceListing.parentCandidates`). The present parent is
/// ticked; **Remove from Parent** takes the page back to the top.
struct MobileSpaceParentPicker: View {
    let page: MobileSpacePage
    let onPick: (String?) -> Void

    @Environment(MobileSpaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    /// A long library shows its first pages until a search narrows it.
    private static let shownLimit = 200

    var body: some View {
        let currentParentID = MobileSpaceListing.parent(of: page.id, in: store.pages, organization: store.organization)?.id
        let candidates = MobileSpaceListing.parentCandidates(for: page.id, in: store.pages, organization: store.organization)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = Array((trimmed.isEmpty ? candidates : candidates.filter { $0.title.localizedCaseInsensitiveContains(trimmed) })
            .prefix(Self.shownLimit))
        NavigationStack {
            List(matches) { candidate in
                Button {
                    if candidate.id != currentParentID { onPick(candidate.id) }
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        MobileSpaceTile(page: candidate, size: 28)
                        Text(MobileSpacePageTitle.display(candidate))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if candidate.id == currentParentID {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .accessibilityLabel("Its parent now")
                        }
                    }
                }
                .tint(.primary)
                .accessibilityIdentifier("space.parentPicker.\(candidate.id)")
            }
            .overlay {
                if matches.isEmpty {
                    Text(trimmed.isEmpty ? "No other pages to nest under" : "No pages match")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Move “\(MobileSpacePageTitle.display(page))” to")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search pages")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if currentParentID != nil {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Remove from Parent") {
                            onPick(nil)
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("space.parentPicker")
    }
}

// MARK: - Share…

/// A page's Markdown as Share… hands it on, read when the share sheet asks for it, so a row's menu
/// loads no page's text until it is shared.
struct MobilePageMarkdownExport: Transferable {
    let pageID: String
    let store: MobileSpaceStore

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .utf8PlainText) { export in
            let markdown = try await export.store.body(of: export.pageID).markdown
            return Data(markdown.utf8)
        }
    }
}
