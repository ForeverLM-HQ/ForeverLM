#if os(macOS)
import Foundation
import Observation

/// What this Mac opened last in the Space: the pages, sites, canvases and pictures the
/// sidebar's **Recents** lists, newest first (docs/docs-design.md, "The
/// Space"). ChatGPT's Space keeps the same list so a learner gets back to what
/// they were just in without searching for it.
///
/// Device-local and never synced, like `NotebookRecency`: which page this Mac
/// had open is this Mac's arrangement, and opening a page must write nothing
/// that travels — the record's `updatedAt` is untouched (AGENTS.md, "Opening
/// is a read"). An id stays after its record is gone; the sidebar shows only
/// what the open library still holds, and the oldest entries go once
/// `capacity` is passed.
@Observable
@MainActor
final class SpaceRecents {
    static let shared = SpaceRecents()
    static let preferenceKey = "space.recents.v1"
    /// How many openings are remembered; the sidebar shows the first few that
    /// still exist.
    static let capacity = 40

    struct Item: Equatable, Hashable, Sendable {
        enum Kind: String, Sendable {
            /// A page, a linked Google Doc or a site: an `ArtifactRecord`.
            case artifact
            /// A picture in `GeneratedImageStore`, by its image id.
            case image
            /// A canvas (`KnowledgeMapCanvas`), by its id.
            case canvas
            /// A list of goals or ideas (`SpaceList`), by its id.
            case list
        }

        let kind: Kind
        let id: String
        var openedAt: Date
        /// A picture's title when it was opened. A record's title is read
        /// from the library each time; a picture's lives in its file, which
        /// the sidebar does not read for a row.
        var title: String? = nil
        /// When the picture's latest version was drawn, as it was opened, for
        /// the same reason: Screen record mode lets a picture on screen by it
        /// (`ScreenRecordScope.allowsImage`). Nil for a record, and for a
        /// picture noted before this was kept, which then shows only when kept
        /// on the mode's list.
        var createdAt: Date? = nil
    }

    private(set) var items: [Item]
    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        self.items = Self.load(from: defaults)
    }

    /// Notes an opening, the latest winning: the item moves to the top.
    func note(_ kind: Item.Kind, id: String, title: String? = nil, createdAt: Date? = nil, at date: Date = Date()) {
        guard !id.isEmpty else { return }
        if items.first?.kind == kind, items.first?.id == id, items.first?.title == title,
           items.first?.createdAt == createdAt { return }
        var next = items.filter { !($0.kind == kind && $0.id == id) }
        next.insert(Item(kind: kind, id: id, openedAt: date, title: title, createdAt: createdAt), at: 0)
        if next.count > Self.capacity { next.removeLast(next.count - Self.capacity) }
        items = next
        save()
    }

    /// Forgets one item: deleted for good, so it is never offered again.
    func forget(_ kind: Item.Kind, id: String) {
        let next = items.filter { !($0.kind == kind && $0.id == id) }
        guard next.count != items.count else { return }
        items = next
        save()
    }

    // MARK: Persistence

    /// The entries a `save()` left in `defaults`; none for nil (a test's), an
    /// absent key, or a value in a shape this build does not read.
    static func load(from defaults: UserDefaults?) -> [Item] {
        guard let raw = defaults?.array(forKey: preferenceKey) as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let kindRaw = entry["k"] as? String, let kind = Item.Kind(rawValue: kindRaw),
                  let id = entry["id"] as? String, !id.isEmpty,
                  let seconds = (entry["t"] as? NSNumber)?.doubleValue, seconds.isFinite else { return nil }
            let created = ((entry["c"] as? NSNumber)?.doubleValue).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
            return Item(
                kind: kind, id: id, openedAt: Date(timeIntervalSince1970: seconds), title: entry["n"] as? String,
                createdAt: created
            )
        }
    }

    private func save() {
        let raw: [[String: Any]] = items.map { item in
            var entry: [String: Any] = ["k": item.kind.rawValue, "id": item.id, "t": item.openedAt.timeIntervalSince1970]
            if let title = item.title { entry["n"] = title }
            if let createdAt = item.createdAt { entry["c"] = createdAt.timeIntervalSince1970 }
            return entry
        }
        defaults?.set(raw, forKey: Self.preferenceKey)
    }
}
#endif
