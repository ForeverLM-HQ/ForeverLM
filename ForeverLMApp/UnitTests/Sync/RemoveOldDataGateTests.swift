import Foundation
import Testing
@testable import ForeverLM

/// A fake of the importer's side of the removal (WP16b owns the real one): the facts it reads, what a
/// final pass finds, and every call the removal makes on it.
actor FakeOldContainerImporter: OldContainerImporting {
    var current: OldContainerImportFacts
    var passResult: Result<OldContainerFinalPass, Error> = .success(.quiet)
    private(set) var calls: [String] = []
    private(set) var restartedAt: Date?
    private(set) var removedAt: Date?

    struct PassFailure: Error, LocalizedError { var errorDescription: String? { "the pass failed" } }

    init(_ facts: OldContainerImportFacts) { current = facts }

    func setPass(_ result: Result<OldContainerFinalPass, Error>) { passResult = result }
    func facts() async throws -> OldContainerImportFacts { current }

    func runFinalPass() async throws -> OldContainerFinalPass {
        calls.append("pass")
        return try passResult.get()
    }

    /// What the real importer does: the quiet stretch starts over at `date`.
    func restartQuietWait(at date: Date) async throws {
        calls.append("restart")
        restartedAt = date
        current.finishedAt = nil
        current.quietSince = date
    }

    func recordRemoval(at date: Date) async throws {
        calls.append("removed")
        removedAt = date
        current.removedAt = date
    }

    func answer(_ question: OldContainerImportFacts.Question, _ answer: ImportQuestionAnswer) async throws {
        calls.append("answer \(answer.rawValue)")
        current.question = nil
    }
}

/// "Remove old iCloud data" (docs/cloudkit-schema-design.md §13.8, R3-m13, R6-m12): disabled until late
/// import is quiet for 7 days, parity is clean and the learner confirms; a final pass that finds a write
/// aborts the removal and restarts the wait; the dialog names every old record still waiting.
@Suite("Remove old data gate", .serialized)
struct RemoveOldDataGateTests {
    private static let day: TimeInterval = 86_400
    private static let now = Date(timeIntervalSinceReferenceDate: 812_000_000)
    private static let user = "alice"
    /// The old container's identifier, as FakeCloudKit names it.
    private static let oldContainerID = FakeCloudKit.legacyContainer

    private static func quietFacts(days: Double = 8, finished: Bool = true) -> OldContainerImportFacts {
        OldContainerImportFacts(
            lastOldZoneWriteAt: now.addingTimeInterval(-days * day - 3_600),
            quietSince: now.addingTimeInterval(-days * day),
            finishedAt: finished ? now.addingTimeInterval(-(days - 7) * day) : nil
        )
    }

    private static let cleanParity = ByteParityReport(checked: 3, newSatellites: 2, localFiles: 1)

    /// An old container holding `Knowledge`, two `Team-*` zones and a zone the removal must not touch.
    private static func oldContainer() -> (FakeCloudKit, FakeCloudKit.Transport) {
        let server = FakeCloudKit()
        for zone in ["Knowledge", "Team-one", "Team-two", "Scratch"] {
            server.put([], zone: zone, owner: user, container: Self.oldContainerID)
        }
        return (server, server.transport(user: user, container: Self.oldContainerID))
    }

    private static func removal(_ importer: FakeOldContainerImporter, _ transport: FakeCloudKit.Transport,
                                parity: ByteParityReport = cleanParity, at date: Date = now) -> OldContainerRemoval {
        OldContainerRemoval(importer: importer, parity: { parity }, oldContainer: transport, now: { date })
    }

    // MARK: The three conditions

    @Test("The gate stays closed until late import has been quiet for 7 days")
    func quietForSevenDays() {
        let evaluate = { (facts: OldContainerImportFacts?, now: Date) in
            OldContainerRemovalGate.evaluate(facts: facts, parity: Self.cleanParity, now: now)
        }
        #expect(evaluate(Self.quietFacts(days: 6.5, finished: false), Self.now).blockers == [.notQuiet(daysLeft: 1)])
        #expect(evaluate(Self.quietFacts(days: 3, finished: false), Self.now).blockers == [.notQuiet(daysLeft: 4)])
        #expect(!evaluate(Self.quietFacts(days: 8, finished: false), Self.now).isOpen, "the importer must have marked it finished")
        let seven = evaluate(Self.quietFacts(days: 7), Self.now)
        #expect(seven.isOpen)
        #expect(evaluate(Self.quietFacts(days: 7), Self.now.addingTimeInterval(-60)).blockers == [.notQuiet(daysLeft: 1)])
        var noQuietStart = Self.quietFacts()
        noQuietStart.quietSince = nil
        #expect(evaluate(noQuietStart, Self.now).blockers == [.notQuiet(daysLeft: 7)])
    }

    @Test("A parity report with anything missing keeps the gate closed, and so does a waiting question or no importer")
    func otherBlockers() {
        let missing = ByteParityReport.build(
            digests: [OldAssetDigest(sourceID: "a", title: "A paper", field: .pdf)], coverage: { _ in .missing }
        )
        #expect(OldContainerRemovalGate.evaluate(facts: Self.quietFacts(), parity: missing, now: Self.now).blockers == [.parityNotClean(missing: 1)])
        #expect(OldContainerRemovalGate.evaluate(facts: Self.quietFacts(), parity: nil, now: Self.now).blockers == [.parityNotClean(missing: 0)],
                "a report that could not be read is not clean")
        var asking = Self.quietFacts()
        asking.question = .init(pass: .importPass, deleting: 90, of: 100)
        #expect(OldContainerRemovalGate.evaluate(facts: asking, parity: Self.cleanParity, now: Self.now).blockers == [.questionWaiting])
        #expect(OldContainerRemovalGate.evaluate(facts: nil, parity: Self.cleanParity, now: Self.now).blockers == [.importUnavailable])
        var removed = Self.quietFacts()
        removed.removedAt = Self.now
        #expect(OldContainerRemovalGate.evaluate(facts: removed, parity: Self.cleanParity, now: Self.now).blockers == [.alreadyRemoved])
    }

    @Test("Without the learner's confirmation nothing runs: no pass, no deletion")
    func needsConfirmation() async {
        let (server, transport) = Self.oldContainer()
        let importer = FakeOldContainerImporter(Self.quietFacts())
        let result = await Self.removal(importer, transport).remove(confirmed: false)
        #expect(result == .notConfirmed)
        #expect(await importer.calls.isEmpty)
        #expect(server.zoneNames(owner: Self.user, container: Self.oldContainerID).count == 4)
    }

    @Test("A closed gate refuses even a confirmed removal, and runs no pass")
    func closedGateRefuses() async {
        let (server, transport) = Self.oldContainer()
        let importer = FakeOldContainerImporter(Self.quietFacts(days: 3, finished: false))
        let result = await Self.removal(importer, transport).remove(confirmed: true)
        #expect(result == .refused([.notQuiet(daysLeft: 4)]))
        #expect(await importer.calls.isEmpty)
        #expect(server.zoneNames(owner: Self.user, container: Self.oldContainerID).count == 4)
    }

    @Test("Ideas, research directions and skills only the old zones hold keep the gate closed, and an unreadable count does too (F12)")
    func uncarriedRecordsRefuse() async {
        let (server, transport) = Self.oldContainer()
        let records = [("idea-1", CloudKitSyncEntity.idea), ("dir-1", .researchDirection), ("skill-1", .skill), ("doc-1", .artifact)].map {
            CloudRecord(id: CloudRecordID($0.0, in: CloudZoneID("Knowledge")), recordType: $0.1.recordType)
        }
        server.put(records, zone: "Knowledge", owner: Self.user, container: Self.oldContainerID)
        let importer = FakeOldContainerImporter(Self.quietFacts())
        let removal = Self.removal(importer, transport)
        let judged = await removal.gate()
        #expect(judged.gate.blockers == [.notCarried(count: 3)], "three records no step of the move carries: \(judged.gate.blockers)")
        #expect(await removal.remove(confirmed: true) == .refused([.notCarried(count: 3)]))
        #expect(await importer.calls.isEmpty, "no pass runs and nothing is deleted")
        #expect(server.zoneNames(owner: Self.user, container: Self.oldContainerID).count == 4)

        #expect(OldContainerRemovalGate.evaluate(facts: Self.quietFacts(), parity: Self.cleanParity, notCarried: nil, now: Self.now).blockers == [.oldZonesUnreadable])
    }

    // MARK: The final pass

    @Test("A quiet final pass lets the old Knowledge and Team zones go, and nothing else, and records it")
    func quietPassRemoves() async {
        let (server, transport) = Self.oldContainer()
        let importer = FakeOldContainerImporter(Self.quietFacts())
        let result = await Self.removal(importer, transport).remove(confirmed: true)
        #expect(result == .removed(zones: ["Knowledge", "Team-one", "Team-two"]))
        #expect(server.zoneNames(owner: Self.user, container: Self.oldContainerID) == ["Scratch"])
        #expect(await importer.calls == ["pass", "removed"], "the pass runs before any deletion")
        #expect(await importer.removedAt == Self.now)
        // The new container is never touched.
        #expect(server.zoneNames(owner: Self.user).isEmpty)
    }

    @Test("A final pass that finds an old-zone write aborts the removal, keeps every zone and restarts the 7-day wait")
    func foundWriteAbortsAndRestartsTheWait() async {
        let (server, transport) = Self.oldContainer()
        let importer = FakeOldContainerImporter(Self.quietFacts())
        await importer.setPass(.success(.foundWrites(count: 2)))
        let result = await Self.removal(importer, transport).remove(confirmed: true)
        #expect(result == .aborted(.oldZoneWrites(count: 2)))
        #expect(server.zoneNames(owner: Self.user, container: Self.oldContainerID).count == 4, "nothing was deleted")
        #expect(await importer.calls == ["pass", "restart"])
        #expect(await importer.restartedAt == Self.now)

        // The wait starts again: a week later less a minute the gate is still shut, a week later it opens.
        let facts = await importer.current
        let early = OldContainerRemovalGate.evaluate(facts: facts, parity: Self.cleanParity, now: Self.now.addingTimeInterval(7 * Self.day - 60))
        #expect(!early.isOpen)
        var finished = facts
        finished.finishedAt = Self.now.addingTimeInterval(7 * Self.day)
        #expect(OldContainerRemovalGate.evaluate(facts: finished, parity: Self.cleanParity, now: Self.now.addingTimeInterval(7 * Self.day)).isOpen)
        #expect(!OldContainerRemovalGate.evaluate(facts: facts, parity: Self.cleanParity, now: Self.now.addingTimeInterval(7 * Self.day)).isOpen,
                "until the importer marks it finished again")
    }

    @Test("A final pass that asks the 5% question, or fails, deletes nothing and starts no new wait")
    func questionOrFailureDeletesNothing() async {
        let (server, transport) = Self.oldContainer()
        let asking = FakeOldContainerImporter(Self.quietFacts())
        await asking.setPass(.success(.asksQuestion))
        #expect(await Self.removal(asking, transport).remove(confirmed: true) == .aborted(.guardQuestion))
        #expect(await asking.calls == ["pass"])

        let failing = FakeOldContainerImporter(Self.quietFacts())
        await failing.setPass(.failure(FakeOldContainerImporter.PassFailure()))
        #expect(await Self.removal(failing, transport).remove(confirmed: true) == .aborted(.passFailed("the pass failed")))
        #expect(await failing.calls == ["pass"])
        #expect(server.zoneNames(owner: Self.user, container: Self.oldContainerID).count == 4)
    }

    @Test("Facts that changed between the dialog and the confirmation are judged again")
    func judgedAgainAtConfirmation() async {
        let (server, transport) = Self.oldContainer()
        let importer = FakeOldContainerImporter(Self.quietFacts())
        let removal = Self.removal(importer, transport)
        #expect(await removal.gate().gate.isOpen)
        // An old build wrote meanwhile and the importer's poll saw it.
        try? await importer.restartQuietWait(at: Self.now)
        let result = await removal.remove(confirmed: true)
        #expect(result == .refused([.notQuiet(daysLeft: 7)]))
        #expect(server.zoneNames(owner: Self.user, container: Self.oldContainerID).count == 4)
    }

    @Test("A deletion iCloud refuses is a failure, and records no removal")
    func failedDeletion() async {
        let (server, transport) = Self.oldContainer()
        let importer = FakeOldContainerImporter(Self.quietFacts())
        server.failNext(.modifyZones, container: Self.oldContainerID, with: CloudError(.networkUnavailable, message: "offline"))
        let result = await Self.removal(importer, transport).remove(confirmed: true)
        if case .failed = result {} else { Issue.record("expected a failure, got \(result)") }
        #expect(await importer.removedAt == nil)
        #expect(server.zoneNames(owner: Self.user, container: Self.oldContainerID).count == 4)
    }

    // MARK: The dialog

    @Test("The dialog names the last old-zone activity, every old record still waiting and every old asset nothing covers")
    func dialogNamesWhatRemains() async {
        let (_, transport) = Self.oldContainer()
        var facts = Self.quietFacts()
        facts.waiting = [
            .init(recordName: "rec-1", title: "A meeting series' attachments", since: Self.now.addingTimeInterval(-9 * Self.day)),
            .init(recordName: "rec-2", title: nil, since: nil),
        ]
        facts.keptRemovals = [.init(id: "k1", what: "A deleted card", at: nil)]
        facts.notApplied = [.init(id: "n1", what: "A value dropped after 30 days", at: nil), .init(id: "n2", what: "Another", at: nil)]
        let importer = FakeOldContainerImporter(facts)
        let parity = ByteParityReport.build(
            digests: [OldAssetDigest(sourceID: "s1", title: "Zebra paper", field: .pdf), OldAssetDigest(sourceID: "s2", title: "Alpha paper", field: .readerHTML),
                      OldAssetDigest(sourceID: "s2", title: "Alpha paper", field: .content)],
            coverage: { _ in .missing }
        )
        let dialog = await Self.removal(importer, transport, parity: parity).dialog(facts: facts, parity: parity)
        #expect(dialog.lastOldZoneWriteAt == facts.lastOldZoneWriteAt)
        #expect(dialog.waiting.map { $0.recordName } == ["rec-1", "rec-2"])
        #expect(dialog.missingTitles == ["Alpha paper", "Zebra paper"], "by title, once each")
        #expect(dialog.keptRemovals == 1)
        #expect(dialog.notApplied == 2)
        #expect(dialog.zones == ["Knowledge", "Team-one", "Team-two"])
        #expect(!dialog.remainsNothing)
    }

    @Test("The removable zones are the learner's own Knowledge and Team zones, never a zone someone else owns")
    func removableZones() {
        let zones = [
            CloudZoneID("Knowledge"), CloudZoneID("Team-1"), CloudZoneID("Team-2", ownerName: "someone-else"),
            CloudZoneID("Library"), CloudZoneID("Scratch"), CloudZoneID("Tasks"), CloudZoneID("Teams"),
        ]
        #expect(OldContainerRemoval.removableZoneNames(zones).map(\.description) == ["Knowledge", "Team-1"])
    }
}

/// The byte parity report (§13.4 P4b, §13.8): an old asset is covered by a new satellite, by a local
/// file on this Mac or by a FileRef that names the Mac holding it.
@Suite("Byte parity report")
struct ByteParityReportTests {
    private let digests = [
        OldAssetDigest(sourceID: "paper-1", title: "Paper one", field: .pdf),
        OldAssetDigest(sourceID: "paper-2", title: "Paper two", field: .pdf),
        OldAssetDigest(sourceID: "paper-3", title: "Paper three", field: .pdf),
        OldAssetDigest(sourceID: "book-1", title: "A book", field: .pdf),
        OldAssetDigest(sourceID: "paper-1", title: "Paper one", field: .content),
        OldAssetDigest(sourceID: "show-1", title: "An episode", field: .rawTTML),
        OldAssetDigest(sourceID: "chap-1", title: "A chapter", field: .readerHTML),
    ]

    private func inputs(satellites: Set<ByteParityInputs.SatelliteKey> = [], local: Set<String> = [], held: [ByteParityInputs.SatelliteKey: String] = [:]) -> ByteParityInputs {
        ByteParityInputs(
            digests: digests, satellites: satellites,
            localFile: { local.contains("\($0.sourceID)/\($0.field.rawValue)") },
            heldBy: { held[$0] }
        )
    }

    @Test("Every old asset needs a new satellite, a local file or a named holder, and what has none is listed by title")
    func coverage() {
        let report = inputs(
            satellites: [.init(owner: "paper-1", role: "pdf"), .init(owner: "paper-1", role: "text"), .init(owner: "book-1", role: "epub")],
            local: ["paper-2/sourcePDFAsset", "show-1/podcastRawTTMLAsset"],
            held: [.init(owner: "chap-1", role: "readerHTML"): "Robin's MacBook"]
        ).report()
        #expect(report.checked == 7)
        #expect(report.newSatellites == 3, "a book's original is its epub satellite")
        #expect(report.localFiles == 2)
        #expect(report.heldByOtherMacs == 1)
        #expect(report.missing.map(\.title) == ["Paper three"])
        #expect(!report.isClean)
    }

    @Test("A report with every asset covered is clean, and an empty library is clean")
    func clean() {
        let all = Set(digests.flatMap { digest in digest.field.satelliteRoles.map { ByteParityInputs.SatelliteKey(owner: digest.sourceID, role: $0) } })
        #expect(inputs(satellites: all).report().isClean)
        #expect(ByteParityReport.build(digests: [], coverage: { _ in .missing }).isClean)
    }

    @Test("A satellite of another role does not cover an asset")
    func roleMustMatch() {
        let report = inputs(satellites: [.init(owner: "paper-1", role: "thumbnail"), .init(owner: "paper-2", role: "text")]).report()
        #expect(report.missing.contains { $0.sourceID == "paper-1" && $0.field == .pdf })
        #expect(report.missing.contains { $0.sourceID == "paper-2" && $0.field == .pdf })
    }

    @Test("The titles a line lists are unique, sorted, and cut with a count of the rest")
    func titles() {
        let report = ByteParityReport.build(
            digests: (1...8).map { OldAssetDigest(sourceID: "s\($0)", title: "T\($0)", field: .pdf) } + [OldAssetDigest(sourceID: "s1", title: "T1", field: .content)],
            coverage: { _ in .missing }
        )
        let titles = report.titles(limit: 5)
        #expect(titles.shown == ["T1", "T2", "T3", "T4", "T5"])
        #expect(titles.more == 3)
    }

    @Test("The local-file check follows a stored path, the archived article, canonical text and raw TTML")
    func localFacts() {
        let facts = ByteParityLocalFacts(
            paths: ["paper": ["Papers/a.pdf"], "chapter": ["Books/c.xhtml"]],
            sourcesWithContent: ["article"], sourcesWithRawTTML: ["episode"]
        )
        let exists: (String) -> Bool = { $0 == "Papers/a.pdf" || $0.hasSuffix("/chapter/article.html") }
        #expect(facts.holds(OldAssetDigest(sourceID: "paper", title: "", field: .pdf), fileExists: exists))
        #expect(facts.holds(OldAssetDigest(sourceID: "chapter", title: "", field: .readerHTML), fileExists: exists), "an archived article's page")
        #expect(!facts.holds(OldAssetDigest(sourceID: "chapter", title: "", field: .pdf), fileExists: exists))
        #expect(facts.holds(OldAssetDigest(sourceID: "article", title: "", field: .content), fileExists: exists))
        #expect(!facts.holds(OldAssetDigest(sourceID: "paper", title: "", field: .content), fileExists: exists))
        #expect(facts.holds(OldAssetDigest(sourceID: "episode", title: "", field: .rawTTML), fileExists: exists))
    }
}
