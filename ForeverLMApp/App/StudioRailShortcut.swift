// The icon strip shortcuts.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A place the learner keeps on the icon strip, after the strip's own rows
/// and before the ⋯, as Codex keeps the rows pinned to its strip (product
/// owner, 2026-10-12: "the left sidebar never gets collapsed basically so
/// there can be some shortcuts there similar to codex app"). The ⋯ offers
/// every other place and keeps one here; a shortcut is one of those places,
/// one click away from anywhere.
enum StudioRailShortcut: Hashable, Identifiable, Sendable {
    /// One of the Space sidebar's places: Notebooks, Board, Pages, Sites, Canvases,
    /// Images or Google Drive.
    case place(SpaceDestination)
    /// The Courses list, the Space sidebar's hub.
    case courses
    /// Not a place but a start: the Feynman Technique on what the learner
    /// read recently, a new chat (product owner, 2026-11-24: "a one-button
    /// accessible thingy that I can pin maybe in the top left. It should just
    /// be a chat"). Offered last in the ⋯ and kept on the strip like a place.
    case feynmanTechnique

    var id: String { key }

    static let feynmanTechniqueKey = "feynmanTechnique"

    /// The Space places a shortcut can be. All is the Space itself (its
    /// row), Trash is a place to visit rarely, and a team's, a space's or a
    /// list's place is an item the Space sidebar pins.
    private static let places: Set<SpaceDestination> = [.notebooks, .board, .plan, .pages, .sites, .animations, .canvases, .images, .drive]

    /// Every shortcut this Mac offers, in the Space sidebar's order:
    /// Notebooks, Courses, then the rest; Canvases only where canvases are
    /// listed.
    static func offered(listsCanvases: Bool) -> [StudioRailShortcut] {
        let sidebar = SpaceDestination.sidebarPlaces(listsCanvases: listsCanvases).filter(places.contains)
        let leading = sidebar.filter { $0 == .notebooks }
        let rest = sidebar.filter { $0 != .notebooks }
        return leading.map(Self.place) + [.courses] + rest.map(Self.place) + [.feynmanTechnique]
    }

    /// How the strip stores it: the place's `SpaceDestination.key`, or
    /// `courses`.
    var key: String {
        switch self {
        case .place(let place): return place.key
        case .courses: return "courses"
        case .feynmanTechnique: return Self.feynmanTechniqueKey
        }
    }

    /// Nil for a key that names no shortcut — one a later build added, or a
    /// place that is no shortcut — so the strip drops it rather than drawing
    /// a phantom.
    init?(key: String) {
        if key == "courses" {
            self = .courses
            return
        }
        if key == Self.feynmanTechniqueKey {
            self = .feynmanTechnique
            return
        }
        let place = SpaceDestination(key: key)
        guard place.key == key, Self.places.contains(place) else { return nil }
        self = .place(place)
    }

    /// The Space sidebar's hub as a shortcut: every hub is one.
    init(hub: SpaceHub) {
        switch hub {
        case .courses: self = .courses
        }
    }

    var title: String {
        switch self {
        case .place(let place): return place.title
        case .courses: return SpaceHub.courses.title
        case .feynmanTechnique: return TeachBack.title
        }
    }

    var systemImage: String {
        switch self {
        case .place(let place): return place.symbolName
        case .courses: return SpaceHub.courses.symbolName
        // The notebook guide's chip draws the same.
        case .feynmanTechnique: return "person.bubble"
        }
    }

    /// The picture the strip draws instead of `systemImage`, where the Space
    /// sidebar's row draws one: Google Drive's own logo.
    var assetImage: String? {
        self == .place(.drive) ? "GoogleDriveIcon" : nil
    }

    /// The pane the place also opens in, dragged to an edge of the center:
    /// Pages, Sites and Courses. Nil for a place that opens only in the Space.
    var centerTab: StudioCenterTab? {
        switch self {
        case .place(let place): return place.openableKind?.centerTab
        case .courses: return SpaceHub.courses.tab.centerTab
        case .feynmanTechnique: return nil
        }
    }

    /// What a Space sidebar row or a kept shortcut drags: the place, which
    /// the strip keeps where it is dropped (product owner, 2026-10-13: "let me
    /// drag these things to the left side bar to pin them; e.g. pages"), and
    /// the place's pane where it has one, which an edge of the center opens
    /// beside, as the row's drag always did. Each destination reads only the
    /// type it registered for.
    func dragProvider() -> NSItemProvider {
        let provider = centerTab.map { studioCenterTabDragProvider(for: $0) } ?? NSItemProvider()
        let data = Data(key.utf8)
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.studioRailShortcut.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        provider.suggestedName = title
        return provider
    }

    /// Starts the drag: the strip draws the place where it would land, and
    /// the content drop zones stay hidden, as for a pane.
    /// `onStrip`: the drag began on the strip's own icon, which the strip
    /// moves as the drag goes, rather than on the Space sidebar's row.
    func beginDrag(onStrip: Bool = false) {
        StudioDragVisibility.shared.begin(
            centerTab: centerTab,
            railShortcut: self,
            stripEntry: onStrip ? .shortcut(self) : nil
        )
    }

    /// The place a strip drop carries, read off the first provider with one.
    /// False when none carries a place.
    @discardableResult
    static func loadDropped(
        from providers: [NSItemProvider],
        _ receive: @escaping @MainActor (StudioRailShortcut) -> Void
    ) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.studioRailShortcut.identifier)
        }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.studioRailShortcut.identifier) { data, _ in
            guard let data, let shortcut = StudioRailShortcut(key: String(decoding: data, as: UTF8.self)) else { return }
            Task { @MainActor in receive(shortcut) }
        }
        return true
    }
}

/// The shortcuts on the icon strip, in the order the learner kept them.
/// Follows the account, like the hidden rows (`StudioRailHiddenItems`): the
/// strip is the learner's arrangement, not one Mac's. None until the learner
/// keeps one from the ⋯.
struct StudioRailShortcuts: Equatable {

    var items: [StudioRailShortcut]

    init(_ items: [StudioRailShortcut] = []) {
        var seen = Set<StudioRailShortcut>()
        self.items = items.filter { seen.insert($0).inserted }
    }

    /// Decodes the comma-separated keys the preference holds, dropping a key
    /// this build does not know and any repeat.
    init(storage: String) {
        self.init(
            storage.split(separator: ",")
                .compactMap { StudioRailShortcut(key: String($0).trimmingCharacters(in: .whitespaces)) }
        )
    }

    var storage: String {
        items.map(\.key).joined(separator: ",")
    }

    func contains(_ shortcut: StudioRailShortcut) -> Bool { items.contains(shortcut) }

    /// Kept at the end of the strip, or taken off it.
    func setting(_ shortcut: StudioRailShortcut, shown: Bool) -> StudioRailShortcuts {
        var kept = items.filter { $0 != shortcut }
        if shown { kept.append(shortcut) }
        return StudioRailShortcuts(kept)
    }

    /// The shortcuts the strip draws: the kept ones this Mac offers, so a
    /// kept Canvases waits, unshown, where canvases are not listed.
    func shown(listsCanvases: Bool) -> [StudioRailShortcut] {
        let offered = Set(StudioRailShortcut.offered(listsCanvases: listsCanvases))
        return items.filter(offered.contains)
    }
}
