// The strip footer items, the strip entries, the strip order and the shortcut item provider.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// An icon on the strip below the ⋯: voice, the work running for an AI app,
/// AI Usage, the day, the bell, MCP, Settings and the account. Each is one
/// the learner can drag up or down among the others (`StudioStripOrder`).
enum StudioStripFooterItem: String, CaseIterable, Identifiable, Sendable {
    case voice
    case work
    case aiUsage
    case day
    case notifications
    case mcp
    case settings
    case account

    var id: String { rawValue }

    /// Its name in Show in Sidebar and its Hide item.
    var title: String {
        switch self {
        case .voice: return "Voice"
        case .work: return "AI App Work"
        case .aiUsage: return "AI Usage"
        case .day: return "Day"
        case .notifications: return "Notifications"
        case .mcp: return "MCP"
        case .settings: return "Settings"
        case .account: return "Account"
        }
    }

    /// Its glyph in Show in Sidebar: the strip's own where it draws a
    /// symbol, a near one where it draws a logo or the avatar.
    var systemImage: String {
        switch self {
        case .voice: return "waveform"
        case .work: return "sparkles"
        case .aiUsage: return "chart.bar"
        case .day: return "calendar"
        case .notifications: return "bell"
        case .mcp: return "point.3.connected.trianglepath.dotted"
        case .settings: return "gearshape"
        case .account: return "person.crop.circle"
        }
    }
}

/// Which of the strip's bottom icons the learner has hidden (product owner,
/// 2026-11-08: "i also need the ability to hide these if i want to"). Follows
/// the account, like the hidden rows (`StudioRailHiddenItems`). Every icon is
/// shown until the learner hides it; a hidden one comes back from Show in
/// Sidebar, on the ⋯ and on every remaining icon's menu; the ⋯ is always
/// drawn, so the way back never leaves with the icons. Settings stays ⌘,
/// away with its icon hidden.
struct StudioStripFooterHiddenItems: Equatable {

    var items: Set<StudioStripFooterItem>

    init(_ items: Set<StudioStripFooterItem> = []) {
        self.items = items
    }

    /// Decodes the comma-separated raw values, dropping a name this build
    /// does not know.
    init(storage: String) {
        items = Set(
            storage.split(separator: ",")
                .compactMap { StudioStripFooterItem(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
        )
    }

    /// Sorted so equal sets encode identically.
    var storage: String {
        items.map(\.rawValue).sorted().joined(separator: ",")
    }

    func contains(_ item: StudioStripFooterItem) -> Bool { items.contains(item) }

    func setting(_ item: StudioStripFooterItem, hidden: Bool) -> StudioStripFooterHiddenItems {
        var copy = self
        if hidden { copy.items.insert(item) } else { copy.items.remove(item) }
        return copy
    }
}

/// One icon of the strip the learner can drag to another place in its own
/// group (product owner, 2026-11-08: "for all these icons at the bottom left
/// and also top left; allow me to drag to reorder them"). The top group is
/// the strip's own rows and the places kept there, mixed as the learner
/// arranges them; the bottom group is the footer's icons. An icon never
/// crosses from one group to the other: the ⋯ and the free space stand
/// between them.
enum StudioStripEntry: Hashable, Identifiable, Sendable {
    case row(StudioRailItem)
    case shortcut(StudioRailShortcut)
    case footer(StudioStripFooterItem)

    var id: String { key }

    /// How the order stores it: the row's, the place's or the footer
    /// icon's own name. The three sets of names never meet, which the
    /// tests hold, so no prefix is needed.
    var key: String {
        switch self {
        case .row(let item): return item.rawValue
        case .shortcut(let shortcut): return shortcut.key
        case .footer(let item): return item.rawValue
        }
    }

    init?(key: String) {
        if let item = StudioStripFooterItem(rawValue: key) {
            self = .footer(item)
        } else if let item = StudioRailItem(rawValue: key) {
            self = .row(item)
        } else if let shortcut = StudioRailShortcut(key: key) {
            self = .shortcut(shortcut)
        } else {
            return nil
        }
    }

    var isFooter: Bool {
        if case .footer = self { return true }
        return false
    }
}

/// The order the learner dragged one group of strip icons into. Follows
/// the account, like the hidden rows and the shortcuts: the strip is the
/// learner's arrangement, not one Mac's. Empty until the learner drags,
/// and then only a list of names: what the strip shows still comes from
/// the hidden rows, the kept shortcuts and the footer's own conditions, and
/// this only says where each shown icon stands.
struct StudioStripOrder: Equatable {

    /// The names in order. A name not shown now (a hidden row, a shortcut
    /// taken off, MCP's icon while its light is off) keeps its place, so it
    /// comes back where the learner left it.
    var keys: [String]

    init(_ keys: [String] = []) {
        var seen = Set<String>()
        self.keys = keys.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    init(storage: String) {
        self.init(storage.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
    }

    var storage: String { keys.joined(separator: ",") }

    /// The shown names, given in the strip's own order, in the learner's.
    /// One the learner never placed (a new shortcut, a row a later build
    /// added) stands after the one it follows in the strip's own order.
    func arranged(_ shown: [String]) -> [String] {
        let shownSet = Set(shown)
        return merged(with: shown).filter(shownSet.contains)
    }

    /// The shown entries in the learner's order.
    func arranged(_ shown: [StudioStripEntry]) -> [StudioStripEntry] {
        let byKey = Dictionary(shown.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return arranged(shown.map(\.key)).compactMap { byKey[$0] }
    }

    /// `key` takes `target`'s place, as a drag that reaches it moves it:
    /// below it when coming from above, above it when coming from below.
    func moving(_ key: String, to target: String, shown: [String]) -> StudioStripOrder {
        var names = merged(with: shown)
        guard key != target,
              let from = names.firstIndex(of: key),
              let to = names.firstIndex(of: target) else { return self }
        names.remove(at: from)
        names.insert(key, at: to)
        return StudioStripOrder(names)
    }

    /// `key` just above `target`, or last when there is no target: where a
    /// place dragged in from the Space sidebar lands.
    func placing(_ key: String, before target: String?, shown: [String]) -> StudioStripOrder {
        var names = merged(with: shown).filter { $0 != key }
        if let target, target != key, let index = names.firstIndex(of: target) {
            names.insert(key, at: index)
        } else {
            names.append(key)
        }
        return StudioStripOrder(names)
    }

    /// Every stored name, with each shown one the learner never placed put
    /// right after the shown one before it in the strip's own order, or
    /// first when it leads.
    private func merged(with shown: [String]) -> [String] {
        var names = keys
        for (index, key) in shown.enumerated() where !names.contains(key) {
            if index > 0, let previous = names.firstIndex(of: shown[index - 1]) {
                names.insert(key, at: previous + 1)
            } else {
                names.insert(key, at: 0)
            }
        }
        return names
    }
}

extension NSItemProvider {
    /// Marks a drag as one of the strip's icons, which the strip moves where
    /// the drag goes. Read in this process only.
    func carryingStripEntry(_ entry: StudioStripEntry) -> NSItemProvider {
        let data = Data(entry.key.utf8)
        registerDataRepresentation(
            forTypeIdentifier: UTType.studioStripEntry.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return self
    }
}
