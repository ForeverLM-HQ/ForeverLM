import Foundation
import Testing
@testable import ForeverLM

/// The ReadingState record on the Mac (docs/cloudkit-schema-design.md §3.5.18, §4.3, §12.7 v160, WP12):
/// one record per work from `reading_states`, the walk's progress and the Understanding row, all on the
/// source's wire id; the furthest pair's epoch; item completions; the narration's resume point from
/// the preference row and the file; team copies; arrival before the source; and a source delete.
@Suite("ReadingState projection")
struct ReadingStateProjectionTests {
    typealias F = NotebookSyncFixture

    static func fields(_ store: KnowledgeStore, _ targetID: String) throws -> [String: SyncJSON]? {
        F.savedFields(try F.pending(store)["ReadingState:rs:\(targetID)"])
    }

    /// A team's copy of `personalID`, as generation 1 holds one and WP7's wire ids name it.
    static func addTeamCopy(_ store: KnowledgeStore, _ id: String, of personalID: String) throws {
        try F.addTeamCopy(store, id, of: personalID)
    }

    static func viewed(_ store: KnowledgeStore, _ id: String, _ column: String) throws -> String? {
        try F.text(store, "SELECT CAST(\(column) AS TEXT) FROM source_projection WHERE id = ?", [.text(id)])
    }

    @Test("Mark unread starts the furthest pair's next epoch at 0, which beats older maxima")
    func furthestEpochReset() throws {
        let (root, store) = try F.makeStore("rs-epoch")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addSource(store, "src-1")
        try store.updateSourceReadingLocator(sourceID: "src-1", locator: #"{"webScrollFraction":0.6}"#)
        var fields = try #require(try Self.fields(store, "src-1"))
        #expect(fields["targetKind"] == .string("source") && fields["targetID"] == .string("src-1"))
        #expect(fields["furthest"] == .array([.number(0), .number(0.6)]))
        #expect(fields["locator"]?["t"] == .string("web") && fields["locator"]?["fraction"] == .number(0.6))
        #expect(fields["locator"]?["mac"] == .string(#"{"webScrollFraction":0.6}"#), "the Mac's own string rides along")
        #expect(fields["lastReadAt"]?.int64Value != nil)
        try F.sendAll(store)

        try store.updateSourceReadAt(sourceID: "src-1", readAt: Date(timeIntervalSinceReferenceDate: 700_000_000))
        try F.sendAll(store)
        try store.updateSourceReadAt(sourceID: "src-1", readAt: nil)
        fields = try #require(try Self.fields(store, "src-1"))
        #expect(fields["furthest"] == .array([.number(1), .number(0)]), "a reset is [epoch + 1, 0]")
        #expect(fields["readAt"] == .null)
        // X compares the pair: the reset outranks the older maximum.
        #expect(FieldMerge.compareOrdered(.array([.number(1), .number(0)]), .array([.number(0), .number(0.6)])).map { $0 > 0 } == true)
        // The view reads the reading state back.
        #expect(try Self.viewed(store, "src-1", "read_at") == nil)
        #expect(try Self.viewed(store, "src-1", "reading_position_locator") == #"{"webScrollFraction":0.6}"#)
    }

    @Test("completedAt comes from the item completions, and an inbound one completes every item of the source")
    func completedAtFromItemCompletions() throws {
        let (root, store) = try F.makeStore("rs-completed", triggers: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try F.addSource(store, "src-1")
        try F.addNotebook(store, "nb-1")
        try F.addNotebook(store, "nb-2")
        try F.file(store, "src-1", into: "nb-1")
        try F.file(store, "src-1", into: "nb-2")
        try store.execute("UPDATE learning_goal_items SET completed_at = CASE goal_id WHEN 'nb-1' THEN 900 ELSE 500 END")
        try store.deriveReadingStates()
        #expect(try F.text(store, "SELECT CAST(completed_at AS TEXT) FROM reading_states WHERE wire_id = 'src-1'") == "500.0", "the first completion")

        try F.prepareReplica(store)
        try store.installOutboxTriggers(F.registry)
        let at: Int64 = 1_759_400_000_000
        try F.apply(store, [try F.record(.readingState, "rs:src-1", [
            "targetKind": .string("source"), "targetID": .string("src-1"), "completedAt": SyncJSON(at),
        ])])
        let seconds = SyncTime.cocoaSeconds(milliseconds: at)
        #expect(try F.count(store, "SELECT COUNT(*) FROM learning_goal_items WHERE source_id = 'src-1' AND completed_at = ?", [.real(seconds)]) == 2)
        #expect(try F.pending(store).isEmpty, "an apply sends nothing back")
    }

    @Test("A position set on a team copy shows on the personal copy and the reverse, and a stale copy writes nothing")
    func teamCopySharesOneState() throws {
        let (root, store) = try F.makeStore("rs-team")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addSource(store, "src-p")
        try Self.addTeamCopy(store, "team-copy", of: "src-p")
        try store.updateSourceReadingPosition(sourceID: "team-copy", page: 4)
        #expect(try F.count(store, "SELECT COUNT(*) FROM reading_states") == 1)
        #expect(try F.text(store, "SELECT wire_id FROM reading_states") == "src-p")
        #expect(try Self.viewed(store, "src-p", "reading_position_page") == "4")
        #expect(try Self.viewed(store, "team-copy", "reading_position_page") == "4")

        try store.updateSourceReadingPosition(sourceID: "src-p", page: 9)
        #expect(try Self.viewed(store, "team-copy", "reading_position_page") == "9")
        // A write of the old columns (what a stale copy's generation-1 save does) changes nothing read.
        try store.execute("UPDATE sources SET reading_position_page = 2, read_at = 5 WHERE id = 'team-copy'")
        #expect(try Self.viewed(store, "team-copy", "reading_position_page") == "9")
        #expect(try Self.viewed(store, "team-copy", "read_at") == nil)
        let pending = try F.pending(store)
        #expect(pending["ReadingState:rs:team-copy"] == nil)
        #expect(Self.fieldsOf(pending["ReadingState:rs:src-p"])?["locator"] == .object(["t": .string("pdf"), "page": .number(9)]))
    }

    static func fieldsOf(_ change: OutboxChange?) -> [String: SyncJSON]? { F.savedFields(change) }

    @Test("The walk carries its current step, revealed beats, played steps, raw outcomes and its chat")
    func walkCarriesItsProgress() throws {
        let (rootA, storeA) = try F.makeStore("rs-walk-a")
        let (rootB, storeB) = try F.makeStore("rs-walk-b")
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        try F.prepareReplica(storeA)
        try F.prepareReplica(storeB)
        try F.addSource(storeA, "src-1")
        var progress = WalkthroughProgress(
            subjectID: "src-1", currentStepID: "s3", revealedBeats: ["s1": 2, "s3": 1], playedStepIDs: ["s1", "s3"],
            chatSessionID: "chat-9", updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
        progress.outcomeValues = ["s1": "remembered", "s3": "skippedByALaterBuild"]
        try storeA.saveWalkthroughProgress(progress)
        let fields = try #require(try Self.fields(storeA, "src-1"))
        let main = try #require(fields["walk"]?["main"])
        #expect(main["currentStepID"] == .string("s3"))
        #expect(main["revealedBeats"] == .object(["s1": .number(2), "s3": .number(1)]))
        #expect(main["playedStepIDs"] == .array([.string("s1"), .string("s3")]))
        #expect(main["outcomes"]?["s3"] == .string("skippedByALaterBuild"), "a raw outcome survives")
        #expect(main["chatID"] == .string("chat-9"))
        #expect(main["at"]?.int64Value == SyncTime.milliseconds(progress.updatedAt))

        // Another Mac applies it and reads the walk back whole; a course's walk is kept for the record.
        var walk = try #require(fields["walk"]?.objectValue)
        walk["course.crs-1"] = .object(["currentStepID": .string("c1")])
        var record = fields
        record["walk"] = .object(walk)
        try F.apply(storeB, [try F.record(.readingState, "rs:src-1", record)])
        #expect(try storeB.loadWalkthroughProgress("src-1") == progress)
        let rows = try ReadingStateProjection.rows(targetID: "src-1", connection: storeB)
        #expect(ReadingStateProjection.encodeRows(rows)["walk"]?["course.crs-1"] != nil, "a re-encode never drops another variant")
    }

    @Test("A newer playback-position.json beats the preference row; an evicted file's later patch loses to a newer position")
    func listenPositions() throws {
        let (root, store) = try F.makeStore("rs-listen", triggers: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try F.addSource(store, "src-1")
        try F.addSource(store, "src-2")
        let row = ArticleSpeechPlaybackPosition(globalTime: 30, appleCharacterOffset: nil, contentSignature: "sig", updatedAt: Date(timeIntervalSinceReferenceDate: 700_000_000))
        let file = ArticleSpeechPlaybackPosition(globalTime: 95, appleCharacterOffset: nil, contentSignature: "sig", updatedAt: Date(timeIntervalSinceReferenceDate: 700_000_100))
        try NotebookSchema156MigrationTests.setPreference(store, "listen.position.src-1", ListeningPositionSync.encode(row))
        try KnowledgeStore.$listenFileProbeOverride.withValue({ _ in ["src-1": .present(file), "src-2": .evicted] }) {
            try store.deriveReadingStates()
        }
        #expect(ListenPositionCodec.position(try ReadingStateRow.load("src-1", connection: store)?.listen) == file, "the newer updatedAt wins")
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = 'listenFile' AND target = 'src-2'") == 1)

        // Later the evicted file is downloaded: it becomes a patch stamped with its own time.
        try F.prepareReplica(store)
        let evicted = ArticleSpeechPlaybackPosition(globalTime: 12, appleCharacterOffset: 40, contentSignature: nil, updatedAt: Date(timeIntervalSinceReferenceDate: 700_000_000))
        let read = try KnowledgeStore.$listenFileProbeOverride.withValue({ _ in ["src-2": .present(evicted)] }) {
            try store.runListenFileBackfill()
        }
        #expect(read == 1)
        let patch = try #require(try PendingPatch.load(zoneKey: F.libraryZoneKey, type: "ReadingState", wireID: "rs:src-2", in: store))
        guard case .value(let stamp)? = patch.stamps["listen"] else {
            Issue.record("no listen stamp")
            return
        }
        #expect(stamp.milliseconds == SyncTime.milliseconds(evicted.updatedAt))
        let local = patch.applied(to: SyncEnvelope.new(.readingState, id: "rs:src-2", saltID: OutboxTestProjections.saltID))
        let newer = ListenPositionCodec.wire(ArticleSpeechPlaybackPosition(globalTime: 500, appleCharacterOffset: nil, contentSignature: nil, updatedAt: Date()))
        let server = try SyncEnvelope(storedPayload: try F.record(.readingState, "rs:src-2", [
            "targetKind": .string("source"), "targetID": .string("src-2"), "listen": newer,
        ], ms: SyncTime.milliseconds(Date())).payload)
        #expect(FieldMerge.merge(server: server, local: local, base: nil).merged.fields["listen"] == newer, "a newer position from another device wins")
        let older = try SyncEnvelope(storedPayload: try F.record(.readingState, "rs:src-2", [
            "targetKind": .string("source"), "targetID": .string("src-2"), "listen": newer,
        ], ms: SyncTime.milliseconds(evicted.updatedAt) - 60_000).payload)
        #expect(FieldMerge.merge(server: older, local: local, base: nil).merged.fields["listen"] == ListenPositionCodec.wire(evicted), "and the file beats an older one")
    }

    @Test("The sources with open threads are named by the id this Mac holds, not by the wire id the index is keyed by")
    func unfinishedUnderstandingNamesLocalRows() throws {
        let (root, store) = try F.makeStore("rs-unfinished", triggers: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.addTeamCopy(store, "team-copy", of: "wk-1")
        try F.addSource(store, "src-2")
        try store.execute("""
            INSERT INTO source_understanding (source_id, relative_path, generated_at, generator_version, body_sha256, discussed_idea_ids, open_thread_count)
            VALUES ('wk-1', 'a.md', 10, 1, 'a', '[]', 3), ('src-2', 'b.md', 10, 1, 'b', '[]', 1)
        """)
        #expect(try store.unfinishedUnderstandingSourceIDs() == ["team-copy", "src-2"])
    }

    @Test("An idea listed twice in the Understanding row is sent once, never a trap")
    func duplicateDiscussedIdeas() throws {
        let (root, store) = try F.makeStore("rs-dup-ideas", triggers: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try F.addSource(store, "src-1")
        try store.execute("""
            INSERT INTO source_understanding (source_id, relative_path, generated_at, generator_version, body_sha256, discussed_idea_ids)
            VALUES ('src-1', 'a.md', 10, 1, 'a', '["i1","i1","i2"]')
        """)
        let rows = try ReadingStateProjection.rows(targetID: "src-1", connection: store)
        #expect(ReadingStateProjection.encodeRows(rows)["discussedIdeaKeys"]?.objectValue.map { Set($0.keys) } == ["i1", "i2"])
    }

    @Test("A team copy's and the personal copy's rows that meet on one wire id merge column by column")
    func teamAndPersonalRowsMerge() throws {
        let (root, store) = try F.makeStore("rs-merge", triggers: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try F.addSource(store, "src-p")
        try Self.addTeamCopy(store, "team-copy", of: "src-p")
        try store.executeScript("""
            UPDATE sources SET reading_position_locator = '{"webScrollFraction":0.3}', read_at = 100 WHERE id = 'src-p';
            UPDATE sources SET reading_position_locator = '{"webScrollFraction":0.7}', read_at = 200, review_depth = 'deep' WHERE id = 'team-copy';
            INSERT INTO hidden_sources (source_id, hidden_at) VALUES ('src-p', 5), ('team-copy', 9);
            INSERT INTO source_understanding (source_id, relative_path, generated_at, generator_version, body_sha256, discussed_idea_ids)
            VALUES ('src-p', 'mine.md', 10, 1, 'a', '["i1"]'), ('team-copy', 'team.md', 20, 1, 'b', '["i2"]');
            INSERT INTO walkthrough_progress (subject_id, progress_json, updated_at)
            VALUES ('src-p', '{"subject_id":"src-p","updated_at":1}', 1), ('team-copy', '{"subject_id":"team-copy","updated_at":2}', 2);
        """)
        func run() throws -> String {
            try store.rekeyTeamCopiesPerMemberRows()
            try store.deriveReadingStates()
            var lines: [String] = []
            for sql in [
                "SELECT wire_id || '|' || locator_json || '|' || furthest || '|' || read_at || '|' || review_depth FROM reading_states",
                "SELECT source_id || '|' || hidden_at FROM hidden_sources",
                "SELECT source_id || '|' || relative_path || '|' || discussed_idea_ids FROM source_understanding",
                "SELECT subject_id || '|' || progress_json FROM walkthrough_progress",
            ] {
                try store.query(sql, []) { row in lines.append(row.text(0) ?? "-") }
            }
            return lines.joined(separator: "\n")
        }
        let first = try run()
        let state = try #require(try ReadingStateRow.load("src-p", connection: store))
        #expect(ReadingLocatorCodec.macLocator(wire: state.locator) == #"{"webScrollFraction":0.3}"#, "the personal copy's place")
        #expect(state.furthest == 0.7, "furthest takes the maximum")
        #expect(state.readAt == 200 && state.reviewDepth == "deep")
        #expect(try F.text(store, "SELECT CAST(hidden_at AS TEXT) FROM hidden_sources WHERE source_id = 'src-p'") == "9.0")
        #expect(try F.text(store, "SELECT relative_path || discussed_idea_ids FROM source_understanding WHERE source_id = 'src-p'") == #"team.md["i1","i2"]"#)
        #expect(try F.text(store, "SELECT progress_json FROM walkthrough_progress WHERE subject_id = 'src-p'")?.contains("team-copy") == true)
        #expect(try F.count(store, "SELECT COUNT(*) FROM hidden_sources WHERE source_id = 'team-copy'") == 0)
        #expect(try run() == first, "a second run changes nothing")
    }

    @Test("A ReadingState applied before its Source is held, and shows when the source arrives")
    func appliedBeforeItsSource() throws {
        let (root, store) = try F.makeStore("rs-early")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        let at: Int64 = 1_759_400_000_000
        try F.apply(store, [try F.record(.readingState, "rs:src-late", [
            "targetKind": .string("source"), "targetID": .string("src-late"), "readAt": SyncJSON(at),
            "locator": .object(["t": .string("epub"), "href": .string("OEBPS/c3.xhtml"), "fraction": .number(0.42)]),
        ])])
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_unprojected") == 0, "it waits on nothing")
        #expect(try F.count(store, "SELECT COUNT(*) FROM reading_states WHERE wire_id = 'src-late'") == 1)
        try F.addSource(store, "src-late")
        #expect(try Self.viewed(store, "src-late", "read_at") == String(SyncTime.cocoaSeconds(milliseconds: at)))
        #expect(try store.loadSourceReadingLocator(sourceID: "src-late") == #"{"relativePath":"OEBPS/c3.xhtml","scrollFraction":0.42}"#)
        #expect(try F.pending(store)["ReadingState:rs:src-late"] == nil, "the apply sends nothing back")
    }

    @Test("A source delete keeps the ReadingState row and record")
    func sourceDeleteKeepsReadingState() throws {
        let (root, store) = try F.makeStore("rs-delete")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addSource(store, "src-1")
        try store.updateSourceReadingPosition(sourceID: "src-1", page: 3)
        try F.sendAll(store)
        #expect(try F.held(store, .readingState, "rs:src-1") != nil)
        try store.deleteSource("src-1")
        #expect(try F.count(store, "SELECT COUNT(*) FROM reading_states WHERE wire_id = 'src-1' AND position = 3") == 1)
        #expect(try F.pending(store)["ReadingState:rs:src-1"] == nil, "nothing about the reading state is sent")
    }
}
