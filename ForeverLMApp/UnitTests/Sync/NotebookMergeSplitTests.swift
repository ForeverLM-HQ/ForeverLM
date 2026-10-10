import Foundation
import Testing
@testable import ForeverLM

/// Stores and records for WP8b's suites (docs/cloudkit-schema-design.md §5.2, D17, D48): notebooks with
/// chats, Goals and tasks filed under them, merges and splits run through the generation-2 jobs, and
/// inbound records and deletions applied as the engine applies them, the merge with a pending local
/// change included. Built on `NotebookSyncFixture`, so it also runs standalone over the real sources.
enum NotebookMergeFixture {
    typealias F = NotebookSyncFixture

    static func entry(_ containerID: String, _ sourceID: String) -> String {
        SyncIdentity.entryID(containerID: containerID, itemKind: "source", itemID: sourceID)
    }

    /// A whole field's stamp in `envelope`.
    static func stamp(_ envelope: SyncEnvelope?, _ field: String) -> String? {
        if case .value(let stamp)? = envelope?.stamps[field] { return stamp.rawValue }
        return nil
    }

    static func savedEnvelope(_ change: OutboxChange?) -> SyncEnvelope? {
        guard case .save(let envelope)? = change?.action else { return nil }
        return envelope
    }

    static func merge(_ store: KnowledgeStore, _ mergees: [String], into survivor: String, title: String? = nil) throws -> CompanionGoalMergeResult {
        try store.mergeNotebooksUnderGeneration2(survivorID: survivor, mergeeIDs: mergees, title: title, mergeNotes: true)
    }

    static func split(_ store: KnowledgeStore, _ parent: String, _ parts: [(String, [String])], keepParent: Bool = false) throws -> CompanionGoalSplitResult {
        try store.splitNotebookUnderGeneration2(
            parentID: parent, splits: parts.map { CompanionGoalSplitSpec(title: $0.0, topic: nil, sourceIDs: $0.1, gapIDs: []) }, keepParent: keepParent
        )
    }

    static func addChat(_ store: KnowledgeStore, _ id: String, in notebookID: String) throws {
        try store.execute("INSERT INTO review_sessions (id, topic, started_at, goal_id) VALUES (?, 'Complex I', 1000, ?)", [.text(id), .text(notebookID)])
    }

    static func addTask(_ store: KnowledgeStore, _ id: String, in notebookID: String) throws {
        try store.execute(
            "INSERT INTO notebook_tasks (id, notebook_id, title, created_at, updated_at) VALUES (?, ?, 'Summarise Picard', 1000, 1000)",
            [.text(id), .text(notebookID)]
        )
    }

    /// A notebook's own words, as the app's setters leave them.
    static func setWords(
        _ store: KnowledgeStore, _ id: String, notes: String? = nil, instructions: String? = nil, summary: String? = nil,
        topic: String? = nil, repository: String? = nil, questions: [String]? = nil
    ) throws {
        try store.execute(
            "UPDATE learning_goals SET notes = ?, description = ?, summary = ?, topic = ?, repository = ?, research_questions = ? WHERE id = ?",
            [.text(notes), .text(instructions), .text(summary), .text(topic), .text(repository),
             .text(questions.map(KnowledgeStore.encodeResearchQuestions)), .text(id)]
        )
        try store.keepNotebookRowsForGeneration2(goalIDs: [id])
    }

    static func link(_ store: KnowledgeStore, _ from: String, to related: String) throws {
        try store.execute("INSERT INTO notebook_related_notebook_links (notebook_id, related_notebook_id, linked_at) VALUES (?, ?, 1000)", [.text(from), .text(related)])
    }

    /// A merged notebook's stub as the device that merged it sent it.
    static func stubRecord(_ id: String, into survivor: String, kind: String = "merge", title: String = "Mitochondria",
                           extra: [String: SyncJSON] = [:], ms: Int64 = 1_900_000_000_000, device: String = "otheraaa") throws -> ReplicaRecord {
        var fields: [String: SyncJSON] = [
            "title": .string(title), "status": .string("merged"), "mergedInto": .string(survivor), "foldKind": .string(kind),
            "createdAt": SyncJSON(Int64(1_759_000_000_000)),
        ]
        fields.merge(extra) { _, new in new }
        return try F.record(.notebook, id, fields, ms: ms, device: device)
    }

    /// Another device's record, applied as the engine applies a fetched one: merged with this Mac's
    /// pending change of it when there is one (§6.2).
    static func absorb(_ store: KnowledgeStore, _ record: ReplicaRecord) async throws {
        let cloud = CloudRecord(
            id: CloudRecordID(record.recordName, in: CloudZoneID("Library")), recordType: record.recordType,
            encryptedFields: [CloudRecord.payloadKey: .bytes(record.payload)], systemFields: Data([9])
        )
        try await MacPrivateSyncStore.direct(store).perform { state in
            try state.replica.apply { _ in
                _ = try InboundApply(state: state, now: Date(), passStart: nil, moveMaps: MoveMapIndex()).absorb(cloud, zoneKey: F.libraryZoneKey)
            }
        }
    }

    /// The server's deletion of a record this Mac holds, applied as the engine applies one.
    static func absorbDeletion(_ store: KnowledgeStore, _ type: SyncRecordType, _ wireID: String) async throws {
        let name = RecordNaming.recordName(type: type, id: wireID, salt: F.salt)
        try await MacPrivateSyncStore.direct(store).perform { state in
            try state.replica.apply { _ in
                try InboundApply(state: state, now: Date(), passStart: nil, moveMaps: MoveMapIndex())
                    .absorbDeletion(CloudRecordDeletion(id: CloudRecordID(name, in: CloudZoneID("Library")), recordType: type.rawValue), zoneKey: F.libraryZoneKey)
            }
        }
    }

    static func goalParent(_ store: KnowledgeStore, _ id: String) throws -> String? {
        try F.text(store, "SELECT parent_notebook_id FROM learning_goals WHERE id = ?", [.text(id)])
    }

    static func reviewState(_ store: KnowledgeStore, _ goal: String, _ source: String) throws -> String? {
        try F.text(store, "SELECT COALESCE(review_state, 'approved') FROM learning_goal_items WHERE goal_id = ? AND source_id = ?", [.text(goal), .text(source)])
    }
}

/// Bug b34 under generation 2 (§5.2, D17, D48): a merge re-points every child of the merged notebook
/// through the back-pointer index and leaves a permanent redirect, written first; Entries are twinned
/// with their stamps; an emptying split leaves its parent as a `merged` stub with `foldKind = split`;
/// and whatever still names a stub later (a late child, a late Entry, a late write, a late edit) is
/// moved on by the Mac that sees it.
@Suite("Notebook merge and split")
struct NotebookMergeSplitTests {
    typealias F = NotebookSyncFixture
    typealias M = NotebookMergeFixture

    @Test("After a merge nothing names the merged notebook but its redirect, and a late child naming it lands in the survivor")
    func mergeLeavesOnlyTheRedirect() throws {
        let (root, store) = try F.makeStore("merge-redirect")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-a", title: "Mitochondria")
        try F.addNotebook(store, "nb-b", title: "Mito Phenotyping")
        for source in ["src-1", "src-2", "src-3"] { try F.addSource(store, source) }
        try F.file(store, "src-1", into: "nb-a")
        try F.file(store, "src-2", into: "nb-a", reviewState: "pending")
        try F.file(store, "src-3", into: "nb-b")
        try M.addChat(store, "chat-a", in: "nb-a")
        try F.addGoal(store, "goal-a", parent: "nb-a")
        try M.addTask(store, "task-a", in: "nb-a")
        try store.execute("INSERT INTO courses (id, title) VALUES ('course-1', 'Bioenergetics')")
        try store.execute("INSERT INTO notebook_course_links (goal_id, course_id) VALUES ('nb-a', 'course-1')")
        // Rows no record carries that file things under A, and a bystander drawing context from it.
        try store.execute("INSERT INTO scheduled_source_goals (scheduled_source_id, goal_id, added_at) VALUES ('placement-1', 'nb-a', 1000)")
        try F.addNotebook(store, "nb-c", title: "GDF15")
        try M.link(store, "nb-c", to: "nb-a")
        try F.sendAll(store)
        let heldEntry = try #require(try F.held(store, .entry, M.entry("nb-a", "src-1")))
        let followed = SyncIdentity.entryID(containerID: "nb-a", itemKind: "course", itemID: "course-1")
        let heldCourse = try #require(try F.held(store, .entry, followed))
        let heldPending = try #require(try F.held(store, .entry, M.entry("nb-a", "src-2")))

        let result = try M.merge(store, ["nb-a"], into: "nb-b")

        #expect(result.mergedGoalIDs == ["nb-a"])
        #expect(result.sourcesAdded == 2)
        #expect(result.chatsMoved == 1 && result.childGoalsMoved == 1 && result.tasksMoved == 1)
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_notebook_children WHERE notebook_id = 'nb-a'") == 0, "nothing is filed under the merged id")
        #expect(try F.text(store, "SELECT merged_into || '|' || fold_kind || '|' || status FROM learning_goals WHERE id = 'nb-a'") == "nb-b|merge|archived")
        #expect(try NotebookResolutionTable.resolve("nb-a", connection: store).id == "nb-b")
        #expect(try M.goalParent(store, "goal-a") == "nb-b")
        #expect(try F.text(store, "SELECT goal_id FROM review_sessions WHERE id = 'chat-a'") == "nb-b")
        #expect(try F.text(store, "SELECT goal_id FROM scheduled_source_goals WHERE scheduled_source_id = 'placement-1'") == "nb-b")
        #expect(try F.count(store, "SELECT COUNT(*) FROM notebook_related_notebook_links WHERE related_notebook_id = 'nb-a'") == 0)
        #expect(try F.count(store, "SELECT COUNT(*) FROM notebook_related_notebook_links WHERE notebook_id = 'nb-c' AND related_notebook_id = 'nb-b'") == 1)

        let pending = try F.pending(store)
        // The redirect is one save: status, mergedInto and foldKind together.
        let stub = try #require(F.savedFields(pending["Notebook:nb-a"]))
        #expect(stub["status"] == .string("merged") && stub["mergedInto"] == .string("nb-b") && stub["foldKind"] == .string("merge"))
        // A's Entries go; their twins in B carry A's values and stamps verbatim.
        #expect(pending["Entry:\(M.entry("nb-a", "src-1"))"]?.action == .delete)
        #expect(pending["Entry:\(M.entry("nb-a", "src-2"))"]?.action == .delete)
        let twin = try #require(M.savedEnvelope(pending["Entry:\(M.entry("nb-b", "src-1"))"]))
        for field in ["state", "approval", "origin"] {
            #expect(M.stamp(twin, field) == M.stamp(heldEntry, field), "\(field) copied verbatim")
        }
        // A followed course follows the survivor, its Entry's stamps copied too.
        #expect(pending["Entry:\(followed)"]?.action == .delete)
        let course = try #require(M.savedEnvelope(pending["Entry:\(SyncIdentity.entryID(containerID: "nb-b", itemKind: "course", itemID: "course-1"))"]))
        #expect(M.stamp(course, "state") == M.stamp(heldCourse, "state"))
        let pendingTwin = try #require(M.savedEnvelope(pending["Entry:\(M.entry("nb-b", "src-2"))"]))
        #expect(pendingTwin.fields["approval"] == .string("pending"))
        #expect(M.stamp(pendingTwin, "approval") == M.stamp(heldPending, "approval"))
        // Nothing sent names A but the redirect's own record and the deletions of its Entries.
        for (key, change) in pending where key != "Notebook:nb-a" {
            guard let fields = F.savedFields(change) else { continue }
            #expect(!fields.values.contains(.string("nb-a")), "\(key) still names the merged notebook")
        }

        // A device that had not seen the merge files a Goal under A: it lands in B.
        try F.apply(store, [try F.record(.goal, "goal-late", [
            "title": .string("Late"), "notebookID": .string("nb-a"), "status": .string("active"),
            "dueAt": SyncJSON(Int64(1_800_000_000_000)), "createdAt": SyncJSON(Int64(1_759_000_000_000)),
        ])])
        #expect(try M.goalParent(store, "goal-late") == "nb-a")
        try store.keepNotebookStubs()
        #expect(try M.goalParent(store, "goal-late") == "nb-b")
        #expect(F.savedFields(try F.pending(store)["Goal:goal-late"])?["notebookID"] == .string("nb-b"))
    }

    @Test("A late write to a merged notebook's Entry lands on the survivor's Entry, and a stale device's new Entry under the stub is twinned into it")
    func lateEntriesLandInTheSurvivor() async throws {
        let (root, store) = try F.makeStore("merge-late-entries")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-a", title: "Mitochondria")
        try F.addNotebook(store, "nb-b", title: "Mito Phenotyping")
        for source in ["src-1", "src-9"] { try F.addSource(store, source) }
        try F.file(store, "src-1", into: "nb-a")
        try F.sendAll(store)
        // The last complete pass saw the Entry, so the deletion is not the last word (§6.2).
        try store.execute("UPDATE ck_records SET seen_pass = 10 WHERE zone_key = ?", [.text(F.libraryZoneKey)])
        try store.execute("UPDATE ck_zones SET last_complete_pass_at = 5 WHERE zone_key = ?", [.text(F.libraryZoneKey)])

        // Offline, this Mac turns the source back into a suggestion; meanwhile another Mac merged A into B.
        try store.execute("UPDATE learning_goal_items SET review_state = 'pending' WHERE goal_id = 'nb-a' AND source_id = 'src-1'")
        try F.apply(store, [
            try M.stubRecord("nb-a", into: "nb-b"),
            try F.entryRecord("nb-b", "src-1", ms: 1_900_000_000_000),
        ])
        try await M.absorbDeletion(store, .entry, M.entry("nb-a", "src-1"))
        #expect(try M.reviewState(store, "nb-a", "src-1") == "pending", "the write waits for its new home")

        try store.keepNotebookStubs()
        #expect(try M.reviewState(store, "nb-a", "src-1") == nil)
        #expect(try M.reviewState(store, "nb-b", "src-1") == "pending", "the write landed on B's Entry")
        var pending = try F.pending(store)
        #expect(F.savedFields(pending["Entry:\(M.entry("nb-b", "src-1"))"])?["approval"] == .string("pending"))
        #expect(pending["Entry:\(M.entry("nb-a", "src-1"))"] == nil, "nothing is created again under the stub")

        // A stale device creates `en:A:src-9`: whoever applies it twins it into B, stamps verbatim.
        let late = try F.entryRecord("nb-a", "src-9", ms: 1_900_000_000_500, device: "staleaaa")
        try F.apply(store, [late])
        let lateEnvelope = try SyncEnvelope(storedPayload: late.payload)
        try store.keepNotebookStubs()
        #expect(try M.reviewState(store, "nb-b", "src-9") == "approved")
        pending = try F.pending(store)
        #expect(pending["Entry:\(M.entry("nb-a", "src-9"))"]?.action == .delete)
        let twin = try #require(M.savedEnvelope(pending["Entry:\(M.entry("nb-b", "src-9"))"]))
        #expect(M.stamp(twin, "state") == M.stamp(lateEnvelope, "state"))
        #expect(M.stamp(twin, "approval") == M.stamp(lateEnvelope, "approval"))
    }

    @Test("A merged notebook's sources arrive in the survivor ticked, and the survivor's own exclusions stand")
    func mergedSourcesArriveTicked() throws {
        let (root, store) = try F.makeStore("merge-ticks")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-a", title: "Mitochondria")
        try F.addNotebook(store, "nb-b", title: "Mito Phenotyping")
        for source in ["src-1", "src-2", "src-3", "src-4"] { try F.addSource(store, source) }
        try F.file(store, "src-1", into: "nb-a")
        try F.file(store, "src-2", into: "nb-a")
        try F.file(store, "src-3", into: "nb-b")
        try F.file(store, "src-4", into: "nb-b")
        try F.sendAll(store)
        try store.setNotebookChatExclusions(notebookID: "nb-a", excluded: ["src-1"])
        try store.setNotebookChatExclusions(notebookID: "nb-b", excluded: ["src-3"])
        try F.sendAll(store)
        let mergedRow = try NotebookStateRow.load("nb-a", connection: store)

        _ = try M.merge(store, ["nb-a"], into: "nb-b")

        #expect(try store.notebookStateSnapshot().excluded["nb-b"] == ["src-3"])
        #expect(try NotebookStateRow.load("nb-a", connection: store) == mergedRow, "the merged notebook's NotebookState is left as it is")
        #expect(try F.count(store, "SELECT COUNT(*) FROM learning_goal_items WHERE goal_id = 'nb-b'") == 4)
    }

    @Test("An item approved in the merged notebook and pending in the survivor ends approved, with the higher relevance; one removed in the survivor is active again")
    func mergeApprovalRule() throws {
        let (root, store) = try F.makeStore("merge-approval")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-a", title: "Mitochondria")
        try F.addNotebook(store, "nb-b", title: "Mito Phenotyping")
        for source in ["src-1", "src-2", "src-3"] { try F.addSource(store, source) }
        try F.file(store, "src-1", into: "nb-a")
        try store.execute("UPDATE learning_goal_items SET relevance = 0.9 WHERE goal_id = 'nb-a' AND source_id = 'src-1'")
        try F.file(store, "src-1", into: "nb-b", reviewState: "pending", origin: "discovered")
        try store.execute("UPDATE learning_goal_items SET relevance = 0.2 WHERE goal_id = 'nb-b' AND source_id = 'src-1'")
        try F.file(store, "src-2", into: "nb-a")
        try F.file(store, "src-2", into: "nb-b", reviewState: "rejected", origin: "discovered")
        try F.file(store, "src-3", into: "nb-a")
        try F.file(store, "src-3", into: "nb-b")
        try F.sendAll(store)
        // B's src-3 is removed, and the removal acknowledged.
        try store.execute("DELETE FROM learning_goal_items WHERE goal_id = 'nb-b' AND source_id = 'src-3'")
        try F.sendAll(store)
        let removed = try #require(try F.held(store, .entry, M.entry("nb-b", "src-3")))
        #expect(removed.fields["state"] == .string("removed"))
        let keyBefore = try F.text(store, "SELECT order_key FROM learning_goal_items WHERE goal_id = 'nb-b' AND source_id = 'src-1'")

        _ = try M.merge(store, ["nb-a"], into: "nb-b")

        #expect(try M.reviewState(store, "nb-b", "src-1") == "approved")
        #expect(try M.reviewState(store, "nb-b", "src-2") == "approved")
        #expect(try F.text(store, "SELECT relevance FROM learning_goal_items WHERE goal_id = 'nb-b' AND source_id = 'src-1'") == "0.9")
        #expect(try F.text(store, "SELECT order_key FROM learning_goal_items WHERE goal_id = 'nb-b' AND source_id = 'src-1'") == keyBefore, "B's order stands")
        let pending = try F.pending(store)
        let approved = try #require(F.savedFields(pending["Entry:\(M.entry("nb-b", "src-1"))"]))
        #expect(approved["approval"] == .string("approved"))
        // Active again, with a stamp of its own that passes the removal's.
        let back = try #require(M.savedEnvelope(pending["Entry:\(M.entry("nb-b", "src-3"))"]))
        #expect(back.fields["state"] == .string("active"))
        let removedStamp = try #require(M.stamp(removed, "state").flatMap(SyncStamp.init))
        let backStamp = try #require(M.stamp(back, "state").flatMap(SyncStamp.init))
        #expect(backStamp.isLater(than: removedStamp))
    }

    @Test("Of two folds of one notebook the first acknowledged stands, nothing the second moved is lost, and the learner is told")
    func firstFoldStands() async throws {
        let (root, store) = try F.makeStore("merge-race")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-a", title: "Mitochondria")
        try F.addNotebook(store, "nb-b", title: "Mito Phenotyping")
        try F.addNotebook(store, "nb-c", title: "Bioenergetics")
        try F.addSource(store, "src-1")
        try F.file(store, "src-1", into: "nb-a")
        try M.addChat(store, "chat-a", in: "nb-a")
        try F.sendAll(store)

        // This Mac folds A into C; another Mac folded A into B first, and the server has its redirect.
        _ = try M.merge(store, ["nb-a"], into: "nb-c")
        try await M.absorb(store, try M.stubRecord("nb-a", into: "nb-b"))

        #expect(try F.text(store, "SELECT merged_into FROM learning_goals WHERE id = 'nb-a'") == "nb-b")
        #expect(try NotebookResolutionTable.resolve("nb-a", connection: store).id == "nb-b")
        #expect(try M.reviewState(store, "nb-c", "src-1") == "approved", "what this Mac moved stays in C")
        #expect(try F.text(store, "SELECT goal_id FROM review_sessions WHERE id = 'chat-a'") == "nb-c")
        let notices = try store.keepNotebookStubs()
        #expect(notices.count == 1)
        #expect(notices.first?.contains("Mitochondria") == true && notices.first?.contains("Mito Phenotyping") == true
            && notices.first?.contains("Bioenergetics") == true)
        #expect(try store.keepNotebookStubs().isEmpty, "told once")
    }

    @Test("An emptying split keeps the parent's notes, Instructions, research questions, summary, repository, ticks and collections on the heir")
    func emptyingSplitKeepsEverythingOnTheHeir() throws {
        let (root, store) = try F.makeStore("split-heir")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-p", title: "Mitochondria")
        try F.addNotebook(store, "nb-x", title: "GDF15")
        for source in ["src-a", "src-b", "src-c", "src-x"] { try F.addSource(store, source) }
        for source in ["src-a", "src-b", "src-c"] { try F.file(store, source, into: "nb-p") }
        try F.file(store, "src-x", into: "nb-x")
        try M.link(store, "nb-p", to: "nb-x")
        try M.addChat(store, "chat-p", in: "nb-p")
        try M.setWords(store, "nb-p", notes: "Supercomplexes look tissue-specific.", instructions: "Answer from primary papers only.",
                       summary: "Respiratory chain structure", repository: "example/mito-notes", questions: ["Do supercomplexes raise OXPHOS flux?"])
        try F.sendAll(store)
        try store.setNotebookChatExclusions(notebookID: "nb-p", excluded: ["src-b"])
        try store.setNotebookContextNotebooks(notebookID: "nb-p", contextNotebookIDs: ["nb-x"])
        try store.setNotebookCollections(notebookID: "nb-p", collectionIDs: ["nbc-1"])
        try F.sendAll(store)

        let result = try M.split(store, "nb-p", [("OXPHOS", ["src-a"]), ("Biogenesis", ["src-b", "src-c"])])

        #expect(result.parentGoalID == nil)
        let heir = try #require(result.heirGoalID)
        #expect(heir == result.childGoalIDs[1], "Biogenesis took two sources")
        #expect(try F.text(store, "SELECT merged_into || '|' || fold_kind FROM learning_goals WHERE id = 'nb-p'") == "\(heir)|split")
        #expect(try F.text(store, "SELECT goal_id FROM review_sessions WHERE id = 'chat-p'") == heir)
        let words = try #require(try NotebookWords.load(heir, connection: store))
        #expect(words.title == "Biogenesis")
        #expect(words.notes == "## Mitochondria\n\nSupercomplexes look tissue-specific.")
        #expect(words.instructions == "Answer from primary papers only.")
        #expect(words.summary == "Respiratory chain structure")
        #expect(words.repository == "example/mito-notes")
        #expect(words.researchQuestions == ["Do supercomplexes raise OXPHOS flux?"])
        #expect(try F.count(store, "SELECT COUNT(*) FROM notebook_related_notebook_links WHERE notebook_id = ? AND related_notebook_id = 'nb-x'", [.text(heir)]) == 1)
        // The member's sets went to the heir, the untick still naming what it named.
        let snapshot = try store.notebookStateSnapshot()
        #expect(snapshot.excluded[heir] == ["src-b"])
        #expect(snapshot.contextNotebooks[heir] == ["nb-x"])
        #expect(snapshot.collections[heir] == ["nbc-1"])
        // The parent's Entries are deleted, never left removed under the stub.
        let pending = try F.pending(store)
        for source in ["src-a", "src-b", "src-c"] { #expect(pending["Entry:\(M.entry("nb-p", source))"]?.action == .delete) }
        let notebook = try #require(F.savedFields(pending["Notebook:\(heir)"]))
        #expect(notebook["instructions"] == .string("Answer from primary papers only."))
    }

    @Test("A late child of a split parent resolves to the heir")
    func lateChildOfSplitParent() throws {
        let (root, store) = try F.makeStore("split-late-child")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-p", title: "Mitochondria")
        for source in ["src-a", "src-b"] { try F.addSource(store, source); try F.file(store, source, into: "nb-p") }
        try F.sendAll(store)
        let result = try M.split(store, "nb-p", [("OXPHOS", ["src-a"]), ("Biogenesis", ["src-b"])])
        let heir = try #require(result.heirGoalID)
        #expect(heir == result.childGoalIDs[0], "of equals, the first listed")
        #expect(try NotebookResolutionTable.resolve("nb-p", connection: store).id == heir)

        try F.apply(store, [try F.record(.goal, "goal-late", [
            "title": .string("Late"), "notebookID": .string("nb-p"), "status": .string("active"),
            "dueAt": SyncJSON(Int64(1_800_000_000_000)), "createdAt": SyncJSON(Int64(1_759_000_000_000)),
        ])])
        try store.keepNotebookStubs()
        #expect(try M.goalParent(store, "goal-late") == heir)
    }

    @Test("A late rename of a merged notebook never renames the survivor, while a late Instructions edit still fills a blank one")
    func lateRenameNeverRenamesTheSurvivor() throws {
        let (root, store) = try F.makeStore("merge-late-rename")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-a", title: "Mitochondria")
        try F.addNotebook(store, "nb-b", title: "Mito Phenotyping")
        try M.setWords(store, "nb-a", instructions: nil)
        try M.setWords(store, "nb-b", instructions: nil)
        try F.sendAll(store)
        _ = try M.merge(store, ["nb-a"], into: "nb-b")
        try F.sendAll(store)

        // A device that had not seen the merge renames A and gives it Instructions.
        try F.apply(store, [try M.stubRecord("nb-a", into: "nb-b", title: "Renamed late", extra: [
            "instructions": .string("Use primary sources"),
        ], ms: 1_950_000_000_000, device: "staleaaa")])
        try store.keepNotebookStubs()

        #expect(try F.text(store, "SELECT title FROM learning_goals WHERE id = 'nb-b'") == "Mito Phenotyping")
        #expect(try F.text(store, "SELECT description FROM learning_goals WHERE id = 'nb-b'") == "Use primary sources")
        #expect(try F.text(store, "SELECT title FROM learning_goals WHERE id = 'nb-a'") == "Renamed late", "the stub keeps its own fields")
        let survivorChange = try #require(try F.pending(store)["Notebook:nb-b"])
        #expect(survivorChange.stamps[StampedPath("instructions")] != nil)
        #expect(survivorChange.stamps[StampedPath("title")] == nil, "B's title is not written")
        // Forwarded once: clearing B's Instructions afterwards is not undone by the next pass.
        try store.execute("UPDATE learning_goals SET description = NULL WHERE id = 'nb-b'")
        try store.keepNotebookStubs()
        #expect(try F.text(store, "SELECT description FROM learning_goals WHERE id = 'nb-b'") == nil)
    }

    @Test("An emptied Goal, which has no redirect, goes as it does today once its sources moved; a stub is never merged or split again")
    func emptiedGoalGoes() throws {
        let (root, store) = try F.makeStore("split-goal")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-x", title: "Mitochondria")
        try F.addGoal(store, "goal-p", parent: "nb-x")
        for source in ["src-a", "src-b"] { try F.addSource(store, source); try F.file(store, source, into: "goal-p") }
        try F.sendAll(store)

        let result = try M.split(store, "goal-p", [("Week one", ["src-a", "src-b"])])

        let heir = try #require(result.heirGoalID)
        #expect(try F.count(store, "SELECT COUNT(*) FROM learning_goals WHERE id = 'goal-p'") == 0)
        #expect(try F.text(store, "SELECT entity_kind || '|' || parent_notebook_id FROM learning_goals WHERE id = ?", [.text(heir)]) == "goal|nb-x")
        let pending = try F.pending(store)
        #expect(pending["Goal:goal-p"]?.action == .delete)
        #expect(pending["Entry:\(M.entry("goal-p", "src-a"))"]?.action == .delete)
        #expect(F.savedFields(pending["Entry:\(M.entry(heir, "src-a"))"])?["containerKind"] == .string("goal"))

        try F.addNotebook(store, "nb-y", title: "GDF15")
        _ = try M.merge(store, ["nb-y"], into: "nb-x")
        #expect(throws: KnowledgeStoreError.self) { try M.merge(store, ["nb-x"], into: "nb-y") }
        #expect(throws: KnowledgeStoreError.self) { try M.split(store, "nb-y", [("Part", [])]) }
    }

    @Test("A split keeps the zone: a personal notebook's children are in Library, a team's in the team's zone")
    func splitKeepsTheZone() throws {
        let (root, store) = try F.makeStore("split-zone")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-p", title: "Mitochondria")
        for source in ["src-a", "src-b", "src-c", "src-d"] { try F.addSource(store, source) }
        for source in ["src-a", "src-b"] { try F.file(store, source, into: "nb-p") }
        try F.sendAll(store)
        try F.addNotebook(store, "nb-t", title: "Nexus reading")
        for source in ["src-c", "src-d"] { try F.file(store, source, into: "nb-t") }
        try store.execute("UPDATE learning_goals SET team_id = 'team-1' WHERE id = 'nb-t'")
        try store.execute("INSERT INTO ck_identity (zone_key, record_type, wire_id, local_id) VALUES ('private/Space-team-1', 'Notebook', 'nb-t', 'nb-t')")

        let personal = try M.split(store, "nb-p", [("OXPHOS", ["src-a"])], keepParent: true)
        let team = try M.split(store, "nb-t", [("Complex I", ["src-c"])], keepParent: true)

        let child = try #require(personal.childGoalIDs.first)
        #expect(try F.pending(store)["Notebook:\(child)"]?.zoneKey == F.libraryZoneKey)
        let teamChild = try #require(team.childGoalIDs.first)
        #expect(try F.text(store, "SELECT zone_key FROM ck_identity WHERE local_id = ?", [.text(teamChild)]) == "private/Space-team-1")
        #expect(try F.text(store, "SELECT team_id FROM learning_goals WHERE id = ?", [.text(teamChild)]) == "team-1")
        // A kept parent is no stub, and its Entry of a source a child took is removed, not deleted.
        #expect(try F.text(store, "SELECT COALESCE(merged_into, '') FROM learning_goals WHERE id = 'nb-p'") == "")
        try F.sendAll(store)
        let removed = try #require(try F.held(store, .entry, M.entry("nb-p", "src-a")))
        #expect(removed.fields["state"] == .string("removed"))
    }
}
