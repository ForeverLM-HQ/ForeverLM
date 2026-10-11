import Foundation
import Testing
@testable import ForeverLM

@Suite("Canvas: named versions")
struct KnowledgeMapVersionsTests {
    private func makeHistory() -> (history: KnowledgeMapVersionHistory, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnowledgeMapVersionsTests-\(UUID().uuidString)", isDirectory: true)
        return (KnowledgeMapVersionHistory(rootDirectory: root), root)
    }

    private func layout(cards: Int, regions: Int = 0, edges: Int = 0, at: Double = 1) -> KnowledgeMapLayout {
        var layout = KnowledgeMapLayout()
        for index in 0..<cards { layout.place("idea:\(index)", x: Double(index) * 300, y: 0, at: at) }
        for index in 0..<regions {
            layout.setRegion("r\(index)", .init(name: "Region \(index)", x: Double(index) * 900, y: 500, w: 800, h: 400, color: "#378ADD", at: at))
        }
        for index in 0..<edges where cards >= 2 {
            layout.setEdge("e\(index)", .init(from: "idea:0", to: "idea:1", label: "link \(index)", at: at))
        }
        return layout
    }

    private func version(_ id: Int, _ kind: KnowledgeMapVersion.Kind) -> KnowledgeMapVersion {
        KnowledgeMapVersion(
            id: KnowledgeMapVersionPolicy.fileName(at: Date(timeIntervalSince1970: Double(id)), kind: kind),
            name: "v\(id)", at: Date(timeIntervalSince1970: Double(id)), kind: kind, cards: 0, regions: 0, arrows: 0
        )
    }

    // MARK: Policy

    @Test("A version is kept on its own once the newest automatic one is ten minutes old and something changed")
    func automaticDue() {
        let now = Date(timeIntervalSince1970: 100_000)
        let policy = KnowledgeMapVersionPolicy.self
        #expect(policy.automaticVersionIsDue(newestAutomaticAt: nil, changedEntries: 1, now: now))
        #expect(!policy.automaticVersionIsDue(newestAutomaticAt: nil, changedEntries: 0, now: now), "nothing changed")
        #expect(!policy.automaticVersionIsDue(newestAutomaticAt: now.addingTimeInterval(-599), changedEntries: 5, now: now))
        #expect(policy.automaticVersionIsDue(newestAutomaticAt: now.addingTimeInterval(-600), changedEntries: 1, now: now))
    }

    @Test("A change is a card, region or arrow added, removed or altered; the time it was written is not a change")
    func changedEntries() {
        let base = layout(cards: 3, regions: 1, edges: 1)
        #expect(KnowledgeMapVersionPolicy.changedEntries(from: base, to: base) == 0)
        var rewritten = base
        rewritten.place("idea:0", x: 0, y: 0, at: 99)
        #expect(KnowledgeMapVersionPolicy.changedEntries(from: base, to: rewritten) == 0, "put back where it was")
        var edited = base
        edited.place("idea:0", x: 50, y: 0, at: 99)
        edited.unplace("idea:2", at: 99)
        edited.setRegion("r0", .init(name: "Renamed", x: 0, y: 500, w: 800, h: 400, color: "#378ADD", at: 99))
        edited.setEdge("e9", .init(from: "idea:0", to: "idea:1", label: "new", at: 99))
        #expect(KnowledgeMapVersionPolicy.changedEntries(from: base, to: edited) == 4)
        #expect(KnowledgeMapVersionPolicy.changedEntries(from: nil, to: base) == 5, "everything is new against no version")
    }

    @Test("Past the cap the oldest automatic versions go first; the learner's own go only when they are all that is left")
    func dropOrder() {
        let few = (1...30).map { version($0, .auto) }
        #expect(KnowledgeMapVersionPolicy.versionsToDrop(few).isEmpty)

        var mixed = (1...25).map { version($0, .auto) } + (101...110).map { version($0, .manual) }
        #expect(mixed.count == 35)
        let dropped = KnowledgeMapVersionPolicy.versionsToDrop(mixed)
        #expect(dropped.map(\.name) == ["v1", "v2", "v3", "v4", "v5"], "the five oldest automatic ones")

        mixed = (1...3).map { version($0, .auto) } + (101...130).map { version($0, .manual) }
        let all = KnowledgeMapVersionPolicy.versionsToDrop(mixed)
        #expect(all.map(\.name) == ["v1", "v2", "v3"])

        let onlyManual = (101...133).map { version($0, .manual) }
        #expect(KnowledgeMapVersionPolicy.versionsToDrop(onlyManual).map(\.name) == ["v101", "v102", "v103"])
    }

    @Test("A file's name says when and how the version was kept")
    func fileNames() {
        let at = Date(timeIntervalSince1970: 1_791_345_600.123)
        let name = KnowledgeMapVersionPolicy.fileName(at: at, kind: .manual)
        #expect(name == "1791345600123-manual.json")
        let parsed = KnowledgeMapVersionPolicy.parse(fileName: name)
        #expect(parsed?.kind == .manual)
        #expect(parsed.map { abs($0.at.timeIntervalSince(at)) < 0.001 } == true)
        #expect(KnowledgeMapVersionPolicy.parse(fileName: "notes.txt") == nil)
        #expect(KnowledgeMapVersionPolicy.parse(fileName: "12-other.json") == nil)
        #expect(KnowledgeMapVersionPolicy.parse(fileName: ".DS_Store") == nil)
    }

    @Test("A name of the learner's is one line of at most 80 characters; with none, the date names it")
    func names() {
        let at = Date(timeIntervalSince1970: 1_791_345_600)
        #expect(KnowledgeMapVersionPolicy.manualName("  Before   the\nreorg ", at: at) == "Before the reorg")
        #expect(KnowledgeMapVersionPolicy.manualName(String(repeating: "x", count: 200), at: at).count == 80)
        #expect(KnowledgeMapVersionPolicy.manualName("   ", at: at) == KnowledgeMapVersionPolicy.automaticName(at: at))
        let calendar = Calendar(identifier: .gregorian)
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(KnowledgeMapVersionPolicy.automaticName(at: Date(timeIntervalSince1970: 1_791_345_600), calendar: utc) == "7 Oct 2026, 04:00")
    }

    @Test("A version's summary counts its cards, regions and arrows")
    func summary() {
        let one = KnowledgeMapVersion(id: "1-auto.json", name: "n", at: Date(), kind: .auto, cards: 1, regions: 1, arrows: 1)
        #expect(one.summary == "1 card · 1 region · 1 arrow")
        let many = KnowledgeMapVersion(id: "1-auto.json", name: "n", at: Date(), kind: .auto, cards: 12, regions: 0, arrows: 3)
        #expect(many.summary == "12 cards · 0 regions · 3 arrows")
    }

    // MARK: The store

    @Test("A version keeps the layout, its name and its counts, and lists newest first")
    func keepAndList() throws {
        let (history, root) = makeHistory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = layout(cards: 2)
        let second = layout(cards: 4, regions: 2, edges: 3)
        let early = Date(timeIntervalSince1970: 1_791_345_000)
        let late = early.addingTimeInterval(3_600)
        try history.keep(first, canvasID: "cnv-a", name: "Before the reorg", kind: .manual, at: early)
        let kept = try history.keep(second, canvasID: "cnv-a", kind: .auto, at: late)
        #expect(kept.kind == .auto)
        #expect(kept.name == KnowledgeMapVersionPolicy.automaticName(at: late))

        let listed = history.versions(of: "cnv-a")
        #expect(listed.map(\.kind) == [.auto, .manual])
        #expect(listed.map(\.name).last == "Before the reorg")
        #expect(listed.first?.cards == 4 && listed.first?.regions == 2 && listed.first?.arrows == 3)
        #expect(try history.layout(of: listed[1], canvasID: "cnv-a") == first)
        #expect(try history.layout(of: listed[0], canvasID: "cnv-a") == second)
        #expect(history.versions(of: "cnv-other").isEmpty, "each canvas has a folder of its own")
    }

    @Test("A canvas keeps thirty versions; the automatic ones are dropped first and the learner's own survive")
    func cap() throws {
        let (history, root) = makeHistory()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        for index in 0..<35 {
            try history.keep(layout(cards: 1), canvasID: "cnv-a", kind: .auto, at: base.addingTimeInterval(Double(index)))
        }
        #expect(history.versions(of: "cnv-a").count == 30)
        #expect(history.versions(of: "cnv-a").last?.at == base.addingTimeInterval(5), "the five oldest went")

        for index in 0..<10 {
            try history.keep(layout(cards: 2), canvasID: "cnv-a", name: "Mine \(index)", kind: .manual, at: base.addingTimeInterval(100 + Double(index)))
        }
        let after = history.versions(of: "cnv-a")
        #expect(after.count == 30)
        #expect(after.filter { $0.kind == .manual }.count == 10, "ten of the learner's, all kept")
        #expect(after.filter { $0.kind == .auto }.count == 20)
        #expect(after.last?.at == base.addingTimeInterval(15), "the oldest automatic ones went to make room")

        for index in 0..<25 {
            try history.keep(layout(cards: 3), canvasID: "cnv-b", name: "Named \(index)", kind: .manual, at: base.addingTimeInterval(Double(index)))
        }
        for index in 25..<33 {
            try history.keep(layout(cards: 3), canvasID: "cnv-b", name: "Named \(index)", kind: .manual, at: base.addingTimeInterval(Double(index)))
        }
        let named = history.versions(of: "cnv-b")
        #expect(named.count == 30, "the cap holds when every version is the learner's")
        #expect(named.last?.name == "Named 3", "then the oldest of them goes")
    }

    @Test("Two versions in one millisecond both stay")
    func sameMillisecond() throws {
        let (history, root) = makeHistory()
        defer { try? FileManager.default.removeItem(at: root) }
        let at = Date(timeIntervalSince1970: 1_791_000_000)
        try history.keep(layout(cards: 1), canvasID: "cnv-a", name: "A", kind: .manual, at: at)
        try history.keep(layout(cards: 2), canvasID: "cnv-a", name: "B", kind: .manual, at: at)
        #expect(history.versions(of: "cnv-a").map(\.name) == ["B", "A"])
    }

    @Test("A version can be deleted, a canvas's history can go whole, and a hostile id names no folder")
    func deleting() throws {
        let (history, root) = makeHistory()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        let one = try history.keep(layout(cards: 1), canvasID: "cnv-a", name: "One", kind: .manual, at: base)
        try history.keep(layout(cards: 2), canvasID: "cnv-a", name: "Two", kind: .manual, at: base.addingTimeInterval(10))
        try history.delete(one, canvasID: "cnv-a")
        #expect(history.versions(of: "cnv-a").map(\.name) == ["Two"])
        history.removeHistory(of: "cnv-a")
        #expect(history.versions(of: "cnv-a").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cnv-a").path))

        for hostile in ["", "..", "../x", "a/b", ".hidden"] {
            #expect(history.directory(for: hostile) == nil, "\(hostile) is no canvas id")
            #expect(throws: (any Error).self) { try history.keep(layout(cards: 1), canvasID: hostile, kind: .manual) }
        }
    }

    @Test("A file the list cannot read is left out, and a file that is no version is ignored")
    func damagedFiles() throws {
        let (history, root) = makeHistory()
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = try history.keep(layout(cards: 1), canvasID: "cnv-a", name: "Good", kind: .manual)
        let folder = root.appendingPathComponent("cnv-a")
        try Data("not json".utf8).write(to: folder.appendingPathComponent("1791000000000-auto.json"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        #expect(history.versions(of: "cnv-a").map(\.name) == ["Good"])
        #expect(throws: (any Error).self) {
            try history.layout(of: KnowledgeMapVersion(id: "1791000000000-auto.json", name: "x", at: Date(), kind: .auto, cards: 0, regions: 0, arrows: 0), canvasID: "cnv-a")
        }
        #expect(try history.layout(of: kept, canvasID: "cnv-a") == layout(cards: 1))
    }

    @Test("Automatic versions: the first after an edit, none within ten minutes, the next after ten with a change, none without one")
    func automaticVersions() throws {
        let (history, root) = makeHistory()
        defer { try? FileManager.default.removeItem(at: root) }
        let t0 = Date(timeIntervalSince1970: 1_791_000_000)
        let blank = KnowledgeMapLayout()
        #expect(history.keepAutomaticallyIfDue(blank, canvasID: "cnv-a", now: t0) == nil, "an empty canvas has nothing to keep")

        var canvas = layout(cards: 2)
        #expect(history.keepAutomaticallyIfDue(canvas, canvasID: "cnv-a", now: t0) != nil)
        canvas.place("idea:5", x: 0, y: 900, at: 2)
        #expect(history.keepAutomaticallyIfDue(canvas, canvasID: "cnv-a", now: t0.addingTimeInterval(300)) == nil, "five minutes on")
        #expect(history.keepAutomaticallyIfDue(canvas, canvasID: "cnv-a", now: t0.addingTimeInterval(601)) != nil)
        #expect(history.versions(of: "cnv-a").count == 2)
        #expect(history.keepAutomaticallyIfDue(canvas, canvasID: "cnv-a", now: t0.addingTimeInterval(2_000)) == nil, "nothing changed since")

        // A version the learner saved a moment ago holds this state: no copy of it.
        canvas.place("idea:6", x: 0, y: 1_200, at: 3)
        try history.keep(canvas, canvasID: "cnv-a", name: "Saved", kind: .manual, at: t0.addingTimeInterval(2_100))
        #expect(history.keepAutomaticallyIfDue(canvas, canvasID: "cnv-a", now: t0.addingTimeInterval(3_000)) == nil)
        #expect(history.versions(of: "cnv-a").count == 3)
    }

    // MARK: Restore

    @Test("A restore writes the snapshot's cards, regions and arrows back and removes the rest with tombstones")
    func restoreTombstones() {
        var snapshot = KnowledgeMapLayout()
        snapshot.place("idea:a", x: 10, y: 10, at: 5)
        snapshot.place("idea:b", x: 20, y: 20, at: 5)
        snapshot.setRegion("r1", .init(name: "Old", x: 0, y: 0, w: 500, h: 500, color: "#378ADD", at: 5))
        snapshot.setEdge("e1", .init(from: "idea:a", to: "idea:b", label: "old", at: 5))
        snapshot.removed["p:idea:z"] = 4

        var current = KnowledgeMapLayout()
        current.name = .init(text: "My canvas", at: 50)
        current.created = 42
        current.trash = .init(since: nil, at: 60)
        current.notebook = .init(id: "nb-1", at: 70)
        current.place("idea:b", x: 99, y: 99, at: 30)
        current.place("idea:c", x: 5, y: 5, at: 30)
        current.setRegion("r2", .init(name: "New", x: 0, y: 0, w: 100, h: 100, color: "#378ADD", at: 30))
        current.setEdge("e2", .init(from: "idea:b", to: "idea:c", label: "new", at: 30))

        KnowledgeMapVersionRestore.apply(snapshot, to: &current, at: 1_000)

        #expect(Set(current.placements.keys) == ["idea:a", "idea:b"])
        #expect(current.placements["idea:b"] == .init(x: 20, y: 20, at: 1_000), "written as the newest, so every Mac takes it")
        #expect(current.placements["idea:a"]?.at == 1_000)
        #expect(current.removed["p:idea:c"] == 1_000, "a tombstone, so another Mac follows")
        #expect(Set(current.regions.keys) == ["r1"])
        #expect(current.removed["r:r2"] == 1_000)
        #expect(Set(current.edges.keys) == ["e1"])
        #expect(current.removed["e:e2"] == 1_000)
        #expect(current.removed["p:idea:z"] == nil, "the snapshot's own tombstones are not brought back")

        // What the canvas is stays the current row's.
        #expect(current.name?.text == "My canvas")
        #expect(current.created == 42)
        #expect(current.trash == .init(since: nil, at: 60))
        #expect(current.notebook == .init(id: "nb-1", at: 70))
    }

    @Test("A restore of what is already there writes nothing, and a card taken off since comes back")
    func restoreIsQuietAndBringsBack() {
        var snapshot = KnowledgeMapLayout()
        snapshot.place("idea:a", x: 1, y: 2, at: 5)
        snapshot.place("idea:gone", x: 3, y: 4, at: 5)

        var current = snapshot
        current.unplace("idea:gone", at: 40)
        current.place("idea:a", x: 1, y: 2, at: 41)
        let before = current
        KnowledgeMapVersionRestore.apply(KnowledgeMapLayout(), to: &current, at: 100)
        #expect(current.placements.isEmpty)

        current = before
        KnowledgeMapVersionRestore.apply(snapshot, to: &current, at: 100)
        #expect(current.placements["idea:a"]?.at == 41, "already the same: left as it was")
        #expect(current.placements["idea:gone"] == .init(x: 3, y: 4, at: 100))
        #expect(current.removed["p:idea:gone"] == nil, "the learner's old removal is cleared by the card's return")
    }

    @Test("Another Mac that still holds what the restore removed follows it when the rows merge, whichever merges first")
    func restoreSyncs() {
        var shared = KnowledgeMapLayout()
        shared.place("idea:a", x: 1, y: 1, at: 10)
        shared.place("idea:c", x: 2, y: 2, at: 10)
        shared.setEdge("e2", .init(from: "idea:a", to: "idea:c", label: "x", at: 10))
        var snapshot = KnowledgeMapLayout()
        snapshot.place("idea:a", x: 7, y: 7, at: 5)

        var restored = shared
        KnowledgeMapVersionRestore.apply(snapshot, to: &restored, at: 500)
        let other = shared
        let one = restored.merged(with: other)
        let two = other.merged(with: restored)
        #expect(one == two)
        #expect(one.placements["idea:c"] == nil)
        #expect(one.edges["e2"] == nil)
        #expect(one.placements["idea:a"]?.x == 7)
    }

    @Test("Restoring as the model writes it is one edit that Undo takes back")
    func restoreIsOneUndoableEdit() {
        var snapshot = KnowledgeMapLayout()
        snapshot.place("idea:a", x: 10, y: 10, at: 5)
        var current = KnowledgeMapLayout()
        current.place("idea:a", x: 50, y: 50, at: 30)
        current.place("idea:b", x: 60, y: 60, at: 30)
        let before = current
        KnowledgeMapVersionRestore.apply(snapshot, to: &current, at: 100)
        let edit = KnowledgeMapEdit(before: before, after: current, at: Date())
        #expect(edit.changes)
        var undone = current
        edit.restore(edit.before, into: &undone, at: 200)
        #expect(undone.placements["idea:a"]?.x == 50)
        #expect(undone.placements["idea:b"]?.x == 60)
    }
}
