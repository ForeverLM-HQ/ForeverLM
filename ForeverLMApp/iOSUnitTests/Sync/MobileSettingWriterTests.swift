import Foundation
import Testing
@testable import ForeverLM

/// The phone's synced preferences under generation 2 (docs/cloudkit-schema-design.md §3.5.3, §10; §14.2
/// WP20b): a key the settings catalog lists is a Setting of typed JSON, checked against the catalog as
/// `set_app_setting` checks it; a domain prefix is a field of its own record; the callers keep generation
/// 1's key-and-value shape through `MobileModelPreferenceStore`.
@Suite("iPhone Setting writer", .serialized)
struct MobileSettingWriterTests {
    typealias Fixture = MobileWriterFixture

    static func store(_ writer: MobileRecordWriter) -> MobileModelPreferenceStore {
        MobileModelPreferenceStore(writer: { writer })
    }

    static func setting(_ replica: MobileReplica, _ key: String) async throws -> SyncEnvelope? {
        try await Fixture.held(replica, .setting, key, in: Fixture.library)
    }

    // MARK: - The catalog

    @Test("Every key and family the phone sets is the catalog's: same type, account scope, range and values, never retired")
    func catalogParity() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("schema/generated/settings-catalog.json")
        let catalog = try SyncJSON(parsing: Data(contentsOf: url))
        let keys = try #require(catalog["keys"]?.objectValue)
        for (key, entry) in MobileSettingCatalog.keys {
            let listed = try #require(keys[key], "\(key) is in the catalog")
            #expect(listed["type"]?.stringValue == entry.type, "\(key)'s type")
            #expect(listed["scope"]?.arrayValue?.contains(.string("account")) == true, "\(key) is an account Setting")
            #expect(listed["retired"]?.boolValue != true, "\(key) is live")
            #expect(listed["range"]?["min"]?.numberValue == entry.range?.lowerBound, "\(key)'s minimum")
            #expect(listed["range"]?["max"]?.numberValue == entry.range?.upperBound, "\(key)'s maximum")
        }
        let families = try #require(catalog["families"]?.objectValue)
        for (prefix, entry) in MobileSettingCatalog.families {
            let patterns = try #require(families[prefix]?.arrayValue, "\(prefix) is a family")
            let pattern = try #require(patterns.first { $0["retired"]?.boolValue != true })
            #expect(pattern["type"]?.stringValue == entry.type)
            #expect(pattern["values"]?.arrayValue?.compactMap(\.stringValue) == entry.values)
        }
        for prefix in MobilePreferenceRoute.notOnPhonePrefixes + ["listen.position.", "courseQuiz.score.", "lectureQuiz.score."] {
            #expect(catalog["records"]?[prefix] != nil, "\(prefix) is a domain prefix, not a Setting")
        }
    }

    @Test("A value is typed JSON and comes back as the property-list value generation 1's row held")
    func valueCodec() throws {
        #expect(MobileSettingValue.typed(true, type: "bool") == .object(["t": "bool", "v": .bool(true)]))
        #expect(MobileSettingValue.typed(30, type: "int") == .object(["t": "int", "v": 30]))
        #expect(MobileSettingValue.typed("30", type: "int") == nil, "a string is not an int")
        #expect(MobileSettingValue.typed(1.5, type: "int") == nil, "a fraction is not an int")
        #expect(MobileSettingValue.typed(["a", "b"], type: "array") == .object(["t": "array", "v": ["a", "b"]]))
        let data = Data("{\"provider\":\"OpenRouter\"}".utf8)
        let typed = try #require(MobileSettingValue.typed(data, type: "data"))
        #expect(typed["v"] == .string(data.base64EncodedString()))
        #expect(MobileSettingValue.plist(typed) as? Data == data)
        #expect((MobileSettingValue.plist(.object(["t": "int", "v": 45])) as? NSNumber)?.intValue == 45)
        #expect(MobileSettingValue.plist(.object(["t": "array", "v": ["x"]])) as? [String] == ["x"])
        #expect(MobileSettingValue.plist(.object(["t": "bool", "v": .null])) == nil, "a cleared Setting has no value")
        #expect(MobileSettingValue.plist(.number(45)) == nil, "a bare number is not a Setting's value")
    }

    // MARK: - Settings

    @Test("A Setting is written with its key, typed value and device; the same value again writes nothing; nil clears it")
    func writeSetting() async throws {
        let replica = try await Fixture.replica(space: nil)
        let store = Self.store(Fixture.writer(replica))
        try await store.setInt(45, forKey: MemoryReviewBudget.preferenceKey)
        let setting = try #require(try await Self.setting(replica, MemoryReviewBudget.preferenceKey))
        #expect(setting.fields["key"] == .string(MemoryReviewBudget.preferenceKey))
        #expect(setting.fields["value"] == .object(["t": "int", "v": 45]))
        #expect(setting.fields["updatedBy"] == .string(Fixture.deviceID))
        #expect(try await store.int(forKey: MemoryReviewBudget.preferenceKey) == 45)

        let stamps = try #require(try await Fixture.patch(replica, .setting, MemoryReviewBudget.preferenceKey, in: Fixture.library)).stamps
        try await store.setInt(45, forKey: MemoryReviewBudget.preferenceKey)
        #expect(try await Fixture.patch(replica, .setting, MemoryReviewBudget.preferenceKey, in: Fixture.library)?.stamps == stamps)

        try await store.setBool(true, forKey: AIDataPolicy.denyDataCollectionKey)
        #expect(try await store.bool(forKey: AIDataPolicy.denyDataCollectionKey) == true)
        try await store.setStringArray(["m1", "m2"], forKey: TextToSpeechCostConfirmationPreferences.suppressedModelIDsKey)
        #expect(try await store.stringArray(forKey: TextToSpeechCostConfirmationPreferences.suppressedModelIDsKey) == ["m1", "m2"])

        try await store.removeValue(forKey: AIDataPolicy.denyDataCollectionKey)
        #expect(try await Self.setting(replica, AIDataPolicy.denyDataCollectionKey)?.fields["value"] == .null, "kept, cleared")
        #expect(try await store.bool(forKey: AIDataPolicy.denyDataCollectionKey) == nil)
        try await store.removeValue(forKey: DailyReviewPreparationKeys.enabled)
        #expect(try await Self.setting(replica, DailyReviewPreparationKeys.enabled) == nil, "clearing a Setting never held writes nothing")
    }

    @Test("A key the phone does not set, a value of the wrong type, out of range or not among a family's values is refused before anything is queued")
    func refusals() async throws {
        let replica = try await Fixture.replica(space: nil)
        let store = Self.store(Fixture.writer(replica))
        await #expect(throws: MobileRecordWriterError.self) { try await store.setString("x", forKey: "studio.hiddenTabs") }
        await #expect(throws: MobileRecordWriterError.self) { try await store.setString("x", forKey: "made.up.key") }
        await #expect(throws: MobileRecordWriterError.self) { try await store.setInt(500, forKey: MemoryReviewBudget.preferenceKey) }
        await #expect(throws: MobileRecordWriterError.self) { try await store.setString("yes", forKey: AIDataPolicy.denyDataCollectionKey) }
        let rating = ArticleSpeechVoiceRating.preferenceKey(modelID: "openai/tts", voiceID: "alloy")
        await #expect(throws: MobileRecordWriterError.self) { try await store.setString("sideways", forKey: rating) }
        await #expect(throws: MobileRecordWriterError.self) { try await store.setString("x", forKey: "cards.state.deck1") }
        #expect(try await Fixture.patchCount(replica) == 0)

        try await store.setString("up", forKey: rating)
        #expect(try await store.string(forKey: rating) == "up")
        try await store.setString("deep", forKey: MemoryReviewDepth.typePreferenceKey(sourceType: "Paper"))
        #expect(try await store.string(forKey: "memory.reviewDepth.type.paper") == "deep")
    }

    @Test("A Setting another device wrote reads through the store; a domain prefix the phone does not hold reads as absent")
    func readsWhatOthersWrote() async throws {
        let replica = try await Fixture.replica(space: nil)
        let route = Data("{\"provider\":\"OpenRouter\",\"model\":\"m\"}".utf8)
        try await Fixture.apply(replica, [
            (Fixture.library, try MobileSyncFixture.envelope(.setting, "aiRoute.defaultChat", [
                "key": .string("aiRoute.defaultChat"), "value": .object(["t": "data", "v": .string(route.base64EncodedString())]),
            ])),
            (Fixture.library, try MobileSyncFixture.envelope(.setting, "images.drawNotebookCovers.automatic", [
                "key": .string("images.drawNotebookCovers.automatic"), "value": .object(["t": "bool", "v": .bool(false)]),
            ])),
        ])
        let store = Self.store(Fixture.writer(replica))
        #expect(try await store.data(forKey: "aiRoute.defaultChat") == route)
        #expect(try await store.bool(forKey: "images.drawNotebookCovers.automatic") == false)
        #expect(try await store.strings(forKeys: ["images.drawNotebookCovers.automatic", "nothing.here"]).isEmpty, "a Bool is not a String row")
    }

    @Test("A naming mark is held under the notebook its id resolves to: set for a merged notebook, it is the survivor's and reads back through either id")
    func namingMarkFollowsMerge() async throws {
        let replica = try await Fixture.replica(space: nil)
        try await Fixture.apply(replica, [
            (Fixture.library, try MobileReadModelFixture.notebook("nb-c", "Gamma", edited: 100)),
            (Fixture.library, try MobileReadModelFixture.notebook("nb-m", "Merged", edited: 50, [
                "status": .string("merged"), "mergedInto": .string("nb-c"), "foldKind": .string("merge"),
            ])),
        ])
        let store = Self.store(Fixture.writer(replica))
        try await store.setString("named", forKey: NotebookNaming.preferenceKey(notebookID: "nb-m"))
        #expect(try await Self.setting(replica, NotebookNaming.preferenceKey(notebookID: "nb-c"))?.fields["key"]
                == .string(NotebookNaming.preferenceKey(notebookID: "nb-c")))
        #expect(try await Self.setting(replica, NotebookNaming.preferenceKey(notebookID: "nb-m")) == nil, "nothing under the merged id")
        #expect(try await store.string(forKey: NotebookNaming.preferenceKey(notebookID: "nb-m")) == "named")
        #expect(try await store.string(forKey: NotebookNaming.preferenceKey(notebookID: "nb-c")) == "named")
    }

    // MARK: - Domain prefixes

    @Test("A listening position is the member's ReadingState.listen; it reads back as generation 1's row; clearing it clears the field")
    func listenPosition() async throws {
        let replica = try await Fixture.replica(space: nil)
        let store = Self.store(Fixture.writer(replica))
        let key = ListeningPositionSync.preferenceKey(sourceID: "src1")
        let position = ArticleSpeechPlaybackPosition(globalTime: 754.5, appleCharacterOffset: 1_200, contentSignature: "sig",
                                                     updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try await store.setString(try #require(ListeningPositionSync.encode(position)), forKey: key)
        let state = try #require(try await Fixture.held(replica, .readingState, "rs:src1", in: Fixture.library))
        #expect(state.fields["targetID"] == .string("src1"))
        #expect(state.fields["listen"]?["globalTime"] == .number(754.5))
        #expect(state.fields["listen"]?["at"] == SyncJSON(Int64(1_800_000_000_000)))
        #expect(try await store.string(forKey: key).flatMap(ListeningPositionSync.decode) == position)
        #expect(try await store.strings(forKeys: [key]).count == 1)

        try await store.removeValue(forKey: key)
        #expect(try await Fixture.held(replica, .readingState, "rs:src1", in: Fixture.library)?.fields["listen"] == .null)
        #expect(try await store.string(forKey: key) == nil)
    }

    @Test("The pins, open groups and order rows are NotebookState fields: flags set and cleared, keys given in the row's order")
    func notebookLists() async throws {
        let replica = try await Fixture.replica(space: nil)
        try await Fixture.apply(replica, [
            (Fixture.library, try MobileReadModelFixture.notebook("nbA", "A", edited: 1)),
            (Fixture.library, try MobileReadModelFixture.notebook("nbB", "B", edited: 2)),
            (Fixture.library, try MobileReadModelFixture.notebook("nbC", "C", edited: 3)),
        ])
        let store = Self.store(Fixture.writer(replica))
        try await store.setStringArray(["nbA", "nbB", "gone"], forKey: NotebookPins.preferenceKey)
        #expect(try await Fixture.held(replica, .notebookState, "ns:nbA", in: Fixture.library)?.fields["pinned"] == .bool(true))
        #expect(try await Fixture.held(replica, .notebookState, "ns:nbB", in: Fixture.library)?.fields["pinned"] == .bool(true))
        #expect(try await Fixture.held(replica, .notebookState, "ns:gone", in: Fixture.library) == nil, "an id no notebook has is left out")
        try await store.setStringArray(["nbB"], forKey: NotebookPins.preferenceKey)
        #expect(try await Fixture.held(replica, .notebookState, "ns:nbA", in: Fixture.library)?.fields["pinned"] == .bool(false))
        #expect(try await store.stringArray(forKey: NotebookPins.preferenceKey) == ["nbB"])

        try await store.setStringArray(["nbC", "nbA", "nbB"], forKey: "studio.projectOrder")
        #expect(try await store.stringArray(forKey: "studio.projectOrder") == ["nbC", "nbA", "nbB"])
        let keyOfA = try await Fixture.held(replica, .notebookState, "ns:nbA", in: Fixture.library)?.fields["sidebarKey"]
        try await store.setStringArray(["nbB", "nbC", "nbA"], forKey: "studio.projectOrder")
        #expect(try await store.stringArray(forKey: "studio.projectOrder") == ["nbB", "nbC", "nbA"])
        #expect(try await Fixture.held(replica, .notebookState, "ns:nbC", in: Fixture.library)?.fields["sidebarKey"] != nil)
        #expect(try await Fixture.held(replica, .notebookState, "ns:nbA", in: Fixture.library)?.fields["sidebarKey"] == keyOfA,
                "a key that still sits in order is kept")
    }

    @Test("A quiz's score is a Sitting of its own: the latest reads back with the quiz's first pass; the same score twice is one Sitting")
    func quizScores() async throws {
        let replica = try await Fixture.replica(space: nil)
        let store = Self.store(Fixture.writer(replica))
        let key = LectureQuizScore.preferenceKey(courseQuizID: "q1")
        let pass = LectureQuizScore(right: 4, total: 4, takenAt: Date(timeIntervalSince1970: 1_800_000_000))
        try await store.setLectureQuizScore(pass.recorded(after: nil), forKey: key)
        try await store.setLectureQuizScore(pass.recorded(after: nil), forKey: key)
        #expect(try await replica.read { try $0.connection.scalarInteger("SELECT COUNT(*) FROM m_sittings WHERE kind = 'courseQuiz'") } == 1)
        let id = MobileMemoryRecords.quizSittingID(key: key, takenAt: pass.takenAt)
        let sitting = try #require(try await Fixture.held(replica, .sitting, id, in: Fixture.library))
        #expect(sitting.fields["deviceID"] == .string(Fixture.deviceID))
        #expect(sitting.fields["scope"] == .object(["quizID": "q1"]))
        #expect(sitting.fields["startedAt"] == SyncJSON(Int64(1_800_000_000_000)))
        #expect(sitting.fields["result"] == .object(["right": 4, "of": 4, "passed": .bool(true), "passedAt": SyncJSON(Int64(1_800_000_000_000))]))

        let retake = LectureQuizScore(right: 1, total: 4, takenAt: Date(timeIntervalSince1970: 1_800_086_400))
        let previous = try #require(try await store.lectureQuizScores(forKeys: [key])[key])
        try await store.setLectureQuizScore(retake.recorded(after: previous), forKey: key)
        let latest = try #require(try await store.lectureQuizScores(forKeys: [key])[key])
        #expect(latest.right == 1)
        #expect(latest.takenAt == retake.takenAt)
        #expect(latest.passedAt == pass.takenAt, "a worse retake keeps the first pass")
        #expect(latest.hasPassed)
        #expect(try await store.lectureQuizScores(forKeys: [LectureQuizScore.preferenceKey(courseQuizID: "q2")]).isEmpty)
        await #expect(throws: MobileRecordWriterError.self) { try await store.removeValue(forKey: key) }
    }
}
