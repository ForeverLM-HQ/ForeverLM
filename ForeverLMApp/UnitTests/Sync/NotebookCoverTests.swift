import CoreGraphics
import Foundation
import Testing
@testable import ForeverLM

/// Notebook covers on the Mac (docs/cloudkit-schema-design.md D53, §5.9, WP31): a notebook made one at a
/// time gets its cover drawn once, on the account's Images model, billed as `notebook_cover` with the
/// notebook as its source; the bytes go up as its `cover` satellite before `files.cover` moves, by a
/// compare-and-set save that never overwrites a cover another writer set. Nothing is drawn with the
/// Setting off, under generation 1, or for a notebook made in bulk.
@Suite("Notebook covers", .serialized)
struct NotebookCoverTests {
    private typealias C = NotebookCoverFixture
    private typealias F = NotebookSyncFixture
    private typealias J = JobSyncFixture

    @Test("A notebook made one at a time is drawn once: bytes first, then files.cover, and never again")
    func drawnOnce() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.mac(server, "cover-once")
        try await C.addNotebook(mac, "nb-1")
        let drawer = C.Drawer()
        let cache = C.cache()
        let covers = C.service(mac, drawer: drawer, cache: cache)

        #expect(try mac.store.queueNotebookCover("nb-1", gates: NotebookCoverGates(automatic: true)))
        #expect(await covers.drainQueued() == 1)
        #expect(drawer.count == 1)
        let cover = try #require(try C.serverCover(mac, "nb-1"), "the pointer moved on the server")
        #expect(cover.owner == "nb-1" && cover.role == "cover" && cover.mime == NotebookCoverImage.mime)
        #expect(try C.M.onServer(mac, cover), "the satellite is on the server")
        #expect(try C.replicaCover(mac, "nb-1") == cover, "the replica took the acknowledged save")
        #expect(cover.value["gen"]?["model"]?.stringValue == "account-images-model")
        #expect(cover.value["gen"]?["device"]?.stringValue == mac.deviceID)
        #expect(cache.data(hash: cover.hash) != nil, "this Mac keeps the picture it drew")
        #expect(try C.queued(mac) == 0)
        #expect(try mac.outboxRows() == 0, "the pointer went beside the engine, not through the outbox")

        // Asked again (a second create, a retry): nothing is drawn over the cover.
        #expect(try mac.store.queueNotebookCover("nb-1", gates: NotebookCoverGates(automatic: true)))
        await covers.drainQueued()
        #expect(drawer.count == 1)
        #expect(try C.serverCover(mac, "nb-1") == cover)
        #expect(try C.queued(mac) == 0)
    }

    @Test("The drawing names no model and is billed as notebook_cover with the notebook as its source")
    func billedAsNotebookCover() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.mac(server, "cover-billing")
        try await C.addNotebook(mac, "nb-1", title: "🧬 Mitochondria")
        let drawer = C.Drawer()
        try mac.store.queueNotebookCover("nb-1", gates: NotebookCoverGates(automatic: true))
        await C.service(mac, drawer: drawer).drainQueued()

        let request = try #require(drawer.requests.first)
        #expect(request.model == nil, "the account's Images model, never a model the cover code names")
        #expect(request.usageTask == "notebook_cover")
        #expect(request.source == AIUsageSource(id: "nb-1", type: "notebook", title: "Mitochondria"))
        #expect(request.shape == .square && request.quality == .low)
        #expect(request.prompt.contains("Subject: Mitochondria"), "the title without its emoji")
        #expect(request.prompt.contains("What the learner is after: Read carefully"), "the Instructions")
        #expect(request.prompt.contains("🧬"), "the emoji, as a hint")
        #expect(request.prompt.contains("no text, letters"))
    }

    @Test("Nothing is queued with the Setting off, under generation 1, or for a Goal")
    func nothingQueuedWhenClosed() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.mac(server, "cover-closed")
        try await C.addNotebook(mac, "nb-1")
        #expect(try !mac.store.queueNotebookCover("nb-1", gates: NotebookCoverGates(automatic: false)))
        try NotebookSyncFixture.addGoal(mac.store, "goal-1", parent: "nb-1")
        #expect(try !mac.store.queueNotebookCover("goal-1", gates: NotebookCoverGates(automatic: true)))
        #expect(try C.queued(mac) == 0)
    }

    @Test("A queued cover pauses for the Setting and is drawn once it allows it")
    func pausesForTheGates() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.mac(server, "cover-pause")
        try await C.addNotebook(mac, "nb-1")
        try mac.store.queueNotebookCover("nb-1", gates: NotebookCoverGates(automatic: true))
        let drawer = C.Drawer()
        let gates = C.Gates(automatic: false)
        let covers = C.service(mac, drawer: drawer, gates: gates)

        #expect(await covers.drainQueued() == 0)
        #expect(try drawer.count == 0 && C.queued(mac) == 1)
        gates.value = NotebookCoverGates(automatic: true)
        #expect(await covers.drainQueued() == 1)
        #expect(drawer.count == 1)
        #expect(try C.serverCover(mac, "nb-1") != nil)
    }

    @Test("A notebook not sent yet, or still unnamed, waits; it is drawn once it is sent and named")
    func waitsForItsRecordAndItsName() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.mac(server, "cover-wait")
        try await C.addNotebook(mac, "nb-1", title: NotebookNaming.placeholderTitle, send: false)
        let mark = NotebookNaming.Mark.unnamed(title: NotebookNaming.placeholderTitle)
        try mac.store.execute("INSERT INTO user_preferences (key, value, updated_at) VALUES (?, ?, 1000)", [
            .text(NotebookNaming.preferenceKey(notebookID: "nb-1")), .text(PreferenceStore.encodePlist(mark.encoded) ?? ""),
        ])
        try mac.store.queueNotebookCover("nb-1", gates: NotebookCoverGates(automatic: true))
        let drawer = C.Drawer()
        let covers = C.service(mac, drawer: drawer)

        #expect(await covers.drainQueued() == 0, "unnamed")
        await EngineTestDriver.pause()
        try await mac.send()
        #expect(await covers.drainQueued() == 0, "still under the placeholder")
        #expect(drawer.count == 0)

        // ForeverLM names it: the mark says named, and the title is the mark's.
        let named = NotebookNaming.Mark(title: "Mitochondrial membranes", summary: nil, sources: 1, exchanges: 0)
        try mac.store.execute("UPDATE user_preferences SET value = ? WHERE key = ?", [
            .text(PreferenceStore.encodePlist(named.encoded) ?? ""), .text(NotebookNaming.preferenceKey(notebookID: "nb-1")),
        ])
        try mac.store.execute("UPDATE learning_goals SET title = ?, updated_at = updated_at + 1 WHERE id = 'nb-1'", [.text(named.title)])
        await EngineTestDriver.pause()
        try await mac.send()
        #expect(await covers.drainQueued() == 1)
        #expect(drawer.requests.first?.prompt.contains("Subject: Mitochondrial membranes") == true)
        #expect(try C.serverCover(mac, "nb-1") != nil)
    }

    @Test("A cover another writer set while this Mac drew is kept; the drawn one is never pointed at")
    func anotherWriterFirst() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.mac(server, "cover-race")
        try await C.addNotebook(mac, "nb-1")
        let other = C.otherCover("nb-1")
        let drawer = C.Drawer()
        drawer.during = { try C.patchServer(mac, .notebook, "nb-1", ["files": .elements(["cover": other.value])]) }
        try mac.store.queueNotebookCover("nb-1", gates: NotebookCoverGates(automatic: true))

        #expect(await C.service(mac, drawer: drawer).drainQueued() == 1)
        #expect(drawer.count == 1)
        #expect(try C.serverCover(mac, "nb-1") == other, "the first acknowledged cover stands")
        #expect(try C.replicaCover(mac, "nb-1") == other, "the losing save took the server's version")
        #expect(try mac.serverEnvelope(.notebook, "nb-1")?.fields["title"]?.stringValue == "🧬 Mitochondria")
    }

    @Test("A drawing that fails is tried once more, then the notebook keeps its emoji and leaves the queue")
    func twoAttempts() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.mac(server, "cover-attempts")
        try await C.addNotebook(mac, "nb-1")
        let drawer = C.Drawer()
        drawer.fails = true
        try mac.store.queueNotebookCover("nb-1", gates: NotebookCoverGates(automatic: true))
        let covers = C.service(mac, drawer: drawer)
        await covers.drainQueued()
        await covers.drainQueued()
        await covers.drainQueued()
        #expect(drawer.count == 2, "two attempts, as the spec says")
        #expect(try C.serverCover(mac, "nb-1") == nil)
        #expect(try mac.count("SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = ? AND attempts = ? AND last_error IS NOT NULL", [
            .text(NotebookCoverQueue.newKind), .integer(2),
        ]) == 1, "kept, logged, and never drawn again")
    }

    @Test("An upload that failed after the drawing is tried again from the kept picture, without drawing again")
    func keptDrawingIsReused() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.mac(server, "cover-kept")
        try await C.addNotebook(mac, "nb-1")
        let drawer = C.Drawer()
        let cache = C.cache()
        let covers = C.service(mac, drawer: drawer, cache: cache)
        try mac.store.queueNotebookCover("nb-1", gates: NotebookCoverGates(automatic: true))
        // The upload's zone is gone for one pass: the drawing is kept in the queue row.
        let rootName = SyncSchema.rootRecordName
        let root = try #require(try mac.store.replica.record(zoneKey: PrivateSyncZones.libraryKey, recordName: rootName))
        try mac.store.replica.deleteRecord(zoneKey: PrivateSyncZones.libraryKey, recordName: rootName)
        await covers.drainQueued()
        #expect(try drawer.count == 1 && C.serverCover(mac, "nb-1") == nil)
        let kept = try #require(NotebookCoverStaged(json: try mac.text(
            "SELECT payload_json FROM ck_backfill_queue WHERE kind = ?", [.text(NotebookCoverQueue.newKind)]
        ).flatMap { try SyncJSON(parsing: Data($0.utf8)) }))
        #expect(try mac.count("SELECT attempts FROM ck_backfill_queue") == 0, "a zone not ready is no attempt")

        try mac.store.replica.upsertRecord(root)
        await covers.drainQueued()
        #expect(drawer.count == 1, "the kept picture went up")
        #expect(try C.serverCover(mac, "nb-1")?.hash == kept.hash)
    }

    @Test("A cover Job is claimed once this Mac holds the notebook's record, and only a cover Job with a notebook is")
    func coverJobIsClaimed() async throws {
        let (root, store) = try F.makeStore("cover-job")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        try F.sendAll(store)
        try F.addNotebook(store, "nb-2")
        try F.apply(store, [
            try J.jobRecord("job-cover", kind: "makeDerived", target: "nb:nb-1", params: ["derived": .string("cover")]),
            try J.jobRecord("job-early", kind: "makeDerived", target: "nb:nb-2", params: ["derived": .string("cover")]),
            try J.jobRecord("job-other", kind: "makeDerived", target: "nb:nb-1", params: ["derived": .string("thumbnail")]),
            try J.jobRecord("job-bare", kind: "makeDerived", params: ["derived": .string("cover")]),
        ])
        let work = FakeJobWork(store: store)
        let runner = J.runner(store, work: work)

        #expect(await runner.pass() == [.claim("job-cover")], "nb-2's record is not sent, so this Mac does not hold it yet")
        try F.sendAll(store)
        #expect(Set(await runner.pass()) == [.start("job-cover"), .claim("job-early")], "held now")
        #expect(try await J.settled(store, "job-cover") == "done")
        #expect(work.recorded == ["drawNotebookCover nb-1"])
        let job = try #require(F.savedFields(try F.pending(store)["Job:job-cover"]))
        #expect(job["result"] == .object(["refs": .array([.string("nb:nb-1")]), "note": .string("Drew the notebook's cover.")]))
        #expect(try F.text(store, "SELECT group_concat(status, ',') FROM jobs WHERE id IN ('job-other', 'job-bare')") == "queued,queued",
                "another kind of derived picture, or a Job with no notebook, is never claimed")
    }

    @Test("A cover Job for a notebook still under its placeholder name is not run; once it is named, it is")
    func coverJobWaitsForTheName() async throws {
        let (root, store) = try F.makeStore("cover-job-name")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1", title: NotebookNaming.placeholderTitle)
        let mark = NotebookNaming.Mark.unnamed(title: NotebookNaming.placeholderTitle)
        try store.execute("INSERT INTO user_preferences (key, value, updated_at) VALUES (?, ?, 1000)", [
            .text(NotebookNaming.preferenceKey(notebookID: "nb-1")), .text(PreferenceStore.encodePlist(mark.encoded) ?? ""),
        ])
        try F.sendAll(store)
        try F.apply(store, [
            try J.jobRecord("job-cover", kind: "makeDerived", target: "nb:nb-1", params: ["derived": .string("cover")]),
        ])
        let work = FakeJobWork(store: store)
        let runner = J.runner(store, work: work)

        #expect(await runner.pass() == [], "the record is held, but the notebook is still called New notebook")
        #expect(try F.text(store, "SELECT status FROM jobs WHERE id = 'job-cover'") == "queued")
        #expect(work.recorded.isEmpty)

        // The naming step names it: the mark says named, and the title is the mark's.
        let named = NotebookNaming.Mark(title: "Mitochondrial membranes", summary: nil, sources: 1, exchanges: 0)
        try store.execute("UPDATE user_preferences SET value = ? WHERE key = ?", [
            .text(PreferenceStore.encodePlist(named.encoded) ?? ""), .text(NotebookNaming.preferenceKey(notebookID: "nb-1")),
        ])
        try store.execute("UPDATE learning_goals SET title = ?, updated_at = updated_at + 1 WHERE id = 'nb-1'", [.text(named.title)])
        try F.sendAll(store)

        #expect(await runner.pass() == [.claim("job-cover")])
        try F.sendAll(store)
        #expect(await runner.pass() == [.start("job-cover")])
        #expect(try await J.settled(store, "job-cover") == "done")
        #expect(work.recorded == ["drawNotebookCover nb-1"])
    }

    @Test("A cover Job draws once and follows the Setting as the creation does")
    func coverJobFollowsTheGates() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.mac(server, "cover-job-gates")
        try await C.addNotebook(mac, "nb-1")
        let drawer = C.Drawer()
        let gates = C.Gates(automatic: false)
        let covers = C.service(mac, drawer: drawer, gates: gates)
        let picked = ImageGenerationModel.unresolved(id: "test/picked-in-the-menu")

        await #expect(throws: NotebookCoverService.Refusal.settingOff) { try await covers.drawForJob("nb-1") }
        #expect(drawer.count == 0)
        gates.value = NotebookCoverGates(automatic: true)
        let first = try await covers.drawForJob("nb-1")
        guard case .drawn(let cover) = first else { Issue.record("expected a cover, got \(first)"); return }
        #expect(try C.serverCover(mac, "nb-1") == cover)
        #expect(try await covers.drawForJob("nb-1") == .hasCover)
        #expect(drawer.count == 1)
        // Redraw With draws over a cover the notebook has, with the Setting off.
        gates.value = NotebookCoverGates(automatic: false)
        let redrawn = try await covers.drawNow("nb-1", model: picked)
        guard case .drawn(let second) = redrawn else { Issue.record("expected a redraw, got \(redrawn)"); return }
        #expect(second.hash != cover.hash && drawer.count == 2)
        #expect(try C.serverCover(mac, "nb-1") == second)
    }

    @Test("A cover drawn on one Mac shows on another: its replica names it, the bytes are fetched once and kept, and the notice goes out")
    func coverShowsOnAnotherMac() async throws {
        let server = EngineTestDriver.server()
        let a = try await C.mac(server, "cover-show-a")
        let b = try EngineTestDevice(server, name: "cover-show-b", deviceID: "macbbbbb", registry: KnowledgeStore.projectionRegistry)
        try await b.bootstrap(.macWithoutLibrary)
        try await C.addNotebook(a, "nb-1")
        try await C.addNotebook(a, "nb-2")
        try a.store.queueNotebookCover("nb-1", gates: NotebookCoverGates(automatic: true))
        await C.service(a, drawer: C.Drawer()).drainQueued()
        let drawn = try #require(try C.serverCover(a, "nb-1"))

        let notices = NoticeCounter(.notebookCoversDidChange)
        try await b.sync()
        let cache = C.cache()
        let covers = C.service(b, drawer: C.Drawer(), cache: cache)
        #expect(await covers.pointer(ofRow: "nb-2") == nil, "a notebook with no cover")
        let pointer = try #require(await covers.pointer(ofRow: "nb-1"))
        #expect(pointer.file == drawn && pointer.target == .library("nb-1"))
        #expect(cache.data(hash: drawn.hash) == nil)
        let bytes = try #require(await covers.bytes(of: pointer))
        #expect(SyncIdentity.sha256Hex(bytes) == drawn.hash && cache.data(hash: drawn.hash) == bytes, "fetched, verified and kept")
        #expect(await notices.waitFor(1), "the arrival tells the cover pictures to read the replica again")
    }

    @Test("A merge's survivor with no cover takes the folded notebook's, and one that has its own keeps it")
    func mergeFoldsTheCover() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.mac(server, "cover-merge")
        for id in ["nb-a", "nb-b", "nb-c"] { try await C.addNotebook(mac, id) }
        let drawer = C.Drawer()
        let covers = C.service(mac, drawer: drawer)
        for id in ["nb-a", "nb-c"] { try mac.store.queueNotebookCover(id, gates: NotebookCoverGates(automatic: true)) }
        await covers.drainQueued()
        let coverA = try #require(try C.serverCover(mac, "nb-a"))
        let coverC = try #require(try C.serverCover(mac, "nb-c"))
        #expect(coverA != coverC && drawer.count == 2)

        _ = try mac.store.mergeNotebooksUnderGeneration2(survivorID: "nb-b", mergeeIDs: ["nb-a"], title: nil, mergeNotes: true)
        #expect(try C.queued(mac, kind: NotebookCoverQueue.foldKind) == 1, "queued in the merge's own transaction")
        #expect(try C.serverCover(mac, "nb-b") == nil)
        await covers.drainQueued()
        #expect(try C.serverCover(mac, "nb-b") == coverA, "the folded notebook's FileRef, verbatim")
        #expect(try C.replicaCover(mac, "nb-b") == coverA)
        #expect(try C.queued(mac, kind: NotebookCoverQueue.foldKind) == 0 && drawer.count == 2, "nothing was drawn")

        _ = try mac.store.mergeNotebooksUnderGeneration2(survivorID: "nb-b", mergeeIDs: ["nb-c"], title: nil, mergeNotes: true)
        #expect(try C.queued(mac, kind: NotebookCoverQueue.foldKind) == 0, "a survivor with a cover queues none")
        #expect(try C.serverCover(mac, "nb-b") == coverA)
    }

    @Test("An emptying split's heir takes the parent's cover once its own record is sent")
    func splitHeirTakesTheCover() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.mac(server, "cover-split-heir")
        try await C.addNotebook(mac, "nb-p")
        for source in ["s1", "s2", "s3"] {
            try F.addSource(mac.store, source)
            try F.file(mac.store, source, into: "nb-p")
        }
        await EngineTestDriver.pause()
        try await mac.send()
        let drawer = C.Drawer()
        let covers = C.service(mac, drawer: drawer)
        try mac.store.queueNotebookCover("nb-p", gates: NotebookCoverGates(automatic: true))
        await covers.drainQueued()
        let cover = try #require(try C.serverCover(mac, "nb-p"))

        let result = try mac.store.splitNotebookUnderGeneration2(
            parentID: "nb-p", splits: [
                CompanionGoalSplitSpec(title: "OXPHOS", topic: nil, sourceIDs: ["s1"], gapIDs: []),
                CompanionGoalSplitSpec(title: "Biogenesis", topic: nil, sourceIDs: ["s2", "s3"], gapIDs: []),
            ], keepParent: false
        )
        let heir = try #require(result.heirGoalID)
        #expect(try C.queued(mac, kind: NotebookCoverQueue.foldKind) == 1)
        #expect(await covers.drainQueued() == 0, "the heir's record is not sent yet, so its cover waits")
        #expect(try C.queued(mac, kind: NotebookCoverQueue.foldKind) == 1)
        await EngineTestDriver.pause()
        try await mac.send()
        #expect(await covers.drainQueued() == 1)
        #expect(try C.serverCover(mac, heir) == cover)
        #expect(drawer.count == 1, "drawn once, for the parent, and never for the heir")
        let other = try #require(result.childGoalIDs.first { $0 != heir })
        #expect(try C.serverCover(mac, other) == nil, "a split's children are drawn no cover of their own")
    }

    @Test("A split's new notebooks and an import queue no cover")
    func bulkMadeNotebooksGetNone() async throws {
        let (root, store) = try NotebookSyncFixture.makeStore("cover-split")
        defer { try? FileManager.default.removeItem(at: root) }
        try NotebookSyncFixture.prepareReplica(store)
        try NotebookSyncFixture.addNotebook(store, "nb-1")
        try NotebookSyncFixture.addSource(store, "s1")
        try NotebookSyncFixture.addSource(store, "s2")
        _ = try store.createCompanionGoal(
            title: "Imported notebook", description: nil, summary: nil, topic: "imports", startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt, dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
        _ = try NotebookMergeJob(connection: store, registry: KnowledgeStore.projectionRegistry).split(
            "nb-1", into: [
                NotebookMergeJob.Child(title: "Half one", topic: nil, sourceIDs: ["s1"], gapIDs: []),
                NotebookMergeJob.Child(title: "Half two", topic: nil, sourceIDs: ["s2"], gapIDs: []),
            ], keepParent: true
        )
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM ck_backfill_queue WHERE kind LIKE 'notebookCover%'") == 0)
    }
}

/// Counts the notices of one name, for a suite that waits for the one the main queue posts.
private final class NoticeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = 0
    private var token: NSObjectProtocol?

    init(_ name: Notification.Name) {
        token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            self?.lock.withLock { self?.seen += 1 }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    func waitFor(_ count: Int) async -> Bool {
        for _ in 0..<200 {
            if lock.withLock({ seen }) >= count { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}

/// A cover without its ground (`NotebookCoverCutout`; the product owner, 2026-10-06: the icons were small, on a
/// background, and "perhaps they can just be icons with no background?"). The drawn pictures are opaque
/// squares, so the app takes the flat ground away and crops to what is drawn.
@Suite("Notebook cover cutout")
struct NotebookCoverCutoutTests {
    private struct Colour { var red: UInt8, green: UInt8, blue: UInt8 }
    private static let cream = Colour(red: 250, green: 246, blue: 235)
    private static let navy = Colour(red: 20, green: 50, blue: 110)

    /// A 256-pixel picture on `ground`: each disc is (centre x, centre y, radius, colour), drawn in order.
    private func picture(ground: Colour, discs: [(Int, Int, Int, Colour)]) -> CGImage {
        let side = 256
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        func fill(_ colour: Colour) {
            context.setFillColor(CGColor(srgbRed: CGFloat(colour.red) / 255, green: CGFloat(colour.green) / 255, blue: CGFloat(colour.blue) / 255, alpha: 1))
        }
        fill(ground)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        for (x, y, radius, colour) in discs {
            fill(colour)
            context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        return context.makeImage()!
    }

    /// The alpha of one pixel of `image`, from its top-left.
    private func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels[(y * image.width + x) * 4 + 3]
    }

    @Test("A cover on a flat ground comes back as the subject alone: square, cropped to it, ground clear")
    func cutsTheGroundAndCrops() throws {
        // A disc of 40 points well off the middle of a cream square.
        let bare = try #require(NotebookCoverCutout.bare(picture(ground: Self.cream, discs: [(80, 170, 40, Self.navy)])))
        #expect(bare.width == bare.height, "square, so every place draws it the same way")
        #expect((80...100).contains(bare.width), "the disc's 81 points and a little room, not the 256 it was drawn in (\(bare.width))")
        #expect(alpha(bare, x: 0, y: 0) == 0 && alpha(bare, x: bare.width - 1, y: bare.height - 1) == 0, "the corners are ground")
        #expect(alpha(bare, x: bare.width / 2, y: bare.height / 2) == 255, "the subject is opaque")
    }

    @Test("A pale part inside the subject stays: only ground that reaches the border goes")
    func keepsAnEnclosedPaleRegion() throws {
        let ring = picture(ground: Self.cream, discs: [(128, 128, 60, Self.navy), (128, 128, 30, Self.cream)])
        let bare = try #require(NotebookCoverCutout.bare(ring))
        #expect(alpha(bare, x: 0, y: 0) == 0)
        #expect(alpha(bare, x: bare.width / 2, y: bare.height / 2) == 255, "the ring's inside is still drawn")
    }

    @Test("A white tile on a cream ground goes with it, and a coloured tile stays")
    func tiles() throws {
        let white = Colour(red: 255, green: 255, blue: 255)
        let onWhite = try #require(NotebookCoverCutout.bare(picture(ground: Self.cream, discs: [(128, 128, 100, white), (128, 128, 40, Self.navy)])))
        #expect((80...100).contains(onWhite.width), "cropped to the navy disc, not the white tile (\(onWhite.width))")
        let teal = Colour(red: 40, green: 130, blue: 140)
        let onTeal = try #require(NotebookCoverCutout.bare(picture(ground: Self.cream, discs: [(128, 128, 100, teal), (128, 128, 40, white)])))
        #expect(onTeal.width > 190, "the coloured tile is part of the icon (\(onTeal.width))")
    }

    @Test("A picture whose border is not one flat colour is left as drawn")
    func leavesAGradientGround() throws {
        let side = 256
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: [CGColor(srgbRed: 0.1, green: 0.2, blue: 0.5, alpha: 1), CGColor(srgbRed: 0.9, green: 0.7, blue: 0.3, alpha: 1)] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: 0), options: [])
        #expect(NotebookCoverCutout.bare(context.makeImage()!) == nil)
    }

    @Test("A subject that would vanish on a light window, or nothing at all, is left as drawn")
    func leavesWhatCannotBeSeen() {
        let blue = Colour(red: 70, green: 140, blue: 200)
        let white = Colour(red: 255, green: 255, blue: 255)
        #expect(NotebookCoverCutout.bare(picture(ground: blue, discs: [(128, 128, 60, white)])) == nil, "a white glyph on a blue tile")
        #expect(NotebookCoverCutout.bare(picture(ground: Self.cream, discs: [])) == nil, "an empty ground")
    }

    @Test("A cover is asked for on pure white with no tile, so the cut leaves the icon alone")
    func promptAsksForNoGround() {
        let prompt = ImageGenerationCatalog.notebookCoverPrompt(title: "🧬 Cells", instructions: nil, summary: nil, topic: nil)
        #expect(prompt.contains("pure white background") && prompt.contains("no tile"))
        #expect(prompt.contains("fills most of the frame"))
        #expect(!prompt.contains("app icon") && !prompt.contains("background colour") && !prompt.contains("gradient background") && !prompt.contains("pale solid background"), "nothing asks for a ground")
    }

    @Test("A cover is drawn as an emoji, whatever the Images style")
    func promptAsksForAnEmoji() {
        let prompt = ImageGenerationCatalog.notebookCoverPrompt(title: "🧬 Cells", instructions: nil, summary: nil, topic: nil)
        #expect(prompt.hasPrefix("An emoji for a research notebook."))
        #expect(prompt.contains(ImageGenerationCatalog.notebookCoverEmojiStyle))
        #expect(!prompt.contains("Flat vector emblem") && !prompt.contains("line art"))
    }
}
