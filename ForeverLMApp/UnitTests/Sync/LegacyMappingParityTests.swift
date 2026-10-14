import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// `LegacyV2Mapping` against the activation's derivations (docs/cloudkit-schema-design.md §10, §13.6, R17,
/// WP15c): the same old records give the same v2 records either way, chat kinds and `marksReviewed`
/// included, and an Idea with its links; two Macs hash alike; every record a mapping gives is classified as owned or not; what an
/// old payload omits gives nothing; and the revision-9, R5-2, R6-2, R7-m1, R7-m5 and R8-m7 cases.
@Suite("Legacy mapping parity")
struct LegacyMappingParityTests {
    typealias F = LegacyParityFixture

    /// An old world applied to a generation-1 store, and the mappings of its records taken before the
    /// activation, so they read only generation-1 truth.
    struct World {
        let root: URL
        let store: KnowledgeStore
        let records: [CKRecord]
        let mappings: [LegacyMapping]

        func mapping(_ entity: CloudKitSyncEntity, _ key: String) -> LegacyMapping? {
            mappings.first { $0.entity == entity && $0.logicalKey == key }
        }
    }

    static func world(_ name: String) throws -> World {
        let (root, store) = try F.makeStore(name)
        let records = try F.oldWorld(in: root.appendingPathComponent("assets", isDirectory: true))
        try F.apply(records, to: store)
        return World(root: root, store: store, records: records, mappings: try F.mappings(records, store: store))
    }

    @Test("Every record the mapping gives is the record the activation derives, field for field")
    func mappingMatchesActivation() throws {
        let world = try Self.world("parity")
        defer { try? FileManager.default.removeItem(at: world.root) }
        try F.activate(world.store)

        let merged = F.merged(world.mappings)
        #expect(merged.count > 30, "the old world gives every kind of record")
        for (key, record) in merged.sorted(by: { $0.key < $1.key }) {
            let derived = try F.encoded(world.store, record.type, record.id)
            #expect(derived != nil, "the activation derives \(key)")
            guard let derived else { continue }
            var expected = F.normalized(derived, dropping: F.activationOnly[record.type] ?? [])
            var given = F.normalized(record.fields)
            // The activation stamps an override with the time it applied the old record, which the mapping has not.
            if record.type == .mark, MarkKey(id: record.id)?.kind == "visibleOverride" {
                expected["at"] = nil
                given["at"] = nil
            }
            let missing = Set(given.keys).symmetricDifference(expected.keys).sorted()
            let changed = given.keys.filter { expected[$0] != nil && given[$0] != expected[$0] }.sorted()
            #expect(given == expected, Comment(rawValue: "\(key) differs: \(missing) \(changed)"))
        }

        // Chat kinds and `marksReviewed` (D50, R4-m8).
        func chat(_ id: String) -> [String: SyncJSON]? { merged["Chat:\(id)"]?.fields }
        #expect(chat("chat-plain")?["kind"] == "chat")
        #expect(chat("chat-review")?["kind"] == "review")
        #expect(chat(F.quizChatID)?["kind"] == "quizSitting")
        #expect(chat("mac-live-1")?["kind"] == "voice")
        #expect(chat("memory-1")?["kind"] == "memory")
        #expect(chat(F.walkChatID)?["kind"] == "walkthrough")
        #expect(chat("chat-plain")?["marksReviewed"] == .bool(true), "a chat with no kind marks reviewed, as today's appends do")
        #expect(chat("memory-1")?["marksReviewed"] == .bool(false))
        #expect(chat("chat-review")?["overallScore"] == .number(0.8), "a review keeps its score")

        // An Idea: archived reads as `dismissed`, its links keyed by target (§3.5.26, WP25a).
        let idea = try #require(merged["Idea:\(F.ideaID)"]?.fields)
        #expect(idea["kind"] == .string("idea") && idea["status"] == .string("dismissed"))
        #expect(idea["body"] == .string("Check the kinetics paper"))
        #expect(Set(idea["links"]?.objectValue?.keys.map { $0 } ?? []) == ["src:src-article", "nb:\(F.notebookID)", "cht:chat-plain"])
        #expect(idea["links"]?["src:src-article"]?["kind"] == .string("source"))
    }

    @Test("Every source, notebook, Entry, chat, course and Doc the activation derives, the mapping gives")
    func mappingCoversTheLibrary() throws {
        let world = try Self.world("coverage")
        defer { try? FileManager.default.removeItem(at: world.root) }
        try F.activate(world.store)
        let given = Set(world.mappings.flatMap(\.records).map(\.key))

        var wanted: [String] = []
        func collect(_ type: SyncRecordType, _ sql: String) throws {
            try world.store.query(sql, []) { row in if let id = row.text(0) { wanted.append("\(type.rawValue):\(id)") } }
        }
        try collect(.source, "SELECT id FROM sources")
        try collect(.notebook, "SELECT id FROM learning_goals WHERE entity_kind = 'notebook'")
        try collect(.goal, "SELECT id FROM learning_goals WHERE entity_kind = 'goal'")
        try collect(.artifact, "SELECT 'notes:' || id FROM learning_goals WHERE entity_kind = 'notebook'")
        try collect(.entry, "SELECT 'en:' || goal_id || ':source:' || source_id FROM learning_goal_items")
        try collect(.entry, "SELECT 'en:' || goal_id || ':course:' || course_id FROM notebook_course_links")
        try collect(.entry, "SELECT 'en:' || group_id || ':source:' || source_id FROM group_members WHERE group_id LIKE 'playlist\\_%' ESCAPE '\\'")
        try collect(.course, "SELECT id FROM courses")
        try collect(.lesson, "SELECT id FROM course_lectures")
        try collect(.quiz, "SELECT id FROM course_quizzes")
        try collect(.chat, "SELECT id FROM review_sessions")
        try collect(.artifact, "SELECT id FROM global_artifacts WHERE id NOT LIKE 'carddeck-%'")
        try collect(.comment, "SELECT id FROM artifact_comments")
        try collect(.placement, "SELECT id FROM scheduled_sources")
        try collect(.card, "SELECT id FROM memory_items")
        try collect(.collection, "SELECT id FROM books UNION SELECT id FROM meeting_groups UNION SELECT id FROM video_playlists UNION SELECT id FROM source_collections")
        // The learner's own records: highlights, reading states, enrollments, answers' Sittings, logs and hides.
        try collect(.highlight, "SELECT highlight_id FROM source_highlights")
        try collect(.readingState, "SELECT 'rs:' || wire_id FROM reading_states UNION SELECT 'rs:' || subject_id FROM walkthrough_progress")
        try collect(.enrollment, "SELECT 'enr:' || course_id FROM course_enrollments")
        try collect(.sitting, "SELECT id FROM memory_sittings")
        try collect(.activityLog, "SELECT 'al:' || day || ':' || device_id FROM activity_logs")
        try collect(.card, "SELECT card_id FROM memory_card_states")
        try collect(.idea, "SELECT id FROM ideas")
        try collect(.mark, "SELECT 'mk:hidden:src:' || source_id FROM hidden_sources UNION SELECT 'mk:hidden:art:' || artifact_id FROM hidden_artifacts "
                    + "UNION SELECT 'mk:hidden:cht:' || session_id FROM hidden_review_sessions UNION SELECT 'mk:liked:src:' || source_id FROM videos WHERE liked_at IS NOT NULL "
                    + "UNION SELECT 'mk:rated:exc:' || id FROM review_exchanges WHERE rating IS NOT NULL UNION SELECT 'mk:wantIdea:src:' || source_id || '#' || id FROM source_ideas WHERE wanted = 1")
        for key in wanted {
            #expect(given.contains(key), "the mapping gives \(key)")
        }
    }

    @Test("Two Macs mapping one old world compute the same owner flags and field hashes")
    func twoMacsHashAlike() throws {
        let first = try Self.world("mac-a")
        let second = try Self.world("mac-b")
        defer {
            try? FileManager.default.removeItem(at: first.root)
            try? FileManager.default.removeItem(at: second.root)
        }
        #expect(first.mappings.count == second.mappings.count)
        for (a, b) in zip(first.mappings, second.mappings) {
            #expect(a.baseEntry().serialized() == b.baseEntry().serialized(), "\(a.entity.rawValue) \(a.logicalKey)")
        }
    }

    @Test("A notebook made, or a show blocked, after the activation began is the new world's: no old row turns it off (F7)")
    func newWorldIsNotTurnedOff() throws {
        let world = try Self.world("new-world")
        defer { try? FileManager.default.removeItem(at: world.root) }
        let context = StoreLegacyMappingContext(connection: world.store)
        #expect(try context.notebookIDs().contains(F.notebookID), "with no activation journal nothing is left out")

        let started = Date(timeIntervalSinceNow: -3_600).timeIntervalSinceReferenceDate
        try world.store.execute("CREATE TABLE IF NOT EXISTS ck_activation (id INTEGER PRIMARY KEY, started_at REAL)")
        try world.store.execute("INSERT OR REPLACE INTO ck_activation (id, started_at) VALUES (1, ?)", [.real(started)])
        try world.store.execute("UPDATE learning_goals SET created_at = ? WHERE id = ?", [.real(started + 60), .text(F.notebookID)])
        #expect(try !context.notebookIDs().contains(F.notebookID), "a notebook made after T0 is listed by no old pins row")
        try world.store.execute("UPDATE learning_goals SET created_at = ? WHERE id = ?", [.real(started - 60), .text(F.notebookID)])
        #expect(try context.notebookIDs().contains(F.notebookID), "one that existed is")

        try world.store.execute("DELETE FROM blocked_podcast_shows")
        try world.store.execute("INSERT INTO blocked_podcast_shows (show_name, blocked_at) VALUES ('Old Show', ?), ('New Show', ?)", [.real(started - 60), .real(started + 60)])
        #expect(try context.heldBlockedShows() == ["Old Show"], "a show blocked after T0 is not turned off by a row that never listed it")
    }

    @Test("An existing Entry, Lesson or Task keeps its place: the order key is a creation's alone and is not hashed (F4)")
    func orderKeysAreCreateOnly() throws {
        let world = try Self.world("order-keys")
        defer { try? FileManager.default.removeItem(at: world.root) }
        let ordered = world.mappings.flatMap(\.records).filter { [.entry, .lesson, .task].contains($0.type) && $0.fields["orderKey"] != nil }
        // Three kinds carry a key that is the old record's own value: a meeting's action item (placed by its `position`,
        // `<source>#<n>`), a playlist's member (by its sort index) and a followed course (one fixed key). They change only
        // when the old record does, so they are hashed. Every other item is planned against this Mac's held keys.
        func carriesItsOwnKey(_ record: LegacyV2Record) -> Bool {
            (record.type == .task && record.id.contains("#"))
                || (record.type == .entry && (record.fields["containerKind"] == "playlist" || EntryID(record.id)?.itemKind == "course"))
        }
        let ownKey = ordered.filter(carriesItsOwnKey)
        let placed = ordered.filter { !carriesItsOwnKey($0) }
        #expect(!placed.isEmpty, "the old world has items that are placed")
        #expect(Set(ownKey.map(\.type)) == [.task, .entry], "and a meeting's action item, a playlist's member and a followed course")
        for record in ownKey {
            #expect(!record.createOnlyFields.contains("orderKey") && LegacyFieldHashes.hashes(record)["orderKey"] != nil, "\(record.key)")
        }
        for record in placed {
            #expect(record.createOnlyFields.contains("orderKey"), "\(record.key)")
            #expect(LegacyFieldHashes.hashes(record)["orderKey"] == nil, "\(record.key): a key planned against this Mac's held keys is no change of the old record")
        }
        for notebook in world.mappings.flatMap(\.records).filter({ $0.type == .notebook }) {
            for (question, row) in notebook.fields["researchQuestions"]?.objectValue ?? [:] {
                var withoutKey = row.objectValue ?? [:]
                withoutKey["orderKey"] = nil
                #expect(LegacyFieldHashes.hashes(notebook)["researchQuestions/\(question)"] == LegacyFieldHashes.hash(.object(withoutKey)))
            }
        }
    }

    @Test("A quiz's revision is hashed by its questions, so an old Course write that leaves them alone does not raise it (F34)")
    func quizRevisionFollowsTheQuestions() throws {
        let world = try Self.world("quiz-revision")
        defer { try? FileManager.default.removeItem(at: world.root) }
        let quizzes = world.mappings.flatMap(\.records).filter { $0.type == .quiz }
        #expect(!quizzes.isEmpty)
        for quiz in quizzes {
            let revision = try #require(quiz.fields["revision"])
            #expect(LegacyFieldHashes.hashes(quiz)["revision"] != LegacyFieldHashes.hash(revision), "\(quiz.id): the revision itself is no change of the old record")
        }
    }

    @Test("Every (old type, v2 type) pair is classified, and only §10's records have no owner")
    func ownershipIsClassified() throws {
        let world = try Self.world("owners")
        defer { try? FileManager.default.removeItem(at: world.root) }
        let unownedTypes: Set<SyncRecordType> = LegacyOwnership.neverRemoved.union([.collection, .device, .zoneRoot])
        for mapping in world.mappings {
            for record in mapping.records {
                #expect(LegacyOwnership.allows(mapping.entity, record), "\(mapping.entity.rawValue) gives \(record.key) as \(record.giving.rawValue)")
                if !record.owned, record.giving != .feeds {
                    #expect(unownedTypes.contains(record.type), "\(record.key) has no owner")
                }
            }
        }
        // A Source owns its playlist Entry only for a `playlist_` group (R6-2, R7-m5); the playlist's
        // Collection comes from the group id, create only, and a course's group gives nothing.
        let video = try #require(world.mapping(.source, "src-video-pl"))
        let entry = try #require(video.record(.entry, PlaylistEntryProjection.entryID(playlistID: F.playlistGroup, sourceID: "src-video-pl")))
        #expect(entry.owned)
        let playlist = try #require(video.record(.collection, F.playlistGroup))
        #expect(playlist.giving == .createsOnly)
        #expect(playlist.fields["kind"] == "playlist")
        #expect(playlist.fields["externalKey"] == .string(String(F.playlistGroup.dropFirst(PlaylistEntryProjection.playlistPrefix.count))))
        #expect(playlist.fields["title"] == .string(F.playlistGroup))
        let member = try #require(world.mapping(.source, "src-course-member"))
        #expect(member.records.filter { $0.giving != .clears }.map(\.type) == [.source], "a course's group id gives no Entry and no Collection")
        let channel = try #require(world.mapping(.source, "src-video-ch")?.records.first { $0.type == .collection })
        #expect(channel.giving == .creates)
        #expect(channel.fields["kind"] == "youtubeChannel")
        // A meeting series feeds its sessions' attachments and owns its action items.
        let series = try #require(world.mapping(.meetingGroup, "mg-1"))
        let attachments = try #require(series.record(.source, "src-meeting"))
        #expect(attachments.giving == .feeds)
        #expect(attachments.fields["meta"]?["attachments"]?["ma-1"]?["title"] == "Slides")
        #expect(series.records.contains { $0.type == .task && $0.owned })
        // A draft deck whose package did not come gives nothing (with one: `CardRecordLifecycleTests.lateImportDeck`).
        let deck = LegacyRecord(
            entity: .artifact, logicalKey: "carddeck-src-article", recordName: "r", modifiedAt: Date(),
            payload: .artifact(CloudKitArtifactPayload(artifact: ArtifactRecord(
                id: "carddeck-src-article", title: "Cards", homeNotebookID: nil, linkedNotebookIDs: [], kind: .flashcards, createdAt: Date(), updatedAt: Date()
            )))
        )
        #expect(try LegacyV2Mapping.map(deck, context: StoreLegacyMappingContext(connection: world.store)).records.isEmpty)
    }

    @Test("A key an old payload omits gives nothing and never counts as a removed child")
    func omittedKeysGiveNothing() throws {
        let world = try Self.world("omitted")
        defer { try? FileManager.default.removeItem(at: world.root) }
        let context = StoreLegacyMappingContext(connection: world.store)
        func map(_ entity: CloudKitSyncEntity, _ key: String, _ payload: LegacyPayload) throws -> LegacyMapping {
            try LegacyV2Mapping.map(LegacyRecord(entity: entity, logicalKey: key, recordName: key, modifiedAt: Date(), payload: payload), context: context)
        }

        let course = try map(.course, "c-old", .course(CloudKitCoursePayload(
            id: "c-old", title: "Old", courseCode: nil, institution: nil, instructors: nil, playlistURL: nil, quizzes: nil
        )))
        #expect(!course.records.contains { $0.type == .quiz || $0.type == .lesson })
        #expect(course.isSilent(on: .quiz, id: "quiz-1"), "no `quizzes` removes no Quiz")
        #expect(course.isSilent(on: .lesson, id: "lec-1"), "an empty outline, which generation 1 never applies, removes no Lesson")

        let goal = LearningGoalRecord(id: F.notebookID, title: "Mitochondria", startAt: F.date(1), endAt: F.openEnd, createdAt: F.date(1),
                                      updatedAt: F.date(2), status: "active", items: [], kind: "companion")
        let notebook = try map(.learningGoal, F.notebookID, .learningGoal(CloudKitLearningGoalPayload(goal: goal)))
        #expect(notebook.isSilent(on: .entry, id: SyncIdentity.entryID(containerID: F.notebookID, itemKind: "course", itemID: F.followedCourse)))
        #expect(!notebook.isSilent(on: .entry, id: SyncIdentity.entryID(containerID: F.notebookID, itemKind: "source", itemID: "src-article")))
        let fields = try #require(notebook.record(.notebook, F.notebookID)?.fields)
        for omitted in ["researchQuestions", "openQuestions", "relatedNotebookIDs", "repository", "homeArtifactID"] {
            #expect(fields[omitted] == nil, "\(omitted) is omitted")
        }

        let series = try map(.meetingGroup, "mg-2", .meetingGroup(CloudKitMeetingGroupPayload(id: "mg-2", metadata: MeetingMetadata(title: "Old"))))
        #expect(series.isSilent(on: .task, id: "src-meeting#0"))
    }

    @Test("Collections rows give NotebookState.collections and their Settings, hashed per element; a deleted row the empty list")
    func notebookCollectionsRows() throws {
        let world = try Self.world("collections")
        defer { try? FileManager.default.removeItem(at: world.root) }
        let membership = try #require(world.mapping(.preference, NotebookCollections.membershipPreferenceKeyPrefix + F.notebookID))
        let state = try #require(membership.record(.notebookState, SyncIdentity.notebookStateID(notebookID: F.notebookID)))
        #expect(state.giving == .creates)
        #expect(state.wholeFields == ["collections"])
        #expect(state.fields["notebookID"] == .string(F.notebookID))
        let hashes = try #require(membership.hashes[state.key])
        #expect(hashes["collections/nbc-1"] != nil)
        #expect(hashes["collections/nbc-2"] != nil, "the base names every id the row held (R8-m7)")

        let name = try #require(world.mapping(.preference, "notebookCollection.nbc-1"))
        let setting = try #require(name.record(.setting, "notebookCollection.nbc-1"))
        #expect(setting.owned)
        #expect(setting.fields["value"]?["v"] == "Bioenergetics")

        let deleted = LegacyV2Mapping.mapDeletion(entity: .preference, logicalKey: NotebookCollections.membershipPreferenceKeyPrefix + F.notebookID)
        let emptied = try #require(deleted.record(.notebookState, SyncIdentity.notebookStateID(notebookID: F.notebookID)))
        #expect(emptied.fields["collections"] == .object([:]), "a deleted row is the empty list (R7-m1)")
        #expect(emptied.wholeFields == ["collections"])
        #expect(LegacyV2Mapping.mapDeletion(entity: .preference, logicalKey: "account.displayName").records.isEmpty)
    }

    @Test("An old unticked list names its Entries from the replica, is a whole field, and a deleted row takes its ids out (F6)")
    func chatExclusionRows() throws {
        let world = try Self.world("exclusions")
        defer { try? FileManager.default.removeItem(at: world.root) }
        try F.activate(world.store)
        // The Entry's stamps are the replica's: the seed has sent the Entry, so they can be named. Without them
        // every untick waits (`NotebookStateRow.pendingPair`) and the field is held back whole.
        try NotebookSyncFixture.prepareReplica(world.store)
        let entryID = SyncIdentity.entryID(containerID: F.notebookID, itemKind: "source", itemID: "src-article")
        try world.store.replica.upsertRecord(try NotebookSyncFixture.record(.entry, entryID, ["state": .string("active"), "approval": .string("approved")]))
        let context = StoreLegacyMappingContext(connection: world.store)
        // A source in the notebook's context is an untick whatever this Mac held before; one in no Entry of it is not.
        let pairs = try context.excludedPairs(notebookID: F.notebookID, sources: ["src-article", "src-in-no-notebook"])
        #expect(pairs.keys.sorted() == ["src-article"], "an untick of a source no Entry holds is not stored (§5.6): \(pairs)")
        #expect(pairs["src-article"].map { $0 != NotebookStateRow.pendingPair } == true, "named from the replica's Entry: \(pairs)")

        let payload = CloudKitPreferencePayload(
            key: NotebookChatSelection.preferenceKeyPrefix + F.notebookID, valuePlistXML: PreferenceStore.encodePlist(["src-article"]) ?? "", updatedAt: Date()
        )
        var mapping = LegacyMapping(entity: .preference, logicalKey: payload.key)
        try LegacyV2Mapping.mapPreference(payload, context: context, into: &mapping)
        let state = try #require(mapping.record(.notebookState, SyncIdentity.notebookStateID(notebookID: F.notebookID)))
        #expect(state.wholeFields == ["excluded"], "a re-tick leaves the map")
        #expect(LegacyFieldHashes.hashes(state)["excluded/src-article"] == LegacyFieldHashes.hash(.bool(true)), "hashed by the source alone, not by its Entry's stamps")

        for prefix in [NotebookChatSelection.preferenceKeyPrefix, NotebookChatContext.preferenceKeyPrefix] {
            let deleted = LegacyV2Mapping.mapDeletion(entity: .preference, logicalKey: prefix + F.notebookID)
            let emptied = try #require(deleted.record(.notebookState, SyncIdentity.notebookStateID(notebookID: F.notebookID)))
            #expect(emptied.giving == .clears && emptied.wholeFields.count == 1, "a deleted row is the empty list and makes no record")
        }
    }

    @Test("A course's home gives nothing; the follow comes only from the notebook's list (revision 9)")
    func followComesOnlyFromTheNotebook() throws {
        let world = try Self.world("follow")
        defer { try? FileManager.default.removeItem(at: world.root) }
        let homed = try #require(world.mapping(.course, F.homedCourse))
        #expect(!homed.records.contains { $0.type == .entry && EntryID($0.id)?.itemKind == "course" })
        #expect(homed.record(.course, F.homedCourse)?.fields["notebookID"] == nil)

        let follows = world.mappings.flatMap(\.records).filter { $0.type == .entry && EntryID($0.id)?.itemKind == "course" }
        #expect(follows.map(\.id) == [SyncIdentity.entryID(containerID: F.notebookID, itemKind: "course", itemID: F.followedCourse)])
        #expect(follows.first?.owned == true)
    }

    @Test("A chat over 512 KiB and a Doc decode from payloadAsset, and a Doc's body hashes by its bodyRevision")
    func payloadAssetForms() throws {
        let world = try Self.world("asset")
        defer { try? FileManager.default.removeItem(at: world.root) }
        let folder = world.root.appendingPathComponent("big", isDirectory: true)
        let context = StoreLegacyMappingContext(connection: world.store)

        let long = String(repeating: "Complex IV reduces oxygen to water. ", count: 16_000)
        let chat = CloudKitReviewSessionPayload(
            id: "chat-long", topic: "Long", startedAt: F.date(100), endedAt: nil, status: "completed", overallScore: nil, summary: nil,
            sourceIDs: [], cardIDs: [], exchangeCount: 1,
            exchanges: [CloudKitReviewExchangePayload(id: "ex-long", sessionID: "chat-long", sequenceNumber: 0, question: "Explain",
                                                      userAnswer: long, evaluation: "Yes", score: nil, sourceRefs: [], knowledgeNote: nil, answeredAt: F.date(101))]
        )
        let data = try F.json(chat)
        #expect(data.count > 512 * 1_024)
        let decoded = try LegacyRecordDecoder.decode(F.record(.reviewSession, "chat-long", data, payloadInAsset: true, in: folder))
        let mapped = try LegacyV2Mapping.map(decoded, context: context)
        #expect(mapped.record(.chat, "chat-long") != nil)
        #expect(mapped.record(.exchange, "ex-long")?.fields["userAnswer"] != nil, "the turn is given, its text spilled if long")

        let doc = try #require(world.records.first { $0.recordType == CloudKitSyncEntity.artifact.recordType })
        let fetched = try LegacyRecordDecoder.decode(doc)
        #expect(fetched.bodyPackage != nil)
        guard case .artifact(let payload) = fetched.payload, let revision = payload.bodyRevision else {
            Issue.record("the Doc decodes as an Artifact with a bodyRevision")
            return
        }
        let withBody = try #require(try LegacyV2Mapping.map(fetched, context: context).record(.artifact, F.docID))
        #expect(FileRef(json: withBody.fields["body"] ?? .null)?.hash == revision, "the body's FileRef carries the bodyRevision")
        #expect(LegacyFieldHashes.hashes(withBody)["body"] == revision)

        // An unchanged Doc's package is never downloaded: no body, the same hash.
        let unfetched = LegacyRecord(entity: .artifact, logicalKey: F.docID, recordName: fetched.recordName, modifiedAt: fetched.modifiedAt,
                                     payload: fetched.payload, bodyPackage: nil)
        let without = try #require(try LegacyV2Mapping.map(unfetched, context: context).record(.artifact, F.docID))
        #expect(without.fields["body"] == nil)
        #expect(LegacyFieldHashes.hashes(without)["body"] == revision)
    }

    @Test("An old record that gained a child gives that v2 record whole")
    func gainedChildIsWhole() throws {
        let world = try Self.world("gained")
        defer { try? FileManager.default.removeItem(at: world.root) }
        try F.activate(world.store)
        let context = StoreLegacyMappingContext(connection: world.store)
        let original = try #require(world.records.first { $0.recordType == "ReviewSession" && $0.recordID.recordName == CloudKitRecordMapper.recordName(for: .reviewSession, logicalKey: "chat-plain") })
        guard case .reviewSession(let payload) = try LegacyRecordDecoder.decode(original).payload else {
            Issue.record("the chat decodes")
            return
        }
        let turn = CloudKitReviewExchangePayload(id: "ex-new", sessionID: "chat-plain", sequenceNumber: 2, question: "And then?",
                                                 userAnswer: "Water.", evaluation: "Yes.", score: nil, sourceRefs: [], knowledgeNote: nil, answeredAt: F.date(75))
        let gained = CloudKitReviewSessionPayload(
            id: payload.id, topic: payload.topic, startedAt: payload.startedAt, endedAt: payload.endedAt, status: payload.status,
            overallScore: payload.overallScore, summary: payload.summary, sourceIDs: payload.sourceIDs, cardIDs: payload.cardIDs,
            exchangeCount: 3, goalID: payload.goalID, exchanges: payload.exchanges + [turn]
        )
        let mapped = try LegacyV2Mapping.map(LegacyRecord(entity: .reviewSession, logicalKey: "chat-plain", recordName: "r", modifiedAt: Date(),
                                                          payload: .reviewSession(gained)), context: context)
        let exchange = try #require(mapped.record(.exchange, "ex-new"))
        #expect(exchange.owned)
        let required = SyncRecordType.exchange.spec.fields.filter { $0.requirement == .always }.map(\.name)
        for field in required {
            #expect(exchange.fields[field] != nil, "a new Exchange is given whole: \(field)")
        }
        #expect(exchange.fields["chatID"] == "chat-plain")
        #expect(exchange.fields["seq"] == SyncJSON(Int64(2)))
    }

    // MARK: The learner's own state

    @Test("An old record that holds a state gives its Mark on, and one that says the state is off gives a clears that makes nothing")
    func marksAreOnOrCleared() throws {
        let world = try Self.world("marks")
        defer { try? FileManager.default.removeItem(at: world.root) }
        func mark(_ entity: CloudKitSyncEntity, _ key: String, _ id: String) -> LegacyV2Record? { world.mapping(entity, key)?.record(.mark, id) }

        let hidden = try #require(mark(.hiddenSource, "src-chapter", MarkKey.source("hidden", "src-chapter").id))
        #expect(hidden.giving == .creates)
        #expect(hidden.fields["on"] == .bool(true))
        #expect(mark(.dismissedSource, "https://example.com/nope", MarkKey.dismissed(url: "https://example.com/nope").id)?.fields["value"]?["title"] == "Nope")
        #expect(mark(.hiddenPodcastShow, "Hidden Show", MarkKey.hiddenShow("Hidden Show").id)?.fields["value"]?["name"] == "Hidden Show")
        #expect(mark(.source, "src-video-ch", MarkKey.source("liked", "src-video-ch").id)?.fields["value"]?["at"] != nil)
        #expect(mark(.source, "src-video-ch", MarkKey.source("provenance", "src-video-ch").id)?.fields["value"]?["origin"] == "safari")
        #expect(mark(.source, "src-podcast", MarkKey.source("visibleOverride", "src-podcast").id)?.fields["on"] == .bool(true))
        #expect(mark(.reviewSession, "chat-plain", MarkKey(kind: "rated", target: "exc:ex-1").id)?.fields["value"]?["rating"] == "liked")
        #expect(mark(.reviewSession, "chat-plain", MarkKey(kind: "rated", target: "exc:ex-2").id) == nil, "an unrated turn gives no rating")
        #expect(mark(.videoPlaylist, F.followedPlaylist, MarkKey(kind: "following", target: "col:" + F.followedPlaylist).id)?.fields["value"]?["autoImport"] == true)

        // An idea that is not wanted and a source with no override give `clears`, which create no Mark.
        let unwanted = try #require(mark(.sourceIdea, "idea-2", MarkKey.source("wantIdea", "src-article", sub: "idea-2").id))
        #expect(unwanted.giving == .clears)
        #expect(unwanted.fields["on"] == .bool(false))
        let wanted = try #require(mark(.sourceIdea, "idea-1", MarkKey.source("wantIdea", "src-article", sub: "idea-1").id))
        #expect(wanted.giving == .creates)
        #expect(mark(.videoCitedPaper, "vcp-1", MarkKey.source("citedDecision", "src-video-ch", sub: "vcp-1").id)?.fields["value"]?["status"] == "dismissed")
        #expect(world.mapping(.source, "src-article")?.record(.mark, MarkKey.source("liked", "src-article").id) == nil, "a source that was never liked gives no like")

        // A blocked-shows row gives the shows it lists, and turns off a show this Mac holds that it dropped.
        let blocked = try #require(world.mapping(.preference, SourceDiscovery.blockedPodcastShowsPreferenceKey))
        #expect(blocked.record(.mark, MarkKey.blockedShow("Bad Show").id)?.giving == .creates)

        // A clears record is in the base with its hashes and never owned, so a later write of the old record
        // that says the same does not clear what the new world set since (F2).
        let idea = try #require(world.mapping(.sourceIdea, "idea-2"))
        #expect(idea.records.count == 1)
        let listed = try #require(idea.baseEntry().objectValue?["r"]?.objectValue?[unwanted.key]?.objectValue)
        #expect(listed["o"] == .bool(false) && listed["h"]?.objectValue?["on"] != nil)
    }

    @Test("A source gives its read mark, place and depth; an unread one clears the read mark and makes no state; a team copy gives only the read mark")
    func readingStates() throws {
        let world = try Self.world("reading")
        defer { try? FileManager.default.removeItem(at: world.root) }
        let read = try #require(world.mapping(.source, "src-article")?.record(.readingState, SyncIdentity.readingStateID(targetID: "src-article")))
        #expect(read.giving == .creates)
        #expect(read.fields["reviewDepth"] == "standard")
        #expect(read.fields["readAt"] != nil && read.fields["locator"]?["t"] == "web")
        #expect(read.fields["furthest"]?.arrayValue?.last == .number(0.4))
        #expect(read.fields["targetKind"] == "source" && read.fields["targetID"] == "src-article")
        #expect(read.fields["completedAt"] == nil, "a completion is the notebook item's to give")

        let unread = try #require(world.mapping(.source, "src-video-pl")?.record(.readingState, SyncIdentity.readingStateID(targetID: "src-video-pl")))
        #expect(unread.giving == .clears)
        #expect(unread.fields["readAt"] == .null)
        #expect(unread.fields["locator"] == nil)

        // A notebook item's completion, and a walk and a narration position, each give their field only.
        let completed = try #require(world.mapping(.learningGoal, F.notebookID)?.record(.readingState, SyncIdentity.readingStateID(targetID: "src-article")))
        #expect(completed.fields["completedAt"] != nil && completed.fields["readAt"] == nil)
        let walk = try #require(world.mapping(.walkthroughProgress, "src-article")?.record(.readingState, SyncIdentity.readingStateID(targetID: "src-article")))
        #expect(walk.fields["walk"]?["main"]?["chatID"] == .string(F.walkChatID))
        #expect(LegacyFieldHashes.hashes(walk)["walk/main"] != nil, "a map field hashes per element")
        let listen = try #require(world.mapping(.preference, ListeningPositionSync.preferenceKeyPrefix + "src-article")?.record(.readingState, SyncIdentity.readingStateID(targetID: "src-article")))
        #expect(listen.fields["listen"]?["globalTime"] == .number(12.5))

        // A team copy of the source gives the read mark and the furthest, never the place or the depth.
        let context = StoreLegacyMappingContext(connection: world.store)
        let copy = try F.source(F.article("team-copy", url: "https://example.com/essay", title: "An essay", type: "article", domain: "example.com", state: "ready", added: 10,
                                          extras: ["readAt": F.date(30).timeIntervalSinceReferenceDate, "readingPositionLocator": "{\"webScrollFraction\":0.7}"]),
                                reviewDepth: "deep", in: world.root)
        var decoded = try LegacyRecordDecoder.decode(copy)
        decoded = LegacyRecord(entity: decoded.entity, logicalKey: decoded.logicalKey, recordName: decoded.recordName, zoneName: "Team-0F1E2D3C-0000-4000-8000-000000000000",
                               modifiedAt: decoded.modifiedAt, payload: decoded.payload)
        let team = try #require(try LegacyV2Mapping.map(decoded, context: context).records.first { $0.type == .readingState })
        #expect(team.fields["readAt"] != nil && team.fields["furthest"] != nil)
        #expect(team.fields["locator"] == nil && team.fields["reviewDepth"] == nil)
    }

    @Test("Answers, quiz scores and review time are Sittings and logs under legacy22; a course focus creates an Enrollment whose status only a creation sets")
    func historyAndEnrollments() throws {
        let world = try Self.world("history")
        defer { try? FileManager.default.removeItem(at: world.root) }
        let session = try #require(world.mapping(.memoryAttempt, "att-1")?.records.first)
        #expect(session.id == SyncIdentity.sittingLegacyID("session:chat-review"))
        #expect(session.fields["deviceID"] == .string(SyncIdentity.legacyDeviceID) && session.fields["kind"] == "memoryReview")
        #expect(session.fields["answers"]?["att-1"]?["subject"] == "crd:mi-1")
        #expect(session.fields["answers"]?["att-1"]?["curriculumFingerprint"] != nil, "an attempt from before fingerprints takes its item's, as the activation does")
        let day = try #require(world.mapping(.memoryAttempt, "att-2")?.records.first)
        #expect(day.fields["kind"] == "cards" && day.fields["chatID"] == nil)

        let quiz = try #require(world.mapping(.preference, LectureQuizScore.courseQuizPreferenceKeyPrefix + "quiz-1")?.records.first)
        #expect(quiz.id == SyncIdentity.sittingLegacyID("quiz:courseQuiz:" + LectureQuizScore.courseQuizPreferenceKeyPrefix + "quiz-1"))
        #expect(quiz.fields["result"]?["passed"] == true)

        let review = try #require(world.mapping(.memoryReviewActivity, MemoryReviewGoal.activityID(day: "2026-09-01", deviceID: "old-device-1"))?.records.first)
        #expect(review.id == SyncIdentity.activityLogID(day: "2026-09-01", deviceID: SyncIdentity.legacyDeviceID))
        #expect(review.fields["reviewByDevice"]?["old-device-1"]?["activeSeconds"] == .number(300))
        #expect(LegacyFieldHashes.hashes(review)["reviewByDevice/old-device-1"] != nil)
        let days = try #require(world.mapping(.scheduledSource, "ss-1")?.records.filter { $0.type == .activityLog })
        #expect(days.count == 1 && days.first?.fields["sources"]?["src-article"]?["kinds"] == ["chat", "read"])

        let focus = try #require(world.mapping(.preference, LearnerProfile.courseFocusPreferenceKeyPrefix + F.followedCourse)?.records.first)
        #expect(focus.giving == .creates && focus.id == SyncIdentity.enrollmentID(courseID: F.followedCourse))
        #expect(focus.fields["focus"] == "How the electron chain is built" && focus.fields["status"] == "enrolled")
        #expect(focus.createOnlyFields == ["status"])
        #expect(LegacyFieldHashes.hashes(focus)["status"] == nil, "a creation's field is not hashed, so a change to it applies nothing")
        let blank = LegacyV2Mapping.mapDeletion(entity: .preference, logicalKey: LearnerProfile.courseFocusPreferenceKeyPrefix + F.followedCourse)
        #expect(blank.records.first?.giving == .clears)
        #expect(blank.records.first?.fields["focus"] == .null)

        let deck = try #require(world.mapping(.preference, MemoryCardDeckState.preferenceKeyPrefix + MemoryCard.draftDeckID(sourceID: "src-article")))
        let kept = try #require(deck.record(.card, "mi-1"))
        #expect(kept.giving == .feeds && kept.wholeFields == ["variants"])
        #expect(Set(kept.fields.keys) == ["seedKey", "variants", "alwaysAsk", "deckSourceID"])
        let skipped = try #require(deck.record(.card, SyncIdentity.cardDraftID(deckSourceID: "src-article", seedKey: "walk:step-2")))
        #expect(skipped.giving == .creates && skipped.fields["status"] == "skipped" && skipped.fields["skippedAt"] != nil)
    }

    @Test("A Team feeds its space's root, and a connector's health feeds this Mac's Device row once it has an id")
    func teamAndDevice() throws {
        let world = try Self.world("device")
        defer { try? FileManager.default.removeItem(at: world.root) }
        let context = StoreLegacyMappingContext(connection: world.store)
        let teamID = "0F1E2D3C-0000-4000-8000-000000000000"
        let payload = CloudKitTeamPayload(id: teamID, name: "Lab", createdAt: F.date(1), updatedAt: F.date(2), familyPlanCode: nil)
        let root = try #require(try LegacyV2Mapping.map(
            LegacyRecord(entity: .team, logicalKey: teamID, recordName: "t", modifiedAt: Date(), payload: .team(payload)), context: context
        ).records.first)
        #expect(root.type == .zoneRoot && root.id == "root" && root.giving == .feeds)
        #expect(root.spaceID == teamID.lowercased())
        #expect(root.fields["name"] == "Lab" && root.fields["familyPlanCode"] == nil, "a plan code the record omits gives nothing")

        let health = world.mapping(.preference, "connectorHealth.zoom.state")
        #expect(health?.records.isEmpty == true, "this Mac has no device id yet, so nothing is fed")
        let clock = try JSONEncoder().encode(StampClock(deviceID: "devtest2"))
        try world.store.execute("INSERT INTO ck_clock (id, clock_json, updated_at) VALUES (1, ?, 0)", [.text(String(decoding: clock, as: UTF8.self))])
        let state = try #require(world.records.first { $0.recordID.recordName == CloudKitRecordMapper.recordName(for: .preference, logicalKey: "connectorHealth.zoom.state") })
        let device = try #require(try LegacyV2Mapping.map(LegacyRecordDecoder.decode(state), context: context).records.first)
        #expect(device.type == .device && device.giving == .feeds && device.id == SyncIdentity.deviceRecordID("devtest2"))
        #expect(device.fields["connectorHealth"]?["zoom"]?["state"] == "healthy")
        #expect(LegacyFieldHashes.hashes(device)["connectorHealth/zoom"] != nil)
    }
}
