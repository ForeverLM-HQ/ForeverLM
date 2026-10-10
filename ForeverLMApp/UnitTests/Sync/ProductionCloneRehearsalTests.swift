import CloudKit
import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// WP28's scale run on a copy of a real library, with no network (docs/cloudkit-schema-design.md §13.3, §13.4,
/// §14 WP28 step 1; the runbook is docs/cutover-rehearsal.md).
///
/// Skipped unless `FOREVERLM_REHEARSAL_STORE` names a folder holding a copy of a generation-1 `knowledge.db`
/// (the orchestrator passes it to the test host as `TEST_RUNNER_FOREVERLM_REHEARSAL_STORE`). When it runs, it
/// does to an APFS clone of that copy (`rehearsal-run/`, beside it) what build N does on the product owner's Mac at T0:
/// the generation-2 open (the rollback copy, then the pending migrations), the activation as
/// `GenerationActivationRunner` runs it, the backfills `MacSyncSession` drains, the zone bootstrap and every
/// pass of `CutoverSeeder` into a FakeCloudKit library container, until the root says the seed is
/// complete. It reports what it found to `rehearsal-report.json` beside the copy, and prints a summary.
///
/// The copy's generation-1 sync history (`sync_metadata`, `sync_changes`, `sync_asset_digests`) describes the
/// old container's Production environment, which nothing here can read: the old container this run gets holds
/// no records, so a `full` activation's catch-up would find no `Knowledge` zone (or trip the 5% guard). As
/// WP28's scale run prescribes (R3-x1), the clone's history is emptied first and the seed runs under the
/// rehearsal override (`FOREVERLM_REHEARSAL_SEED_LOCAL`): a `fresh` activation that asks nothing of the old
/// container, seeded as a brand-new account's library. Satellites are planned and measured, never uploaded.
///
/// It reads only the copy and the folders named beside it; never the Mac's Application Support, iCloud Drive
/// or CloudKit.
@Suite("Production clone rehearsal", .serialized,
       .enabled(if: RehearsalPaths.configured != nil, "FOREVERLM_REHEARSAL_STORE names no copy of a library"))
struct ProductionCloneRehearsalTests {
    @Test("A copy of a real generation-1 library opens as generation 2, activates and seeds a fake new container to complete")
    func rehearse() async throws {
        let paths = try #require(RehearsalPaths.configured)
        if let refusal = paths.refusal() {
            Issue.record("The rehearsal refuses to run: \(refusal)")
            return
        }
        let report = RehearsalReport(paths: paths)
        let run = RehearsalRun(paths: paths, report: report)
        let previousUnderstandingRoot = KnowledgeStore.understandingRootOverride
        defer { KnowledgeStore.understandingRootOverride = previousUnderstandingRoot }
        do {
            try await run.perform()
        } catch {
            report.set("error", String(describing: error))
            report.write()
            report.printSummary()
            throw error
        }
        report.write()
        report.printSummary()
        run.assertOutcome()
    }
}

/// The rehearsal's folders: what the variables name, what it refuses, and how a stored path is found in the
/// copy without naming anything outside it. Runs everywhere, with no copy.
@Suite("Production clone rehearsal paths")
struct ProductionCloneRehearsalPathTests {
    private static func paths(_ folder: URL, content: Bool = true) throws -> RehearsalPaths {
        let copy = folder.appendingPathComponent("appdata", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        if content { try FileManager.default.createDirectory(at: folder.appendingPathComponent("Content", isDirectory: true), withIntermediateDirectories: true) }
        return try #require(RehearsalPaths.from(["FOREVERLM_REHEARSAL_STORE": copy.path]))
    }

    @Test("No variable, no rehearsal; the folders beside the copy are found, and the run and the report go beside it")
    func environment() throws {
        #expect(RehearsalPaths.from([:]) == nil)
        #expect(RehearsalPaths.from(["FOREVERLM_REHEARSAL_STORE": "  "]) == nil)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rehearsal-env-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let paths = try Self.paths(folder)
        #expect(paths.content?.lastPathComponent == "Content")
        #expect(paths.understanding == nil && paths.audio == nil, "an optional folder that is not there is not named")
        #expect(paths.run.deletingLastPathComponent().path == paths.copy.deletingLastPathComponent().path)
        #expect(paths.report.lastPathComponent == "rehearsal-report.json")
        #expect(paths.refusal() != nil, "a copy without knowledge.db is refused")
        try Data().write(to: paths.copy.appendingPathComponent("knowledge.db"))
        #expect(paths.refusal() == nil)
    }

    @Test("A copy inside the Mac's Application Support or iCloud Drive is refused")
    func refusesTheMacsOwnFolders() throws {
        let support = NSHomeDirectory() + "/Library/Application Support/ForeverLM/.appdata"
        let inSupport = try #require(RehearsalPaths.from(["FOREVERLM_REHEARSAL_STORE": support]))
        #expect(inSupport.refusal()?.contains("is inside") == true)
        let drive = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/Documents/ForeverLM"
        let inDrive = try #require(RehearsalPaths.from(["FOREVERLM_REHEARSAL_STORE": "/tmp/rehearsal/appdata", "FOREVERLM_REHEARSAL_UNDERSTANDING": drive]))
        #expect(inDrive.refusal()?.contains("is inside") == true)
    }

    @Test("A stored path is found in the copy's Content: relative, absolute on any Mac, or under an old iCloud root; an address or an outside file is not")
    func locatesStoredPaths() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rehearsal-locate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let paths = try Self.paths(folder)
        let content = try #require(paths.content)
        func located(_ stored: String) -> String? { paths.locate(storedPath: stored).map { String($0.path.dropFirst(content.path.count + 1)) } }
        #expect(located("Papers/A.pdf") == "Papers/A.pdf")
        #expect(located("ForeverLM/Papers/A.pdf") == "Papers/A.pdf")
        #expect(located("/Users/someone/Library/Application Support/ForeverLM/Content/Papers/A.pdf") == "Papers/A.pdf")
        #expect(located("/Users/someone/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM 2/Books/B.epub") == "Books/B.epub")
        let retired = LegacyIdentityAdoption.retiredProductFolderName
        #expect(located("/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/Documents/\(retired)/Papers/C.pdf") == "Papers/C.pdf")
        #expect(located("https://example.org/a.pdf") == nil)
        #expect(located("/Users/someone/Downloads/D.pdf") == nil, "a file outside every content root is not in the copy")
        #expect(located("../outside.pdf") == nil)
        #expect(paths.isInside(content.appendingPathComponent("Papers/A.pdf")))
        #expect(!paths.isInside(URL(fileURLWithPath: "/Users/someone/Library/Application Support/ForeverLM/Content/Papers/A.pdf")))
        let noContent = try Self.paths(folder.appendingPathComponent("other", isDirectory: true), content: false)
        #expect(noContent.locate(storedPath: "Papers/A.pdf") == nil, "with no Content copy nothing is found")
    }

    @Test("A narration's position file is looked for in the copy's Audio folder, by iCloud Drive's layout")
    func narrationInTheCopy() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rehearsal-audio-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Audio", isDirectory: true), withIntermediateDirectories: true)
        let paths = try Self.paths(folder)
        let url = try #require(paths.narrationPosition(sourceID: "src-1"))
        #expect(url.path.hasPrefix(folder.appendingPathComponent("Audio").path + "/"))
        #expect(url.lastPathComponent == ArticleSpeechPlaybackPosition.fileName)
    }
}

/// What the rehearsal counts as owed (`RehearsalRun.expectedRecords`, `RehearsalRun.outboxLeftovers`), on
/// small stores. Runs everywhere, with no copy. Run 1 on the production copy counted 7,702 Marks as missing
/// that were never on, and 57 outbox rows that wait for a space as left over.
@Suite("Production clone rehearsal accounting")
struct ProductionCloneRehearsalAccountingTests {
    private typealias F = NotebookSyncFixture

    @Test("A Mark the rows never turned on is no record: the parity expects exactly the Marks the feeder sends")
    func neverOnMarksAreNoRecords() throws {
        let (root, store) = try F.makeStore("rehearsal-marks")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addSource(store, "src-a")
        try MarkProjectionTests.addVideo(store, "src-vid")
        try MarkProjectionTests.addVideo(store, "src-liked", likedAt: 700_000_000, origin: "youtubePlaylist")
        try store.execute("""
            INSERT INTO source_ideas (id, source_id, statement, recall_note, wanted, content_hash, created_at, updated_at)
            VALUES ('idea-on', 'src-a', 'Wanted', 'note', 1, 'h1', 1, 8000), ('idea-off', 'src-a', 'Not wanted', 'note', 0, 'h2', 1, 8000)
        """)
        try store.execute("""
            INSERT INTO video_cited_papers (id, source_id, title, status, imported_source_id, created_at, updated_at)
            VALUES ('cand-imported', 'src-vid', 'Imported', 'imported', 'src-a', 1, 9000), ('cand-pending', 'src-vid', 'Pending', 'pending', NULL, 1, 9000)
        """)

        let expected = try RehearsalRun.expectedRecords(store)
        let marks = expected.records[SyncRecordType.mark.rawValue] ?? []
        #expect(marks.contains("mk:wantIdea:src:src-a#idea-on") && !marks.contains("mk:wantIdea:src:src-a#idea-off"))
        #expect(marks.contains("mk:citedDecision:src:src-vid#cand-imported") && !marks.contains("mk:citedDecision:src:src-vid#cand-pending"))
        #expect(marks.contains("mk:liked:src:src-liked") && !marks.contains("mk:liked:src:src-vid"))
        #expect(marks.contains("mk:provenance:src:src-liked") && !marks.contains("mk:provenance:src:src-vid"))
        let neverOn = expected.neverOnMarks[SyncRecordType.mark.rawValue] ?? [:]
        #expect(neverOn["wantIdea"] == 1 && neverOn["citedDecision"] == 1 && neverOn["liked"] == 1)
        #expect(neverOn["provenance"] == 2, "the article and the video with no discovery origin")

        let sent = Set(try F.pending(store).keys.filter { $0.hasPrefix("Mark:") }.map { String($0.dropFirst("Mark:".count)) })
        #expect(sent == marks, "the feeder sends exactly the Marks the parity expects")
    }

    @Test("An outbox row that feeds a space's copy waits for SpaceSync and is not a leftover of the private seed")
    func spaceRowsAreP6s() throws {
        let (root, store) = try F.makeStore("rehearsal-outbox")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addSource(store, "src-p")
        // A team's copy of it, which the activation filed in the team's space.
        try store.execute("""
            INSERT INTO sources (id, date_added, state, source_type, status, team_id, wire_id) VALUES ('src-t', 1, 'ready', 'article', 'active', 'team-1', 'src-p')
        """)
        try store.execute("""
            INSERT INTO articles (source_id, url, normalized_url, title, domain)
            VALUES ('src-t', 'https://example.com/src-p', 'example.com/src-p', 'Title src-p', 'example.com')
        """)
        try store.execute("INSERT INTO ck_identity (zone_key, record_type, wire_id, local_id) VALUES ('private/Space-team-1', 'Source', 'src-p', 'src-t')")
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_outbox_fields WHERE source_table = 'articles'") == 2)

        let leftovers = try RehearsalRun.outboxLeftovers(store)
        #expect(leftovers.spaceRows["articles"] == 1, "the team copy's row: its Source is the space's")
        #expect(leftovers.privateRows["articles"] == 1, "the personal copy's row is the private engine's")
    }
}

// MARK: - Where the copy is

/// The copy and the folders beside it (docs/cutover-rehearsal.md): `FOREVERLM_REHEARSAL_STORE` holds
/// `knowledge.db`; the content folders are `FOREVERLM_REHEARSAL_ROOT` (default `<store>/../Content`), the
/// Understanding documents `FOREVERLM_REHEARSAL_UNDERSTANDING` (default `<store>/../Understanding`) and the
/// narration folders `FOREVERLM_REHEARSAL_AUDIO` (default `<store>/../Audio`), each optional.
struct RehearsalPaths: Sendable {
    let copy: URL
    let content: URL?
    let understanding: URL?
    let audio: URL?
    /// The working clone the rehearsal migrates, activates and seeds; the copy itself is never written.
    let run: URL
    let report: URL

    static let runMarker = ".foreverlm-rehearsal-run"

    static var configured: RehearsalPaths? { from(ProcessInfo.processInfo.environment) }

    static func from(_ environment: [String: String]) -> RehearsalPaths? {
        guard let raw = environment["FOREVERLM_REHEARSAL_STORE"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let copy = folder(raw)
        let parent = copy.deletingLastPathComponent()
        func optional(_ key: String, _ name: String) -> URL? {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return folder(value) }
            let candidate = parent.appendingPathComponent(name, isDirectory: true)
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
        return RehearsalPaths(
            copy: copy, content: optional("FOREVERLM_REHEARSAL_ROOT", "Content"),
            understanding: optional("FOREVERLM_REHEARSAL_UNDERSTANDING", "Understanding"), audio: optional("FOREVERLM_REHEARSAL_AUDIO", "Audio"),
            run: parent.appendingPathComponent("rehearsal-run", isDirectory: true), report: parent.appendingPathComponent("rehearsal-report.json")
        )
    }

    private static func folder(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    /// The folders a rehearsal never reads or writes: the Mac's own libraries, iCloud Drive, app containers.
    static var forbiddenRoots: [String] {
        let home = NSHomeDirectory()
        var roots = [home + "/Library/Application Support", home + "/Library/Mobile Documents", home + "/Library/Containers"]
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.standardizedFileURL.path {
            roots.append(support)
        }
        return roots
    }

    /// Why the rehearsal must not run on these folders, or nil.
    func refusal() -> String? {
        for url in [copy, content, understanding, audio, run].compactMap({ $0 }) {
            let path = url.path
            if let root = Self.forbiddenRoots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                return "\(path) is inside \(root); copy the library somewhere of its own first (docs/cutover-rehearsal.md)"
            }
        }
        guard FileManager.default.fileExists(atPath: copy.appendingPathComponent("knowledge.db").path) else {
            return "\(copy.path) holds no knowledge.db"
        }
        if run.path == copy.path { return "the working clone would be the copy itself" }
        return nil
    }

    /// The path of a stored source file inside the copy's content folder, from the shapes a library stores:
    /// relative to the content root, or absolute under a ForeverLM content root on any Mac. Nil for a file the
    /// copy cannot hold (an address, a file outside every content root); nothing outside the copy is named.
    func locate(storedPath path: String) -> URL? {
        guard let content, !path.contains("://"), !path.isEmpty else { return nil }
        let relative: String?
        if path.hasPrefix("/") {
            relative = Self.relativeToContentRoot(absolute: path)
        } else {
            relative = StorageService.relativeSourcePath(path)
        }
        guard let relative, !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return nil }
        return content.appendingPathComponent(relative)
    }

    static func relativeToContentRoot(absolute path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        let retired = NSRegularExpression.escapedPattern(for: LegacyIdentityAdoption.retiredProductFolderName)
        let rootName = "^(ForeverLM|\(retired))( Dev| First Run)?( [0-9]+)?$"
        for index in parts.indices.dropFirst() {
            guard parts[index].range(of: rootName, options: .regularExpression) != nil else { continue }
            if parts[index - 1] == "Documents", index + 1 < parts.count {
                return parts[(index + 1)...].joined(separator: "/")
            }
            if parts[index - 1] == "Application Support", index + 2 < parts.count, parts[index + 1] == "Content" {
                return parts[(index + 2)...].joined(separator: "/")
            }
        }
        return nil
    }

    /// A narration's `playback-position.json` in the copy of the narration folders, by the same layout iCloud
    /// Drive keeps (the path is computed, nothing under iCloud Drive is read).
    func narrationPosition(sourceID: String) -> URL? {
        guard let audio else { return nil }
        let root = SyncedArticleAudioStore.ubiquityAudioRootURL().path
        let full = SyncedArticleAudioStore.ubiquityPlaybackPositionURL(sourceID: sourceID).path
        guard full.hasPrefix(root + "/") else { return nil }
        return audio.appendingPathComponent(String(full.dropFirst(root.count + 1)))
    }

    /// Whether `url` is inside the copy's folders or the working clone: the only places a stat may look.
    func isInside(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return [content, understanding, audio, run].compactMap({ $0?.path }).contains { path.hasPrefix($0 + "/") }
    }
}

// MARK: - The run

/// The rehearsal's steps, each timed into the report.
final class RehearsalRun: @unchecked Sendable {
    let paths: RehearsalPaths
    let report: RehearsalReport
    static let account = "rehearsal"
    static let deviceID = "rehearse"
    /// The engine's clock runs ahead of the wall clock by more than any debounce, so a row written just
    /// before a send is due (as `EngineTestDevice` does).
    static let ahead: TimeInterval = 5
    static let clock: @Sendable () -> Date = { Date().addingTimeInterval(RehearsalRun.ahead) }

    private(set) var journal: ActivationJournal?
    private(set) var seedOutcomes: [CutoverSeedOutcome] = []
    private(set) var rootSeed: [String: SyncJSON] = [:]
    private(set) var copyIntegrity: String?
    private(set) var copyQuickCheck: String?
    private(set) var oldContainerCalls = -1
    private(set) var quarantined = 0
    private(set) var oversize = 0
    private(set) var outboxLeft: Int64 = -1
    private(set) var parityMissing = 0
    private(set) var bootstrapOutcome: ZoneBootstrap.Outcome?

    init(paths: RehearsalPaths, report: RehearsalReport) {
        self.paths = paths
        self.report = report
    }

    func perform() async throws {
        report.set("startedAt", ISO8601DateFormatter().string(from: Date()))
        report.set("paths", [
            "copy": paths.copy.path, "content": paths.content?.path ?? NSNull(), "understanding": paths.understanding?.path ?? NSNull(),
            "audio": paths.audio?.path ?? NSNull(), "workingClone": paths.run.path,
        ] as [String: Any])
        report.set("build", ["schemaVersion": Int(KnowledgeStore.schemaVersion), "schemaRevision": SyncSchema.schemaRevision] as [String: Any])

        try report.step("clone") { try self.makeWorkingClone() }
        try report.step("emptyGeneration1History") { try self.emptyGeneration1History() }

        // Nothing below reads the Mac's iCloud Drive: the Understanding documents and the narration positions
        // come from the copy's folders, or from nowhere.
        let understanding = paths.understanding ?? paths.run.appendingPathComponent("no-understanding", isDirectory: true)
        try FileManager.default.createDirectory(at: understanding, withIntermediateDirectories: true)
        KnowledgeStore.understandingRootOverride = understanding.path
        let paths = self.paths
        let probe: @Sendable ([String]) -> [String: ListenFileProbe] = { ids in
            var found: [String: ListenFileProbe] = [:]
            for id in ids {
                guard let url = paths.narrationPosition(sourceID: id), let probed = KnowledgeStore.probeListenFile(url) else { continue }
                found[id] = probed
            }
            return found
        }
        let missingFile = paths.run.appendingPathComponent("not-in-copy", isDirectory: true)
        let locate: @Sendable (String) -> URL = { stored in
            paths.locate(storedPath: stored) ?? missingFile.appendingPathComponent(SyncIdentity.sha256Hex(Data(stored.utf8)))
        }
        try await KnowledgeStore.$listenFileProbeOverride.withValue(probe) {
            try await KnowledgeStore.$sourceFileLocationOverride.withValue(locate) {
                try await self.rehearse()
            }
        }
    }

    // MARK: Step 0: the working clone, and the copy's generation-1 history

    private func makeWorkingClone() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: paths.run.path) {
            guard manager.fileExists(atPath: paths.run.appendingPathComponent(RehearsalPaths.runMarker).path) else {
                throw RehearsalError("\(paths.run.path) exists and is not a rehearsal's working clone; move it away first")
            }
            try manager.removeItem(at: paths.run)
        }
        try manager.createDirectory(at: paths.run, withIntermediateDirectories: true)
        try Data().write(to: paths.run.appendingPathComponent(RehearsalPaths.runMarker))
        // `copyItem` clones on APFS: instant, and the copy is never written.
        for name in ["knowledge.db", "knowledge.db-wal"] {
            let source = paths.copy.appendingPathComponent(name)
            guard manager.fileExists(atPath: source.path) else { continue }
            try manager.copyItem(at: source, to: paths.run.appendingPathComponent(name))
        }
        let size = (try? manager.attributesOfItem(atPath: paths.run.appendingPathComponent("knowledge.db").path)[.size] as? NSNumber)?.int64Value ?? 0
        report.set("copy", ["databaseBytes": size, "walCopied": manager.fileExists(atPath: paths.run.appendingPathComponent("knowledge.db-wal").path)] as [String: Any])
    }

    /// WP28 step 1 (R3-x1): the clone's sync history names the old container's Production records, so it is
    /// emptied (in the clone only) before the first generation-2 open. What it held is reported, and the old
    /// asset digests are kept for the byte parity report.
    private var oldAssetDigests: [OldAssetDigest] = []

    private func emptyGeneration1History() throws {
        let database = try RehearsalDatabase(paths.run.appendingPathComponent("knowledge.db").path)
        let version = Int(try database.scalar("PRAGMA user_version") ?? "0") ?? 0
        var history: [String: Any] = ["userVersion": version]
        var byEntity: [String: Int] = [:]
        if database.tableExists("sync_metadata") {
            for row in try database.rows("SELECT entity_type, COUNT(*) FROM sync_metadata WHERE system_fields IS NOT NULL GROUP BY entity_type") {
                byEntity[row[0] ?? "?"] = Int(row[1] ?? "0") ?? 0
            }
        }
        history["syncedRecordsByEntity"] = byEntity
        for table in ["sync_metadata", "sync_changes", "sync_asset_digests"] where database.tableExists(table) {
            history[table] = Int(try database.scalar("SELECT COUNT(*) FROM \(table)") ?? "0") ?? 0
        }
        if database.tableExists("sync_asset_digests"), database.tableExists("sync_metadata") {
            let fields = OldAssetField.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
            do {
                for row in try database.rows("""
                    SELECT m.logical_key, COALESCE(s.title, m.logical_key), d.field
                    FROM sync_asset_digests d
                    JOIN sync_metadata m ON m.record_name = d.record_name AND m.entity_type = 'source' AND m.is_deleted = 0
                    LEFT JOIN sources s ON s.id = m.logical_key
                    WHERE d.digest IS NOT NULL AND d.digest <> '-' AND d.field IN (\(fields))
                """) {
                    guard let id = row[0], let field = row[2].flatMap(OldAssetField.init(rawValue:)) else { continue }
                    oldAssetDigests.append(OldAssetDigest(sourceID: id, title: row[1] ?? id, field: field))
                }
            } catch {
                history["oldAssetDigestsError"] = String(describing: error)
            }
        }
        for table in ["sync_metadata", "sync_changes", "sync_asset_digests"] where database.tableExists(table) {
            try database.exec("DELETE FROM \(table)")
        }
        report.set("generation1History", history)
    }

    // MARK: Steps 1 to 4

    private func rehearse() async throws {
        let paths = self.paths
        let directory = paths.run
        let contentRoot = paths.content ?? directory.appendingPathComponent("no-content", isDirectory: true)
        try FileManager.default.createDirectory(at: contentRoot, withIntermediateDirectories: true)

        // Step 1: the generation-2 open takes the rollback copy, then runs the pending migrations (§13.3 step 1).
        let fromVersion = try RehearsalDatabase(directory.appendingPathComponent("knowledge.db").path).scalar("PRAGMA user_version")
        KnowledgeStoreOpening.startNewLaunchForTesting(databaseAt: directory.appendingPathComponent("knowledge.db").path)
        let store = try report.step("open") {
            try KnowledgeStore(
                storeDirectory: directory, contentDirectory: contentRoot, legacyContentDirectories: [],
                startupPreferenceSnapshot: [:], syncGeneration: .two
            )
        }
        GenerationActivationRunner.holdIfActivationMayBeFull(store)
        let toVersion = try store.scalarInteger("PRAGMA user_version")
        var copyFacts: [String: Any] = [
            "fromUserVersion": Int(fromVersion ?? "0") ?? 0, "toUserVersion": Int(toVersion ?? 0),
            "migrationsRun": (Int(fromVersion ?? "0") ?? 0) != Int(toVersion ?? 0),
            "note": "migrations run in one transaction inside the open; the open's time is the copy plus every pending migration",
        ]
        if let record = store.rollbackCopy {
            copyFacts["rollbackCopy"] = ["file": record.fileName, "method": record.method.rawValue, "userVersion": Int(record.userVersion)] as [String: Any]
        } else {
            copyFacts["rollbackCopyFailure"] = store.rollbackCopyFailure ?? "no copy was taken"
        }
        if let check = store.rollbackCopyCheck {
            let checked = await report.stepAsync("rollbackCopyQuickCheck") { await check.value }
            copyQuickCheck = checked.quickCheck
            copyFacts["quickCheck"] = checked.quickCheck ?? NSNull()
        }
        let copyURL = directory.appendingPathComponent(KnowledgeRollbackCopy.Kind.beforeGeneration2.fileName)
        if FileManager.default.fileExists(atPath: copyURL.path) {
            copyIntegrity = try report.step("rollbackCopyIntegrityCheck") {
                let copy = try RehearsalDatabase(copyURL.path, immutable: true)
                return try copy.rows("PRAGMA integrity_check").compactMap { $0.first ?? nil }.joined(separator: "; ")
            }
            copyFacts["integrityCheck"] = copyIntegrity ?? NSNull()
            copyFacts["copyUserVersion"] = Int(try RehearsalDatabase(copyURL.path, immutable: true).scalar("PRAGMA user_version") ?? "0") ?? 0
        }
        report.set("open", copyFacts)
        report.write()

        // Step 2: the activation, as `GenerationActivationLauncher` runs it, with an old container that holds
        // nothing (§13.3 step 3).
        let server = FakeCloudKit(start: Date())
        let oldContainer = server.transport(user: Self.account, container: FakeCloudKit.legacyContainer, device: "rehearsal-mac")
        let timings = DerivationTimings()
        var environment = ActivationEnvironment()
        environment.oldContainerTransport = oldContainer
        environment.status = ActivationStatus()
        environment.sleep = { _ in }
        environment.derivations = KnowledgeStore.activationDerivations.map { derivation in
            ActivationDerivation(id: derivation.id) { store in
                let started = ContinuousClock.now
                defer { timings.add(derivation.id, started.duration(to: .now).seconds) }
                try derivation.run(store)
            }
        }
        let runner = GenerationActivationRunner(access: DirectStoreAccess(store: store), environment: environment)
        let journal = try await report.stepAsync("activation") { try await runner.run() }
        self.journal = journal
        oldContainerCalls = oldContainer.calls.count
        report.set("activation", [
            "journal": Self.describe(journal), "derivationSeconds": timings.ordered, "oldContainerCalls": oldContainerCalls,
            "otherSeconds": max(0, (report.seconds["activation"] ?? 0) - timings.total),
            "note": "otherSeconds is the journal, the copy's record and the trigger install",
        ] as [String: Any])
        report.write()

        // Step 3: the new container. The zone bootstrap makes the root `seeding` with this Mac's claim, as a Mac
        // holding its library does; sends wait for the seeder (`holdSendsForSeed`) as `MacSyncSession.begin` has them.
        let local = MacPrivateSyncStore.direct(store)
        let transport = server.transport(user: Self.account, device: "rehearsal-mac")
        let oldForBootstrap = server.transport(user: Self.account, container: FakeCloudKit.legacyContainer, device: "rehearsal-mac")
        var pacing = SyncPacerState.Configuration()
        pacing.capacity = 1_000_000
        pacing.refillPerSecond = 1_000_000
        let pacer = SyncPacer(configuration: pacing)
        let moveMaps = MoveMapIndex()
        let engine = PrivateSyncEngine(transport: transport, store: local, pacer: pacer, moveMaps: moveMaps, deviceID: Self.deviceID, clock: Self.clock)
        let deviceID = Self.deviceID
        try report.step("claimOwnRows") {
            try store.claimOwnMemoryRows(deviceID: deviceID)
            _ = try CutoverPendingChanges.capture(in: store, registry: KnowledgeStore.projectionRegistry)
        }
        try await local.perform { try $0.replica.setEngineState(ReplicaStore.EngineScope.holdSendsForSeed, Data("wait".utf8)) }
        var bootstrap = ZoneBootstrap(transport: transport, legacyTransport: oldForBootstrap, store: local, client: .macHoldingLibrary, deviceID: deviceID)
        bootstrap.now = Self.clock
        Self.follow(server)
        bootstrapOutcome = try await report.stepAsync("bootstrap") { try await bootstrap.run() }
        try await report.stepAsync("firstRound") {
            Self.follow(server)
            try await engine.sync()
        }
        do {
            try store.inDerivationTransaction { _ = try $0.ensureThisDeviceRow() }
        } catch {
            report.set("deviceRowError", String(describing: error))
        }
        let holdReleased = try await local.perform { state -> Bool in
            guard let root = try state.replica.personalRoot()?.envelope else { return false }
            let seed = CutoverRootState(root: root)
            guard seed.state == "seeding", seed.claimDevice == deviceID else { return false }
            try state.replica.setEngineState(ReplicaStore.EngineScope.holdSendsForSeed, nil)
            return true
        }
        report.set("bootstrap", ["outcome": String(describing: bootstrapOutcome), "holdReleasedForSeeder": holdReleased] as [String: Any])

        // The activation's queues, drained before the seed sends the records that carry their pointers
        // (`SyncBackfillDrain`, run here on this task so the copy's folders stand in for the Mac's).
        try report.step("backfills") {
            var laid = 0
            while true {
                let before = try store.satelliteBackfillProgress()
                laid += try store.runSatelliteBackfillBatch(limit: 50)
                if try store.satelliteBackfillProgress() == before { break }
            }
            laid += try store.runListenFileBackfill(limit: 50)
            report.set("backfillsLaid", laid)
        }
        report.set("backfillQueues", try Self.backfillQueues(store))
        report.set("sourceFilesNotInCopy", try Self.sourceFilesNotLaidOut(store))
        report.write()

        // Step 4: the seed, every pass, until the root says complete. Satellites are planned and measured, not
        // uploaded; P4b (bytes from the old container) and P6 (teams into spaces) need what this run has not.
        let blobs = BlobStore(transport: transport, store: local, deviceID: deviceID, pacer: { _ in pacer }, clock: Self.clock)
        let writer = MaintenanceWriter(transport: transport, store: local, moveMaps: moveMaps, deviceID: deviceID, clock: Self.clock)
        let phases = PhaseTimeline()
        let plan = SatellitePlanBox()
        let planner = CutoverSatellites(store: local, blobs: blobs, pendingCount: { await engine.pendingCount })
        var seedEnvironment = CutoverSeedEnvironment(
            transport: transport, store: local, registry: KnowledgeStore.projectionRegistry, blobs: blobs, writer: writer, deviceID: deviceID,
            oldContainer: FakeCloudKit.legacyContainer,
            send: {
                Self.follow(server)
                try await engine.sendChanges()
            },
            pendingCount: { await engine.pendingCount },
            holdsLibrary: { true }
        )
        seedEnvironment.clock = Self.clock
        seedEnvironment.sleep = { _ in }
        seedEnvironment.configuration.canaryPause = 0
        seedEnvironment.configuration.rehearsalSeedLocal = true
        seedEnvironment.pause = { await pacer.pause(of: .engine, writes: true) }
        seedEnvironment.prepare = { pass, state in
            guard pass == .structure, let local = (state as? MacPrivateSyncStore.State)?.store else { return }
            try SeedDocBodies.choose(in: local)
        }
        seedEnvironment.uploadSatellites = {
            let items = try await local.onStore { try planner.satellites(in: $0) }
            let measured = SatellitePlan.measure(items, paths: paths)
            plan.set(measured)
            return CutoverSatelliteTotals(satellites: measured.availableParts, bytes: measured.availableBytes)
        }
        seedEnvironment.progress = { phase in phases.mark(phase) }
        let seeder = CutoverSeeder(seedEnvironment)
        for _ in 0..<6 {
            let outcome = try await report.stepAsync("seed.run\(seedOutcomes.count + 1)") { try await seeder.run() }
            seedOutcomes.append(outcome)
            // A stall, or records a pass left unsent, resumes on the next round, as the app's rounds do.
            switch outcome {
            case .stopped(.sendsStalled), .stopped(.unsent): continue
            default: break
            }
            break
        }
        try await report.stepAsync("lastRound") {
            Self.follow(server)
            try await engine.sync()
        }
        report.set("seed", [
            "outcomes": seedOutcomes.map { String(describing: $0) }, "phaseSeconds": phases.durations(),
            "recoverBytes": "not run: the old container holds nothing here (P4b)", "teams": "not run: P6 needs SpaceSync (\(try Self.teamCounts(store)))",
        ] as [String: Any])
        if let measured = plan.value { report.set("satellites", measured.json) }

        // What the server holds now.
        if let stored = server.storedRecord(SyncSchema.rootRecordName, zone: PrivateSyncZones.library.zoneName, owner: Self.account),
           let payload = stored.payload, let root = try? SyncEnvelope(storedPayload: payload) {
            rootSeed = root.fields["seed"]?.objectValue ?? [:]
            report.set("root", [
                "seed": rootSeed.mapValues { String(describing: $0) },
                "legacyImport": root.fields["legacyImport"].map { String(describing: $0) } ?? NSNull(),
            ] as [String: Any])
        }
        try collectOutcome(store, server: server)
        report.set("finishedAt", ISO8601DateFormatter().string(from: Date()))
    }

    // MARK: What the run left

    private func collectOutcome(_ store: KnowledgeStore, server: FakeCloudKit) throws {
        let library = PrivateSyncZones.libraryKey
        let catalog = PrivateSyncZones.key(PrivateSyncZones.catalog)
        let limit = SyncSchema.Limits.payloadMaxBytes

        var types: [String: [String: Any]] = [:]
        var oversizeRecords: [[String: Any]] = []
        try store.query("""
            SELECT zone_key, record_type, COUNT(*), SUM(length(payload)), MAX(length(payload)) FROM ck_records GROUP BY zone_key, record_type
        """, []) { row in
            let zone = row.text(0) ?? "", type = row.text(1) ?? ""
            types["\(zone) \(type)"] = [
                "records": row.integer(2) ?? 0, "payloadBytes": row.integer(3) ?? 0, "largestPayload": row.integer(4) ?? 0,
            ]
        }
        try store.query("SELECT zone_key, record_type, wire_id, length(payload) FROM ck_records WHERE length(payload) > ?", [.integer(Int64(limit))]) { row in
            oversizeRecords.append(["zone": row.text(0) ?? "", "type": row.text(1) ?? "", "id": row.text(2) ?? "", "bytes": row.integer(3) ?? 0])
        }
        oversize = oversizeRecords.count

        var onServer: [String: Int] = [:]
        for zone in PrivateSyncZones.all.map(\.zoneName) {
            for name in server.recordNames(zone: zone, owner: Self.account) {
                let type = server.storedRecord(name, zone: zone, owner: Self.account)?.recordType ?? "?"
                onServer["\(zone) \(type)", default: 0] += 1
            }
        }

        var parked: [[String: Any]] = []
        try store.query("SELECT zone_key, record_name, record_type, reason, length(payload) FROM ck_quarantine ORDER BY reason, record_type", []) { row in
            parked.append([
                "zone": row.text(0) ?? "", "recordName": row.text(1) ?? "", "type": row.text(2) ?? "", "reason": row.text(3) ?? "",
                "payloadBytes": row.integer(4) ?? 0,
            ])
        }
        quarantined = parked.count
        // What the outbox still holds: a row that feeds a space's copy is SpaceSync's after P6, which this
        // run does not run, so it is reported apart and is not a leftover of the private seed.
        let leftovers = try Self.outboxLeftovers(store)
        let patches = try store.scalarInteger("SELECT COUNT(*) FROM ck_patches") ?? 0
        outboxLeft = Int64(leftovers.privateRows.values.reduce(0, +)) + patches

        // Parity: every record a library row feeds (the seed's own reading of the rows) against what the
        // replica holds as acknowledged in Library and Catalog.
        let expectation = try Self.expectedRecords(store)
        let expected = expectation.records
        // What the outbox still holds that feeds a record of the seed's own families with something to send
        // and not on the server (`SeedLeftovers`, the seeder's own check), whatever its time.
        let now = Date().timeIntervalSinceReferenceDate
        let unsent = try SeedLeftovers.unsent(registry: KnowledgeStore.projectionRegistry, connection: store, runStartedAt: now, now: now, sampleSize: 30)
        let emptyExchanges = try Self.emptyExchanges(store).count
        var sent: [String: Set<String>] = [:]
        try store.query("SELECT record_type, wire_id FROM ck_records WHERE zone_key IN (?, ?)", [.text(library), .text(catalog)]) { row in
            sent[row.text(0) ?? "", default: []].insert(row.text(1) ?? "")
        }
        var parity: [String: Any] = [:]
        var missingTotal = 0
        for type in Set(expected.keys).union(sent.keys).sorted() {
            let want = expected[type] ?? [], have = sent[type] ?? []
            let missing = want.subtracting(have)
            missingTotal += missing.count
            var entry: [String: Any] = [
                "fromLocalRows": want.count, "sent": have.count, "missing": missing.count, "notFromRows": have.subtracting(want).count,
                "missingSample": Array(missing.sorted().prefix(20)),
            ]
            if let neverOn = expectation.neverOnMarks[type] { entry["neverOnByKind"] = neverOn }
            parity[type] = entry
        }
        parityMissing = missingTotal

        let digests = oldAssetDigests
        var laidOut = Set<ByteParityInputs.SatelliteKey>()
        for table in [("source_files", "role"), ("source_derived", "kind")] {
            try store.query("SELECT source_id, \(table.1) FROM \(table.0) WHERE file_ref IS NOT NULL", []) { row in
                laidOut.insert(ByteParityInputs.SatelliteKey(owner: row.text(0) ?? "", role: row.text(1) ?? ""))
            }
        }
        let byteParity = ByteParityInputs(digests: digests, satellites: laidOut, localFile: { _ in false }, heldBy: { _ in nil }).report()

        report.set("records", [
            "byZoneAndType": types, "onServerByZoneAndType": onServer, "payloadLimit": limit, "overLimit": oversizeRecords,
            "quarantined": parked, "outboxLeft": outboxLeft, "outboxLeftByTable": leftovers.privateRows, "patchesLeft": patches,
            "outboxWaitingForSpaces": leftovers.spaceRows,
            "outboxNote": "a row that feeds a space's copy waits for SpaceSync, which needs the space zone P6 makes; P6 is not run here",
            "parity": parity, "parityMissingTotal": missingTotal,
            "emptyExchangesLeftLocal": emptyExchanges,
            "seedLeftovers": ["count": unsent.count, "sample": unsent.sample.map { "\($0.type.rawValue) \($0.wireID)" }] as [String: Any],
        ] as [String: Any])
        report.set("byteParity", [
            "note": "old-container assets (sync_asset_digests) against the satellites this run laid out for P5; missing ones need P4b's recovery from the old container",
            "checked": byteParity.checked, "plannedSatellites": byteParity.newSatellites, "missing": byteParity.missing.count,
            "missingSample": byteParity.missing.prefix(30).map { "\($0.title) [\($0.field.rawValue)] \($0.sourceID)" },
        ] as [String: Any])
    }

    func assertOutcome() {
        let journal = self.journal
        #expect(journal?.activatedAt != nil, "the activation finished")
        #expect(journal?.step == .activated)
        #expect(journal?.clonePath == KnowledgeRollbackCopy.Kind.beforeGeneration2.fileName, "the journal records the rollback copy")
        #expect(copyQuickCheck == "ok", "the rollback copy passed quick_check")
        #expect(copyIntegrity == "ok", "the rollback copy passed integrity_check")
        #expect(oldContainerCalls == 0, "a fresh activation asks nothing of the old container")
        if case .created? = bootstrapOutcome {} else { Issue.record("the bootstrap made the root: \(String(describing: bootstrapOutcome))") }
        if case .complete? = seedOutcomes.last {} else { Issue.record("the seed did not complete: \(seedOutcomes)") }
        #expect(rootSeed["metadataCompleteAt"]?.int64Value != nil, "the root shows the metadata complete")
        #expect(rootSeed["state"] == .string("complete"), "the root shows the seed complete")
        #expect(oversize == 0, "no record is over the payload limit")
        #expect(quarantined == 0, "no record was parked or refused")
        #expect(outboxLeft == 0, "everything the private engine sends went out (a row for a space's copy waits for P6)")
        #expect(parityMissing == 0, "every record the library's rows feed is on the server")
    }

    // MARK: Helpers

    static func follow(_ server: FakeCloudKit) {
        let behind = Date().timeIntervalSince(server.now)
        if behind > 0 { server.advance(by: behind) }
    }

    static func describe(_ journal: ActivationJournal) -> [String: Any] {
        [
            "step": journal.step?.rawValue ?? NSNull(), "mode": journal.mode?.rawValue ?? NSNull(), "freshReason": journal.freshReason?.rawValue ?? NSNull(),
            "account": journal.account ?? NSNull(), "clonePath": journal.clonePath ?? NSNull(),
            "cloneUserVersion": journal.cloneUserVersion.map { Int($0) } ?? NSNull(), "startedAt": journal.startedAt ?? NSNull(),
            "derivedAt": journal.derivedAt ?? NSNull(), "activatedAt": journal.activatedAt ?? NSNull(), "catchUpAt": journal.catchUpAt ?? NSNull(),
            "triggerHash": journal.triggerHash ?? NSNull(),
        ]
    }

    struct ExpectedRecords {
        /// Record ids by type.
        var records: [String: Set<String>] = [:]
        /// Marks a row names but never turned on, by type and then kind: no record (§3.5.19).
        var neverOnMarks: [String: [String: Int]] = [:]
    }

    /// The Mark kinds that project from a column of the row they are about (§3.5.19 as built): every row of
    /// the table names the Mark's id, but the Mark is on only while the column says so.
    static let columnMarkKinds: Set<String> = ["wantIdea", "citedDecision", "rated", "liked", "provenance", "following"]

    /// Every record the seed's passes would hand the outbox, from the library's rows (`SeedRowReader`), a
    /// space's copies aside (P6's). A Mark of a column kind that was never on is no record: an idea never
    /// wanted, a cited paper still `pending` or `unresolved`, an exchange never rated, a video never liked,
    /// a source with no discovery origin, and a like or an origin on a team copy (the personal copy holds
    /// the member's). Its row still names the Mark's id, so the seed hands the row to the outbox, and the
    /// feeder settles it with nothing sent: never acknowledged, nothing to remove (§3.5.19: never deleted,
    /// `on` flips, so a Mark exists from its first `on`). Those are counted apart, by kind. A truly empty
    /// exchange is aside too: an Exchange is sent once it holds a question, an answer or a reply
    /// (docs/cloudkit-schema-design.md §3.5.14; an empty turn's rows are dropped, `ExchangeCompletionTests`).
    static func expectedRecords(_ store: KnowledgeStore) throws -> ExpectedRecords {
        let registry = KnowledgeStore.projectionRegistry
        let reader = SeedRowReader(connection: store, registry: registry, fallbackTime: 0)
        let empties = try emptyExchanges(store)
        var expected = ExpectedRecords()
        for table in SeedTable.tables(in: registry) {
            var cursor: String?
            while true {
                let rows = try reader.nextBatch(of: table, after: cursor, limit: 1_000)
                guard let last = rows.last else { break }
                for row in rows {
                    for ref in try reader.records(of: row, in: table) where !ref.isSpaceCopy {
                        if ref.type == .mark, let key = MarkKey(id: ref.wireID), columnMarkKinds.contains(key.kind),
                           try MarkProjection.load(key, connection: store) == nil {
                            expected.neverOnMarks[ref.type.rawValue, default: [:]][key.kind, default: 0] += 1
                            continue
                        }
                        if ref.type == .exchange, empties.contains(ref.wireID) { continue }
                        expected.records[ref.type.rawValue, default: []].insert(ref.wireID)
                    }
                }
                cursor = SeedRowReader.cursor(after: last)
            }
        }
        return expected
    }

    /// The rows the outbox still holds, counted by table and split by where they can go. A row that feeds a
    /// space's copy (`ck_identity` names a space for one of its records) stays until SpaceSync takes that
    /// record, since the feeder drops a row only once every record it feeds has nothing left to send and
    /// the private engine sends no space record; SpaceSync needs the space zone P6 makes. Every other row
    /// is a leftover of the private engine.
    static func outboxLeftovers(_ store: KnowledgeStore) throws -> (privateRows: [String: Int], spaceRows: [String: Int]) {
        let registry = KnowledgeStore.projectionRegistry
        let reader = SeedRowReader(connection: store, registry: registry, fallbackTime: 0)
        let tables = Dictionary(SeedTable.tables(in: registry).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var units: [String: (table: String, localKey: String, removal: String?)] = [:]
        try store.query(
            "SELECT DISTINCT source_table, local_key FROM ck_outbox_fields WHERE source_table <> ?", [.text(OutboxFeeder.pinSource)]
        ) { row in
            let table = row.text(0) ?? "", key = row.text(1) ?? ""
            units[table + "\u{1F}" + key] = (table, key, nil)
        }
        try store.query("SELECT source_table, local_key, record_key_json FROM ck_outbox", []) { row in
            let table = row.text(0) ?? "", key = row.text(1) ?? ""
            units[table + "\u{1F}" + key] = (table, key, row.text(2))
        }
        var privateRows: [String: Int] = [:]
        var spaceRows: [String: Int] = [:]
        for unit in units.values {
            var values: [String: SQLiteValue] = [:]
            if let json = unit.removal {
                values = ((try? SyncJSON(parsing: Data(json.utf8)))?.objectValue ?? [:]).mapValues(SQLiteValue.init(json:))
            } else if let merged = registry.merged(unit.table) {
                values = try liveRoutingValues(store, table: merged, localKey: unit.localKey) ?? [:]
            }
            var feedsSpaceCopy = false
            if let table = tables[unit.table], !values.isEmpty {
                let row = SeedRow(rowid: 0, sort: 0, localKey: unit.localKey, values: values, time: 0)
                feedsSpaceCopy = try reader.records(of: row, in: table).contains(where: \.isSpaceCopy)
            }
            if feedsSpaceCopy {
                spaceRows[unit.table, default: 0] += 1
            } else {
                privateRows[unit.table, default: 0] += 1
            }
        }
        return (privateRows, spaceRows)
    }

    /// The routing columns a live row holds now, read by its outbox local key (one column's value, or a
    /// JSON array of the key columns' values); nil when the row is gone.
    private static func liveRoutingValues(_ store: KnowledgeStore, table: MergedProjectedTable, localKey: String) throws -> [String: SQLiteValue]? {
        let keyValues: [SQLiteValue]
        if table.localKey.count == 1 {
            keyValues = [.text(localKey)]
        } else {
            guard let parts = (try? SyncJSON(parsing: Data(localKey.utf8)))?.arrayValue, parts.count == table.localKey.count else { return nil }
            keyValues = parts.map(SQLiteValue.init(json:))
        }
        let columns = table.routingColumns
        let condition = table.localKey.map { "\(OutboxFeeder.quoted($0)) = ?" }.joined(separator: " AND ")
        var values: [String: SQLiteValue]?
        try store.query(
            "SELECT \(columns.map(OutboxFeeder.quoted).joined(separator: ", ")) FROM \(OutboxFeeder.quoted(table.name)) WHERE \(condition) LIMIT 1",
            keyValues
        ) { row in
            var read: [String: SQLiteValue] = [:]
            for (index, column) in columns.enumerated() { read[column] = OutboxFeeder.value(row, Int32(index)) }
            values = read
        }
        return values
    }

    /// The exchanges with no question, answer or reply (`ExchangeProjection.isComplete`) that no zone of
    /// the replica holds: the only ones never sent.
    static func emptyExchanges(_ store: KnowledgeStore) throws -> Set<String> {
        var empties = Set<String>()
        try store.query("""
            SELECT e.id, e.question, e.user_answer, e.evaluation FROM review_exchanges e
            WHERE NOT EXISTS (SELECT 1 FROM ck_records r WHERE r.record_type = ? AND r.wire_id = e.id)
        """, [.text(SyncRecordType.exchange.rawValue)]) { row in
            let columns: [String: SQLiteValue] = [
                "question": OutboxFeeder.value(row, 1), "user_answer": OutboxFeeder.value(row, 2), "evaluation": OutboxFeeder.value(row, 3),
            ]
            if !ExchangeProjection.isComplete(columns), let id = row.text(0) { empties.insert(id) }
        }
        return empties
    }

    static func backfillQueues(_ store: KnowledgeStore) throws -> [String: Any] {
        var left: [String: Any] = [:]
        try store.query("SELECT kind, COUNT(*), MAX(attempts) FROM ck_backfill_queue GROUP BY kind", []) { row in
            left[row.text(0) ?? "?"] = ["rows": row.integer(1) ?? 0, "maxAttempts": row.integer(2) ?? 0]
        }
        var errors: [String] = []
        try store.query("SELECT kind, target, last_error FROM ck_backfill_queue WHERE last_error IS NOT NULL ORDER BY kind, target LIMIT 30", []) { row in
            errors.append("\(row.text(0) ?? "") \(row.text(1) ?? ""): \(row.text(2) ?? "")")
        }
        return ["left": left, "errorSample": errors]
    }

    /// Sources whose own PDF or EPUB the backfill could not lay out: the file is not in the copy.
    static func sourceFilesNotLaidOut(_ store: KnowledgeStore) throws -> [String: Any] {
        let path = KnowledgeStore.subtypeCoalesce("local_file_path")
        var count = 0
        var sample: [String] = []
        try store.query("""
            SELECT s.id, \(path) FROM sources s \(KnowledgeStore.subtypeJoins)
            WHERE (lower(\(path)) LIKE '%.pdf' OR lower(\(path)) LIKE '%.epub') AND \(path) NOT LIKE '%://%'
              AND NOT EXISTS (SELECT 1 FROM source_files f WHERE f.source_id = s.id AND f.role IN ('pdf', 'epub'))
            ORDER BY s.id
        """, []) { row in
            count += 1
            if sample.count < 30 { sample.append("\(row.text(0) ?? ""): \(row.text(1) ?? "")") }
        }
        return ["count": count, "sample": sample]
    }

    static func teamCounts(_ store: KnowledgeStore) throws -> String {
        let teams = try store.scalarInteger("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'teams'") == 1
            ? store.scalarInteger("SELECT COUNT(*) FROM teams") ?? 0 : 0
        let sources = try store.scalarInteger("SELECT COUNT(*) FROM sources WHERE team_id IS NOT NULL") ?? 0
        return "\(teams) teams, \(sources) team sources"
    }
}

// MARK: - Satellites, measured instead of uploaded

/// What P5 would upload (§13.4 step 2), by role, from the pointers the backfill laid out, with the bytes
/// `sync.originals` (D38) would keep on the Mac. A file is looked for only inside the copy's folders.
struct SatellitePlan: Sendable {
    struct Role: Sendable {
        var items = 0
        var available = 0
        var parts = 0
        var decodedBytes: Int64 = 0
        var storedBytes: Int64 = 0
        var availableStoredBytes: Int64 = 0
        var over50MB = 0
        var over50MBStoredBytes: Int64 = 0
    }

    var roles: [String: Role] = [:]
    var availableParts = 0
    var availableBytes: Int64 = 0
    var unavailableSample: [String] = []

    static let originalRoles: Set<String> = ["pdf", "epub"]
    static let fiftyMB: Int64 = 50 * 1_024 * 1_024

    static func measure(_ items: [SeedSatellite], paths: RehearsalPaths) -> SatellitePlan {
        var plan = SatellitePlan()
        for item in items {
            let base = item.ref.role.split(separator: ".").first.map(String.init) ?? item.ref.role
            let key = "\(item.ownerType.rawValue).\(base)"
            var role = plan.roles[key] ?? Role()
            let stored = item.ref.stored ?? item.ref.size ?? 0
            role.items += 1
            role.decodedBytes += item.ref.size ?? 0
            role.storedBytes += stored
            if originalRoles.contains(base), (item.ref.size ?? 0) > fiftyMB {
                role.over50MB += 1
                role.over50MBStoredBytes += stored
            }
            if isAvailable(item, paths: paths) {
                role.available += 1
                role.parts += max(1, item.ref.parts.count)
                role.availableStoredBytes += stored
                plan.availableParts += max(1, item.ref.parts.count)
                plan.availableBytes += item.ref.size ?? 0
            } else if plan.unavailableSample.count < 30 {
                plan.unavailableSample.append("\(key) \(item.ref.owner)")
            }
            plan.roles[key] = role
        }
        return plan
    }

    static func isAvailable(_ item: SeedSatellite, paths: RehearsalPaths) -> Bool {
        switch item.origin {
        case .none: return false
        // The working folder is this Mac's, not the copy's: the rehearsal never reads it.
        case .narration: return false
        case .docBody: return true
        case .file(let path):
            let url = path.hasPrefix("ck-staging/") ? paths.run.appendingPathComponent(path) : paths.locate(storedPath: path)
            guard let url, paths.isInside(url) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    var json: [String: Any] {
        let total = roles.values.reduce(Int64(0)) { $0 + $1.availableStoredBytes }
        let over = roles.filter { Self.originalRoles.contains(String($0.key.split(separator: ".").last ?? "")) }
        let originals = over.values.reduce(Int64(0)) { $0 + $1.availableStoredBytes }
        let over50 = over.values.reduce(Int64(0)) { $0 + $1.over50MBStoredBytes }
        return [
            "note": "measured, not uploaded: the bytes P5 would upload, stored (after gzip)",
            "byRole": roles.mapValues { role in
                [
                    "items": role.items, "available": role.available, "parts": role.parts, "decodedBytes": role.decodedBytes,
                    "storedBytes": role.storedBytes, "availableStoredBytes": role.availableStoredBytes,
                    "originalsOver50MB": role.over50MB, "originalsOver50MBStoredBytes": role.over50MBStoredBytes,
                ] as [String: Any]
            },
            "uploadStoredBytes": ["all": total, "skipOver50MB": total - over50, "none": total - originals],
            "unavailableSample": unavailableSample,
        ]
    }
}

// MARK: - Recorders

final class SatellitePlanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var plan: SatellitePlan?
    var value: SatellitePlan? { lock.withLock { plan } }
    func set(_ plan: SatellitePlan) { lock.withLock { self.plan = plan } }
}

final class DerivationTimings: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, Double)] = []

    func add(_ id: String, _ seconds: Double) { lock.withLock { entries.append((id, seconds)) } }
    var ordered: [[String: Any]] { lock.withLock { entries.map { ["id": $0.0, "seconds": $0.1] } } }
    var total: Double { lock.withLock { entries.reduce(0) { $0 + $1.1 } } }
}

/// The seed's phases as `CutoverSeeder.progress` names them, and how long each lasted.
final class PhaseTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [(String, ContinuousClock.Instant)] = []

    func mark(_ phase: CutoverSeedPhase) {
        let label: String
        switch phase {
        case .pass(let pass): label = "pass \(pass.rawValue) \(pass.title)"
        default: label = String(describing: phase)
        }
        lock.withLock { marks.append((label, .now)) }
    }

    func durations() -> [[String: Any]] {
        lock.withLock {
            marks.enumerated().map { index, mark in
                let end = index + 1 < marks.count ? marks[index + 1].1 : mark.1
                return ["phase": mark.0, "seconds": mark.1.duration(to: end).seconds]
            }
        }
    }
}

/// The report: every step's wall clock and what it found, written as JSON beside the copy after each step,
/// so a run that stops midway still leaves what it got to.
final class RehearsalReport: @unchecked Sendable {
    let paths: RehearsalPaths
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private var steps: [(String, Double)] = []

    init(paths: RehearsalPaths) {
        self.paths = paths
    }

    var seconds: [String: Double] { lock.withLock { Dictionary(steps, uniquingKeysWith: { $1 }) } }

    func set(_ key: String, _ value: Any) { lock.withLock { values[key] = value } }

    func step<T>(_ name: String, _ body: () throws -> T) throws -> T {
        let started = ContinuousClock.now
        defer { record(name, started) }
        return try body()
    }

    func stepAsync<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        let started = ContinuousClock.now
        defer { record(name, started) }
        return try await body()
    }

    private func record(_ name: String, _ started: ContinuousClock.Instant) {
        let seconds = started.duration(to: .now).seconds
        lock.withLock { steps.append((name, seconds)) }
    }

    private var document: [String: Any] {
        lock.withLock {
            var document = values
            document["stepSeconds"] = steps.map { ["step": $0.0, "seconds": $0.1] }
            return document
        }
    }

    func write() {
        do {
            let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: paths.report, options: .atomic)
        } catch {
            print("The rehearsal report could not be written: \(error)")
        }
    }

    func printSummary() {
        let document = self.document
        var lines = ["", "===== ForeverLM cutover rehearsal =====", "copy: \(paths.copy.path)", "report: \(paths.report.path)"]
        for case let step as [String: Any] in document["stepSeconds"] as? [Any] ?? [] {
            let name = (step["step"] as? String ?? "").padding(toLength: 34, withPad: " ", startingAt: 0)
            lines.append("  " + name + String(format: "%10.2f s", step["seconds"] as? Double ?? 0))
        }
        if let activation = document["activation"] as? [String: Any], let journal = activation["journal"] as? [String: Any] {
            lines.append("activation: mode \(journal["mode"] ?? "?"), step \(journal["step"] ?? "?"), copy \(journal["clonePath"] ?? "none")")
        }
        if let open = document["open"] as? [String: Any] {
            lines.append("store: \(open["fromUserVersion"] ?? "?") -> \(open["toUserVersion"] ?? "?"); copy quick_check \(open["quickCheck"] ?? "?"), integrity_check \(open["integrityCheck"] ?? "?")")
        }
        if let seed = document["seed"] as? [String: Any] { lines.append("seed: \(seed["outcomes"] ?? "?")") }
        if let records = document["records"] as? [String: Any] {
            lines.append("records: parity missing \(records["parityMissingTotal"] ?? "?"), quarantined \((records["quarantined"] as? [Any])?.count ?? -1), over limit \((records["overLimit"] as? [Any])?.count ?? -1), outbox left \(records["outboxLeft"] ?? "?")")
        }
        if let satellites = document["satellites"] as? [String: Any], let bytes = satellites["uploadStoredBytes"] as? [String: Any] {
            lines.append("satellites to upload (stored bytes): \(bytes)")
        }
        if let error = document["error"] { lines.append("error: \(error)") }
        lines.append("=======================================")
        print(lines.joined(separator: "\n"))
    }
}

struct RehearsalError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - The copy, read and written before any KnowledgeStore opens it

/// A plain SQLite connection to the working clone or its rollback copy (immutable, so reading it creates no
/// side file).
final class RehearsalDatabase {
    private var handle: OpaquePointer?

    init(_ path: String, immutable: Bool = false) throws {
        let name = immutable ? URL(fileURLWithPath: path).absoluteString + "?immutable=1" : path
        let flags = immutable ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READWRITE
        let opened = sqlite3_open_v2(name, &handle, flags, nil)
        guard opened == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(opened)"
            sqlite3_close(handle)
            handle = nil
            throw RehearsalError("cannot open \(path): \(message)")
        }
        sqlite3_busy_timeout(handle, 10_000)
    }

    deinit {
        sqlite3_close(handle)
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw RehearsalError("\(sql): \(String(cString: sqlite3_errmsg(handle)))")
        }
    }

    func rows(_ sql: String) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RehearsalError("\(sql): \(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String?]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw RehearsalError("\(sql): \(String(cString: sqlite3_errmsg(handle)))") }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            })
        }
        return rows
    }

    func scalar(_ sql: String) throws -> String? {
        try rows(sql).first?.first ?? nil
    }

    func tableExists(_ name: String) -> Bool {
        (try? scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(name)'")) == "1"
    }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
