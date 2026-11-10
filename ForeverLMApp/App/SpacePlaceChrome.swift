// The Space place chrome: header, title, search field, pills and the dark menu.
#if os(macOS)
import AppKit
import SwiftUI

// MARK: - Place chrome

/// One look for every list of the learner's things — the Space's places, the
/// Courses list, a notebook's own Pages — so no list draws its own head.
/// The product owner, 2026-10-10, of the Courses list's blue New Course beside the
/// Notebooks list's dark New pill: "make sure that this all is always
/// consistent". A new list of things takes `SpacePlaceHeader`,
/// `spacePlaceColumn()` and a dark pill; it never reaches for
/// `.borderedProminent` or a search field of its own (docs/ui-design.md,
/// "One head for every list").
/// True where the Space sidebar beside the list lights the place's row, so
/// the list's head need not name it (`SpacePlaceTitle`).
private struct SpacePlaceNamedBySidebarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var spacePlaceNamedBySidebar: Bool {
        get { self[SpacePlaceNamedBySidebarKey.self] }
        set { self[SpacePlaceNamedBySidebarKey.self] = newValue }
    }
}

enum SpacePlaceMetrics {
    static let titleFont = Font.system(size: 22, weight: .semibold)
    static let searchWidth: CGFloat = 220
    static let horizontalPadding: CGFloat = 28
    static let topPadding: CGFloat = 22
    static let bottomPadding: CGFloat = 32
    static let maxWidth: CGFloat = 1120
    /// From the head's last row to an empty list's line.
    static let emptyTopPadding: CGFloat = 72
}

extension View {
    /// A place's list in the Space's column: the same margins and the same
    /// width cap, centred in a wide pane.
    func spacePlaceColumn() -> some View {
        padding(.horizontal, SpacePlaceMetrics.horizontalPadding)
            .padding(.top, SpacePlaceMetrics.topPadding)
            .padding(.bottom, SpacePlaceMetrics.bottomPadding)
            .frame(maxWidth: SpacePlaceMetrics.maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// A list's head: its name, the search and its one primary action on a line,
/// or the search under the other two where the pane is too narrow for it.
struct SpacePlaceHeader<Title: View, Actions: View>: View {
    @Binding var searchText: String
    /// Bumped to give the search the focus (the Space sidebar's search).
    var searchFocusRequest = 0
    /// The field's prompt: "Search by name" where a list has names alone.
    var searchPrompt = "Search by name"
    var searchIdentifier = "space.search"
    @ViewBuilder let title: () -> Title
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                title()
                Spacer(minLength: 12)
                search
                    .frame(width: SpacePlaceMetrics.searchWidth)
                actions()
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    title()
                    Spacer(minLength: 8)
                    actions()
                }
                search
            }
        }
    }

    private var search: some View {
        SpaceSearchField(text: $searchText, prompt: searchPrompt, focusRequest: searchFocusRequest, identifier: searchIdentifier)
    }
}

/// A list's name, plain, at its head — unless the tab over the pane already
/// says it (Goals under a Goals tab, Pages under a Pages tab), or the Space
/// sidebar's lit row does (the Board and the Plan beside it): then the head
/// is the search and the action alone.
struct SpacePlaceTitle: View {
    @Environment(\.studioPaneTab) private var paneTab
    @Environment(\.spacePlaceNamedBySidebar) private var namedBySidebar
    let title: String

    var body: some View {
        if paneTab?.title != title && !namedBySidebar {
            Text(title)
                .font(SpacePlaceMetrics.titleFont)
                .lineLimit(1)
                .textSelection(.disabled)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// ChatGPT's search over a list: a capsule, "Search by name" where what it
/// lists has names.
struct SpaceSearchField: View {
    @Binding var text: String
    var prompt = "Search by name"
    var focusRequest = 0
    var identifier = "space.search"
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .zoomedSystemFont(size: 11.5, weight: .medium)
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .zoomedSystemFont(size: 12.5)
                .focused($isFocused)
                .accessibilityIdentifier(identifier)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .zoomedSystemFont(size: 11.5)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.hoverWash(in: Circle(), inset: -3))
                .help("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(Color(nsColor: .textBackgroundColor)))
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(isFocused ? 0.22 : 0.12), lineWidth: 1)
        }
        .onChange(of: focusRequest) { _, _ in isFocused = true }
    }
}

/// A list with nothing to show: a glyph over one line, centred under the head
/// (`SpacePlaceMetrics.emptyTopPadding` below it).
struct SpaceEmptyLine: View {
    let systemImage: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(text)
                .zoomedSystemFont(size: 13, weight: .medium)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

/// One of a list's filters (All, Yours, Shared; Drafts, Published…): a word
/// in a capsule that fills while it is chosen. `count`, when given, is what
/// waits there and asks for something ("To Check 12"), drawn quieter beside
/// the word; a zero is never drawn.
struct SpaceScopePill: View {
    let title: String
    let isSelected: Bool
    var count: Int? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let count, count > 0 {
                    Text("\(count)")
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .zoomedSystemFont(size: 12.5, weight: .medium)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Color.primary.opacity(isSelected ? 0.07 : 0))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: 0.05))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel(title)
        .accessibilityValue(count.map { $0 > 0 ? "\($0)" : "" } ?? "")
    }
}

/// ChatGPT's dark pill for a list's one primary action, and for the same
/// action offered again in its empty state: near-black with white words in
/// light mode, the reverse in dark mode.
struct SpaceDarkPillButton: View {
    let title: String
    let systemImage: String?
    let image: String?
    var shortcut: KeyboardShortcut?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            SpaceDarkPillLabel(title: title, systemImage: systemImage, image: image, showsChevron: false, isHovering: isHovering)
        }
        // The pill paints its own hover (a lighter fill); a wash behind a
        // dark fill would not show.
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .ownsRowHoverWash()
        .onHover { isHovering = $0 }
        .fixedSize()
    }
}

/// One row of a Space menu card (`SpaceDarkPillMenu`): a glyph and a name,
/// as Codex's New menu draws them, and on the right what is not ready yet.
struct SpaceMenuItem: Identifiable {
    /// Also the row's accessibility identifier.
    let id: String
    let title: String
    let systemImage: String
    /// Quiet words at the row's end ("in Reading list", "Coming soon").
    var trailing: String? = nil
    var isEnabled = true
    var help: String? = nil
    let action: () -> Void
}

/// The dark pill with its menu: a click drops a card under it, Codex's (product
/// owner, 2026-10-12, beside Codex's New menu: "the codex list of things looks
/// way better!", "things should have icons and be spaced more nicely"). Each
/// group of rows is one section, a hairline between them. The card is a panel
/// of its own (`SpaceMenuPanel`), so it floats over the list under the head
/// and has no popover's arrow.
struct SpaceDarkPillMenu: View {
    let title: String
    let sections: [[SpaceMenuItem]]
    @State private var isHovering = false
    @State private var anchor = SpaceMenuAnchor()

    var body: some View {
        Button {
            anchor.toggle(sections: sections.filter { !$0.isEmpty })
        } label: {
            SpaceDarkPillLabel(title: title, systemImage: nil, image: nil, showsChevron: true, isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .background(SpaceMenuAnchorView(anchor: anchor))
        .ownsRowHoverWash()
        .onHover { isHovering = $0 }
        .fixedSize()
        .onDisappear { anchor.close() }
    }
}

/// Where a pill's card hangs from: the pill's own view, and whether its card
/// is the one open.
@MainActor
final class SpaceMenuAnchor {
    weak var view: NSView?
    let id = UUID()

    func toggle(sections: [[SpaceMenuItem]]) {
        // The press that closed the card (the panel losing key) is the same
        // click as this one: it is a close, not a reopen.
        if SpaceMenuPanel.shared.closedRecently(anchor: id) { return }
        guard let view else { return }
        SpaceMenuPanel.shared.show(sections: sections, below: view, anchor: id)
    }

    func close() {
        SpaceMenuPanel.shared.close(anchor: id)
    }
}

private struct SpaceMenuAnchorView: NSViewRepresentable {
    let anchor: SpaceMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

/// The one open menu card. Its panel takes key, so the rows light under the
/// pointer and Escape closes it, but never main, so the window behind keeps
/// its active title bar, as with a native menu. A click anywhere else takes
/// key from it and closes it.
@MainActor
final class SpaceMenuPanel: NSObject, NSWindowDelegate {
    static let shared = SpaceMenuPanel()

    private var panel: KeyPanel?
    private var anchorID: UUID?
    private var closedAt = Date.distantPast
    private var closedAnchorID: UUID?

    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        var onCancel: (() -> Void)?
        override func cancelOperation(_ sender: Any?) { onCancel?() }
    }

    func closedRecently(anchor: UUID) -> Bool {
        closedAnchorID == anchor && Date().timeIntervalSince(closedAt) < 0.3
    }

    func show(sections: [[SpaceMenuItem]], below view: NSView, anchor: UUID) {
        close()
        guard let window = view.window, window.isVisible else { return }
        let card = SpaceMenuCard(sections: sections) { [weak self] item in
            self?.close()
            item.action()
        }
        let hosting = NSHostingView(rootView: card)
        let fitting = hosting.fittingSize
        let size = NSSize(width: ceil(fitting.width), height: ceil(fitting.height))
        // Measured once, then the hosting view sizes nothing: as a panel's
        // content view with the default options it pins the panel's size on
        // every constraints pass, which looped until AppKit ended the app
        // (build 210, the rail's tooltip panel).
        hosting.sizingOptions = []
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        // Right edges in line, the card's shadow margin outside the pill's.
        let pill = window.convertToScreen(view.convert(view.bounds, to: nil))
        var origin = NSPoint(
            x: pill.maxX - size.width + SpaceMenuCard.shadowMargin,
            y: pill.minY - 2 - size.height + SpaceMenuCard.shadowMargin
        )
        if let visible = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = max(origin.y, visible.minY + 4)
        }

        let panel = KeyPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = container
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        anchorID = anchor
    }

    /// Closes the card, or only the one `anchor` opened.
    func close(anchor: UUID? = nil) {
        guard let panel, anchor == nil || anchor == anchorID else { return }
        self.panel = nil
        closedAnchorID = anchorID
        closedAt = Date()
        anchorID = nil
        panel.delegate = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// The card: white with a hairline and a soft shadow, a glyph and a name per
/// row with room around them, a hairline between groups.
private struct SpaceMenuCard: View {
    static let shadowMargin: CGFloat = 14
    let sections: [[SpaceMenuItem]]
    let choose: (SpaceMenuItem) -> Void

    /// More rows than this scroll, so a long list of goals fits the screen.
    static let rowsShown = 12

    var body: some View {
        Group {
            if sections.reduce(0, { $0 + $1.count }) > Self.rowsShown {
                ScrollView(.vertical) { rows }
                    .frame(height: CGFloat(Self.rowsShown) * SpaceMenuRow.height + 12)
            } else {
                rows
            }
        }
        .padding(6)
        // A long name is cut short rather than widening the card.
        .frame(minWidth: 236, maxWidth: 360, alignment: .leading)
        .fixedSize()
        // The shadow on the card alone; on the whole view it haloed every
        // word.
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
        )
        .padding(Self.shadowMargin)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if index > 0 {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                ForEach(section) { item in
                    SpaceMenuRow(item: item) { choose(item) }
                }
            }
        }
    }
}

private struct SpaceMenuRow: View {
    static let height: CGFloat = 34
    let item: SpaceMenuItem
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: item.systemImage)
                    .zoomedSystemFont(size: 14, weight: .regular)
                    .frame(width: 18)
                Text(item.title)
                    .zoomedSystemFont(size: 13.5)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 16)
                if let trailing = item.trailing {
                    Text(trailing)
                        .zoomedSystemFont(size: 12.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(Color.primary.opacity(item.isEnabled ? 0.88 : 0.35))
            .padding(.horizontal, 10)
            // Every row the card's width, so each lights the same band.
            .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(isHovering && item.isEnabled ? 0.05 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .onHover { isHovering = $0 }
        .help(item.help ?? "")
        .accessibilityIdentifier(item.id)
    }
}

private struct SpaceDarkPillLabel: View {
    let title: String
    let systemImage: String?
    let image: String?
    let showsChevron: Bool
    let isHovering: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let image {
                Image(image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .zoomedSystemFont(size: 11.5, weight: .semibold)
            }
            Text(title)
                .zoomedSystemFont(size: 12.5, weight: .semibold)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .zoomedSystemFont(size: 9.5, weight: .bold)
            }
        }
        .foregroundStyle(Color(nsColor: .textBackgroundColor))
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Capsule().fill(Color.primary.opacity(isHovering ? 0.78 : 0.9)))
        .contentShape(Capsule())
    }
}
#endif
