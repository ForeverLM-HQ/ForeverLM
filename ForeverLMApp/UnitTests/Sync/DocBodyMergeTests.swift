import Foundation
import Testing
@testable import ForeverLM

/// The T merge of a body (docs/cloudkit-schema-design.md §6.2 step 4, §13.6, R8-m4, WP11): a Doc edited
/// here and on another device merges against `document.base.md`, an overlap is held for the writer, and
/// notes merge against `ck_text_bases`, else against the catch-up's notes base kept by wire id, which a
/// later acknowledged upload's entry replaces. WP8b's fold publishes its notes through the same path.
@Suite("Doc body merge")
struct DocBodyMergeTests {
    typealias F = ArtifactSyncFixture
    typealias N = NotebookSyncFixture

    private static let later: Int64 = 1_799_000_000_000

    @Test("A Doc edited on both sides in different places merges cleanly, and the merge is published")
    func cleanMerge() async throws {
        let rig = try F.makeRig("merge-clean")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try F.addDoc(rig.store, "doc-1", markdown: "L1\nL2\nL3\nL4\nL5")
        try await F.publishAndSend(rig)
        try F.write(rig.store, "doc-1", "L1 mine\nL2\nL3\nL4\nL5", at: Date())

        let theirs = try rig.bodies.putDoc("L1\nL2\nL3\nL4\nL5 theirs", owner: "doc-1")
        try N.apply(rig.store, [try F.docRecord("doc-1", body: theirs, ms: Self.later)])
        #expect(try F.bodyRef(rig.store, "doc-1") == theirs)
        #expect(try await rig.publisher.publishDue(now: Date().addingTimeInterval(3_600)).isEmpty, "the server's body is brought in first")

        #expect(try await rig.materializer.materializeDue()["doc-1"] == .merged)
        #expect(try rig.store.loadArtifactMarkdownForSync("doc-1") == "L1 mine\nL2\nL3\nL4\nL5 theirs")
        #expect(try rig.store.loadArtifactBaseMarkdown("doc-1") == "L1\nL2\nL3\nL4\nL5 theirs", "the server's body is the new base")
        try await F.publishAndSend(rig)
        let held = try #require(try N.held(rig.store, .artifact, "doc-1")?.fields["body"].flatMap(FileRef.init(json:)))
        #expect(held.hash == (try rig.store.loadArtifactBodyPackageForSync("doc-1"))?.revision, "the merged body went out under a new pointer")
        #expect(held != theirs)
    }

    @Test("An overlap keeps the server's body, holds it beside the writer's text and publishes nothing until the writer chooses")
    func overlapHeld() async throws {
        let rig = try F.makeRig("merge-overlap")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try F.addDoc(rig.store, "doc-1", markdown: "A\nB\nC")
        try await F.publishAndSend(rig)
        try F.write(rig.store, "doc-1", "A\nB mine\nC", at: Date())
        let theirs = try rig.bodies.putDoc("A\nB theirs\nC", owner: "doc-1")
        try N.apply(rig.store, [try F.docRecord("doc-1", body: theirs, ms: Self.later)])

        #expect(try await rig.materializer.materializeDue()["doc-1"] == .held)
        #expect(try rig.store.loadArtifactMarkdownForSync("doc-1") == "A\nB mine\nC", "the writer's text stays on screen")
        #expect(try rig.store.loadArtifactHeldRemoteMarkdown("doc-1") == "A\nB theirs\nC")
        let uploads = rig.bodies.uploadCount
        try await F.publishAndSend(rig, forcing: ["doc-1"])
        #expect(rig.bodies.uploadCount == uploads, "held for the writer: nothing goes out, even on close")
        #expect(try N.held(rig.store, .artifact, "doc-1")?.fields["body"] == theirs.value, "the server keeps its body")

        // The writer keeps their version.
        try rig.store.discardArtifactHeldRemoteMarkdown("doc-1")
        try await F.publishAndSend(rig)
        #expect(rig.bodies.uploadCount == uploads + 1)
        #expect(try N.held(rig.store, .artifact, "doc-1")?.fields["body"].flatMap(FileRef.init(json:))?.hash
                == (try rig.store.loadArtifactBodyPackageForSync("doc-1"))?.revision)
    }

    @Test("Notes edited on both sides merge against the base the last acknowledged upload wrote")
    func notesAgainstTextBase() async throws {
        let rig = try F.makeRig("merge-notes")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try N.addNotebook(rig.store, "nb-1")
        try F.setNotes(rig.store, "nb-1", "N1\nN2\nN3\nN4\nN5")
        try await F.publishAndSend(rig)
        #expect(try F.text(rig.store, "SELECT base_text FROM ck_text_bases WHERE field = 'body'") == "N1\nN2\nN3\nN4\nN5")

        try F.setNotes(rig.store, "nb-1", "N1 mine\nN2\nN3\nN4\nN5")
        let theirs = try rig.bodies.putNotes("N1\nN2\nN3\nN4\nN5 theirs", notebookID: "nb-1")
        try N.apply(rig.store, [try F.notesRecord("nb-1", body: theirs, ms: Self.later)])
        #expect(try await rig.materializer.materializeDue()["notes:nb-1"] == .merged)
        #expect(try F.notes(rig.store, "nb-1") == "N1 mine\nN2\nN3\nN4\nN5 theirs")
        #expect(try NotesBase.load(notebookID: "nb-1", connection: rig.store) == "N1\nN2\nN3\nN4\nN5 theirs")
        try await F.publishAndSend(rig)
        #expect(try N.held(rig.store, .artifact, "notes:nb-1")?.fields["body"].flatMap(FileRef.init(json:))?.hash
                == SyncIdentity.sha256Hex(Data("N1 mine\nN2\nN3\nN4\nN5 theirs".utf8)))
    }

    @Test("A folded notes body published against a target body edited meanwhile is three-way merged (WP8b's fold)")
    func foldedNotesMerge() async throws {
        let rig = try F.makeRig("merge-fold")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try N.addNotebook(rig.store, "nb-b", title: "Target")
        try F.setNotes(rig.store, "nb-b", "B1\nB2\nB3\nB4\nB5")
        try await F.publishAndSend(rig)
        // The fold writes the target's new notes: its own under its title, then the folded notebook's.
        let folded = "## Target\n\nB1\nB2\nB3\nB4\nB5\n\n## Other\n\nA1"
        try F.setNotes(rig.store, "nb-b", folded)
        // Meanwhile another device edited the target's notes.
        let theirs = try rig.bodies.putNotes("B1\nB2\nB3 edited\nB4\nB5", notebookID: "nb-b")
        try N.apply(rig.store, [try F.notesRecord("nb-b", body: theirs, ms: Self.later)])
        #expect(try await rig.materializer.materializeDue()["notes:nb-b"] == .merged)
        #expect(try F.notes(rig.store, "nb-b") == "## Target\n\nB1\nB2\nB3 edited\nB4\nB5\n\n## Other\n\nA1", "neither edit is overwritten")
    }

    @Test("A notes base written by wire id before any root is found after bootstrap, and a later acknowledged upload's base wins")
    func legacyNotesBase() async throws {
        let (root, store) = try N.makeStore("WP11-merge-legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        try N.addNotebook(store, "nb-1")
        let walked = "N1\nN2\nN3\nN4\nN5"
        try F.setNotes(store, "nb-1", walked)
        // The catch-up's walk, before this Mac knows the zone's salt.
        try NotesBase.saveLegacy(walked, notebookID: "nb-1", connection: store)
        #expect(try NotesBase.recordName(notebookID: "nb-1", connection: store) == nil, "no root yet")

        try N.prepareReplica(store)
        let bodies = F.Bodies()
        let synced = MacPrivateSyncStore.direct(store)
        let rig = F.Rig(root: root, store: store, bodies: bodies,
                        publisher: DocBodyPublisher(store: synced, transfer: bodies.transfer),
                        materializer: DocBodyMaterializer(store: synced, transfer: bodies.transfer))
        #expect(try NotesBase.load(notebookID: "nb-1", connection: store) == walked)
        try F.setNotes(store, "nb-1", "N1 mine\nN2\nN3\nN4\nN5")
        let theirs = try bodies.putNotes("N1\nN2\nN3\nN4\nN5 theirs", notebookID: "nb-1")
        try N.apply(store, [try F.notesRecord("nb-1", body: theirs, ms: Self.later)])
        #expect(try await rig.materializer.materializeDue()["notes:nb-1"] == .merged, "merged against the walk's notes")
        let merged = "N1 mine\nN2\nN3\nN4\nN5 theirs"
        #expect(try F.notes(store, "nb-1") == merged)

        try await F.publishAndSend(rig)
        #expect(try NotesBase.load(notebookID: "nb-1", connection: store) == merged, "the acknowledged upload's entry wins over the walk's")
        // So the next server edit applies outright: this Mac has no edit since that base. Against the
        // walk's notes it would have been taken for one and merged.
        let next = try bodies.putNotes("N1 mine\nN2\nN3 again\nN4\nN5 theirs", notebookID: "nb-1")
        try N.apply(store, [try F.notesRecord("nb-1", body: next, ms: Self.later + 1_000)])
        #expect(try await rig.materializer.materializeDue()["notes:nb-1"] == .applied)
        #expect(try F.notes(store, "nb-1") == "N1 mine\nN2\nN3 again\nN4\nN5 theirs")
    }
}
