import Foundation
import Testing
@testable import ForeverLM

/// A light client's captures on a Mac (docs/cloudkit-schema-design.md §5.4, §9.4, D41, D47, WP14): the
/// `ingestURL` and `ingestFile` Jobs the iPhone and the web write before their first complete Catalog
/// pass. The claiming Mac looks a capture up before it mints one, keeps a file's FileRef verbatim, and
/// files the source into `resolveNotebook(target)`; a target that is gone leaves it in the library, and a
/// target in a space waits for WP15, which pins that case (`SpaceServiceTests`).
@Suite("Job filing", .serialized)
struct JobFilingTests {
    typealias F = NotebookSyncFixture
    typealias J = JobSyncFixture

    private static func store(_ name: String) throws -> (URL, KnowledgeStore) {
        let (root, store) = try F.makeStore("jobs-\(name)")
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        try F.sendAll(store)
        return (root, store)
    }

    /// One claim acknowledged by the server, then the start: what two passes around a send do.
    private static func claimAndRun(_ runner: MacJobRunner, _ store: KnowledgeStore, _ id: String) async throws -> String? {
        #expect(await runner.pass() == [.claim(id)])
        try F.sendAll(store)
        #expect(await runner.pass() == [.start(id)])
        return try await J.settled(store, id)
    }

    private static func workKeys(_ url: String) -> [SyncJSON] {
        SourceWorkKeys.keys(url: url, normalizedURL: URLNormalizer.normalize(url)).map(SyncJSON.string)
    }

    private static func target(_ notebookID: String, approval: String = "approved") -> SyncJSON {
        .object(["notebookID": .string(notebookID), "approval": .string(approval)])
    }

    @Test("A link shared into a notebook lands there, ticked, and the Job says where")
    func linkLandsInItsNotebook() async throws {
        let (root, store) = try Self.store("link")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = "https://example.org/a-shared-page"
        try F.apply(store, [try J.jobRecord("job-1", kind: "ingestURL", params: [
            "url": .string(url), "workKeys": .array(Self.workKeys(url)), "target": Self.target("nb-1"),
        ])])
        let work = FakeJobWork(store: store)
        let runner = J.runner(store, work: work)

        #expect(try await Self.claimAndRun(runner, store, "job-1") == "done")
        let sourceID = SourceIdentity.stableID(for: url)
        #expect(work.recorded == ["importLink \(url)"])
        #expect(try F.text(store, "SELECT review_state FROM learning_goal_items WHERE goal_id = 'nb-1' AND source_id = ?", [.text(sourceID)]) == "approved")
        let entry = try #require(F.savedFields(try F.pending(store)["Entry:\(SyncIdentity.entryID(containerID: "nb-1", itemKind: "source", itemID: sourceID))"]))
        #expect(entry["state"] == .string("active") && entry["approval"] == .string("approved"))
        #expect(try F.count(store, "SELECT COUNT(*) FROM notebook_states WHERE notebook_id = 'nb-1' AND excluded_json LIKE ?", [.text("%\(sourceID)%")]) == 0,
                "ticked in the notebook's chats")
        let job = try #require(F.savedFields(try F.pending(store)["Job:job-1"]))
        #expect(job["status"] == .string("done"))
        #expect(job["result"] == .object(["refs": .array([.string("src:\(sourceID)"), .string("nb:nb-1")])]))

        // The same link again: the library's source is found by its work key, never imported twice.
        try F.apply(store, [try J.jobRecord("job-2", kind: "ingestURL", params: [
            "url": .string(url), "workKeys": .array(Self.workKeys(url)), "target": Self.target("nb-1"),
        ])])
        #expect(try await Self.claimAndRun(runner, store, "job-2") == "done")
        #expect(work.recorded == ["importLink \(url)"])
    }

    @Test("A phone PDF Job becomes a source whose files.pdf is the Job's FileRef, and the same bytes again are that source")
    func phonePDFKeepsItsFileRef() async throws {
        let (root, store) = try Self.store("pdf")
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = J.phonePDF()
        try F.apply(store, [try J.jobRecord("job-pdf", kind: "ingestFile", params: [
            "file": pdf.file.value, "sha256": .string(pdf.sha), "title": .string("Scan of a page"), "capture": .string("scan"),
            "target": Self.target("nb-1"),
        ])])
        let work = FakeJobWork(store: store)
        work.holds(pdf.bytes, for: pdf.file)
        let runner = J.runner(store, work: work)

        #expect(try await Self.claimAndRun(runner, store, "job-pdf") == "done")
        #expect(work.recorded == ["importFile pdf \(pdf.bytes.count)"])
        let sourceID = try #require(try F.text(store, "SELECT source_id FROM source_files WHERE role = 'pdf'"))
        let stored = try #require(try F.text(store, "SELECT file_ref FROM source_files WHERE source_id = ? AND role = 'pdf'", [.text(sourceID)]))
        #expect(try SyncJSON(parsing: Data(stored.utf8)) == pdf.file.value, "verbatim (D41)")
        let source = try #require(F.savedFields(try F.pending(store)["Source:\(sourceID)"]))
        #expect(source["files"]?["pdf"] == pdf.file.value)
        #expect(try F.text(store, "SELECT review_state FROM learning_goal_items WHERE goal_id = 'nb-1' AND source_id = ?", [.text(sourceID)]) == "approved")

        // Its work key is the file's hash: a second capture of the same bytes is that source.
        try F.sendAll(store)
        try store.addWorkKeys(["file:\(pdf.sha)"], to: sourceID)
        try F.apply(store, [try J.jobRecord("job-pdf-2", kind: "ingestFile", params: [
            "file": pdf.file.value, "sha256": .string(pdf.sha), "capture": .string("pdf"),
        ])])
        #expect(try await Self.claimAndRun(runner, store, "job-pdf-2") == "done")
        #expect(work.recorded.count == 1, "looked up before it was minted")
        #expect(F.savedFields(try F.pending(store)["Job:job-pdf-2"])?["result"]?["refs"] == .array([.string("src:\(sourceID)")]))
    }

    @Test("A target that is gone leaves the source in the library, and the Job says so")
    func goneTargetLeavesItInTheLibrary() async throws {
        let (root, store) = try Self.store("gone")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = "https://example.org/orphan"
        try F.apply(store, [try J.jobRecord("job-gone", kind: "ingestURL", params: [
            "url": .string(url), "workKeys": .array([]), "target": Self.target("nb-deleted"),
        ])])
        let runner = J.runner(store, work: FakeJobWork(store: store))
        #expect(try await Self.claimAndRun(runner, store, "job-gone") == "done")
        let sourceID = SourceIdentity.stableID(for: url)
        #expect(try store.sourceExists(sourceID))
        #expect(try F.count(store, "SELECT COUNT(*) FROM learning_goal_items WHERE source_id = ?", [.text(sourceID)]) == 0)
        let result = try #require(F.savedFields(try F.pending(store)["Job:job-gone"])?["result"])
        #expect(result["refs"] == .array([.string("src:\(sourceID)")]))
        #expect(result["note"]?.stringValue?.contains("gone") == true)
    }

    @Test("A notebook that resolves elsewhere files there; a target in a team's notebook, or not projected yet, waits unclaimed")
    func resolvedAndWaitingTargets() async throws {
        let (root, store) = try Self.store("targets")
        defer { try? FileManager.default.removeItem(at: root) }
        // nb-old was merged into nb-1: the capture lands in the survivor.
        try store.execute("INSERT INTO notebook_resolution (id, resolved_id, resolved_zone) VALUES ('nb-old', 'nb-1', 'Library')")
        try F.addNotebook(store, "nb-team")
        try store.execute("UPDATE learning_goals SET team_id = 'team-1' WHERE id = 'nb-team'")
        // nb-arriving's record is here, its row not yet (it waits on a parent, §5.7).
        let arriving = try F.record(.notebook, "nb-arriving", ["title": .string("Arriving")])
        try store.replica.apply { try $0.upsertRecord(arriving) }
        try F.apply(store, [
            try J.jobRecord("job-merged", kind: "ingestURL", params: ["url": .string("https://example.org/merged"), "target": Self.target("nb-old")]),
            try J.jobRecord("job-team", kind: "ingestURL", params: ["url": .string("https://example.org/team"), "target": Self.target("nb-team")]),
            try J.jobRecord("job-arriving", kind: "ingestURL", params: ["url": .string("https://example.org/arriving"), "target": Self.target("nb-arriving")]),
        ])
        let runner = J.runner(store, work: FakeJobWork(store: store))
        #expect(try await Self.claimAndRun(runner, store, "job-merged") == "done")
        let sourceID = SourceIdentity.stableID(for: "https://example.org/merged")
        #expect(try F.count(store, "SELECT COUNT(*) FROM learning_goal_items WHERE goal_id = 'nb-1' AND source_id = ?", [.text(sourceID)]) == 1)
        #expect(await runner.pass().isEmpty, "a team's notebook (WP15) and a notebook not projected yet are never claimed")
        #expect(try F.text(store, "SELECT group_concat(status || ':' || COALESCE(claim_json, '-'), ',') FROM jobs WHERE id IN ('job-team', 'job-arriving')") == "queued:-,queued:-")
    }

    @Test("A tool Job runs only a tool of its kind; a skeletal source's Job fetches it; a kind this build cannot run waits")
    func toolsAndKinds() async throws {
        let (root, store) = try Self.store("tools")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.addSource(store, "src-skeletal")
        try F.apply(store, [
            try J.jobRecord("job-report", kind: "makeDerived", target: "nb:nb-1", params: ["tool": .string("generate_report"), "arguments": .object(["notebook_id": .string("nb-1")])]),
            try J.jobRecord("job-sneaky", kind: "makeDerived", params: ["tool": .string("delete_source"), "arguments": .object(["source_id": .string("src-skeletal")])]),
            try J.jobRecord("job-fetch", kind: "ingestURL", target: "src:src-skeletal", params: ["url": .string("https://example.com/src-skeletal")]),
            // A move into a space is claimed since WP15b (SpaceMoveCrashTests); an original's upload is not yet.
            try J.jobRecord("job-upload", kind: "uploadOriginal", target: "src:src-skeletal", params: [:]),
        ])
        let work = FakeJobWork(store: store)
        let runner = J.runner(store, work: work)
        #expect(Set(await runner.pass()) == [.claim("job-report"), .claim("job-fetch")])
        try F.sendAll(store)
        #expect(Set(await runner.pass()) == [.start("job-report"), .start("job-fetch")])
        #expect(try await J.settled(store, "job-report") == "done")
        #expect(try await J.settled(store, "job-fetch") == "done")
        #expect(Set(work.recorded) == ["callTool generate_report", "fetchContent src-skeletal"])
        #expect(F.savedFields(try F.pending(store)["Job:job-report"])?["result"] == .object(["refs": .array([.string("nb:nb-1")]), "note": .string("Done: generate_report.")]))
        #expect(try F.text(store, "SELECT group_concat(status, ',') FROM jobs WHERE id IN ('job-sneaky', 'job-upload')") == "queued,queued")
    }

    @Test("A Job this Mac started before a quit is failed, never run twice")
    func interruptedJobFails() async throws {
        let (root, store) = try Self.store("interrupted")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.apply(store, [try J.jobRecord("job-1", kind: "fetchContent", target: "src:s1", params: ["tool": .string("refetch_source_content"), "arguments": .object([:])])])
        let work = FakeJobWork(store: store)
        let first = J.runner(store, work: work)
        #expect(await first.pass() == [.claim("job-1")])
        try F.sendAll(store)
        // The start is written and sent, then the app quits before the work ran.
        try store.execute("UPDATE jobs SET status = 'running', lease_until = ? WHERE id = 'job-1'", [.real(Date().timeIntervalSinceReferenceDate + 900)])
        try F.sendAll(store)

        let relaunched = J.runner(store, work: work)
        #expect(await relaunched.pass() == [.interrupted("job-1")])
        #expect(try F.text(store, "SELECT status || ':' || error FROM jobs WHERE id = 'job-1'") == "failed:ForeverLM closed before this job finished.")
        #expect(work.recorded.isEmpty)
    }
}
