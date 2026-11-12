import Foundation

// MARK: - A source, as the library has it

/// Where a source stands in the library, for the rows that show it by id:
/// a Goal's source list, and any row that names a source it does not own.
///
/// Three answers, because the library has three. A row that only asks the
/// active list would call an archived paper "no longer in the library": in
/// that list an archived source and a deleted one look the same. An archived
/// source keeps its `sources` row and its title; only its text is let go, and
/// unarchiving brings it back. Gone means no row at all.
enum LibrarySourcePresence: Equatable {
    /// Active, and loaded: the title the sidebar shows.
    case inLibrary(title: String)
    /// Archived: still a row, still titled, its text let go until unarchived.
    case archived(title: String)
    /// No `sources` row carries the id.
    case gone

    /// The title an active or archived source still has; nil when gone.
    var title: String? {
        switch self {
        case .inLibrary(let title), .archived(let title): return title
        case .gone: return nil
        }
    }

    /// What the row says: the title, or that the source has left the library.
    var label: String {
        title ?? Self.goneLabel
    }

    var isArchived: Bool {
        if case .archived = self { return true }
        return false
    }

    /// The label for a menu item, where a marker has no room of its own.
    var menuLabel: String {
        isArchived ? "\(label) (Archived)" : label
    }

    /// Whether the row can open the source. Opening an archived source
    /// restores it first, so only a gone source is inert.
    var canOpen: Bool {
        self != .gone
    }

    static let goneLabel = "Source no longer in the library"

    /// The answer for one id. `activeTitle` is what the loaded library says —
    /// `articlesById`, which holds active sources only — and `row` what
    /// storage says about the id whatever its status. The loaded title wins
    /// when both answer, because it is the one the sidebar shows; a row that
    /// storage knows as active but the library has not loaded (a source
    /// added a moment ago) reads as in the library rather than as gone.
    static func resolve(activeTitle: String?, row: SourceRowSummary?) -> LibrarySourcePresence {
        if let activeTitle { return .inLibrary(title: activeTitle) }
        guard let row else { return .gone }
        switch row.status {
        case .archived: return .archived(title: row.title)
        case .active: return .inLibrary(title: row.title)
        }
    }
}
