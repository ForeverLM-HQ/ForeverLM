import Foundation
import Testing
@testable import ForeverLM

/// When bodies are published (docs/cloudkit-schema-design.md D44, §6.6 step 4, WP11): on idle (30 s with
/// nothing in the Doc's folder, or the notebook, changed), on close, on Publish and before a send that
/// needs them, never per keystroke, and the pointer only after the bytes.
@Suite("Doc body cadence")
struct DocBodyCadenceTests {
    typealias F = ArtifactSyncFixture
    typealias N = NotebookSyncFixture

    @Test("A typing session publishes one body satellite per idle period, not per keystroke")
    func onePerIdlePeriod() async throws {
        let rig = try F.makeRig("cadence")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let start = Date().addingTimeInterval(-10_000)
        try F.addDoc(rig.store, "doc-1", markdown: "A", editedAt: start)

        // Twenty keystrokes two seconds apart, a publisher round after each.
        var text = "A"
        for keystroke in 1...20 {
            text += " word\(keystroke)"
            let at = start.addingTimeInterval(Double(keystroke) * 2)
            try F.write(rig.store, "doc-1", text, at: at)
            try await rig.publisher.publishDue(now: at.addingTimeInterval(1))
        }
        #expect(rig.bodies.uploadCount == 0, "nothing while the learner types")
        #expect(try F.bodyRef(rig.store, "doc-1") == nil, "and no pointer")

        let lastEdit = start.addingTimeInterval(40)
        try await rig.publisher.publishDue(now: lastEdit.addingTimeInterval(29))
        #expect(rig.bodies.uploadCount == 0, "29 s is not idle yet")
        try await rig.publisher.publishDue(now: lastEdit.addingTimeInterval(31))
        #expect(rig.bodies.uploadCount == 1, "one satellite for the whole session")
        let pointer = try #require(try F.bodyRef(rig.store, "doc-1"))
        #expect(pointer.hash == (try rig.store.loadArtifactBodyPackageForSync("doc-1"))?.revision)
        try await rig.publisher.publishDue(now: lastEdit.addingTimeInterval(600))
        #expect(rig.bodies.uploadCount == 1, "an idle Doc whose pointer is current publishes nothing more")

        // A second session, then its own idle period: one more.
        for keystroke in 1...5 {
            let at = lastEdit.addingTimeInterval(1_000 + Double(keystroke))
            try F.write(rig.store, "doc-1", text + String(repeating: "!", count: keystroke), at: at)
            try await rig.publisher.publishDue(now: at.addingTimeInterval(1))
        }
        try await rig.publisher.publishDue(now: lastEdit.addingTimeInterval(1_100))
        #expect(rig.bodies.uploadCount == 2)
        #expect(Set(rig.bodies.uploads.map(\.hash)).count == 2)
    }

    @Test("Close, Publish or a send that needs the body publish it at once; an unchanged one goes nowhere")
    func publishNow() async throws {
        let rig = try F.makeRig("now")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let now = Date()
        try F.addDoc(rig.store, "doc-1", markdown: "Fresh", editedAt: now)
        try await rig.publisher.publishDue(now: now.addingTimeInterval(1))
        #expect(rig.bodies.uploadCount == 0)
        #expect(try await rig.publisher.publishNow("doc-1", now: now.addingTimeInterval(1)))
        #expect(rig.bodies.uploadCount == 1)
        #expect(try await rig.publisher.publishNow("doc-1", now: now.addingTimeInterval(2)) == false)
        #expect(rig.bodies.uploadCount == 1)
    }

    @Test("The pointer goes out only after the upload, so a failed upload sends nothing")
    func bytesBeforePointer() async throws {
        let rig = try F.makeRig("bytes-first")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try F.addDoc(rig.store, "doc-1", markdown: "Body")
        let failing = DocBodyPublisher(
            store: MacPrivateSyncStore.direct(rig.store),
            transfer: DocBodyTransfer(upload: { _, _, _, _, _ in throw BlobStoreError.failed(CloudError(.internalError, message: "offline")) },
                                      fetch: { _ in Data() })
        )
        #expect(try await failing.publishDue(now: Date().addingTimeInterval(3_600)).isEmpty)
        #expect(try F.bodyRef(rig.store, "doc-1") == nil)
        #expect(N.savedFields(try N.pending(rig.store)["Artifact:doc-1"])?["body"] == nil)
    }

    @Test("Notes publish on the notebook's idle, and wait while a body from another device is being brought in")
    func notesIdleAndFetchFirst() async throws {
        let rig = try F.makeRig("notes-idle")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try N.addNotebook(rig.store, "nb-1")
        let now = Date()
        try F.setNotes(rig.store, "nb-1", "Draft", at: now)
        try await rig.publisher.publishDue(now: now.addingTimeInterval(10))
        #expect(rig.bodies.uploadCount == 0)
        try await rig.publisher.publishDue(now: now.addingTimeInterval(31))
        #expect(rig.bodies.uploadCount == 1)
        try N.sendAll(rig.store)

        // Another device's notes arrive; until they are brought in, this Mac's edit waits.
        let theirs = try rig.bodies.putNotes("Draft, theirs", notebookID: "nb-1")
        try N.apply(rig.store, [try F.notesRecord("nb-1", body: theirs, ms: 1_799_000_000_000)])
        try F.setNotes(rig.store, "nb-1", "Draft, mine", at: now)
        try await rig.publisher.publishDue(now: now.addingTimeInterval(3_600))
        #expect(rig.bodies.uploadCount == 1, "nothing goes out over a body still to fetch")
    }
}
