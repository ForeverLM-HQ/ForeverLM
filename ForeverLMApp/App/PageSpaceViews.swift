#if os(macOS)
import AppKit
import SwiftUI

// MARK: - Spaces of pages
//
// What the Space draws for the learner's spaces of pages (`PageSpaces`,
// docs/docs-design.md, "The Space") beyond the sidebar's rows: a space's icon,
// Move to Space ▸, and the name New Space… asks for from that menu.

/// A space's icon: its name's leading emoji, else a quiet stack, monochrome
/// like the sidebar's other glyphs.
struct PageSpaceGlyph: View {
    let name: String

    var body: some View {
        if let icon = NotebookTitle(name).icon {
            Text(icon)
                .zoomedSystemFont(size: 12.5)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "square.stack")
                .zoomedSystemFont(size: 13, weight: .regular)
        }
    }
}

/// **Move to Space ▸**, on a page's ⋯ and right-click in the Space's lists
/// and in the page's own menu: each space, ticked where the pages are; None,
/// out of every space; then New Space…, which asks for a name and moves the
/// pages into the space it makes. A page is in one space at a time. Drawn only
/// for records a space can hold (`canFileInPageSpace`): a team's library, an
/// animation and a team's record show none.
struct PageSpaceMenu: View {
    @Environment(StudioViewModel.self) private var vm
    let pages: [ArtifactRecord]
    /// What the Space files by id that is no record: a canvas. Always the
    /// learner's own, so it files wherever My Library is open.
    let itemIDs: [String]

    init(pages: [ArtifactRecord]) {
        self.pages = pages
        self.itemIDs = []
    }

    init(page: ArtifactRecord) {
        self.pages = [page]
        self.itemIDs = []
    }

    init(itemIDs: [String]) {
        self.pages = []
        self.itemIDs = itemIDs
    }

    var body: some View {
        let ids = pages.filter { vm.canFileInPageSpace($0) }.map(\.id)
            + (vm.activeTeamID == nil ? itemIDs : [])
        if !ids.isEmpty, !vm.isActiveLibraryReadOnly {
            let current = Set(ids.map { vm.pageSpaces.spaceID(ofPage: $0) })
            Menu {
                ForEach(vm.orderedPageSpaces) { space in
                    Toggle(space.name, isOn: Binding(
                        get: { current == [space.id] },
                        set: { _ in vm.movePages(ids, toPageSpace: space.id) }
                    ))
                }
                Toggle("None", isOn: Binding(
                    get: { current == [nil] },
                    set: { _ in vm.movePages(ids, toPageSpace: nil) }
                ))
                Divider()
                Button("New Space…") {
                    PageSpaceNamePrompt.createSpace(moving: ids, vm: vm)
                }
            } label: {
                Label("Move to Space", systemImage: "square.stack")
            }
        }
    }
}

// MARK: - Subpages
//
// What the Space draws for nested pages (`PageParents`, docs/docs-design.md,
// "Subpages"): the three menu items that nest a page, the sheet Move to Page…
// opens, and the quiet trail over an open page.

/// **New Subpage**, **Move to Page…** and **Remove from Parent**, on a page's
/// ⋯ and right-click in the Space's lists and in the page's own menu. Drawn
/// only for a page that can nest (`canNestPage`: the learner's own Markdown
/// page in My Library); Remove from Parent only while it has a parent.
struct PageNestMenuItems: View {
    @Environment(StudioViewModel.self) private var vm
    let page: ArtifactRecord
    /// Move to Page… asks for a page in a sheet the host draws.
    let onMoveToPage: () -> Void
    /// Hears the subpage New Subpage made, to open it.
    let onCreatedSubpage: (ArtifactRecord) -> Void

    var body: some View {
        if vm.canNestPage(page), !vm.isActiveLibraryReadOnly {
            Button("New Subpage", systemImage: "doc.badge.plus") {
                Task {
                    if let subpage = await vm.createSubpage(of: page.id) { onCreatedSubpage(subpage) }
                }
            }
            Button("Move to Page…", systemImage: "arrow.turn.down.right", action: onMoveToPage)
            if vm.pageParent(of: page.id) != nil {
                Button("Remove from Parent", systemImage: "arrow.turn.up.left") {
                    vm.setPageParent(page.id, to: nil)
                }
            }
        }
    }
}

/// **Move to Page…**: a searchable list of the learner's own pages to put a
/// page under, none that would make it its own ancestor (`pageParentCandidates`).
/// The page's present parent is ticked; picking it again does nothing, and
/// **Remove from Parent** takes the page back to the top.
struct PageParentPickerSheet: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    let page: ArtifactRecord
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    /// A long library shows its first pages until a search narrows it.
    private static let shownLimit = 200

    private var matches: [ArtifactRecord] {
        let candidates = vm.pageParentCandidates(for: page.id)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = trimmed.isEmpty ? candidates : candidates.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
        return Array(found.prefix(Self.shownLimit))
    }

    var body: some View {
        let currentParentID = vm.pageParent(of: page.id)?.id
        VStack(alignment: .leading, spacing: 12) {
            Text("Move “\(page.title)” to")
                .zoomedSystemFont(size: 15, weight: .semibold)
                .lineLimit(1)
            TextField("Search pages", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityIdentifier("page.parentPicker.search")
            let shown = matches
            if shown.isEmpty {
                Text(query.isEmpty ? "No other pages to nest under" : "No pages match")
                    .zoomedSystemFont(size: 12.5)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { candidate in
                            Button {
                                vm.setPageParent(page.id, to: candidate.id)
                                dismiss()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.text")
                                        .zoomedSystemFont(size: 12.5)
                                        .foregroundStyle(.secondary)
                                    Text(candidate.title)
                                        .zoomedSystemFont(size: 13)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer(minLength: 8)
                                    if candidate.id == currentParentID {
                                        Image(systemName: "checkmark")
                                            .zoomedSystemFont(size: 11, weight: .semibold)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 30)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
                            .accessibilityIdentifier("page.parentPicker.\(candidate.id)")
                        }
                    }
                }
                .frame(height: 260)
            }
            HStack {
                if currentParentID != nil {
                    Button("Remove from Parent") {
                        vm.setPageParent(page.id, to: nil)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear { searchFocused = true }
    }
}

/// The quiet line over an open page that has a parent: "Parent › Page", each
/// ancestor a link that opens it (product owner, 2026-10-07: ChatGPT's nested pages).
/// Small, secondary and out of the way ("Quiet chrome", docs/ui-design.md);
/// nothing at all for a top-level page. A trail deeper than
/// `PageParents.displayDepthLimit` leaves the top off behind an ellipsis. Its
/// own view, so the editor's typing never re-reads the rows.
struct PageParentTrail: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    let pageID: String
    /// The page's own side inset, so the line stands where the title does.
    let inset: ArtifactPageInset

    var body: some View {
        let ancestors = vm.pageAncestors(of: pageID)
        if !ancestors.isEmpty {
            let byID = Dictionary(ancestors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let trail = PageParents.trail(ancestors.map(\.id))
            HStack(spacing: 4) {
                if trail.isTruncated {
                    Text("…")
                        .foregroundStyle(.tertiary)
                    separator
                }
                ForEach(trail.ids, id: \.self) { id in
                    if let ancestor = byID[id] {
                        Button {
                            Task { await vm.openDoc(id, revealing: nil, in: windowState) }
                        } label: {
                            Text(ancestor.title)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Open \(ancestor.title)")
                        .accessibilityIdentifier("page.trail.\(id)")
                        separator
                    }
                }
                Text(vm.artifacts.first { $0.id == pageID }?.title ?? "")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .zoomedSystemFont(size: 11.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(inset)
            .padding(.top, 12)
            .textSelection(.disabled)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Parent pages")
        }
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .zoomedSystemFont(size: 8, weight: .semibold)
            .foregroundStyle(.quaternary)
            .accessibilityHidden(true)
    }
}

/// New Space… from Move to Space ▸. A menu cannot hold a sheet, and the menu
/// is drawn in places that have none to offer (a page's own menu, a row's
/// right-click), so the name is asked over the window in front: an alert with
/// one field, the question a collection's New Collection… asks. The space is
/// the learner's own (no Invite people: the sidebar's + makes a shared one),
/// and the pages move into it.
@MainActor
enum PageSpaceNamePrompt {
    static func createSpace(moving pageIDs: [String], vm: StudioViewModel) {
        let alert = NSAlert()
        alert.messageText = "New Space"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Name your space"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            vm.createPageSpace(named: field.stringValue, moving: pageIDs)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
#endif
