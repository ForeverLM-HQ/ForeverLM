// The strip drop delegate and the rail button rows.
import SwiftUI
import AppKit

// MARK: - Rows

/// One of the rail's top rows: an icon and a title, in one colour, as
/// ChatGPT's sidebar draws them (product owner, 2026-10-06: "cleaner and fewer
/// buttons and bells and whistles"). A selected row is told by its fill
/// alone; its icon is never tinted. Open Beside, Open in Other Window and
/// Hide are on its menu, and the row drags to the center's edge.
/// The strip's drop handling for one icon, or for the strip's free space
/// (`target` nil). A strip icon's own drag (`StudioDragVisibility`'s
/// `draggedStripEntry`) takes the place of each icon of its group it
/// reaches, so the group rearranges under the pointer, as the Dock does;
/// the drop only ends it. A place dragged in from the Space sidebar is
/// kept where it is dropped.
struct StudioStripDropDelegate: DropDelegate {
    let target: StudioStripEntry?
    /// The top group takes places from the Space sidebar; the footer none.
    let acceptsPlaces: Bool
    let footer: Bool
    let reorder: (StudioStripEntry) -> Void
    let hoverPlace: (Bool) -> Void
    let keepPlace: ([NSItemProvider]) -> Bool

    private var draggedEntry: StudioStripEntry? { StudioDragVisibility.shared.draggedStripEntry }

    func validateDrop(info: DropInfo) -> Bool {
        if let draggedEntry { return draggedEntry.isFooter == footer || target == nil }
        return acceptsPlaces && info.hasItemsConforming(to: [.studioRailShortcut])
    }

    func dropEntered(info: DropInfo) {
        if let draggedEntry {
            if draggedEntry != target { reorder(draggedEntry) }
        } else if acceptsPlaces {
            hoverPlace(true)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if draggedEntry == nil { hoverPlace(false) }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { StudioDragVisibility.shared.endSoon() }
        if draggedEntry != nil { return true }
        hoverPlace(false)
        guard acceptsPlaces else { return false }
        return keepPlace(info.itemProviders(for: [.studioRailShortcut]))
    }
}

struct RailButtonRow: View {
    let title: String
    var systemImage: String? = nil
    /// A picture drawn in the strip in place of `systemImage`: a kept
    /// place's own logo (`StudioRailShortcut.assetImage`).
    var assetImage: String? = nil
    /// Non-nil for a row the learner may hide: its menu then ends with Hide
    /// and the Show in Sidebar submenu that brings any hidden row back.
    var railItem: StudioRailItem? = nil
    var isSelected = false
    var openBeside: (() -> Void)?
    /// What this row opens, when it is a destination that can be sent to
    /// another window. Nil for a row that is only an action here.
    var otherWindowDestination: StudioWindowDestination? = nil
    var help: String? = nil
    var identifier: String? = nil
    /// Drawn in a notebook window's icon strip (`StudioNavigationRail`'s
    /// compact rail): the glyph alone, its title as the help, the same menu.
    var isCompact = false
    /// Non-nil for a shortcut the learner kept on the strip
    /// (`StudioRailShortcuts`): its menu then offers Remove from Sidebar and
    /// the Show in Sidebar submenu.
    var removeFromRail: (() -> Void)? = nil
    let action: () -> Void
    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.openWindow) private var openWindow
    @PreferenceStorage(Prefs.Rail.hiddenItems) private var hiddenRailItemsStorage: String
    @State private var hovering = false

    var body: some View {
        if isCompact {
            compactBody
        } else {
            fullBody
        }
    }

    private var iconStyle: Color {
        isSelected ? Color.primary : Color.secondary
    }

    private var compactBody: some View {
        Button(action: action) {
            RailGlyph(systemImage: systemImage ?? "circle", assetImage: assetImage, isSelected: isSelected)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(StudioSelectionBackground(isSelected: isSelected, isHovered: hovering))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .railTooltip(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
    }

    private var fullBody: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(iconStyle)
                        .frame(width: 16)
                }
                Text(title)
                    .font(.callout)
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, StudioDesign.Spacing.xSmall)
            .frame(minHeight: StudioDesign.Metrics.navigationRowMinHeight)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(StudioSelectionBackground(isSelected: isSelected, isHovered: hovering))
        .help(help ?? "")
        .accessibilityIdentifier(identifier ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
    }

    @ViewBuilder
    private var menuItems: some View {
            if let openBeside {
                Button("Open Beside", systemImage: "rectangle.split.2x1", action: openBeside)
            }
            if let otherWindowDestination {
                OpenStudioDestinationInOtherWindowMenu(
                    destination: otherWindowDestination,
                    currentWindowState: windowState,
                    openNewWindow: { openWindow(id: "studio") }
                )
            }
            if let railItem {
                if openBeside != nil || otherWindowDestination != nil {
                    Divider()
                }
                Button {
                    hiddenRailItemsStorage = StudioRailHiddenItems(storage: hiddenRailItemsStorage)
                        .setting(railItem, hidden: true)
                        .storage
                } label: {
                    Label("Hide \(title)", systemImage: "eye.slash")
                }
                .accessibilityIdentifier("studio.navigation.hide.\(railItem.rawValue)")
                RailItemVisibilityMenu()
            }
            if let removeFromRail {
                if otherWindowDestination != nil {
                    Divider()
                }
                Button(action: removeFromRail) {
                    Label("Remove from Sidebar", systemImage: "pin.slash")
                }
                RailItemVisibilityMenu()
            }
    }
}

/// An icon strip glyph in its 36 × 30 square. Lit, a symbol is filled, as
/// Codex's strip draws its lit icon (measured off its window); a
/// symbol with no fill keeps its outline. A logo (`assetImage`) is drawn as
/// it is, the selection fill behind it saying it is lit.
struct RailGlyph: View {
    let systemImage: String
    var assetImage: String? = nil
    var isSelected = false

    var body: some View {
        Group {
            if let assetImage {
                Image(assetImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .symbolVariant(isSelected ? .fill : .none)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
        }
        .frame(width: 36, height: 30)
    }
}

/// The strip's ⋯, Codex's: every place not kept on the strip, opened with a
/// click, and Show in Sidebar, which keeps one there or hides a row. Drawn
/// whatever the learner hid, so the way back to a hidden row is always here.
struct RailMoreButton: View {
    /// The places to list: the shortcuts the strip does not draw.
    let places: [StudioRailShortcut]
    let open: (StudioRailShortcut) -> Void
    @State private var hovering = false

    var body: some View {
        // A single Image label in a `.button` Menu, sized from outside: a
        // macOS Menu drops any chrome inside its label.
        Menu {
            ForEach(places) { place in
                Button { open(place) } label: {
                    Label(place.title, systemImage: place.systemImage)
                }
            }
            if !places.isEmpty {
                Divider()
            }
            RailItemVisibilityMenu()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: 36, height: 30)
        .background(StudioSelectionBackground(isSelected: false, isHovered: hovering))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .railTooltip("More")
        .accessibilityLabel("More")
        .accessibilityIdentifier("studio.navigation.more")
        .onHover { hovering = $0 }
    }
}

/// Show in Sidebar: one checkmark per hideable rail row, then one per place
/// the strip can keep as a shortcut (`StudioRailShortcuts`), then one per
/// bottom icon (`StudioStripFooterHiddenItems`). It sits on every hideable
/// row's menu, every shortcut's, every bottom icon's, the ⋯'s and the
/// Notebooks header's, so anything hidden is always one right-click away
/// from coming back.
struct RailItemVisibilityMenu: View {
    @Environment(StudioViewModel.self) private var vm
    @PreferenceStorage(Prefs.Rail.hiddenItems) private var hiddenRailItemsStorage: String
    @PreferenceStorage(Prefs.Rail.shortcuts) private var railShortcutsStorage: String
    @PreferenceStorage(Prefs.Rail.hiddenFooterItems) private var hiddenFooterItemsStorage: String

    var body: some View {
        let hidden = StudioRailHiddenItems(storage: hiddenRailItemsStorage)
        let shortcuts = StudioRailShortcuts(storage: railShortcutsStorage)
        let hiddenFooter = StudioStripFooterHiddenItems(storage: hiddenFooterItemsStorage)
        Menu {
            ForEach(StudioRailItem.allCases) { item in
                Toggle(isOn: Binding(
                    get: { !hidden.contains(item) },
                    set: { shown in
                        hiddenRailItemsStorage = StudioRailHiddenItems(storage: hiddenRailItemsStorage)
                            .setting(item, hidden: !shown)
                            .storage
                    }
                )) {
                    Label(item.title, systemImage: item.systemImage)
                }
            }
            Divider()
            ForEach(StudioRailShortcut.offered(listsCanvases: vm.listsCanvases)) { shortcut in
                Toggle(isOn: Binding(
                    get: { shortcuts.contains(shortcut) },
                    set: { shown in
                        railShortcutsStorage = StudioRailShortcuts(storage: railShortcutsStorage)
                            .setting(shortcut, shown: shown)
                            .storage
                    }
                )) {
                    Label(shortcut.title, systemImage: shortcut.systemImage)
                }
            }
            Divider()
            ForEach(StudioStripFooterItem.allCases) { item in
                Toggle(isOn: Binding(
                    get: { !hiddenFooter.contains(item) },
                    set: { shown in
                        hiddenFooterItemsStorage = StudioStripFooterHiddenItems(storage: hiddenFooterItemsStorage)
                            .setting(item, hidden: !shown)
                            .storage
                    }
                )) {
                    Label(item.title, systemImage: item.systemImage)
                }
            }
        } label: {
            Label("Show in Sidebar", systemImage: "sidebar.left")
        }
        .accessibilityIdentifier("studio.navigation.showInSidebar")
    }
}
