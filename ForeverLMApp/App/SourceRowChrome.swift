// Row chrome and hover helpers for source sidebar rows.
import SwiftUI
import AppKit

/// What a row of the Sources list adds around the row itself: the
/// selection's grey wash, the hairline under a full row, the click that
/// selects and opens, and the row's menu.
///
/// `highlightIDs` are the sources whose selection lights the row (a book's
/// row lights for any of its chapters); `rowID` is the one a click selects.
/// The menu is built only while the pointer is over the row: SwiftUI builds a
/// `.contextMenu`'s items in the row's body, so a menu on every row would be
/// built again for each row that scrolls in, and a right-click always lands
/// on a hovered row. A row whose own label carries its menu passes none.
struct LazySourceRowChrome<MenuContent: View>: ViewModifier {
    let highlightIDs: Set<String>
    let rowID: String
    let onClick: () -> Void
    let menu: (() -> MenuContent)?

    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    @Environment(\.sourcesListLayout) private var sourcesListLayout
    @State private var isHovered = false

    func body(content: Content) -> some View {
        let isSelected = !(windowState?.sidebarSelectedSourceIDs.isDisjoint(with: highlightIDs) ?? true)
        return content
            .padding(.vertical, sourcesListLayout == .compact ? 1 : 5)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.10 : 0))
                    .padding(.horizontal, -6)
            }
            .overlay(alignment: .bottom) {
                if sourcesListLayout != .compact && !isSelected {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 1)
                        .padding(.leading, 46)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture(count: 1).onEnded { onClick() })
            .onHover { isHovered = $0 }
            .contextMenu {
                if isHovered, let menu { menu() }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .id(rowID)
    }
}

/// A series or playlist row's label, handed whether the pointer is over it,
/// with the hover kept in its own view so a hover never re-runs the list's
/// body. The whole row counts, whitespace included.
struct SourceGroupRowHover<Content: View>: View {
    @ViewBuilder let content: (_ isHovered: Bool) -> Content

    @State private var isHovered = false

    var body: some View {
        content(isHovered)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}
