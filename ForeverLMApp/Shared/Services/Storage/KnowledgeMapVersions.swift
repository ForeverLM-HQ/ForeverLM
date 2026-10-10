import Foundation
import OSLog

// A canvas's earlier layouts, kept on this Mac only: Heptabase's version
// history of a whiteboard, with its manual "save version" (docs/heptabase-
// canvas-parity.md, "Cards: editing and sizing"; docs/knowledge-map-design.md,
// "Versions, export and publishing"). It is the Pages pattern
// (`PageVersionHistory`) for a canvas.
//
// Each version is a snapshot of the canvas's layout row, in a file of its own
// under the library's `.appdata/CanvasHistory/<canvas id>/`, beside knowledge.db
// and `PageHistory`: outside everything the sync engine or iCloud carries, so
// another Mac keeps its own. The file's name is the version's identity: when it
// was kept, in milliseconds since 1970, and whether the learner named it or the
// app kept it on its own (`1791345600123-manual.json`), so a listing needs no
// index to keep in step. Inside, the row's JSON as the preference store holds it
// (`layout`, text, so a snapshot keeps what a later build adds to the row) with
// the version's `name` and `at`, and its counts for the list.
//
// Foundation only, so the policy and the store run in a test without the app.

/// One kept layout of a canvas.
struct KnowledgeMapVersion: Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Kept by the app after a burst of edits, or before a restore.
        case auto
        /// Kept by the learner, with a name of their own.
        case manual
    }

    /// The file's name, which is the version's identity.
    let id: String
    /// What the list calls it: the learner's name, or the date for one kept
    /// automatically.
    let name: String
    let at: Date
    let kind: Kind
    /// What the snapshot holds, for the list: cards placed, regions, arrows.
    let cards: Int
    let regions: Int
    let arrows: Int

    /// "12 cards · 2 regions · 3 arrows", as the list says it.
    var summary: String {
        func part(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
        return [part(cards, "card"), part(regions, "region"), part(arrows, "arrow")].joined(separator: " · ")
    }
}

/// When a version is kept and which go: pure, so the tests read it.
enum KnowledgeMapVersionPolicy {
    /// A canvas keeps at most this many versions, the oldest automatic ones
    /// going first.
    static let maximumVersions = 30
    /// A version is kept on its own once the newest automatic one is this old.
    static let automaticInterval: TimeInterval = 10 * 60
    /// A burst of edits has settled once the canvas has been left this long.
    static let settleDelay: TimeInterval = 20

    /// Whether the app keeps a version on its own: the newest automatic one
    /// is ten minutes old (or there is none) and something on the canvas
    /// changed since the newest version of any kind.
    static func automaticVersionIsDue(newestAutomaticAt: Date?, changedEntries: Int, now: Date) -> Bool {
        guard changedEntries >= 1 else { return false }
        guard let newestAutomaticAt else { return true }
        return now.timeIntervalSince(newestAutomaticAt) >= automaticInterval
    }

    /// How many cards, regions and arrows differ between two layouts: an entry
    /// added, removed or changed counts one. The time an entry was written is
    /// not a change, so a card put back where it was counts none.
    static func changedEntries(from old: KnowledgeMapLayout?, to new: KnowledgeMapLayout) -> Int {
        let old = old ?? KnowledgeMapLayout()
        func differing<Entry: Equatable>(_ a: [String: Entry], _ b: [String: Entry], stripped: (Entry) -> Entry) -> Int {
            Set(a.keys).union(b.keys).filter { key in
                switch (a[key], b[key]) {
                case (nil, nil): return false
                case (let lhs?, let rhs?): return stripped(lhs) != stripped(rhs)
                default: return true
                }
            }.count
        }
        return differing(old.placements, new.placements) { var copy = $0; copy.at = 0; return copy }
            + differing(old.regions, new.regions) { var copy = $0; copy.at = 0; return copy }
            + differing(old.edges, new.edges) { var copy = $0; copy.at = 0; return copy }
    }

    /// The versions a canvas no longer keeps, past `maximum`: the oldest
    /// automatic ones first, then, only when every one left is the learner's
    /// own, the oldest of those.
    static func versionsToDrop(_ versions: [KnowledgeMapVersion], maximum: Int = maximumVersions) -> [KnowledgeMapVersion] {
        let excess = versions.count - maximum
        guard excess > 0 else { return [] }
        func oldestFirst(_ list: [KnowledgeMapVersion]) -> [KnowledgeMapVersion] {
            list.sorted { lhs, rhs in lhs.at != rhs.at ? lhs.at < rhs.at : lhs.id < rhs.id }
        }
        let automatic = oldestFirst(versions.filter { $0.kind == .auto })
        let manual = oldestFirst(versions.filter { $0.kind == .manual })
        return Array((automatic + manual).prefix(excess))
    }

    static func sortedNewestFirst(_ versions: [KnowledgeMapVersion]) -> [KnowledgeMapVersion] {
        versions.sorted { lhs, rhs in lhs.at != rhs.at ? lhs.at > rhs.at : lhs.id > rhs.id }
    }

    // MARK: Names

    static func fileName(at date: Date, kind: KnowledgeMapVersion.Kind) -> String {
        "\(Int64((date.timeIntervalSince1970 * 1_000).rounded()))-\(kind.rawValue).json"
    }

    /// When and how a file's name says it was kept; nil for anything else in
    /// the folder.
    static func parse(fileName: String) -> (at: Date, kind: KnowledgeMapVersion.Kind)? {
        guard fileName.hasSuffix(".json") else { return nil }
        let stem = fileName.dropLast(".json".count)
        guard let dash = stem.firstIndex(of: "-"),
              let milliseconds = Int64(stem[..<dash]),
              let kind = KnowledgeMapVersion.Kind(rawValue: String(stem[stem.index(after: dash)...])) else { return nil }
        return (Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000), kind)
    }

    /// What a version kept on its own is called: the day and time, as
    /// "9 Oct 2026, 21:41". Fixed in form, so a name kept on one Mac reads
    /// alike on another.
    static func automaticName(at date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter.string(from: date)
    }

    /// A version's name as the learner typed it: whitespace folded, trimmed,
    /// cut at 80 characters; the date when nothing is left.
    static func manualName(_ raw: String, at date: Date) -> String {
        let folded = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let cut = String(folded.prefix(80)).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? automaticName(at: date) : cut
    }
}

/// Writing a version's layout back over the canvas's, as one edit: pure, so
/// the tests read it.
enum KnowledgeMapVersionRestore {
    /// Makes `layout`'s cards, regions and arrows the snapshot's, written at
    /// `at` so every Mac takes them: an entry the snapshot holds is written
    /// (one already the same is left, so a restore of what is there sends
    /// nothing), an entry it lacks is removed with a tombstone, so another
    /// Mac that still holds it follows rather than bringing it back. What the
    /// canvas is stays the current row's: its name, its Trash mark, its
    /// notebook, its date and its published page.
    ///
    /// Cards go first, then regions, then arrows, so an arrow coming back has
    /// both ends; taking a card off takes its arrows with it, and the
    /// snapshot's own arrows are written after.
    static func apply(_ snapshot: KnowledgeMapLayout, to layout: inout KnowledgeMapLayout, at: Double) {
        for ref in layout.placements.keys.sorted() where snapshot.placements[ref] == nil {
            layout.unplace(ref, at: at)
        }
        for (ref, placement) in snapshot.placements.sorted(by: { $0.key < $1.key }) {
            guard !sameIgnoringTime(layout.placements[ref], placement, strip: { var c = $0; c.at = 0; return c }) else { continue }
            var written = placement
            written.at = at
            layout.placements[ref] = written
            layout.removed.removeValue(forKey: "p:" + ref)
        }
        for id in layout.regions.keys.sorted() where snapshot.regions[id] == nil {
            layout.removeRegion(id, at: at)
        }
        for (id, region) in snapshot.regions.sorted(by: { $0.key < $1.key }) {
            guard !sameIgnoringTime(layout.regions[id], region, strip: { var c = $0; c.at = 0; return c }) else { continue }
            var written = region
            written.at = at
            layout.setRegion(id, written)
        }
        for id in layout.edges.keys.sorted() where snapshot.edges[id] == nil {
            layout.removeEdge(id, at: at)
        }
        for (id, edge) in snapshot.edges.sorted(by: { $0.key < $1.key }) {
            guard !sameIgnoringTime(layout.edges[id], edge, strip: { var c = $0; c.at = 0; return c }) else { continue }
            var written = edge
            written.at = at
            layout.setEdge(id, written)
        }
    }

    private static func sameIgnoringTime<Entry: Equatable>(_ current: Entry?, _ snapshot: Entry, strip: (Entry) -> Entry) -> Bool {
        guard let current else { return false }
        return strip(current) == strip(snapshot)
    }
}

/// The folder of every canvas's versions on this Mac, and what it keeps. Every
/// call that a write passes through logs and swallows its own failure where it
/// can: a version is a convenience, and a canvas's edit never waits on it.
struct KnowledgeMapVersionHistory: Sendable {
    static let folderName = "CanvasHistory"

    let rootDirectory: URL

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
        category: "KnowledgeMapVersions"
    )

    /// What a version file holds.
    private struct Stored: Codable {
        var format: Int
        var name: String
        var at: Double
        var kind: KnowledgeMapVersion.Kind
        var cards: Int
        var regions: Int
        var arrows: Int
        /// The layout row's JSON, as the preference store holds it.
        var layout: String
    }

    private static let currentFormat = 1

    /// The canvas's folder; nil for an id that could name a path elsewhere.
    func directory(for canvasID: String) -> URL? {
        guard !canvasID.isEmpty,
              !canvasID.contains("/"),
              !canvasID.contains(".."),
              !canvasID.hasPrefix(".") else { return nil }
        return rootDirectory.appendingPathComponent(canvasID, isDirectory: true)
    }

    // MARK: Reading

    /// The canvas's versions, newest first. A file that cannot be read is
    /// left out, not an error.
    func versions(of canvasID: String) -> [KnowledgeMapVersion] {
        guard let directory = directory(for: canvasID),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let versions = names.compactMap { name -> KnowledgeMapVersion? in
            guard let parsed = KnowledgeMapVersionPolicy.parse(fileName: name),
                  let stored = Self.read(directory.appendingPathComponent(name)) else { return nil }
            return KnowledgeMapVersion(
                id: name,
                name: stored.name,
                at: parsed.at,
                kind: parsed.kind,
                cards: stored.cards,
                regions: stored.regions,
                arrows: stored.arrows
            )
        }
        return KnowledgeMapVersionPolicy.sortedNewestFirst(versions)
    }

    /// The layout a version kept.
    func layout(of version: KnowledgeMapVersion, canvasID: String) throws -> KnowledgeMapLayout {
        guard let directory = directory(for: canvasID),
              KnowledgeMapVersionPolicy.parse(fileName: version.id) != nil,
              let stored = Self.read(directory.appendingPathComponent(version.id, isDirectory: false)),
              let layout = KnowledgeMapLayout(preferenceValue: stored.layout) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return layout
    }

    private static func read(_ url: URL) -> Stored? {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.format <= currentFormat else { return nil }
        return stored
    }

    // MARK: Writing

    /// Keeps `layout` as a version, whatever the policy says, then drops the
    /// versions past the cap. A name of the learner's is folded to one line;
    /// with none, the date names it.
    @discardableResult
    func keep(
        _ layout: KnowledgeMapLayout,
        canvasID: String,
        name: String? = nil,
        kind: KnowledgeMapVersion.Kind,
        at date: Date = Date()
    ) throws -> KnowledgeMapVersion {
        guard let directory = directory(for: canvasID) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Two versions in one millisecond take the next free one.
        var savedAt = date
        var fileName = KnowledgeMapVersionPolicy.fileName(at: savedAt, kind: kind)
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path) {
            savedAt = savedAt.addingTimeInterval(0.001)
            fileName = KnowledgeMapVersionPolicy.fileName(at: savedAt, kind: kind)
        }
        let versionName = name.map { KnowledgeMapVersionPolicy.manualName($0, at: savedAt) }
            ?? KnowledgeMapVersionPolicy.automaticName(at: savedAt)
        let stored = Stored(
            format: Self.currentFormat,
            name: versionName,
            at: savedAt.timeIntervalSince1970,
            kind: kind,
            cards: layout.placements.count,
            regions: layout.regions.count,
            arrows: layout.edges.count,
            layout: layout.preferenceValue
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(stored).write(to: directory.appendingPathComponent(fileName), options: .atomic)
        prune(canvasID)
        return KnowledgeMapVersion(
            id: fileName,
            name: versionName,
            at: Date(timeIntervalSince1970: TimeInterval(Int64((savedAt.timeIntervalSince1970 * 1_000).rounded())) / 1_000),
            kind: kind,
            cards: stored.cards,
            regions: stored.regions,
            arrows: stored.arrows
        )
    }

    /// Keeps `layout` as a version unless the newest version already holds
    /// what it holds (no card, region or arrow differs): the version kept
    /// before a restore, which a second restore of the same state must not
    /// pile up. Nil when nothing was kept.
    @discardableResult
    func keepIfChanged(
        _ layout: KnowledgeMapLayout,
        canvasID: String,
        name: String? = nil,
        kind: KnowledgeMapVersion.Kind,
        at date: Date = Date()
    ) throws -> KnowledgeMapVersion? {
        let newestLayout = versions(of: canvasID).first.flatMap { try? self.layout(of: $0, canvasID: canvasID) }
        guard KnowledgeMapVersionPolicy.changedEntries(from: newestLayout, to: layout) >= 1 else { return nil }
        return try keep(layout, canvasID: canvasID, name: name, kind: kind, at: date)
    }

    /// Keeps `layout` as an automatic version when the policy says to: the
    /// newest automatic version is ten minutes old (or there is none) and
    /// the layout differs from the newest version of any kind in at least one
    /// card, region or arrow. Nil when nothing was kept, or the write failed.
    @discardableResult
    func keepAutomaticallyIfDue(_ layout: KnowledgeMapLayout, canvasID: String, now: Date = Date()) -> KnowledgeMapVersion? {
        let existing = versions(of: canvasID)
        let newestLayout = existing.first.flatMap { try? self.layout(of: $0, canvasID: canvasID) }
        let changed = KnowledgeMapVersionPolicy.changedEntries(from: newestLayout, to: layout)
        guard KnowledgeMapVersionPolicy.automaticVersionIsDue(
            newestAutomaticAt: existing.first(where: { $0.kind == .auto })?.at,
            changedEntries: changed,
            now: now
        ) else { return nil }
        do {
            return try keep(layout, canvasID: canvasID, kind: .auto, at: now)
        } catch {
            Self.logger.error("Keeping a version of canvas \(canvasID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Drops the versions past the cap, the oldest automatic ones first.
    func prune(_ canvasID: String) {
        guard let directory = directory(for: canvasID) else { return }
        for version in KnowledgeMapVersionPolicy.versionsToDrop(versions(of: canvasID)) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(version.id, isDirectory: false))
        }
    }

    /// One version, gone from the list.
    func delete(_ version: KnowledgeMapVersion, canvasID: String) throws {
        guard let directory = directory(for: canvasID),
              KnowledgeMapVersionPolicy.parse(fileName: version.id) != nil else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(version.id, isDirectory: false))
    }

    /// The canvas is gone for good, and its versions go with it.
    func removeHistory(of canvasID: String) {
        guard let directory = directory(for: canvasID),
              FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Self.logger.error("Removing the versions of canvas \(canvasID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
