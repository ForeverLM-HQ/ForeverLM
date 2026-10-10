import Foundation
import Testing
@testable import ForeverLM

/// The Setting and Device projections (docs/cloudkit-schema-design.md §3.5.2, §3.5.3, §10, WP12b): plist
/// values as typed JSON for every value type and back; a synced key that no record took over is a
/// Setting, the record-backed ones never are; a removed key clears its Setting and never deletes it, so a
/// deleted Notebook Collection's name is cleared; an inbound Setting lands in `user_preferences`; under
/// generation 2 the moved keys are no synced preferences; this Mac's connector health is its Device
/// record.
@Suite("Setting projection")
struct SettingProjectionTests {
    typealias F = NotebookSyncFixture

    static func writePreference(_ store: KnowledgeStore, _ key: String, _ value: Any) throws {
        try store.writePreference(key: key, valuePlistXML: try #require(PreferenceStore.encodePlist(value)))
    }

    @Test("Every plist value type becomes typed JSON and comes back as the same plist value")
    func valueTypesRoundTrip() throws {
        // A plist keeps a date to the second.
        let date = Date(timeIntervalSinceReferenceDate: 780_000_000)
        let cases: [(Any, String)] = [
            (true, "bool"), (false, "bool"), (42, "int"), (Int64(-7), "int"), (2.5, "double"), (1.0, "double"), ("Kokoro", "string"),
            (["a", "b"], "array"), ([1, 2.5, true] as [Any], "array"), (["model": "x", "effort": 3, "on": false] as [String: Any], "dict"),
            (Data([0, 1, 254, 255]), "data"), (date, "date"),
        ]
        for (value, type) in cases {
            let xml = try #require(PreferenceStore.encodePlist(value))
            let typed = try #require(SettingValueCodec.typed(plistXML: xml), "\(value)")
            #expect(typed.objectValue?["t"] == .string(type), "\(value) is a \(type)")
            let back = try #require(SettingValueCodec.plist(typed), "\(value)")
            let backXML = try #require(PreferenceStore.encodePlist(back))
            #expect(SettingValueCodec.typed(plistXML: backXML) == typed, "\(value) comes back whole")
        }
        #expect(SettingValueCodec.typed(plistXML: try #require(PreferenceStore.encodePlist(true))) != SettingValueCodec.typed(plistXML: try #require(PreferenceStore.encodePlist(1))),
                "a Bool never becomes a number")
        #expect(SettingValueCodec.typed(plistXML: try #require(PreferenceStore.encodePlist(date)))?.objectValue?["v"] == SyncJSON(SyncTime.milliseconds(date)))
        #expect(SettingValueCodec.typed(plistXML: "") == .null, "an empty value is no value")
        #expect(SettingValueCodec.plist(.object(["t": .string("bool"), "v": .string("yes")])) == nil, "a value that does not fit its type is refused")
    }

    @Test("A synced key no record took over is a Setting; the record-backed keys and the device-local ones never are")
    func whichKeysAreSettings() {
        for key in ["readerOriginalPageColors", "uiZoomStep", "studio.courseOrder", "studio.workspaceView.desk", "notebookCollection.nbc-1", "notebook.naming.nb-1"] {
            #expect(SyncedPreferenceKeys.isSetting(key), "\(key)")
        }
        for key in ["studio.projectOrder", NotebookPins.preferenceKey, "studio.navigation.expandedProjectIDs.v1", "podcasts.blockedShows",
                    "connectorHealth.readAI.state", "notebook.collections.nb-1", "notebook.chatExcluded.nb-1", "course.focus.c-1",
                    "listen.position.src-1", "cards.state.deck-1", "courseQuiz.score.q-1", "lectureQuiz.score.s-1", "studio.navigationRailWidth"] {
            #expect(!SyncedPreferenceKeys.isSetting(key), "\(key)")
        }
        // Generation 1 syncs every one of the moved keys as before; generation 2 none of them.
        for key in ["studio.projectOrder", NotebookPins.preferenceKey, "studio.navigation.expandedProjectIDs.v1", "podcasts.blockedShows", "connectorHealth.readAI.state"] {
            #expect(SyncedPreferenceKeys.isSynced(key, for: .one), "\(key) syncs under generation 1")
            #expect(!SyncedPreferenceKeys.isSynced(key, for: .two), "\(key) is no synced preference under generation 2")
        }
    }

    @Test("A Setting's row encodes its typed value; a removed key clears it and the record stays")
    func settingEncodesAndClears() throws {
        let (root, store) = try F.makeStore("set-encode")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try Self.writePreference(store, "readerOriginalPageColors", true)
        try Self.writePreference(store, "notebookCollection.nbc-1", "🧪 Lab work")
        try Self.writePreference(store, "studio.navigationRailWidth", 220.0)
        try Self.writePreference(store, "cards.state.deck-1", ["c1": "kept"])
        let pending = try F.pending(store)
        let setting = try #require(F.savedFields(pending["Setting:readerOriginalPageColors"]))
        #expect(setting["key"] == .string("readerOriginalPageColors"))
        #expect(setting["value"] == .object(["t": .string("bool"), "v": .bool(true)]))
        #expect(F.savedFields(pending["Setting:notebookCollection.nbc-1"])?["value"] == .object(["t": .string("string"), "v": .string("🧪 Lab work")]))
        #expect(pending["Setting:studio.navigationRailWidth"] == nil, "a device-local key is no Setting")
        #expect(pending["Setting:cards.state.deck-1"] == nil, "a deck's card state is the Card's")
        try F.sendAll(store)

        // The collection is deleted: its name's row goes, and its Setting is cleared, never deleted.
        try store.deletePreference(key: "notebookCollection.nbc-1")
        let cleared = try #require(try F.pending(store)["Setting:notebookCollection.nbc-1"])
        guard case .save(let envelope) = cleared.action else { Issue.record("a cleared Setting is saved, not deleted"); return }
        #expect(envelope.fields["value"] == .null)
    }

    @Test("An inbound Setting writes its row, an inbound null removes it, and a space's Setting or a record's key writes nothing")
    func inboundSettings() throws {
        let (root, store) = try F.makeStore("set-inbound")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.apply(store, [
            try F.record(.setting, "uiZoomStep", ["key": .string("uiZoomStep"), "value": .object(["t": .string("int"), "v": SyncJSON(2)])]),
            try F.record(.setting, "studio.projectOrder", ["key": .string("studio.projectOrder"), "value": .object(["t": .string("array"), "v": .array([.string("nb")])])]),
        ])
        let xml = try #require(try F.text(store, "SELECT value FROM user_preferences WHERE key = 'uiZoomStep'"))
        #expect(PreferenceStore.decodePlist(xml) as? Int == 2)
        #expect(try F.count(store, "SELECT COUNT(*) FROM user_preferences WHERE key = 'studio.projectOrder'") == 0, "a record's key is no Setting")
        #expect(try F.pending(store).keys.filter { $0.hasPrefix("Setting:") }.isEmpty, "an apply sends nothing back")

        try F.apply(store, [try F.record(.setting, "uiZoomStep", ["key": .string("uiZoomStep"), "value": .null], ms: 1_900_000_000_000)])
        #expect(try F.count(store, "SELECT COUNT(*) FROM user_preferences WHERE key = 'uiZoomStep'") == 0)
        #expect(InboundSettingRemovals.pending.contains("uiZoomStep"), "UserDefaults is told to drop the key after the apply")
    }

    @Test("This Mac's connector health is its Device record, from generation 1's rows and from each later change")
    func connectorHealthIsTheDeviceRecord() throws {
        let (root, store) = try F.makeStore("set-device")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try Self.writePreference(store, "connectorHealth.readAI.state", "healthy")
        try Self.writePreference(store, "connectorHealth.readAI.lastSeenAt", 1_759_000_000.5)
        let deviceID = try #require(try store.thisSyncDeviceID())
        try store.inDerivationTransaction { _ = try $0.ensureThisDeviceRow() }
        let fields = try #require(F.savedFields(try F.pending(store)["Device:dev:\(deviceID)"]))
        #expect(fields["deviceID"] == .string(deviceID) && fields["platform"] == .string("mac"))
        #expect(fields["schemaRevision"] == nil && fields["appBuild"] == nil && fields["lastSeenDay"] == nil && fields["roles"] == nil,
                "the build fields, the last day seen and the roles are the maintenance writer's, never this projection's")
        #expect(fields["connectorHealth"] == .object(["readAI": .object(["state": .string("healthy"), "lastSeenAt": SyncJSON(Int64(1_759_000_000_500))])]))
        #expect(try F.pending(store)["Setting:connectorHealth.readAI.state"] == nil, "a connector's health is no Setting")
        try F.sendAll(store)

        try store.saveThisDeviceConnectorHealth(ConnectorHealthMap.map(["connectorHealth.readAI.state": "needsReconnect"]))
        #expect(F.savedFields(try F.pending(store)["Device:dev:\(deviceID)"])?["connectorHealth"]?.objectValue?["readAI"]
                == .object(["state": .string("needsReconnect")]))

        // Another device's record lands in its own row and is never sent from here.
        try F.apply(store, [try F.record(.device, "dev:otheraaa", [
            "deviceID": .string("otheraaa"), "platform": .string("ios"), "appVersion": .string("1.0"), "appBuild": .string("9"),
            "schemaRevision": SyncJSON(1), "lastSeenDay": .string("2026-10-01"), "roles": .object(["automationRunner": .bool(true)]),
        ])])
        #expect(try F.text(store, "SELECT platform || ':' || roles_json FROM devices WHERE device_id = 'otheraaa'") == #"ios:["automationRunner"]"#)
        #expect(try F.pending(store)["Device:dev:otheraaa"] == nil)
    }
}
