import Foundation
import Testing
@testable import ForeverLM

/// The Idea projection (docs/cloudkit-schema-design.md §3.5.26): an Idea jotted down on the Mac reaches the
/// record with its links keyed by target and its archive as `dismissed`; an Idea another client writes (the
/// Vision Pro's `RecordPatch(.idea, …)`, the hosted MCP's `create_idea`) lands in `ideas` and `idea_links`;
/// a status the Mac reads as one of its two is never rewritten; a Direction is left in the replica; deletes
/// go both ways; and an activated store whose triggers predate the projection sends the Ideas it holds once
/// its triggers are refreshed.
@Suite("Idea projection")
struct IdeaProjectionTests {
    typealias F = NotebookSyncFixture

    private static func store(_ name: String, registry: ProjectionRegistry? = nil) throws -> (URL, KnowledgeStore) {
        let (root, store) = try F.makeStore("idea-\(name)", triggers: registry == nil)
        if let registry { try store.installOutboxTriggers(registry) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        try F.addSource(store, "src-1")
        return (root, store)
    }

    private static func ms(_ seconds: Double) -> SyncJSON { SyncJSON(SyncTime.milliseconds(cocoaSeconds: seconds)) }

    @Test("An Idea made here encodes its words, its links keyed by target and a first writer's kind and provenance")
    func ideaFields() throws {
        let (root, store) = try Self.store("fields")
        defer { try? FileManager.default.removeItem(at: root) }
        let idea = try store.createIdea(title: "Complex IV may set the pace", notes: "Check the kinetics paper", links: [
            IdeaLink(kind: .source, targetID: "src-1"), IdeaLink(kind: .notebook, targetID: "nb-1"),
        ])
        let fields = try #require(F.savedFields(try F.pending(store)["Idea:\(idea.id)"]))
        #expect(fields["kind"] == .string("idea") && fields["status"] == .string("open"))
        #expect(fields["title"] == .string("Complex IV may set the pace") && fields["body"] == .string("Check the kinetics paper"))
        #expect(fields["madeBy"] == .object(["route": .string("user")]))
        #expect(fields["createdAt"] == Self.ms(idea.createdAt.timeIntervalSinceReferenceDate))
        #expect(fields["editedAt"] == Self.ms(idea.updatedAt.timeIntervalSinceReferenceDate))
        let links = try #require(fields["links"]?.objectValue)
        #expect(Set(links.keys) == ["src:src-1", "nb:nb-1"])
        #expect(links["src:src-1"] == .object([
            "kind": .string("source"), "target": .string("src:src-1"), "addedAt": Self.ms(idea.links[0].addedAt.timeIntervalSinceReferenceDate),
        ]))
        #expect(links["nb:nb-1"]?["kind"] == .string("notebook"))
    }

    @Test("Archive is `dismissed`, an unlink removes the element, and a delete deletes the record")
    func editsHere() throws {
        let (root, store) = try Self.store("edits")
        defer { try? FileManager.default.removeItem(at: root) }
        let idea = try store.createIdea(title: "Heteroplasmy drifts", links: [IdeaLink(kind: .source, targetID: "src-1")])
        try F.sendAll(store)

        try store.setIdeaStatus(idea.id, status: .archived)
        _ = try store.unlinkIdea(idea.id, kind: .source, targetIDs: ["src-1"])
        let fields = try #require(F.savedFields(try F.pending(store)["Idea:\(idea.id)"]))
        #expect(fields["status"] == .string("dismissed"))
        #expect(fields["links"]?["src:src-1"] == .null, "the link's element is removed")
        try F.sendAll(store)

        try store.deleteIdea(idea.id)
        let change = try #require(try F.pending(store)["Idea:\(idea.id)"])
        #expect(change.action == .delete)
    }

    @Test("An Idea another client writes lands in ideas and idea_links, and sends nothing back")
    func inboundIdea() throws {
        let (root, store) = try Self.store("inbound")
        defer { try? FileManager.default.removeItem(at: root) }
        // The notebook and source the store was made with go out first, so
        // what is left pending is the apply's alone.
        try F.sendAll(store)
        // As the Vision Pro writes one (`VisionLibrary.createIdea`), with a link as the hosted MCP keys one.
        try F.apply(store, [try F.record(.idea, "vp-1", [
            "kind": .string("idea"), "title": .string("Mitophagy fails first"), "body": .string("In aged neurons"),
            "status": .string("open"), "madeBy": .object(["route": .string("ai"), "model": .string("example/model")]),
            "createdAt": SyncJSON(Int64(1_759_000_000_000)), "editedAt": SyncJSON(Int64(1_759_100_000_000)),
            "links": .object([
                "src:src-1": .object(["kind": .string("source"), "target": .string("src:src-1"), "addedAt": SyncJSON(Int64(1_759_050_000_000))]),
                "crs:course-1": .object(["kind": .string("course"), "target": .string("crs:course-1"), "addedAt": SyncJSON(Int64(1_759_050_000_000))]),
            ]),
        ])])
        let idea = try #require(try store.loadIdea("vp-1"))
        #expect(idea.title == "Mitophagy fails first" && idea.notes == "In aged neurons" && idea.status == .open)
        #expect(idea.createdAt == SyncTime.date(milliseconds: 1_759_000_000_000))
        #expect(idea.updatedAt == SyncTime.date(milliseconds: 1_759_100_000_000))
        #expect(idea.links == [IdeaLink(kind: .source, targetID: "src-1", addedAt: SyncTime.date(milliseconds: 1_759_050_000_000))],
                "a link to a kind the Mac does not link is dropped")
        #expect(try F.pending(store).isEmpty, "an applied record sends nothing back")

        // Archived elsewhere, the link taken off.
        try F.apply(store, [try F.record(.idea, "vp-1", [
            "kind": .string("idea"), "title": .string("Mitophagy fails first"), "status": .string("dismissed"),
            "madeBy": .object(["route": .string("ai")]), "createdAt": SyncJSON(Int64(1_759_000_000_000)),
            "editedAt": SyncJSON(Int64(1_759_200_000_000)), "links": .object(["src:src-1": .null]),
        ], ms: 1_759_500_000_000)])
        let archived = try #require(try store.loadIdea("vp-1"))
        #expect(archived.status == .archived && archived.links.isEmpty)
        #expect(archived.notes == "In aged neurons", "a field the record does not carry is left alone")
    }

    @Test("A status, provenance or kind the record holds is kept when the Mac edits the Idea")
    func heldFieldsAreKept() throws {
        let (root, store) = try Self.store("held")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.apply(store, [try F.record(.idea, "web-1", [
            "kind": .string("idea"), "title": .string("Drift or selection?"), "status": .string("pursuing"),
            "madeBy": .object(["route": .string("ai"), "model": .string("example/model")]),
            "createdAt": SyncJSON(Int64(1_759_000_000_000)), "editedAt": SyncJSON(Int64(1_759_000_000_000)),
        ])])
        #expect(try store.loadIdea("web-1")?.status == .open, "pursuing reads as open")

        try store.updateIdea("web-1", title: "Drift, or selection?")
        let fields = try #require(F.savedFields(try F.pending(store)["Idea:web-1"]))
        #expect(fields["title"] == .string("Drift, or selection?"))
        #expect(fields["status"] == .string("pursuing"), "an open Mac row never rewrites pursuing to open")
        #expect(fields["madeBy"] == .object(["route": .string("ai"), "model": .string("example/model")]))
        #expect(fields["createdAt"] == SyncJSON(Int64(1_759_000_000_000)))
    }

    @Test("A Direction is left in the replica, and an Idea deleted elsewhere leaves the Mac")
    func directionAndInboundDelete() throws {
        let (root, store) = try Self.store("direction")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.apply(store, [try F.record(.idea, "dir-1", [
            "kind": .string("direction"), "title": .string("Map the respiratory supercomplexes"), "status": .string("open"),
            "madeBy": .object(["route": .string("ai")]), "createdAt": SyncJSON(Int64(1_759_000_000_000)),
            "editedAt": SyncJSON(Int64(1_759_000_000_000)),
        ])])
        #expect(try F.count(store, "SELECT COUNT(*) FROM ideas") == 0)
        #expect(try F.held(store, .idea, "dir-1") != nil, "kept raw for the projection that holds Directions")

        let idea = try store.createIdea(title: "Ours", links: [IdeaLink(kind: .source, targetID: "src-1")])
        try F.sendAll(store)
        try store.replica.apply { replica in
            let held = try #require(try replica.record(zoneKey: F.libraryZoneKey, recordType: "Idea", wireID: idea.id))
            try replica.deleteRecord(zoneKey: F.libraryZoneKey, recordName: held.recordName)
            try ProjectionApply(store: store, registry: F.registry)
                .projectDeletion(zoneKey: F.libraryZoneKey, recordName: held.recordName, type: .idea, wireID: idea.id)
        }
        #expect(try store.loadIdea(idea.id) == nil)
        #expect(try F.count(store, "SELECT COUNT(*) FROM idea_links") == 0)
        #expect(try F.pending(store)["Idea:\(idea.id)"] == nil, "an inbound delete sends nothing back")
    }

    @Test("An activated store whose triggers predate the projection sends the Ideas it holds once they are refreshed")
    func refreshSendsExistingIdeas() throws {
        let older = ProjectionRegistry(KnowledgeStore.projectionRegistry.projections.filter { $0.recordType != .idea })
        let (root, store) = try Self.store("refresh", registry: older)
        defer { try? FileManager.default.removeItem(at: root) }
        let idea = try store.createIdea(title: "Jotted before the update", links: [IdeaLink(kind: .source, targetID: "src-1")])
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_outbox_fields WHERE source_table IN ('ideas', 'idea_links')") == 0,
                "no trigger watched the Ideas")

        try store.installOutboxTriggers(F.registry)
        let fields = try #require(F.savedFields(try F.pending(store)["Idea:\(idea.id)"]))
        #expect(fields["title"] == .string("Jotted before the update"))
        #expect(fields["links"]?["src:src-1"]?["target"] == .string("src:src-1"))
        #expect(fields["editedAt"] == Self.ms(idea.updatedAt.timeIntervalSinceReferenceDate), "dated with its own time")

        try F.sendAll(store)
        try store.installOutboxTriggers(F.registry)
        #expect(try F.pending(store).isEmpty, "an unchanged registry queues nothing again")
        try store.updateIdea(idea.id, notes: "Now watched")
        #expect(F.savedFields(try F.pending(store)["Idea:\(idea.id)"])?["body"] == .string("Now watched"))
    }
}
