import Foundation
import Testing
@testable import ForeverLM

/// Per-member state never reaches a space (docs/cloudkit-schema-design.md D18, §3.5, §9.3, PD-15, WP12b):
/// no priv-only type and no member-local field can be written into a space zone; the shareable types
/// carry no member-local field; every priv-only type is placed in `Library` whatever zone it is written
/// in; and a copied Source or Collection carries none of the member's own state (the like, the discovery
/// origin, the follow), which travel as Marks in `Library`.
@Suite("Per-member isolation")
struct PerMemberIsolationTests {
    typealias F = NotebookSyncFixture

    static let member = SpaceWriteGuard.Writer(user: "_member", permission: .readWrite, isOwner: true)

    static var privateOnlyTypes: [SyncRecordType] { SyncRecordType.allCases.filter { $0.spec.isPrivateOnly } }

    @Test("Every priv-only type is refused in a space, and placed in Library wherever it is written")
    func privateOnlyTypesNeverEnterASpace() throws {
        #expect(Set(Self.privateOnlyTypes).isSuperset(of: [.mark, .highlight, .placement, .readingState, .notebookState, .device, .enrollment, .card, .sitting]))
        for type in Self.privateOnlyTypes {
            let refusals = SpaceWriteGuard.refusals(writing: type.rawValue, fields: [:], by: Self.member)
            #expect(refusals.contains(.privateOnlyType(type.rawValue)), "\(type.rawValue) is refused in a space")
            #expect(throws: SpaceWriteGuard.Refusal.self) { try SpaceWriteGuard.check(writing: type.rawValue, fields: [:], by: Self.member) }
        }
    }

    @Test("No shareable type carries a member-local field, and the guard refuses one wherever it is declared")
    func memberLocalFieldsStayOnPrivateTypes() throws {
        for type in SyncRecordType.allCases where !type.spec.isPrivateOnly {
            let local = type.spec.fields.filter(\.isMemberLocal).map(\.name)
            #expect(local.isEmpty, "\(type.rawValue) declares member-local fields \(local)")
        }
        // Mark.value is member-local: a Mark's value written as though Mark were shareable is still refused.
        let mark = SyncRecordType.mark.spec
        let shareable = SyncTypeSpec(
            .mark, prefix: mark.prefix, zones: mark.zones, home: mark.home, isPrivateOnly: false,
            idForms: mark.idForms, idDeterminism: mark.idDeterminism, cloudKitFields: mark.cloudKitFields, fields: mark.fields
        )
        let refusals = SpaceWriteGuard.refusals(writing: "Mark", fields: ["value": .object(["at": SyncJSON(1)])], by: Self.member, spec: shareable)
        #expect(refusals.contains(.memberLocalField(type: "Mark", field: "value")))
    }

    @Test("A Source and a Collection encode none of the member's own state; the like, the origin and the follow are Marks")
    func copiedSourcesAndCollectionsCarryNoMemberState() throws {
        let (root, store) = try F.makeStore("isolation-copies")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try store.execute("INSERT INTO sources (id, date_added, state, source_type, status) VALUES ('vid-1', 100, 'ready', 'video', 'active')")
        try store.execute("""
            INSERT INTO videos (source_id, url, normalized_url, title, domain, liked_at, discovery_origin)
            VALUES ('vid-1', 'https://youtube.com/watch?v=vid-1', 'youtube.com/watch?v=vid-1', 'A talk', 'Mito Lab', 700000000, 'youtubePlaylist')
        """)
        try store.execute("INSERT INTO video_playlists (id, title, playlist_url, auto_import) VALUES ('pl-1', 'Uploads', 'https://youtube.com/playlist?list=UU1', 1)")
        try store.writeSourceHidden("vid-1", hidden: true)
        let pending = try F.pending(store)
        let source = try #require(F.savedFields(pending["Source:vid-1"]))
        let collection = try #require(F.savedFields(pending["Collection:pl-1"]))
        for (name, fields) in [("Source", source), ("Collection", collection)] {
            let text = String(decoding: SyncJSON.object(fields).serialized(), as: UTF8.self)
            for word in ["liked", "700000000", "youtubePlaylist", "autoImport", "auto_import"] {
                #expect(!text.contains(word), "\(name) carries \(word)")
            }
            #expect(SpaceWriteGuard.refusals(writing: name, fields: fields, by: Self.member).isEmpty, "a copy of the \(name) may enter a space")
        }
        for id in ["mk:liked:src:vid-1", "mk:provenance:src:vid-1", "mk:following:col:pl-1", "mk:hidden:src:vid-1"] {
            let change = try #require(pending["Mark:\(id)"], "\(id) is a Mark")
            #expect(change.zone == .library, "\(id) goes to Library")
        }
    }

    @Test("The feeder never puts a personal record into a space, even one about a team copy")
    func personalRecordsOfTeamCopiesStayInLibrary() throws {
        let (root, store) = try F.makeStore("isolation-team-copy")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addSource(store, "src-a")
        try HighlightProjectionTests.addTeamCopy(store, "team-copy-a", of: "src-a")
        try store.writeSourceHidden(try store.personalStateSourceKey("team-copy-a"), hidden: true)
        try store.saveSourceHighlight(HighlightProjectionTests.highlight("hl-1", source: "team-copy-a"))
        for change in try F.pending(store).values where change.recordType.spec.isPrivateOnly {
            #expect(change.zone == .library, "\(change.recordType.rawValue) \(change.wireID) goes to Library")
            #expect(!change.zoneKey.contains("Space-"))
        }
        #expect(try F.pending(store)["Highlight:hl-1"] != nil && F.savedFields(try F.pending(store)["Highlight:hl-1"])?["sourceID"] == .string("src-a"))
    }
}
