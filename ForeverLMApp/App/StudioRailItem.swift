// The rail items and the hidden rail items.
import SwiftUI
import AppKit

/// A rail row above the notebooks the learner may take off the rail: New
/// chat, Memory, Browser, Library and the Space. Memory is one row like
/// the others (the product owner, 2026-09-22: it "just needs to be part of that
/// list"), not a row of its own over the notebooks. The Notebooks header,
/// the chats and the footer are the rail's skeleton and stay.
///
/// Rows that left, each falling out of the stored hidden set as a name this
/// build does not know (`StudioRailHiddenItems.init(storage:)`):
///
/// - Docs, Sites, Videos and Animations (`docs`, `sites`, `videos`,
///   `animations`) went under one Artifacts row on 2026-09-17 (the product owner: "we
///   should just have an 'artifacts' page in the left sidebar") and off the
///   rail on 2026-09-20, as the Artifacts index's kind chips (since
///   2026-10-06 only Docs and Sites are chips, on the Space's tab; the rest
///   are listed in their notebook's Studio).
/// - Planner (`planner`) left on 2026-09-28 and the app on 2026-09-30: the
///   Now chip in the footer shows the day, which is the Mac's Calendar.
/// - Goals and Ideas (`goals`, `ideas`) became Artifacts chips on 2026-09-29
///   (the product owner: "maybe ideas and goals should live under artifacts").
/// - Activity, Courses and Artifacts (`activity`, `courses`, `artifacts`)
///   left (2026-10-01; docs/notebooks-design.md, "The
///   rail"): the rail leads with the notebooks, where the learner works.
///   Activity is reached from the menu bar's Today menu and the Now chip's
///   popover; the courses (a course lives in no notebook; 2026-10-03) are
///   the Space's Courses row, and the Goals (2026-10-06) the Space's tab.
/// - Home (`notebooks`) left on 2026-10-09, when the Notebooks home went
///   ("it doesn't add anything"): the Space is the rail's first row, and its
///   All lists every notebook and course. A stored hidden set naming it drops
///   the name like the rows above.
/// - Canvas (`knowledgeMap`) left on 2026-10-07, when canvases became items
///   in the Space (the product owner: "canvases should be within spaces; just like
///   sites, pages, etc"): each opens from the Space's Canvases, its Recents
///   or its Pinned, as a page does (docs/knowledge-map-design.md).
enum StudioRailItem: String, CaseIterable, Identifiable {
    /// Home (2026-10-16), Codex's first icon, and the strip's + before it
    /// (product owner, 2026-10-16: "the home button should just replace that
    /// + button; and it should show what's currently shown under that +
    /// button"): a blank chat with Home's sidebar beside it, New chat, the
    /// notebooks and every chat. An action that takes the window home, not a
    /// pane of its own.
    case home
    case newChat
    case memory
    /// The Space (2026-10-07): the Pages home, ChatGPT's Space with its own
    /// sidebar. The row was Daily Notes (2026-10-06, docs/notes-graph-design.md)
    /// until the rail became Codex's icon rail; today's note is one page in
    /// the Space, and ⇧⌘D still opens it.
    case space
    /// The web itself, in tabs. Inside a notebook it opens in the document
    /// slot; Discover lives in Add sources.
    case browser
    /// The full-window Library (2026-10-01, decisions v5, 2): the whole
    /// library, every kind, laid out for managing it.
    case library
    /// Plugins (2026-10-13), Codex's grid: every plugin and its state, and
    /// each plugin's page (docs/codex-shell-plan.md, Track 2).
    case plugins
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .newChat: return "New chat"
        case .memory: return "Memory"
        case .space: return "Spaces"
        case .browser: return "Browser"
        case .library: return "Library"
        case .plugins: return ShellPlaces.descriptor(for: .plugins).title
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .newChat: return "square.and.pencil"
        case .memory: return MemoryReviewSession.sidebarIcon
        case .space: return "square.on.square"
        case .browser: return "safari"
        case .library: return "books.vertical"
        case .plugins: return ShellPlaces.descriptor(for: .plugins).glyph
        }
    }
}

/// Which rail rows the learner has hidden. Follows the account, like
/// `studio.hiddenTabs` and `studio.pinnedNotebooks.v1`: hiding a row is tidying
/// work, and the learner who did it on one Mac meant it about their sidebar,
/// not about that Mac (product owner, 2026-09-14: "please make sure it all behaves
/// the same way"). Every row is shown until the learner hides it, and a hidden
/// row comes back from the Show in Sidebar submenu on any remaining row's menu
/// — the Notebooks header's included, so the way back never disappears with the
/// rows.
struct StudioRailHiddenItems: Equatable {
    static let storageKey = Prefs.Rail.hiddenItems.name

    var items: Set<StudioRailItem>

    init(_ items: Set<StudioRailItem> = []) {
        self.items = items
    }

    /// Decodes the comma-separated raw values `@AppStorage` holds. A name this
    /// build does not know — a row a later build added, then removed, or a row
    /// that retired (`StudioRailItem`'s list) — is dropped rather than kept as a
    /// phantom, and leaves the stored value with the learner's next change.
    init(storage: String) {
        items = Set(
            storage.split(separator: ",")
                .compactMap { StudioRailItem(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
        )
    }

    /// Sorted so equal sets encode identically.
    var storage: String {
        items.map(\.rawValue).sorted().joined(separator: ",")
    }

    func contains(_ item: StudioRailItem) -> Bool { items.contains(item) }

    func toggling(_ item: StudioRailItem) -> StudioRailHiddenItems {
        var copy = self
        if copy.items.contains(item) { copy.items.remove(item) } else { copy.items.insert(item) }
        return copy
    }

    func setting(_ item: StudioRailItem, hidden: Bool) -> StudioRailHiddenItems {
        var copy = self
        if hidden { copy.items.insert(item) } else { copy.items.remove(item) }
        return copy
    }

    /// The rows still shown at the top of the rail, in rail order.
    var visibleTopItems: [StudioRailItem] {
        [.home, .newChat, .memory, .space, .browser, .library, .plugins].filter { !items.contains($0) }
    }

    /// The icon rail's rows, Codex's: Home, then Spaces, Memory, Library and
    /// Plugins, in that order, less any the learner hid. Plugins sit under the Library. New chat
    /// is Home's sidebar's row alone.
    static let railOrder: [StudioRailItem] = [.home, .space, .memory, .library, .plugins]

    /// The rows at the top of Home's sidebar: New chat and the Browser.
    static let sidebarOrder: [StudioRailItem] = [.newChat, .browser]

    func railItems() -> [StudioRailItem] {
        Self.railOrder.filter { !items.contains($0) }
    }

    func sidebarItems() -> [StudioRailItem] {
        Self.sidebarOrder.filter { !items.contains($0) }
    }
}
