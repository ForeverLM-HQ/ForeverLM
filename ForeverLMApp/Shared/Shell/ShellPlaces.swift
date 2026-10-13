import Foundation

// MARK: - The shell and its modules

/// ForeverLM is built as Codex's shell with knowledge modules on top
/// (product owner, 2026-10-13: "is there a way to explicitly refactor the
/// codebase such that it's basically 'built off of codex' with extra features
/// on top?"; docs/codex-shell-plan.md). The shell is what the Codex desktop
/// app has — chats as threads, the Space, Plugins, Settings, and its clock —
/// and every module is something ForeverLM adds to it. A module contributes
/// places (`ShellPlace`) to the shell through `ShellPlaces`.
///
/// View-free and Foundation-only, so the iPhone and the web can mirror the
/// same table later.
enum ShellModule: String, CaseIterable, Sendable {
    // The shell: Codex's own parts.

    /// Chats, Codex's threads: the docked chat and the second one beside it.
    case chat
    /// ChatGPT's Space: every page, site, list, canvas, notebook and course in
    /// one list with its own sidebar, and the Pages, Sites, Goals and Ideas it
    /// opens.
    case space
    /// The plugins that read the learner's other apps and the ingest plugins
    /// they built.
    case plugins
    /// The Settings window. No pane: an overlay over the window.
    case settings
    /// Codex's clock: instructions the app runs by itself. Its pane has no way
    /// in (product owner, 2026-10-13: "scheduled is not so important btw; skip
    /// that for now").
    case scheduled

    // The modules ForeverLM adds.

    /// A notebook's three columns, which take the window over
    /// (`NotebookWorkspace`) rather than opening a pane.
    case notebooks
    /// The whole library laid out for managing it.
    case library
    /// A source read, in the Reader.
    case reader
    /// Cards, To Check and the card review.
    case memory
    /// The Canvas and the Atlas.
    case canvas
    /// Courses, their lectures and quizzes.
    case courses
    /// The learner's day.
    case day
    /// The web, in tabs with profiles.
    case browser
    /// The explainer films and animations ForeverLM made.
    case media

    /// Whether this is one of Codex's own parts rather than one ForeverLM adds.
    var isShell: Bool {
        switch self {
        case .chat, .space, .plugins, .settings, .scheduled: return true
        case .notebooks, .library, .reader, .memory, .canvas, .courses, .day, .browser, .media: return false
        }
    }
}

/// The sidebar a place shows beside it, inside the window's card.
enum ShellSidebar: String, Sendable {
    /// Home's sidebar: New chat, the notebooks and the chats, as Codex's Home
    /// draws its projects.
    case home
    /// The Space's own sidebar: its places, Pinned, Recents, Spaces, Trash.
    case space
}

/// What a place is to the learner.
enum ShellPlaceRole: String, Sendable {
    /// A conversation.
    case thread
    /// A list of the learner's things, which opens one of them.
    case list
    /// One thing on screen: a source, a page, a day, a canvas, the web.
    case viewer
}

/// One place a window can show, as its module declares it: what the window
/// calls it, its glyph, which module owns it, which sidebar shows beside it,
/// and what it is. The raw value of its tab is what stored and synced layouts
/// name (`artifacts` for the Space, `notepad` for Pages, `knowledgeMap` for
/// the Canvas) and never changes.
struct ShellPlace: Equatable, Sendable {
    let tab: StudioCenterTab
    let title: String
    /// An SF Symbol.
    let glyph: String
    let module: ShellModule
    /// Nil for a place that has the window's card to itself: no Home sidebar
    /// and no Space sidebar beside it (the Library, Memory, the Canvas, the
    /// Atlas).
    let sidebar: ShellSidebar?
    let role: ShellPlaceRole
}

/// The place registry: one descriptor for every `StudioCenterTab`. The shell
/// reads it instead of listing places by hand, so adding, moving or renaming
/// a place is one entry here; the switch below is the one place that names
/// them all, and a tab without an entry does not compile.
enum ShellPlaces {
    static func descriptor(for tab: StudioCenterTab) -> ShellPlace {
        switch tab {
        case .chat:
            return ShellPlace(tab: tab, title: "Chat", glyph: "bubble.left.and.bubble.right", module: .chat, sidebar: .home, role: .thread)
        case .secondaryChat:
            return ShellPlace(tab: tab, title: "Chat", glyph: "bubble.left.and.bubble.right", module: .chat, sidebar: .home, role: .thread)
        case .reader:
            return ShellPlace(tab: tab, title: "Reader", glyph: "doc.text", module: .reader, sidebar: .home, role: .viewer)
        case .tasks:
            return ShellPlace(tab: tab, title: "Tasks", glyph: "clock.arrow.circlepath", module: .scheduled, sidebar: .home, role: .list)
        case .activity:
            return ShellPlace(tab: tab, title: "Day", glyph: "chart.bar.doc.horizontal", module: .day, sidebar: .home, role: .viewer)
        case .goals:
            return ShellPlace(tab: tab, title: "Goals", glyph: "target", module: .space, sidebar: .home, role: .list)
        case .courses:
            return ShellPlace(tab: tab, title: "Courses", glyph: "graduationcap", module: .courses, sidebar: .space, role: .list)
        case .ideas:
            return ShellPlace(tab: tab, title: "Ideas", glyph: "lightbulb", module: .space, sidebar: .home, role: .list)
        case .notepad:
            return ShellPlace(tab: tab, title: "Pages", glyph: "note.text", module: .space, sidebar: .space, role: .viewer)
        case .sites:
            return ShellPlace(tab: tab, title: "Sites", glyph: "globe", module: .space, sidebar: .space, role: .viewer)
        case .browser:
            return ShellPlace(tab: tab, title: "Browser", glyph: "safari", module: .browser, sidebar: .home, role: .viewer)
        case .videos:
            return ShellPlace(tab: tab, title: "Videos", glyph: "film", module: .media, sidebar: .home, role: .list)
        case .animations:
            return ShellPlace(tab: tab, title: "Animations", glyph: "sparkles.tv", module: .media, sidebar: .home, role: .viewer)
        case .artifacts:
            // The strip's Spaces row's glyph since Plugins took Codex's grid.
            return ShellPlace(tab: tab, title: "Space", glyph: "square.on.square", module: .space, sidebar: .space, role: .list)
        case .memory:
            return ShellPlace(tab: tab, title: "Memory", glyph: "brain", module: .memory, sidebar: nil, role: .list)
        case .library:
            return ShellPlace(tab: tab, title: "Library", glyph: "books.vertical", module: .library, sidebar: nil, role: .list)
        case .knowledgeMap:
            return ShellPlace(tab: tab, title: "Canvas", glyph: "rectangle.3.group", module: .canvas, sidebar: nil, role: .viewer)
        case .atlas:
            return ShellPlace(tab: tab, title: "Atlas", glyph: "point.3.connected.trianglepath.dotted", module: .canvas, sidebar: nil, role: .viewer)
        case .plugins:
            return ShellPlace(tab: tab, title: "Plugins", glyph: "square.grid.2x2", module: .plugins, sidebar: nil, role: .list)
        }
    }

    /// Every place, in `StudioCenterTab`'s order.
    static var all: [ShellPlace] {
        StudioCenterTab.allCases.map(descriptor(for:))
    }

    /// The places a module owns.
    static func tabs(of module: ShellModule) -> Set<StudioCenterTab> {
        Set(all.filter { $0.module == module }.map(\.tab))
    }
}
