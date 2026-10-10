import Foundation

// MARK: - Canvases in the Space
//
// The product owner, 2026-10-07: "canvases should be within spaces; just like sites,
// pages, etc". The Canvas had been one plane for the whole library behind a
// rail row of its own; now the learner makes as many canvases as they like,
// each an item in the Space beside their pages and sites: listed in All and
// under Canvases, filed in a space, renamed, put in Trash and restored
// (docs/knowledge-map-design.md, "Canvases in the Space").
//
// A canvas is its layout row (`map.layout.<canvasID>`, `KnowledgeMapLayout`),
// which carries its name, when it was made and its Trash mark beside what is
// placed on it, all merged entry by entry. So every row there is lists one
// canvas, the first canvas's row included, and nothing about a canvas is on
// a record or in a zone: like the layout, it is the learner's own, per
// member, and a team's library lists none.

/// One canvas as the Space lists it.
struct KnowledgeMapCanvas: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    /// The learner's name for it, or `KnowledgeMap.unnamedCanvasName` for a
    /// canvas never named.
    let name: String
    let createdAt: Date
    /// When anything on it was last written: the list's Last activity.
    let updatedAt: Date
    /// When it went to Trash; nil while it is in use.
    let trashedAt: Date?
    /// The notebook it belongs to, listed and opened from; nil for a canvas
    /// of no notebook.
    let notebookID: String?
    /// How many cards are placed on it and how many regions it holds: what
    /// its shortcut card on another canvas says (`canvas:<id>`).
    let cardCount: Int
    let regionCount: Int

    var isTrashed: Bool { trashedAt != nil }

    init(
        id: String, name: String, createdAt: Date, updatedAt: Date, trashedAt: Date? = nil, notebookID: String? = nil,
        cardCount: Int = 0, regionCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.trashedAt = trashedAt
        self.notebookID = notebookID
        self.cardCount = cardCount
        self.regionCount = regionCount
    }

    /// The canvas a layout row describes.
    init(id: String, layout: KnowledgeMapLayout) {
        let name = layout.name?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let created = layout.created ?? layout.firstWrittenAt ?? 0
        self.init(
            id: id,
            name: name.isEmpty ? KnowledgeMap.unnamedCanvasName : name,
            createdAt: Date(timeIntervalSince1970: created),
            updatedAt: Date(timeIntervalSince1970: layout.lastWrittenAt ?? created),
            trashedAt: layout.trash?.since.map { Date(timeIntervalSince1970: $0) },
            notebookID: layout.notebook?.id,
            cardCount: layout.placements.count,
            regionCount: layout.regions.count
        )
    }
}

/// Every canvas the rows hold, by id. Foundation-only, so the macOS unit
/// tests read it as the Mac does.
struct KnowledgeMapCanvases: Equatable, Sendable {
    private(set) var byID: [String: KnowledgeMapCanvas]

    init(_ canvases: [KnowledgeMapCanvas] = []) {
        byID = Dictionary(canvases.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The canvases in a set of preference rows: every `map.layout.` row
    /// that reads as a layout (`UserDefaults.dictionaryRepresentation()` on
    /// the Mac); the rest are ignored.
    init(rows: [String: Any]) {
        var canvases: [KnowledgeMapCanvas] = []
        for (key, value) in rows {
            guard let id = KnowledgeMap.mapID(fromLayoutKey: key),
                  let layout = KnowledgeMapLayout(preferenceValue: value) else { continue }
            canvases.append(KnowledgeMapCanvas(id: id, layout: layout))
        }
        self.init(canvases)
    }

    func canvas(_ id: String) -> KnowledgeMapCanvas? { byID[id] }

    /// Whether `id` names a canvas that is listed and not in Trash.
    func isInUse(_ id: String) -> Bool { byID[id].map { !$0.isTrashed } ?? false }

    /// Every canvas, newest first, then by id, so two never trade places.
    var all: [KnowledgeMapCanvas] {
        byID.values.sorted { lhs, rhs in
            lhs.createdAt != rhs.createdAt ? lhs.createdAt > rhs.createdAt : lhs.id < rhs.id
        }
    }

    /// The canvases not in Trash, newest first.
    var inUse: [KnowledgeMapCanvas] { all.filter { !$0.isTrashed } }

    /// The canvases of one notebook, not in Trash, newest first.
    func inUse(inNotebook notebookID: String) -> [KnowledgeMapCanvas] {
        inUse.filter { $0.notebookID == notebookID }
    }

    var isEmpty: Bool { byID.isEmpty }

    /// This catalogue after a canvas's row is written (nil: removed).
    func setting(_ layout: KnowledgeMapLayout?, for id: String) -> KnowledgeMapCanvases {
        var copy = self
        copy.byID[id] = layout.map { KnowledgeMapCanvas(id: id, layout: $0) }
        return copy
    }

    /// The canvas to open when nothing names one: the one last active, not
    /// in Trash; nil when there is none.
    var mostRecentlyActive: KnowledgeMapCanvas? {
        inUse.max { lhs, rhs in
            lhs.updatedAt != rhs.updatedAt ? lhs.updatedAt < rhs.updatedAt : lhs.id > rhs.id
        }
    }

    /// A name as it is kept, as a space's is (`PageSpaces.cleanedName`):
    /// whitespace folded, trimmed, cut at 80 characters; nil when nothing is
    /// left.
    static func cleanedName(_ raw: String) -> String? {
        PageSpaces.cleanedName(raw)
    }
}

/// Which canvas this Mac had open, so a relaunch reopens it. This Mac's own
/// choice and never synced, like the window's place in the Space: which
/// canvas is open is an arrangement, not a fact about the canvas.
enum KnowledgeMapOpenCanvas {
    static let preferenceKey = "knowledgeMap.openCanvasID"

    /// The defaults the layout rows are read from: a test's own while it
    /// binds them (`KnowledgeMapRows.overrideDefaults`).
    private static var defaults: UserDefaults { KnowledgeMapRows.overrideDefaults?.defaults ?? .standard }

    static var storedID: String? {
        defaults.string(forKey: preferenceKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func remember(_ canvasID: String) {
        guard storedID != canvasID else { return }
        defaults.set(canvasID, forKey: preferenceKey)
    }

    /// The canvas a launch opens: the one this Mac had open while it is
    /// still in use, else the one last active, else the first canvas, whose
    /// row the first write makes.
    static func initialID(stored: String?, canvases: KnowledgeMapCanvases) -> String {
        if let stored, canvases.isInUse(stored) { return stored }
        return canvases.mostRecentlyActive?.id ?? KnowledgeMap.firstCanvasID
    }
}
