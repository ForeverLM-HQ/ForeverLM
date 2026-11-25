import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The phone's write path (docs/cloudkit-schema-design.md §5.2–§5.6, §6.6, D47, D50;
/// §14.2 WP20): every change a RecordPatch over what the phone holds, stamped at the write, shown at
/// once and sent by the private engine or SpaceSync; captures as Jobs until the first complete Catalog
/// pass; chats with the kind their creation site gives.
@Suite("iPhone record writer", .serialized)
struct MobileRecordWriterTests {
    typealias Fixture = MobileWriterFixture
    static let alice = "alice"
    static let library = CloudZoneID(SyncZone.library.rawValue)

    /// The seeded library of `MobileReplicaTests` on a phone that has synced it once, with a writer
    /// whose writes are already past every debounce when the phone next syncs.
    static func syncedPhone() async throws -> (server: FakeCloudKit, phone: MobileTestDevice, writer: MobileRecordWriter) {
        let server = try MobileReplicaTests.seededLibrary()
        let phone = try await MobileReplicaTests.phone(server)
        try await phone.sync()
        return (server, phone, MobileRecordWriter(replica: phone.replica, deviceID: phone.deviceID, clock: { Date().addingTimeInterval(-60) }))
    }

    static func stored(_ server: FakeCloudKit, _ type: SyncRecordType, _ id: String, zone: String) throws -> SyncEnvelope? {
        let name = RecordNaming.recordName(type: type, id: id, salt: MobileSyncFixture.librarySalt)
        return try server.storedRecord(name, zone: zone, owner: alice)?.payload.map { try SyncEnvelope(storedPayload: $0) }
    }

    // MARK: - Notebooks and their sources

    @Test("Creating a notebook writes a Notebook: on screen at once, then on the server, and the patch goes once it landed")
    func createNotebook() async throws {
        let (server, phone, writer) = try await Self.syncedPhone()
        let id = try await writer.createNotebook(title: "  🧠 Memory  ", instructions: "Cite the PDFs", summary: nil)
        #expect(id == id.lowercased())
        #expect(try await phone.text("SELECT title FROM m_notebooks WHERE zone_key = 'private/Library' AND id = ?", [.text(id)]) == "🧠 Memory")
        #expect(try await Fixture.patched(phone.replica) == ["private/Library Notebook \(id)"])

        try await phone.sync()
        let notebook = try #require(try Self.stored(server, .notebook, id, zone: "Library"))
        #expect(notebook.fields["title"] == .string("🧠 Memory"))
        #expect(notebook.fields["instructions"] == .string("Cite the PDFs"))
        #expect(notebook.fields["status"] == .string("active"))
        #expect(notebook.fields["createdAt"]?.int64Value != nil)
        guard case .value(let stamp)? = notebook.stamps["title"] else { Issue.record("no title stamp"); return }
        #expect(stamp.rawValue.hasSuffix(phone.deviceID), "stamped by the phone")
        #expect(try await Fixture.patchCount(phone.replica) == 0, "the patch went once the save landed")
        #expect(try await phone.text("SELECT record_name FROM m_notebooks WHERE id = ?", [.text(id)]) != nil)
    }

    @Test("A value equal to the one held stamps nothing, and a rename after another stamps later")
    func unchangedValueWritesNothing() async throws {
        let (_, phone, writer) = try await Self.syncedPhone()
        try await writer.transaction { try $0.updateNotebook("nb1", title: "🧬 Cells") }
        #expect(try await Fixture.patchCount(phone.replica) == 0)
        try await writer.transaction { try $0.updateNotebook("nb1", title: "🧬 Cells and membranes") }
        let first = try #require(try await Fixture.patch(phone.replica, .notebook, "nb1", in: Fixture.library)?.stamps["title"])
        try await writer.transaction { try $0.updateNotebook("nb1", title: "🧬 Membranes") }
        let second = try #require(try await Fixture.patch(phone.replica, .notebook, "nb1", in: Fixture.library)?.stamps["title"])
        guard case .value(let a) = first, case .value(let b) = second else { Issue.record("scalar stamps"); return }
        #expect(SyncStamp.compare(b, a) > 0)
    }

    @Test("Adding a source writes an Entry after the last; an untick names its stamps; a remove and re-add ticks it again with no write to the NotebookState")
    func addUntickAndReAdd() async throws {
        let (server, phone, writer) = try await Self.syncedPhone()
        try await writer.transaction { _ = try $0.fileSources(["src2"], into: "nb1") }
        let entry = try #require(try await Fixture.held(phone.replica, .entry, "en:nb1:source:src2", in: Fixture.library))
        #expect(entry.fields["state"] == .string("active"))
        #expect(entry.fields["approval"] == .string("approved"))
        #expect(entry.fields["orderKey"] == .string("a1"))
        #expect(entry.fields["containerID"] == .string("nb1"))
        try await phone.sync()
        #expect(try Self.stored(server, .entry, "en:nb1:source:src2", zone: "Library")?.fields["itemID"] == .string("src2"))

        try await writer.transaction { try $0.setChatExclusions("nb1", to: ["src2"]) }
        let pair = try MobileReadModelFixture.stampPair(try #require(try await Fixture.held(phone.replica, .entry, "en:nb1:source:src2", in: Fixture.library)))
        let state = try #require(try await Fixture.held(phone.replica, .notebookState, "ns:nb1", in: Fixture.library))
        #expect(state.fields["excluded"]?["src2"] == .string(pair))
        #expect(try await writer.read { try $0.chatSelection(of: "nb1") }.excluded == ["src2"])
        try await phone.sync()
        let stateStamps = try #require(try Self.stored(server, .notebookState, "ns:nb1", zone: "Library")).stamps

        try await writer.transaction { try $0.removeSources(["src2"], from: "nb1") }
        #expect(try await Fixture.held(phone.replica, .entry, "en:nb1:source:src2", in: Fixture.library)?.fields["state"] == .string("removed"))
        try await writer.transaction { _ = try $0.fileSources(["src2"], into: "nb1") }
        #expect(try await writer.read { try $0.chatSelection(of: "nb1") }.excluded.isEmpty, "the re-add's new state stamp ticks it again")
        #expect(try await Fixture.patch(phone.replica, .notebookState, "ns:nb1", in: Fixture.library) == nil, "no write to the member's record")
        try await phone.sync()
        #expect(try Self.stored(server, .notebookState, "ns:nb1", zone: "Library")?.stamps == stateStamps)
        #expect(try Self.stored(server, .entry, "en:nb1:source:src2", zone: "Library")?.fields["state"] == .string("active"))
    }

    @Test("A source added to a space notebook is copied into the space first, and its files asked of a Mac")
    func addToSpaceNotebookCopiesTheSource() async throws {
        let replica = try await Fixture.replica()
        try await Fixture.apply(replica, [
            (Fixture.space, try MobileReadModelFixture.notebook("nbs", "Team notebook", edited: 5)),
            (Fixture.catalog, try MobileReadModelFixture.source("srcA", "Mito paper", added: 1, [
                "workKeys": .object(["doi:10.1/a": .bool(true)]),
                "files": .object(["pdf": MobileSyncFixture.fileRef(owner: "srcA", role: "pdf", bytes: Data("pdf".utf8)).value]),
            ])),
        ])
        let writer = Fixture.writer(replica)
        try await writer.transaction { _ = try $0.fileSources(["srcA"], into: "nbs") }
        let copy = try #require(try await Fixture.held(replica, .source, "srcA", in: Fixture.space))
        #expect(copy.fields["title"] == .string("Mito paper"))
        #expect(copy.fields["files"] == nil, "no satellite is pointed at before a Mac copies it")
        #expect(copy.fields["copiedFrom"]?["zone"] == .string("personal"))
        #expect(copy.fields["workKeys"]?["doi:10.1/a"] == .bool(true))
        let entry = try #require(try await Fixture.held(replica, .entry, "en:nbs:source:srcA", in: Fixture.space))
        #expect(entry.fields["addedBy"]?["user"] == .string("phoneuser"))
        let jobs = try await writer.read { try $0.jobs() }
        #expect(jobs.map { $0.fields["kind"] } == [.string("copyFilesToSpace")])
        #expect(jobs.first?.fields["params"]?["spaceID"] == .string("s1"))
    }

    @Test("A read-only member's write into a space is refused before anything is queued")
    func readOnlySpaceRefused() async throws {
        let replica = try await Fixture.replica(space: nil)
        try await MobileSyncFixture.holdSpace(replica, zoneKey: Fixture.joined, zoneName: "Space-s2", owned: false, name: "Lab", permission: "readOnly")
        try await Fixture.apply(replica, [(Fixture.joined, try MobileReadModelFixture.notebook("nbj", "Theirs", edited: 5))])
        let writer = Fixture.writer(replica)
        await #expect(throws: MobileRecordWriterError.self) {
            try await writer.transaction { try $0.updateNotebook("nbj", title: "Mine now") }
        }
        #expect(try await Fixture.patchCount(replica) == 0)
    }

    @Test("Moving a notebook into a space writes Job(moveToSpace), once while it waits")
    func moveToSpaceIsAJob() async throws {
        let replica = try await Fixture.replica()
        try await Fixture.apply(replica, [(Fixture.library, try MobileReadModelFixture.notebook("nb1", "Mine", edited: 5))])
        let writer = Fixture.writer(replica)
        let id = try await writer.requestMoveToSpace("nb1", to: .newSpace(kind: "notebook", name: " Reading group "))
        let job = try #require(try await Fixture.held(replica, .job, id, in: Fixture.library))
        #expect(job.fields["kind"] == .string("moveToSpace"))
        #expect(job.fields["target"] == .string("nb:nb1"))
        #expect(job.fields["params"] == .object(["newSpace": .object(["kind": .string("notebook"), "name": .string("Reading group")])]))
        #expect(job.fields["status"] == .string("queued"))
        #expect(job.fields["requestedBy"]?["platform"] == .string("ios"))
        #expect(try await writer.requestMoveToSpace("nb1", to: .space("s1")) == id, "the waiting request answers")
        await #expect(throws: MobileRecordWriterError.self) { try await writer.requestMoveToSpace("missing", to: .space("s1")) }
    }

    @Test("Deleting a notebook unfiles its Goal and writes nothing to a course it follows: only the follow Entry goes with it")
    func deletingANotebookLeavesItsCourses() async throws {
        let replica = try await Fixture.replica()
        let follow = try MobileReadModelFixture.entry("nb1", "course", "crs1", order: "a0")
        try await Fixture.apply(replica, [
            (Fixture.library, try MobileReadModelFixture.notebook("nb1", "Mine", edited: 5)),
            (Fixture.library, try MobileReadModelFixture.notebook("nb2", "Other", edited: 6)),
            (Fixture.library, try MobileSyncFixture.envelope(.course, "crs1", ["title": .string("Cells 101"), "status": .string("active"), "createdAt": SyncJSON(1)])),
            (Fixture.library, follow),
            (Fixture.library, try MobileReadModelFixture.entry("nb2", "course", "crs1", order: "a0")),
            (Fixture.library, try MobileSyncFixture.envelope(.goal, "gl1", ["title": .string("Finish"), "notebookID": .string("nb1"), "status": .string("active")])),
        ])
        let writer = Fixture.writer(replica)
        try await writer.transaction { try $0.deleteNotebook("nb1", deleteLinkedChats: false) }
        let patched = try await Fixture.patched(replica)
        #expect(patched == ["private/Library Goal gl1"], "no Course and no Entry is written")
        let changes = try await Fixture.changes(replica)
        #expect(changes.map(\.recordType).sorted { $0.rawValue < $1.rawValue } == [.goal, .notebook])
        #expect(changes.contains { $0.action == .delete && $0.wireID == "nb1" })
        #expect(try await Fixture.held(replica, .course, "crs1", in: Fixture.library) != nil)
        #expect(try await Fixture.held(replica, .entry, follow.id, in: Fixture.library)?.fields == follow.fields, "the follow Entry is left; with its notebook gone it reads as nothing")
        let projection = MobileProjection(replica: replica)
        #expect(try await projection.courses().map(\.id) == ["crs1"], "the course stays in the library")
        let other = try #require(try await projection.loadStructure().resolve("nb2"))
        #expect(try await projection.courses(of: other).map(\.id) == ["crs1"], "and another notebook still follows it")
    }

    // MARK: - Captures (D47)

    @Test("An import before the first complete Catalog pass is a Job only, with its filing target; after it a skeletal Source, its Job and the Entry")
    func captureBeforeAndAfterThePass() async throws {
        let (server, phone, writer) = try await Self.syncedPhone()
        try await phone.replica.perform { try $0.connection.execute("UPDATE ck_zones SET last_complete_pass_at = NULL WHERE zone_key = 'private/Catalog'") }
        let url = try #require(URL(string: "https://example.org/a?utm_source=x"))
        let before = try await writer.transaction { try $0.captureURL(url, title: "A", sourceType: "unclassified", target: MobileCaptureTarget(notebookID: "nb1")) }
        let id = try #require(before)
        #expect(try await Fixture.patched(phone.replica).allSatisfy { $0.hasPrefix("private/Library Job ") }, "no Source, no Entry, no Mark")
        let job = try #require(try await writer.read { try $0.jobs() }.first)
        #expect(job.fields["kind"] == .string("ingestURL"))
        #expect(job.fields["target"] == nil)
        #expect(job.fields["params"]?["target"] == .object(["notebookID": .string("nb1"), "approval": .string("approved")]))
        #expect(job.fields["params"]?["workKeys"]?.arrayValue?.first?.stringValue?.hasPrefix("url:") == true)

        // After the pass: the link shared into the notebook lands in it.
        try await phone.replica.perform { try $0.connection.execute("UPDATE ck_zones SET last_complete_pass_at = 1 WHERE zone_key = 'private/Catalog'") }
        let after = try await writer.transaction { try $0.captureURL(url, title: "A", sourceType: "unclassified", target: MobileCaptureTarget(notebookID: "nb1", origin: "share")) }
        #expect(after == id, "the id the Mac would mint for the address")
        let source = try #require(try await Fixture.held(phone.replica, .source, id, in: Fixture.catalog))
        #expect(source.fields["title"] == .string("A"))
        #expect(source.fields["ingest"]?["ord"] == .array([0, 1]))
        #expect(source.fields["madeBy"]?["route"] == .string("ios"))
        guard case .value(let titleStamp)? = source.stamps["title"] else { Issue.record("no title stamp"); return }
        #expect(titleStamp.milliseconds == Int64(SyncSchema.Limits.provisionalStampMs), "a skeleton's title is provisional")
        #expect(try await Fixture.held(phone.replica, .entry, "en:nb1:source:\(id)", in: Fixture.library)?.fields["origin"] == .string("share"))
        #expect(try await Fixture.held(phone.replica, .mark, "mk:provenance:src:\(id)", in: Fixture.library)?.fields["on"] == .bool(true))
        #expect(try await writer.read { try $0.jobs() }.contains { $0.fields["target"] == .string("src:\(id)") })
        try await phone.sync()
        #expect(try Self.stored(server, .source, id, zone: "Catalog") != nil)
        #expect(try Self.stored(server, .entry, "en:nb1:source:\(id)", zone: "Library") != nil)
    }

    @Test("A link shared into a notebook that is gone stays in the library")
    func captureIntoAGoneNotebook() async throws {
        let (_, phone, writer) = try await Self.syncedPhone()
        let url = try #require(URL(string: "https://example.org/b"))
        let id = try #require(try await writer.transaction { try $0.captureURL(url, title: nil, sourceType: "article", target: MobileCaptureTarget(notebookID: "gone")) })
        #expect(try await Fixture.held(phone.replica, .source, id, in: Fixture.catalog) != nil)
        #expect(try await phone.count("SELECT COUNT(*) FROM m_entries WHERE item_id = ?", [.text(id)]) == 0)
    }

    @Test("A scanned PDF uploads its parts first, then a Job(ingestFile) with its target before the pass, and a Source holding files.pdf with an Entry after it")
    func scannedPDF() async throws {
        let (server, phone, _) = try await Self.syncedPhone()
        var pacing = SyncPacerState.Configuration()
        pacing.capacity = 1_000_000
        pacing.refillPerSecond = 1_000_000
        let pacer = SyncPacer(configuration: pacing)
        let blobs = BlobStore(transport: phone.transport, store: phone.replica, deviceID: phone.deviceID, pacer: { _ in pacer })
        let writer = MobileRecordWriter(replica: phone.replica, deviceID: phone.deviceID, blobs: blobs, clock: { Date().addingTimeInterval(-60) })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = directory.appendingPathComponent("Scan.pdf")
        let bytes = Data("%PDF-1.4 scanned pages".utf8)
        try bytes.write(to: pdf)
        let sha = SyncIdentity.sha256Hex(bytes)
        let id = SyncIdentity.sourceFileID(sha256Hex: sha)

        try await phone.replica.perform { try $0.connection.execute("UPDATE ck_zones SET last_complete_pass_at = NULL WHERE zone_key = 'private/Catalog'") }
        #expect(try await writer.captureFile(at: pdf, title: "Scan · today", capture: "scan", target: MobileCaptureTarget(notebookID: "nb1")) == id)
        let content = SyncIdentity.contentID(owner: id, role: "pdf", partHash32: FileRef.partHash32(bytes))
        #expect(server.storedRecord(RecordNaming.recordName(type: .content, id: content, salt: MobileSyncFixture.librarySalt), zone: "Content", owner: Self.alice) != nil,
                "the part is on the server before anything points at it")
        let job = try #require(try await writer.read { try $0.jobs() }.first)
        #expect(job.fields["kind"] == .string("ingestFile"))
        #expect(job.fields["params"]?["sha256"] == .string(sha))
        #expect(job.fields["params"]?["capture"] == .string("scan"))
        #expect(job.fields["params"]?["file"]?["owner"] == .string(id))
        #expect(job.fields["params"]?["target"]?["notebookID"] == .string("nb1"))
        #expect(try await Fixture.held(phone.replica, .source, id, in: Fixture.catalog) == nil)

        try await phone.replica.perform { try $0.connection.execute("UPDATE ck_zones SET last_complete_pass_at = 1 WHERE zone_key = 'private/Catalog'") }
        _ = try await writer.captureFile(at: pdf, title: "Scan · today", capture: "scan", target: MobileCaptureTarget(notebookID: "nb1"))
        let source = try #require(try await Fixture.held(phone.replica, .source, id, in: Fixture.catalog))
        #expect(source.fields["files"]?["pdf"]?["owner"] == .string(id))
        #expect(source.fields["primaryKey"] == .string("file:\(sha)"))
        #expect(try await Fixture.held(phone.replica, .entry, "en:nb1:source:\(id)", in: Fixture.library) != nil)
    }

    // MARK: - Chats (D19, D50)

    static func chat(_ id: String, kind: ChatKind, notebook: String?, turns: Int, score: Double? = nil) -> MobileChatRecord {
        MobileChatRecord(
            id: id, kind: kind, notebookID: notebook, title: "Why membranes", startedAt: Date(timeIntervalSince1970: 1_759_400_000),
            endedAt: Date(timeIntervalSince1970: 1_759_400_600), summary: "Two turns.", overallScore: score, sourceIDs: ["src1"],
            modelProvider: "openrouter", modelID: "some/model",
            exchanges: (1...turns).map { index in
                MobileChatRecord.Exchange(id: "\(id)-ex-\(index)", seq: index, question: "", userAnswer: "Q\(index)", evaluation: "A\(index)",
                                          score: score, answeredAt: Date(timeIntervalSince1970: 1_759_400_000 + Double(index)),
                                          sourceRefs: ["src1"], knowledgeNote: "Recorded on iOS.")
            }
        )
    }

    @Test("A memory review, a course-quiz sitting and a walk's chat are written with their private kinds and stay in Library; a chat goes to its space notebook")
    func chatKinds() async throws {
        let replica = try await Fixture.replica()
        try await Fixture.apply(replica, [(Fixture.space, try MobileReadModelFixture.notebook("nbs", "Team notebook", edited: 5))])
        let writer = Fixture.writer(replica)
        for (id, kind) in [("memory-2026-10-04", ChatKind.memory), ("course-quiz-1", .quizSitting), ("walk-1", .walkthrough), ("ios-review", .review)] {
            try await writer.recordChat(Self.chat(id, kind: kind, notebook: "nbs", turns: 2, score: 0.8))
            let chat = try #require(try await Fixture.held(replica, .chat, id, in: Fixture.library), "\(kind)")
            #expect(chat.fields["kind"] == .string(kind.rawValue))
            #expect(chat.fields["notebookID"] == .string("nbs"), "filed in the space notebook from Library")
            #expect(chat.fields["overallScore"] == .number(0.8))
            #expect(try await Fixture.held(replica, .exchange, "\(id)-ex-1", in: Fixture.library)?.fields["score"] == .number(0.8))
            #expect(try await Fixture.held(replica, .chat, id, in: Fixture.space) == nil)
        }
        try await writer.recordChat(Self.chat("ios-chat", kind: .chat, notebook: "nbs", turns: 1, score: 0.5))
        let chat = try #require(try await Fixture.held(replica, .chat, "ios-chat", in: Fixture.space))
        #expect(chat.fields["kind"] == .string("chat"))
        #expect(chat.fields["overallScore"] == nil, "a score never travels into a space")
        #expect(chat.fields["createdBy"]?["user"] == .string("phoneuser"))
        let exchange = try #require(try await Fixture.held(replica, .exchange, "ios-chat-ex-1", in: Fixture.space))
        #expect(exchange.fields["score"] == nil)
        #expect(exchange.fields["userAnswer"] == .string("Q1"))
        #expect(exchange.fields["evaluation"] == .string("A1"))
        #expect(exchange.fields["seq"] == SyncJSON(1))
    }

    @Test("A voice Feynman Technique's graded turn carries an explanation's grading, and the phone reads its source as explained only when it held")
    func voiceExplanationIsExplained() async throws {
        let replica = try await Fixture.replica()
        let writer = Fixture.writer(replica)
        func chat(_ id: String, source: String, score: Double) -> MobileChatRecord {
            MobileChatRecord(
                id: id, kind: .voice, notebookID: nil, title: "Cristae", startedAt: Date(timeIntervalSince1970: 1_759_400_000),
                endedAt: Date(timeIntervalSince1970: 1_759_400_600), summary: nil, overallScore: score, sourceIDs: [source],
                modelProvider: "OpenAI", modelID: "realtime",
                exchanges: [MobileChatRecord.Exchange(
                    id: "\(id)-ex-1", seq: 1, question: "Explain it", userAnswer: "It goes like this", evaluation: "Good",
                    score: score, answeredAt: Date(timeIntervalSince1970: 1_759_400_100), sourceRefs: [source], knowledgeNote: nil,
                    grading: MorningPickRule.explanationGrading(sourceCount: 1)
                )]
            )
        }
        try await writer.recordChat(chat("ios-live-held", source: "held-source", score: 1))
        try await writer.recordChat(chat("ios-live-partly", source: "partly-source", score: 0.5))
        let exchange = try #require(try await Fixture.held(replica, .exchange, "ios-live-held-ex-1", in: Fixture.library))
        #expect(exchange.fields["grading"]?["operation"] == .string("explain"))
        #expect(exchange.fields["grading"]?["questionVerdict"] == .string("sound"))
        let explained = try await MobileProjection(replica: replica).explainedSourceDates()
        #expect(Set(explained.keys) == ["held-source"])
    }

    @Test("A review recorded on the phone is written review and stays in Library when its notebook moves into a space")
    func reviewStaysInLibrary() async throws {
        let replica = try await Fixture.replica()
        try await Fixture.apply(replica, [(Fixture.library, try MobileReadModelFixture.notebook("nb1", "Mine", edited: 5))])
        let writer = Fixture.writer(replica)
        try await writer.recordChat(Self.chat("ios-r1", kind: .review, notebook: "nb1", turns: 1, score: 0.6))
        #expect(try await Fixture.held(replica, .chat, "ios-r1", in: Fixture.library)?.fields["kind"] == .string("review"))

        // A Mac moved the notebook into the space: a stub in Library, its copy in the space.
        try await Fixture.apply(replica, [
            (Fixture.library, try MobileReadModelFixture.notebook("nb1", "Mine", edited: 6, ["status": .string("moved"), "movedTo": .string("s1")])),
            (Fixture.space, try MobileReadModelFixture.notebook("nb1", "Mine", edited: 6)),
        ])
        try await writer.recordChat(Self.chat("ios-r1", kind: .review, notebook: "nb1", turns: 2, score: 0.7))
        let chat = try #require(try await Fixture.held(replica, .chat, "ios-r1", in: Fixture.library))
        #expect(chat.fields["notebookID"] == .string("nb1"), "it still names the notebook, which resolves into the space")
        #expect(try await Fixture.held(replica, .exchange, "ios-r1-ex-2", in: Fixture.library) != nil)
        #expect(try await Fixture.held(replica, .chat, "ios-r1", in: Fixture.space) == nil)

        // A new ordinary chat filed in it goes to the space.
        try await writer.recordChat(Self.chat("ios-c2", kind: .chat, notebook: "nb1", turns: 1))
        #expect(try await Fixture.held(replica, .chat, "ios-c2", in: Fixture.space) != nil)
    }

    @Test("A continued chat appends Exchange records after the highest seq and rewrites no record but the chat's editedAt")
    func continuedChatAppends() async throws {
        let (server, phone, writer) = try await Self.syncedPhone()
        try await writer.recordChat(Self.chat("ios-c1", kind: .chat, notebook: "nb1", turns: 2))
        try await phone.sync()
        let before = try #require(try Self.stored(server, .exchange, "ios-c1-ex-1", zone: "Library"))
        #expect(try await Fixture.patchCount(phone.replica) == 0)

        let added = [
            MobileNotebookChatContinuation.AddedExchange(id: "ios-c1-ex-1", userAnswer: "changed", evaluation: "changed", answeredAt: Date()),
            MobileNotebookChatContinuation.AddedExchange(id: "ios-c1~s2-1", userAnswer: "More?", evaluation: "Yes.", answeredAt: Date(timeIntervalSince1970: 1_759_500_000)),
            MobileNotebookChatContinuation.AddedExchange(id: "ios-c1~s2-2", userAnswer: "And?", evaluation: "So.", answeredAt: Date(timeIntervalSince1970: 1_759_500_100)),
        ]
        try await writer.transaction {
            try $0.appendExchanges(added, toChat: "ios-c1", knowledgeNote: "Recorded from a notebook chat on iOS.", modelProvider: "openrouter",
                                   modelID: "some/model", endedAt: Date(timeIntervalSince1970: 1_759_500_100))
        }
        #expect(try await Fixture.patched(phone.replica) == [
            "private/Library Chat ios-c1", "private/Library Exchange ios-c1~s2-1", "private/Library Exchange ios-c1~s2-2",
        ])
        #expect(try await Fixture.patch(phone.replica, .chat, "ios-c1", in: Fixture.library)?.changes.keys.sorted() == ["editedAt"])
        #expect(try await Fixture.held(phone.replica, .exchange, "ios-c1~s2-1", in: Fixture.library)?.fields["seq"] == SyncJSON(3))
        #expect(try await Fixture.held(phone.replica, .exchange, "ios-c1~s2-2", in: Fixture.library)?.fields["seq"] == SyncJSON(4))
        try await phone.sync()
        #expect(try Self.stored(server, .exchange, "ios-c1-ex-1", zone: "Library") == before, "the turn already saved is not rewritten")
        #expect(try Self.stored(server, .exchange, "ios-c1~s2-2", zone: "Library")?.fields["userAnswer"] == .string("And?"))
        await #expect(throws: MobileRecordWriterError.chatGone) {
            try await writer.transaction {
                try $0.appendExchanges(added, toChat: "nowhere", knowledgeNote: "", modelProvider: "", modelID: "", endedAt: Date())
            }
        }
    }

    // MARK: - Sending

    @Test("A pending write to a record a move took into a space lands on its copy, and never goes back to Library")
    func pendingWriteToAMovedRecord() async throws {
        let replica = try await Fixture.replica()
        try await Fixture.apply(replica, [
            (Fixture.library, try MobileReadModelFixture.chat("c1", notebook: "nb1", title: "Old", edited: 5)),
            (Fixture.space, try MobileReadModelFixture.chat("c1", notebook: "nb1", title: "Old", edited: 5)),
        ])
        let writer = Fixture.writer(replica, at: Date().addingTimeInterval(-60))
        try await writer.transaction { var patch = RecordPatch(.chat, id: "c1"); patch.changes["title"] = .value(.string("New")); try $0.write(patch, in: Fixture.library) }
        #expect(try await Fixture.changes(replica, scope: .privateZones).map(\.wireID) == ["c1"], "not moved yet: it goes to Library")

        let moves = MoveMapIndex()
        moves.add(key: "job1.1", moves: [MoveMapMove(type: "Chat", id: "c1", from: "Library", to: "Space-s1", at: 1)])
        replica.moveMaps = moves
        #expect(try await Fixture.changes(replica, scope: .privateZones).isEmpty)
        #expect(try await Fixture.patched(replica) == ["private/Space-s1 Chat c1"])
        let spaceChanges = try await Fixture.changes(replica, scope: .spaces)
        let change = try #require(spaceChanges.first)
        guard case .save(let envelope) = change.action else { Issue.record("a save"); return }
        #expect(envelope.fields["title"] == .string("New"))
        #expect(change.recordName == RecordNaming.recordName(type: .chat, id: "c1", salt: MobileSyncFixture.spaceSalt))
        #expect(try await replica.read { try $0.replica.record(zoneKey: Fixture.library, recordType: "Chat", wireID: "c1") } == nil)
    }

    @Test("Due records only: 2 s for structure, 30 s for a ReadingState; a delete goes out as one")
    func debounceAndDeletes() async throws {
        let replica = try await Fixture.replica()
        try await Fixture.apply(replica, [(Fixture.library, try MobileReadModelFixture.notebook("nb1", "Mine", edited: 5))])
        let now = Date()
        let writer = Fixture.writer(replica, at: now)
        try await writer.saveReadingPosition("src1", fraction: 0.4)
        _ = try await writer.createNotebook(title: "Second", instructions: nil, summary: nil)
        try await writer.transaction { try $0.deleteNotebook("nb1", deleteLinkedChats: false) }
        #expect(try await Fixture.changes(replica, at: now.addingTimeInterval(1)).isEmpty)
        let soon = try await Fixture.changes(replica, at: now.addingTimeInterval(3))
        #expect(soon.map(\.recordType).sorted { $0.rawValue < $1.rawValue } == [.notebook, .notebook])
        #expect(soon.contains { $0.action == .delete && $0.wireID == "nb1" })
        #expect(try await Fixture.changes(replica, at: now.addingTimeInterval(31)).contains { $0.recordType == .readingState })
        #expect(try await replica.read { try $0.connection.scalarInteger("SELECT COUNT(*) FROM m_notebooks WHERE id = 'nb1'") } == 0,
                "a deleted notebook leaves the screens at once")
    }
    @Test("A result's chat carries the creation site's kind, else the classifier's, and its turns under the old container's ids")
    func resultKinds() {
        var result = MobileReviewResult(sessionID: "ios-x", topic: "T", sourceID: "src1", goalID: "nb1", startedAt: Date(), endedAt: Date(),
                                        overallScore: nil, summary: "S", exchanges: [MobileReviewRecordedExchange(question: "", userAnswer: "Q",
                                        evaluation: "A", score: nil, answeredAt: Date())], gaps: [], knowledgeNote: "N", modelProvider: "p", modelID: "m")
        #expect(result.chatRecord.kind == .chat)
        result.kind = .review
        #expect(result.chatRecord.kind == .review, "a hands-free review is a review even ungraded")
        #expect(result.chatRecord.exchanges.first?.id == MobileReviewSessionRecorder.exchangeID(sessionID: "ios-x", sequence: 1))
        let memory = MobileReviewResult(sessionID: "memory-2026-10-04", topic: "T", sourceID: nil, goalID: nil, startedAt: Date(), endedAt: Date(),
                                        overallScore: nil, summary: "S", exchanges: [], gaps: [], knowledgeNote: "N", modelProvider: "p", modelID: "m")
        #expect(memory.chatRecord.kind == .memory)
    }
}

/// What the screens' models are told of the phone's own writes (`MobileReplicaChange`), and how the many
/// changes of a busy minute become few library reloads (`MobileReloadCoalescer`).
@Suite("iPhone replica change notices", .serialized)
struct MobileReplicaChangeNoticeTests {
    typealias Fixture = MobileWriterFixture

    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    @Test("A reading position, a day's activity and a sitting's answer are written every few seconds and tell the screens nothing; a notebook, a read mark and a placement do")
    func quietWritesStayQuiet() async throws {
        let replica = try await Fixture.replica(space: nil)
        let writer = Fixture.writer(replica, at: Date().addingTimeInterval(-60))
        let heard = Heard()
        let observer = NotificationCenter.default.addObserver(forName: .mobileReplicaDidChange, object: replica, queue: nil) { _ in heard.add() }
        defer { NotificationCenter.default.removeObserver(observer) }

        try await writer.saveReadingPosition("src1", fraction: 0.4)
        try await writer.saveReadingPosition("src1", fraction: 0.5)
        try await writer.transaction { write in
            try write.recordSourceActivity(sourceID: "src1", day: "2027-01-15", kind: "read", at: Date(), completed: false, fraction: 0.5, engagedSeconds: 40)
            try write.recordReviewSeconds(day: "2027-01-15", seconds: 60, goalSeconds: 900, at: Date())
            _ = try write.recordAnswer(MobileSittingRecorderTests.attempt("att1"), curriculumFingerprint: nil)
        }
        #expect(try await Fixture.patchCount(replica) > 0, "all of it was written and will be sent")
        #expect(heard.value == 0, "none of it is on a list, so no model reads the library again for it")

        _ = try await writer.createNotebook(title: "Cells", instructions: nil, summary: nil)
        #expect(heard.value == 1)
        try await writer.transaction { try $0.markRead("src1", at: Date(), consumed: false) }
        #expect(heard.value == 2, "the read mark is on the source's row")
        try await writer.transaction { try $0.schedule("src1", on: Date(), order: 0, goalID: nil) }
        #expect(heard.value == 3)
    }

    @Test("What changes a screen's model by type and by field")
    func policy() {
        #expect(!MobileReplicaChange.showsOnScreens(.sitting, changing: ["answers"]))
        #expect(!MobileReplicaChange.showsOnScreens(.activityLog, changing: ["sources"]))
        #expect(!MobileReplicaChange.showsOnScreens(.readingState, changing: ["locator", "lastReadAt", "furthest"]))
        #expect(!MobileReplicaChange.showsOnScreens(.readingState, changing: ["listen"]))
        #expect(MobileReplicaChange.showsOnScreens(.readingState, changing: ["readAt", "lastReadAt"]))
        #expect(MobileReplicaChange.showsOnScreens(.notebook, changing: ["title"]))
        #expect(MobileReplicaChange.showsOnScreens(.chat, changing: []), "a deletion of anything the screens list")
    }

    @Test("The first change after a quiet stretch reloads at once, those within the interval share one more, run when the interval is up")
    @MainActor
    func coalescing() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        var reloads = 0
        var slept: [TimeInterval] = []
        let coalescer = MobileReloadCoalescer(interval: 2, now: { clock }, sleep: { slept.append($0); clock = clock.addingTimeInterval($0) },
                                              reload: { reloads += 1 })
        func settle() async { for _ in 0..<30 { await Task.yield() } }

        for _ in 0..<50 { coalescer.changed() }
        await settle()
        #expect(reloads == 1 && slept.isEmpty, "fifty changes at once are one reload, with no wait before it")

        clock = clock.addingTimeInterval(0.5)
        for _ in 0..<50 { coalescer.changed() }
        await settle()
        #expect(reloads == 2, "one more for the burst that came within the interval")
        #expect(slept == [1.5], "run when the interval since the last reload was up")
        #expect(!coalescer.isWaiting)

        clock = clock.addingTimeInterval(10)
        coalescer.changed()
        await settle()
        #expect(reloads == 3 && slept == [1.5], "after a quiet stretch there is no wait")
    }
}
