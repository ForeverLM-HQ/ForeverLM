import Foundation
import Testing
@testable import ForeverLM

/// The import pass's decisions (docs/cloudkit-schema-design.md §13.6, WP16b): what an old record gives is
/// applied field by field, created whole, waited for or removed, as a pure function of the base and the
/// world. The same cases also run standalone over the real sources, with negative controls.
@Suite("Migration import planner")
struct MigrationImportPlannerTests {

    @Test("Field by field")
    func fieldByField() throws {
        let before = mpRecord(.notebook, "nb1", ["title": "Old", "instructions": "same"], .owns)
        let after = mpRecord(.notebook, "nb1", ["title": "New", "instructions": "same"], .owns)
        var world = MigrationWorldSnapshot()
        world.records[mpKey(.notebook, "nb1")] = mpHeld(.notebook, "nb1", ["title": "Old", "instructions": "same"])
        let result = mpPlan([MigrationOldRecordInput(old: mpOld("lg1", [after]), base: mpBase([before]))], world)
        #expect(result.writes.count == 1 && !result.writes[0].creates, "a changed field is one patch")
        #expect(result.writes[0].changes == ["title": .value("New")], "only the field whose hash differs is applied")
        let stamp = result.writes[0].stamps[StampedPath("title")]
        #expect(stamp == mpStamp(.lastWriter, 5_000), "stamped with the old record's modification date, letter L, device legacy22")
        #expect(result.olds[0].nextEntry?.records["Notebook:nb1"]?.hashes["title"] == mpHash("New"), "the base advances to the new hash")
        #expect(result.olds[0].nextEntry?.changeTag == "tag-5000", "and to the new change tag")

        // a later new-world edit always wins
        var later = world
        later.records[mpKey(.notebook, "nb1")] = mpHeld(.notebook, "nb1", ["title": "Mine", "instructions": "same"], ms: 9_000, device: mpDevice)
        let kept = mpPlan([MigrationOldRecordInput(old: mpOld("lg1", [after]), base: mpBase([before]))], later)
        #expect(kept.writes.isEmpty, "a field whose held stamp is later is skipped")
        // an earlier new-world value loses to the old world's later change
        var earlier = world
        earlier.records[mpKey(.notebook, "nb1")] = mpHeld(.notebook, "nb1", ["title": "Mine", "instructions": "same"], ms: 2_000, device: mpDevice)
        #expect(mpPlan([MigrationOldRecordInput(old: mpOld("lg1", [after]), base: mpBase([before]))], earlier).writes.count == 1, "an older new-world stamp is overtaken")
        // the same value is dropped
        var same = world
        same.records[mpKey(.notebook, "nb1")] = mpHeld(.notebook, "nb1", ["title": "New", "instructions": "same"], ms: 1_000)
        #expect(mpPlan([MigrationOldRecordInput(old: mpOld("lg1", [after]), base: mpBase([before]))], same).writes.isEmpty, "a value the record already holds writes nothing")
        // unchanged hashes: nothing
        #expect(mpPlan([MigrationOldRecordInput(old: mpOld("lg1", [before]), base: mpBase([before]))], world).writes.isEmpty, "an unchanged record writes nothing")
        // no base entry: every field is changed
        #expect(mpPlan([MigrationOldRecordInput(old: mpOld("lg1", [after]), base: nil)], world).writes[0].changes.keys.contains("title"), "no base entry, the field is applied")
    }

    @Test("A clears record is in the base, so a later write of the old record with the same state does not wipe what the new world set (F2)")
    func clearsRecordsAreInTheBase() throws {
        // An old Source that was never read gives a clears for the read state: readAt null.
        let cleared = mpRecord(.readingState, "rs:src-r", ["targetKind": "source", "targetID": "src-r", "readAt": SyncJSON.null], .clears)
        var world = MigrationWorldSnapshot()
        // The learner marked the source read on this build, after the seed.
        world.records[mpKey(.readingState, "rs:src-r")] = mpHeld(.readingState, "rs:src-r", ["targetKind": "source", "targetID": "src-r", "readAt": 1_759_000_000_000], ms: 1_000, device: mpDevice)
        let first = mpPlan([MigrationOldRecordInput(old: mpOld("src-r", [cleared], entity: .source), base: nil)], world)
        #expect(first.olds[0].nextEntry?.records["ReadingState:rs:src-r"] == MigrationBaseRecord(owned: false, hashes: LegacyFieldHashes.hashes(cleared)),
                "a clears record is listed, never owned")
        // An old iPhone writes the Source again (a reading position) with the same state: nothing is written.
        let again = mpPlan([MigrationOldRecordInput(old: mpOld("src-r", [cleared], entity: .source), base: first.olds[0].nextEntry)], world)
        #expect(again.writes.isEmpty, "the clears record's hash equals the base's, so the read mark stands: \(again.writes)")
    }

    @Test("A change for a space this Mac may not write is not queued: the old record waits with the base's hashes (F3)")
    func readOnlySpaceWaits() throws {
        let before = mpRecord(.notebook, "nb-t", ["title": "Old"], .owns, space: "team-1")
        let after = mpRecord(.notebook, "nb-t", ["title": "New"], .owns, space: "team-1")
        var world = MigrationWorldSnapshot()
        world.records[mpKey(.notebook, "nb-t", space: "team-1")] = mpHeld(.notebook, "nb-t", ["title": "Old"])
        let input = MigrationOldRecordInput(old: mpOld("lg-t", [after], zone: "Team-team-1", space: "team-1"), base: mpBase([before]))
        let readOnly = mpPlan([input], world)
        #expect(readOnly.writes.isEmpty && readOnly.olds[0].waiting, "the change waits: \(readOnly.writes)")
        #expect(readOnly.olds[0].nextEntry?.records["Notebook:nb-t"]?.hashes["title"] == mpHash("Old"), "so the base does not move past it")
        world.spaces.insert("team-1")
        #expect(mpPlan([input], world).writes.count == 1, "and lands once the space is writable")
    }

    @Test("A deleted collections, context or focus row takes what its base listed out of the member's records, and makes none (F8)")
    func deletedPreferenceRowEmptiesItsField() throws {
        var row = NotebookStateRow(notebookID: "nb1")
        row.collections = ["c1", "c2"]
        let given = LegacyV2Mapping.notebookState(row, giving: "collections")
        let base = mpBase([given, LegacyV2Mapping.enrollmentFocus(courseID: "crs1", focus: "Why")])
        var gone = mpOld("pref-1", [], entity: .preference, deleted: true)
        gone.deletionRecords = LegacyV2Mapping.deletionRecords(base: base)
        #expect(gone.deletionRecords.map(\.key).sorted() == ["Enrollment:enr:crs1", "NotebookState:ns:nb1"])

        var world = MigrationWorldSnapshot()
        world.records[mpKey(.notebookState, "ns:nb1")] = mpHeld(.notebookState, "ns:nb1", ["notebookID": "nb1", "collections": ["c1": true, "c2": true, "c3": true]])
        world.records[mpKey(.enrollment, "enr:crs1")] = mpHeld(.enrollment, "enr:crs1", ["courseID": "crs1", "focus": "Why", "status": "enrolled"])
        let plan = mpPlan([MigrationOldRecordInput(old: gone, base: base)], world)
        let states = plan.writes.first { $0.key == mpKey(.notebookState, "ns:nb1") }
        #expect(states?.changes["collections"] == .elements(["c1": .bool(false), "c2": .bool(false)]), "the ids the row listed leave; one the new world added stays")
        #expect(plan.writes.first { $0.key == mpKey(.enrollment, "enr:crs1") }?.changes["focus"] == .value(.null), "a deleted focus row clears the focus")
        #expect(plan.kept.isEmpty, "none of it is logged as kept, not owned: \(plan.kept)")

        // Nothing is made of a record the new world no longer has.
        let empty = mpPlan([MigrationOldRecordInput(old: gone, base: base)], MigrationWorldSnapshot())
        #expect(empty.writes.isEmpty && empty.creates.isEmpty)
    }

    @Test("Server-first fields")
    func serverFirstFields() throws {
        let before = mpRecord(.exchange, "ex1", ["chatID": "c1", "question": "Q1"], .owns)
        let after = mpRecord(.exchange, "ex1", ["chatID": "c1", "question": "Q2"], .owns)
        var world = MigrationWorldSnapshot()
        world.records[mpKey(.chat, "c1")] = mpHeld(.chat, "c1", ["title": "T"])
        world.records[mpKey(.exchange, "ex1")] = mpHeld(.exchange, "ex1", ["chatID": "c1", "question": "Q1"], ms: 100, device: mpDevice)
        #expect(mpPlan([MigrationOldRecordInput(old: mpOld("rs1", [after], entity: .reviewSession), base: mpBase([before]))], world).writes.isEmpty, "a first write stands for a server-first field")
        world.records[mpKey(.exchange, "ex1")] = mpHeld(.exchange, "ex1", ["chatID": "c1", "question": "Q1"], ms: 1, device: mpDevice)
        #expect(mpPlan([MigrationOldRecordInput(old: mpOld("rs1", [after], entity: .reviewSession), base: mpBase([before]))], world).writes.count == 1, "a provisional first write is overtaken")
    }

    @Test("Creation")
    func creation() throws {
        let exchange = mpRecord(.exchange, "ex2", ["chatID": "c1", "question": "Q", "seq": 3], .owns)
        var world = MigrationWorldSnapshot()
        world.records[mpKey(.chat, "c1")] = mpHeld(.chat, "c1", ["title": "T"])
        let created = mpPlan([MigrationOldRecordInput(old: mpOld("rs1", [exchange], entity: .reviewSession), base: mpBase([]))], world)
        #expect(created.writes.count == 1 && created.writes[0].creates, "a turn appended to a seeded chat is created")
        #expect(created.writes[0].changes.keys.sorted() == ["chatID", "question", "seq"], "created whole, every field")
        #expect(created.writes[0].stamps[StampedPath("question")] == mpStamp(.serverFirst, 5_000), "with the schema's letter")
        #expect(created.creates == [mpKey(.exchange, "ex2")], "the pass lists what it created")
        #expect(created.olds[0].nextEntry?.records["Exchange:ex2"]?.owned == true, "and the base owns it from mpNow")

        var listed = world
        listed.listed.insert(mpKey(.exchange, "ex2"))
        let skipped = mpPlan([MigrationOldRecordInput(old: mpOld("rs1", [exchange], entity: .reviewSession), base: mpBase([]))], listed)
        #expect(skipped.writes.isEmpty && skipped.skipped.map(\.reason) == [.deletedInNewWorld], "a record deleted in the new world is not created again")

        var chatGone = MigrationWorldSnapshot()
        chatGone.listed.insert(mpKey(.chat, "c1"))
        let orphan = mpPlan([MigrationOldRecordInput(old: mpOld("rs1", [exchange], entity: .reviewSession), base: mpBase([]))], chatGone)
        #expect(orphan.writes.isEmpty && orphan.skipped.map(\.reason) == [.parentDeletedInNewWorld], "an exchange appended to a chat deleted in the new world is skipped")

        // an Entry hangs from its container by kind
        let entry = mpRecord(.entry, "en:nb1:source:s1", ["containerKind": "notebook", "containerID": "nb1", "itemKind": "source", "itemID": "s1", "state": "active"], .owns)
        var notebookGone = MigrationWorldSnapshot()
        notebookGone.listed.insert(mpKey(.notebook, "nb1"))
        #expect(mpPlan([MigrationOldRecordInput(old: mpOld("lg1", [entry]), base: mpBase([]))], notebookGone).skipped.map(\.reason) == [.parentDeletedInNewWorld], "an Entry of a deleted notebook is skipped")
        var notebookHere = MigrationWorldSnapshot()
        notebookHere.records[mpKey(.notebook, "nb1")] = mpHeld(.notebook, "nb1", ["title": "T"])
        #expect(mpPlan([MigrationOldRecordInput(old: mpOld("lg1", [entry]), base: mpBase([]))], notebookHere).creates == [mpKey(.entry, "en:nb1:source:s1")], "a source filed into a seeded notebook is created")
        // a notebook the pass creates is there for its own Entries
        let notebook = mpRecord(.notebook, "nb2", ["title": "N"], .owns)
        let entry2 = mpRecord(.entry, "en:nb2:source:s1", ["containerKind": "notebook", "containerID": "nb2", "itemKind": "source", "itemID": "s1", "state": "active"], .owns)
        var deleted = MigrationWorldSnapshot()
        deleted.listed.insert(mpKey(.entry, "en:nb2:source:s1"))
        let both = mpPlan([MigrationOldRecordInput(old: mpOld("lg2", [notebook, entry2]), base: nil)], MigrationWorldSnapshot())
        #expect(both.writes.count == 2 && both.writes.allSatisfy(\.creates), "a notebook and its entry are created together")
    }

    @Test("Waiting")
    func waiting() throws {
        // a meeting series' attachments feed a Source that does not exist yet
        let feed = mpRecord(.source, "src-m1", ["meta": ["attachments": ["k": "v"]]], .feeds)
        let input = MigrationOldRecordInput(old: mpOld("mg1", [feed], entity: .meetingGroup), base: mpBase([]))
        let waits = mpPlan([input], MigrationWorldSnapshot())
        #expect(waits.writes.isEmpty && waits.olds[0].waiting && waits.olds[0].waitingKeys == ["Source:src-m1"], "a feed for a record that does not exist waits")
        #expect(waits.olds[0].nextEntry?.records["Source:src-m1"] == nil && waits.olds[0].nextEntry?.waiting == true, "its hashes stay out of the base so every pass maps it again")
        var arrived = MigrationWorldSnapshot()
        arrived.records[mpKey(.source, "src-m1")] = mpHeld(.source, "src-m1", ["title": "S"], ms: 10)
        let lands = mpPlan([input], arrived)
        #expect(lands.writes.count == 1 && lands.olds[0].waiting == false, "the value lands once the record exists")
        // a record created in the same pass receives the values other old records feed into it
        let source = mpRecord(.source, "src-m1", ["title": "Session", "type": "meeting"], .owns)
        let samePass = mpPlan([input, MigrationOldRecordInput(old: mpOld("src-m1-old", [source], entity: .source), base: nil)], MigrationWorldSnapshot())
        #expect(samePass.writes.count == 1 && samePass.writes[0].creates && samePass.writes[0].changes.keys.contains("meta") && samePass.writes[0].changes.keys.contains("title"),
               "owned records are applied before the values others feed into them, folded into one write")
        #expect(samePass.olds[0].waiting == false, "so nothing waits")
        // thirty days
        let long = mpPlan([input], MigrationWorldSnapshot(), mpOptions(waiting: ["Knowledge/mg1": mpNow.addingTimeInterval(-31 * 86_400)]))
        #expect(long.olds[0].waiting == false && long.notApplied.map(\.reason) == [.waitedTooLong], "a value dropped after 30 days is listed as Not applied")
        let short = mpPlan([input], MigrationWorldSnapshot(), mpOptions(waiting: ["Knowledge/mg1": mpNow.addingTimeInterval(-29 * 86_400)]))
        #expect(short.olds[0].waiting && short.notApplied.isEmpty, "and not before")
        // a feed for a record the new world deleted is skipped, not waited for
        var gone = MigrationWorldSnapshot()
        gone.listed.insert(mpKey(.source, "src-m1"))
        let skip = mpPlan([input], gone)
        #expect(skip.olds[0].waiting == false && skip.skipped.map(\.reason) == [.deletedInNewWorld], "the delete wins over a waiting feed")
        // a clears record never creates and never waits
        let clear = mpRecord(.mark, "mk:hidden:src-x", ["on": false], .clears)
        let none = mpPlan([MigrationOldRecordInput(old: mpOld("hs1", [clear], entity: .hiddenSource), base: nil)], MigrationWorldSnapshot())
        #expect(none.writes.isEmpty && none.olds[0].waiting == false, "a default state creates nothing and waits for nothing")
        // a Team zone whose space is not here waits
        let team = mpRecord(.notebook, "nb-t", ["title": "T"], .owns, space: "team-1")
        let noSpace = mpPlan([MigrationOldRecordInput(old: mpOld("lg-t", [team], zone: "Team-team-1", space: "team-1"), base: nil)], MigrationWorldSnapshot())
        #expect(noSpace.writes.isEmpty && noSpace.olds[0].waiting, "a record of a Team whose space is not on this Mac waits")
        var withSpace = MigrationWorldSnapshot()
        withSpace.spaces.insert("team-1")
        #expect(mpPlan([MigrationOldRecordInput(old: mpOld("lg-t", [team], zone: "Team-team-1", space: "team-1"), base: nil)], withSpace).creates == [mpKey(.notebook, "nb-t", space: "team-1")], "and is created in the space once it is")
    }

    @Test("Creates once")
    func createsOnce() throws {
        let deck = mpRecord(.collection, "col_x", ["kind": "playlist", "externalKey": "pl", "title": "A"], .createsOnly)
        var world = MigrationWorldSnapshot()
        #expect(mpPlan([MigrationOldRecordInput(old: mpOld("s1", [deck], entity: .source), base: nil)], world).creates == [mpKey(.collection, "col_x")], "a playlist's collection is created from the group id")
        world.records[mpKey(.collection, "col_x")] = mpHeld(.collection, "col_x", ["kind": "playlist", "externalKey": "pl", "title": "Mine"], ms: 10)
        let renamed = mpRecord(.collection, "col_x", ["kind": "playlist", "externalKey": "pl", "title": "B"], .createsOnly)
        #expect(mpPlan([MigrationOldRecordInput(old: mpOld("s1", [renamed], entity: .source), base: mpBase([deck]))], world).writes.isEmpty, "once it exists a Source changes nothing on it")
    }

    @Test("Removal")
    func removal() throws {
        let entry = mpRecord(.entry, "en:nb1:source:s1", ["containerKind": "notebook", "containerID": "nb1", "itemKind": "source", "itemID": "s1", "state": "active"], .owns)
        let notebook = mpRecord(.notebook, "nb1", ["title": "N"], .owns)
        var world = MigrationWorldSnapshot()
        world.records[mpKey(.notebook, "nb1")] = mpHeld(.notebook, "nb1", ["title": "N"])
        world.records[mpKey(.entry, "en:nb1:source:s1")] = mpHeld(.entry, "en:nb1:source:s1", ["state": "active"])
        let input = MigrationOldRecordInput(old: mpOld("lg1", [notebook]), base: mpBase([notebook, entry]))
        let removed = mpPlan([input], world)
        #expect(removed.removals == 1 && removed.deletions.isEmpty, "a source taken out of a notebook is one removal")
        #expect(removed.writes.count == 1 && removed.writes[0].changes["state"] == .value("removed"), "an Entry flips its state")
        #expect(removed.writes[0].stamps[StampedPath("state")] == mpStamp(.lastWriter, 5_000), "stamped with the old record's date")
        #expect(removed.olds[0].nextEntry?.records["Entry:en:nb1:source:s1"] == nil, "and leaves the base")

        // an edit the new world made after T0 is kept
        var edited = world
        edited.records[mpKey(.entry, "en:nb1:source:s1")] = mpHeld(.entry, "en:nb1:source:s1", ["state": "active"], ms: 50_000, device: mpDevice)
        let kept = mpPlan([input], edited, mpOptions(since: 10_000))
        #expect(kept.removals == 0 && kept.kept.map(\.reason) == [.editedInNewWorld] && kept.writes.isEmpty, "a record edited in the new world after T0 is kept and logged")
        // a stamp from before T0 is not an edit
        let before = mpPlan([input], edited, mpOptions(since: 90_000))
        #expect(before.removals == 1, "a stamp from before the new world began is not an edit")
        // the learner answered Keep
        let keep = mpPlan([input], world, mpOptions(keep: true))
        #expect(keep.removals == 0 && keep.kept.map(\.reason) == [.keptByAnswer] && keep.olds[0].nextEntry?.records["Entry:en:nb1:source:s1"] == nil, "Keep lists the removal and advances the base past it")
        // an omitted key says nothing
        var silent = LegacyMapping(entity: .learningGoal, logicalKey: "lg1", records: [notebook])
        silent.silentChildren = [LegacyChildScope(type: .entry, itemKind: "source")]
        var quiet = mpOld("lg1", [notebook])
        quiet.mapping = silent
        let none = mpPlan([MigrationOldRecordInput(old: quiet, base: mpBase([notebook, entry]))], world)
        #expect(none.removals == 0 && none.writes.isEmpty && none.olds[0].nextEntry?.records["Entry:en:nb1:source:s1"] != nil, "an omitted key removes nothing and the base keeps the child")
        // a Placement flips, a Setting clears
        let placement = mpRecord(.placement, "pl:s1", ["sourceID": "s1", "state": "active"], .owns)
        var pworld = MigrationWorldSnapshot()
        pworld.records[mpKey(.placement, "pl:s1")] = mpHeld(.placement, "pl:s1", ["state": "active"])
        let flipped = mpPlan([MigrationOldRecordInput(old: mpOld("ss1", [], entity: .scheduledSource, deleted: true), base: mpBase([placement]))], pworld)
        #expect(flipped.writes.first?.changes["state"] == .value("removed"), "a deleted scheduled source flips its Placement")
        let setting = mpRecord(.setting, "notebookCollection.nbc-1", ["value": "Name"], .owns)
        var sworld = MigrationWorldSnapshot()
        sworld.records[mpKey(.setting, "notebookCollection.nbc-1")] = mpHeld(.setting, "notebookCollection.nbc-1", ["value": "Name"])
        let cleared = mpPlan([MigrationOldRecordInput(old: mpOld("pf1", [], entity: .preference, deleted: true), base: mpBase([setting]))], sworld)
        #expect(cleared.writes.first?.changes["value"] == .value(.null), "a deleted preference clears its Setting's value")

        // a deleted old record: owned records go by type, per-member state and history stay
        let source = mpRecord(.source, "s9", ["title": "S"], .owns)
        let reading = mpRecord(.readingState, "rs:s9", ["targetKind": "source", "targetID": "s9"], .creates)
        let highlight = mpRecord(.highlight, "hl1", ["sourceID": "s9"], .creates)
        let card = mpRecord(.card, "card1", ["status": "kept"], .owns)
        var dworld = MigrationWorldSnapshot()
        dworld.records[mpKey(.source, "s9")] = mpHeld(.source, "s9", ["title": "S"])
        dworld.records[mpKey(.readingState, "rs:s9")] = mpHeld(.readingState, "rs:s9", ["targetKind": "source"])
        let gone = mpPlan([MigrationOldRecordInput(old: mpOld("s9", [], entity: .source, deleted: true), base: mpBase([source, reading, highlight]))], dworld)
        #expect(gone.deletions == [MigrationRemoval(key: mpKey(.source, "s9"), deletes: true)], "an old-world Source deletion deletes the Source")
        #expect(Set(gone.kept.map(\.type)) == ["ReadingState", "Highlight"] && Set(gone.kept.map(\.reason)) == [.notOwned], "and keeps its ReadingState and Highlights, listed")
        #expect(gone.olds[0].nextEntry == nil, "the old record leaves the base")
        var cworld = MigrationWorldSnapshot()
        cworld.records[mpKey(.card, "card1")] = mpHeld(.card, "card1", ["status": "kept"])
        let memory = mpPlan([MigrationOldRecordInput(old: mpOld("mi1", [], entity: .memoryItem, deleted: true), base: mpBase([card]))], cworld)
        #expect(memory.deletions.isEmpty && memory.kept.map(\.reason) == [.neverRemoved], "a deleted memory item keeps its Card, listed")
        // already gone: nothing
        #expect(mpPlan([MigrationOldRecordInput(old: mpOld("s9", [], entity: .source, deleted: true), base: mpBase([source]))], MigrationWorldSnapshot()).removals == 0, "a record already gone is no removal")
    }

    @Test("Set elements")
    func setElements() throws {
        let before = mpRecord(.notebookState, "ns:nb1", ["notebookID": "nb1", "collections": ["a": true, "b": true]], .creates, whole: ["collections"])
        let after = mpRecord(.notebookState, "ns:nb1", ["notebookID": "nb1", "collections": ["a": true]], .creates, whole: ["collections"])
        var world = MigrationWorldSnapshot()
        world.records[mpKey(.notebookState, "ns:nb1")] = mpHeld(.notebookState, "ns:nb1", ["notebookID": "nb1", "collections": ["a": true, "b": true, "mine": true]], ms: 10)
        let result = mpPlan([MigrationOldRecordInput(old: mpOld("pf", [after], entity: .preference), base: mpBase([before]))], world)
        #expect(result.writes.count == 1 && result.writes[0].changes["collections"] == .elements(["b": .bool(false)]), "an id a row stops listing leaves the set")
        #expect(result.writes[0].stamps[StampedPath("collections", element: "b")] != nil && result.writes[0].stamps[StampedPath("collections", element: "mine")] == nil, "and an id the member added on build N stays")
        // the row deleted: the empty list
        let emptied = mpRecord(.notebookState, "ns:nb1", ["collections": [:]], .creates, whole: ["collections"])
        let wiped = mpPlan([MigrationOldRecordInput(old: mpOld("pf", [emptied], entity: .preference), base: mpBase([before]))], world)
        #expect(wiped.writes[0].changes["collections"] == .elements(["a": .bool(false), "b": .bool(false)]), "a deleted membership row empties what the base lists (R8-m7)")
        // an element added
        let more = mpRecord(.notebookState, "ns:nb1", ["notebookID": "nb1", "collections": ["a": true, "b": true, "c": true]], .creates, whole: ["collections"])
        let added = mpPlan([MigrationOldRecordInput(old: mpOld("pf", [more], entity: .preference), base: mpBase([before]))], world)
        #expect(added.writes[0].changes["collections"] == .elements(["c": true]), "only the new element is written")
    }

    @Test("Bodies")
    func bodies() throws {
        func file(_ owner: String, _ hash: String) -> SyncJSON {
            FileRef(owner: owner, role: "body", hash: hash, size: 3, mime: "application/x", encoding: "identity", storedParts: [Data("abc".utf8)]).value
        }
        let doc0 = mpRecord(.artifact, "doc1", ["title": "T", "body": file("doc1", "h0")], .owns, overrides: ["body": "h0"])
        let doc1 = mpRecord(.artifact, "doc1", ["title": "T", "body": file("doc1", "h1")], .owns, overrides: ["body": "h1"])
        func world(replica: String?, pending: String? = nil, own: Bool = false) -> MigrationWorldSnapshot {
            var world = MigrationWorldSnapshot()
            world.records[mpKey(.artifact, "doc1")] = mpHeld(.artifact, "doc1", ["title": "T", "body": file("doc1", replica ?? "h0")], replicaBody: replica, pendingBody: pending)
            if own { world.ownEdits.insert(mpKey(.artifact, "doc1")) }
            return world
        }
        let input = MigrationOldRecordInput(old: mpOld("a1", [doc1], entity: .artifact), base: mpBase([doc0]))
        let applied = mpPlan([input], world(replica: "h0"))
        #expect(applied.writes.count == 1 && applied.writes[0].changes.keys.contains("body") && applied.writes[0].bodySource == .docPackage(oldRecord: "Knowledge/a1"), "a body the new world has not touched since the base is applied, whatever the stamp")
        #expect(applied.writes[0].stamps[StampedPath("body")] == mpStamp(.textBody, 5_000), "stamped with the old date and the body's letter, T")
        let recovered = mpPlan([input], world(replica: "hX"))
        #expect(recovered.writes.count == 1 && recovered.writes[0].creates && recovered.writes[0].isRecoveredDoc, "when both worlds changed it, the old body becomes a Recovered Doc")
        #expect(recovered.writes[0].key == mpKey(.artifact, "recovered:doc1:h1"), "under the deterministic id")
        #expect(recovered.writes[0].changes["title"] == .value("Recovered: T") && recovered.writes[0].bodySource == .docPackage(oldRecord: "Knowledge/a1"), "titled Recovered: and holding the old package")
        #expect(!recovered.writes.contains { $0.key == mpKey(.artifact, "doc1") }, "and the new world's body stays")
        #expect(mpPlan([input], world(replica: "h0", own: true)).writes.first?.isRecoveredDoc == true, "this Mac's own edit counts as the new world's")
        #expect(mpPlan([input], world(replica: "h1")).writes.isEmpty, "a body the new world already carries is nothing to apply")
        #expect(mpPlan([input], world(replica: "hX", pending: "h1")).writes.isEmpty, "and so is one this Mac has pending")
        let unchanged = MigrationOldRecordInput(old: mpOld("a1", [doc0], entity: .artifact), base: mpBase([doc0]))
        #expect(mpPlan([unchanged], world(replica: "hX")).writes.isEmpty, "an old body that is the base's applies nothing")
        var listed = world(replica: "hX")
        listed.listed.insert(mpKey(.artifact, "recovered:doc1:h1"))
        #expect(mpPlan([input], listed).writes.isEmpty, "a Recovered Doc the learner deleted stays deleted")
        var exists = world(replica: "hX")
        exists.records[mpKey(.artifact, "recovered:doc1:h1")] = mpHeld(.artifact, "recovered:doc1:h1", ["title": "Recovered: T"])
        #expect(mpPlan([input], exists).writes.isEmpty, "and one that exists is not made twice")
        // a Doc whose package was not fetched gives no body
        let bare = mpRecord(.artifact, "doc1", ["title": "T2", "body": .null], .owns, overrides: ["body": "h1"])
        let noPackage = mpPlan([MigrationOldRecordInput(old: mpOld("a1", [bare], entity: .artifact), base: mpBase([doc0]))], world(replica: "h0"))
        #expect(noPackage.writes.count == 1 && noPackage.writes[0].changes.keys.sorted() == ["title"], "no body is applied or cleared without a package")
        // notes: cleared notes apply, never recover
        let notes0 = mpRecord(.artifact, "notes:nb1", ["title": "Notes", "body": file("notes:nb1", "n0")], .owns)
        let notes1 = mpRecord(.artifact, "notes:nb1", ["title": "Notes", "body": .null], .owns)
        var nworld = MigrationWorldSnapshot()
        nworld.records[mpKey(.artifact, "notes:nb1")] = mpHeld(.artifact, "notes:nb1", ["title": "Notes", "body": file("notes:nb1", "n0")], replicaBody: "n0")
        let cleared = mpPlan([MigrationOldRecordInput(old: mpOld("lg1", [notes1]), base: mpBase([notes0]))], nworld)
        #expect(cleared.writes.first?.changes["body"] == .value(.null) && cleared.writes.first?.bodySource == nil, "emptied notes clear the body")
        nworld.records[mpKey(.artifact, "notes:nb1")] = mpHeld(.artifact, "notes:nb1", ["title": "Notes", "body": file("notes:nb1", "nX")], replicaBody: "nX")
        #expect(mpPlan([MigrationOldRecordInput(old: mpOld("lg1", [notes1]), base: mpBase([notes0]))], nworld).writes.isEmpty, "and lose to a new-world edit without a Recovered Doc")
        // notes edited in the old world, untouched in the new
        let notes2 = mpRecord(.artifact, "notes:nb1", ["title": "Notes", "body": file("notes:nb1", "n2")], .owns)
        nworld.records[mpKey(.artifact, "notes:nb1")] = mpHeld(.artifact, "notes:nb1", ["title": "Notes", "body": file("notes:nb1", "n0")], replicaBody: "n0")
        let notesApplied = mpPlan([MigrationOldRecordInput(old: mpOld("lg1", [notes2]), base: mpBase([notes0]))], nworld)
        #expect(notesApplied.writes.first?.bodySource == .notes(oldRecord: "Knowledge/lg1"), "an old-world edit to untouched notes is applied from the old notes")
        var nown = nworld
        nown.records[mpKey(.artifact, "notes:nb1")] = mpHeld(.artifact, "notes:nb1", ["title": "Notes", "body": file("notes:nb1", "nX")], replicaBody: "nX")
        let notesRecovered = mpPlan([MigrationOldRecordInput(old: mpOld("lg1", [notes2]), base: mpBase([notes0]))], nown)
        #expect(notesRecovered.writes.first?.key == mpKey(.artifact, "recovered:notes:nb1:n2") && notesRecovered.writes.first?.changes["kind"] == .value("doc") && notesRecovered.writes.first?.changes["bodyFormat"] == .value("markdownPackage"), "notes both worlds changed become one Recovered Doc, an ordinary Doc with a package body")
        // creating a Doc whole carries its body
        let created = mpPlan([MigrationOldRecordInput(old: mpOld("a2", [doc1], entity: .artifact), base: nil)], MigrationWorldSnapshot())
        #expect(created.writes.count == 1 && created.writes[0].creates && created.writes[0].bodySource == .docPackage(oldRecord: "Knowledge/a2"), "a created Doc carries its package")
    }

    @Test("The body rule on its own")
    func theBodyRuleOnItsOwn() throws {
        typealias Rule = MigrationBodyRule
        #expect(Rule.decide(oldHash: nil, baseHash: "a", replicaHash: "a", pendingHash: nil, ownEdit: false) == .nothing, "no old body, nothing")
        #expect(Rule.decide(oldHash: "b", baseHash: "a", replicaHash: "a", pendingHash: nil, ownEdit: false) == .apply, "untouched since the base: apply")
        #expect(Rule.decide(oldHash: "b", baseHash: "a", replicaHash: "c", pendingHash: nil, ownEdit: false) == .recover, "both changed: recover")
        #expect(Rule.decide(oldHash: "b", baseHash: "a", replicaHash: "a", pendingHash: "c", ownEdit: false) == .recover, "a different pending body counts as the new world's")
        #expect(Rule.decide(oldHash: "b", baseHash: nil, replicaHash: nil, pendingHash: nil, ownEdit: false) == .apply, "a body on neither side before: apply")
        #expect(Rule.decide(oldHash: "b", baseHash: nil, replicaHash: "c", pendingHash: nil, ownEdit: false) == .recover, "a base that never listed it and a body already there: recover")
    }

    @Test("Two old records, one record")
    func twoOldRecordsOneRecord() throws {
        let a = mpRecord(.readingState, "rs:s1", ["targetKind": "source", "targetID": "s1", "readAt": 1_000], .creates)
        let b = mpRecord(.readingState, "rs:s1", ["targetKind": "source", "targetID": "s1", "readAt": 2_000], .creates)
        let first = MigrationOldRecordInput(old: mpOld("s1", [a], ms: 4_000, entity: .source), base: nil)
        let second = MigrationOldRecordInput(old: mpOld("pf1", [b], ms: 6_000, entity: .preference), base: nil)
        let result = mpPlan([first, second], MigrationWorldSnapshot())
        #expect(result.writes.count == 1, "two old records' values for one record fold into one write")
        #expect(result.writes[0].changes["readAt"] == .value(2_000) && result.writes[0].stamps[StampedPath("readAt")]?.milliseconds == 6_000, "the later stamp wins per field")
        // creates come before patches
        var world = MigrationWorldSnapshot()
        world.records[mpKey(.notebook, "nb1")] = mpHeld(.notebook, "nb1", ["title": "A"])
        let n = mpRecord(.notebook, "nb1", ["title": "B"], .owns)
        let c = mpRecord(.chat, "c9", ["title": "C"], .owns)
        let ordered = mpPlan([MigrationOldRecordInput(old: mpOld("lg1", [n]), base: mpBase([mpRecord(.notebook, "nb1", ["title": "A"], .owns)])),
                            MigrationOldRecordInput(old: mpOld("rs9", [c], entity: .reviewSession), base: nil)], world)
        #expect(ordered.writes.map(\.creates) == [true, false], "creates are ordered before patches")
    }

    @Test("Rows only this Mac holds")
    func rowsOnlyThisMacHolds() throws {
        let exchange = mpRecord(.exchange, "ex7", ["chatID": "c1", "question": "Q"], .owns)
        var world = MigrationWorldSnapshot()
        world.records[mpKey(.chat, "c1")] = mpHeld(.chat, "c1", ["title": "T"])
        world.localOnly.insert(mpKey(.exchange, "ex7"))
        let result = mpPlan([MigrationOldRecordInput(old: mpOld("rs1", [exchange], entity: .reviewSession), base: mpBase([]))], world)
        #expect(result.writes.isEmpty && result.olds[0].nextEntry?.records["Exchange:ex7"] != nil, "rows this Mac derived and has not uploaded are left to its reconcile")
    }

    @Test("A queued capture is provisional")
    func aQueuedCaptureIsProvisional() throws {
        let ingest: SyncJSON = .object(["state": "queued", "ord": [0, 1]])
        let capture = mpRecord(.source, "src-cap", ["title": "https://x.test/a", "url": "https://x.test/a", "type": "article", "summary": "S", "ingest": ingest], .owns)
        let created = mpPlan([MigrationOldRecordInput(old: mpOld("s-cap", [capture], entity: .source), base: nil)], MigrationWorldSnapshot())
        let stamps = created.writes[0].stamps
        #expect(stamps[StampedPath("title")]?.milliseconds == 1 && stamps[StampedPath("url")]?.milliseconds == 1 && stamps[StampedPath("type")]?.milliseconds == 1, "a queued capture's title, url and type take provisional stamps")
        #expect(stamps[StampedPath("summary")]?.milliseconds == 5_000, "its other fields take the old date")
        var world = MigrationWorldSnapshot()
        world.records[mpKey(.source, "src-cap")] = mpHeld(.source, "src-cap", ["title": "A real title", "url": "https://x.test/a", "type": "article"], ms: 100, device: mpDevice)
        let present = mpPlan([MigrationOldRecordInput(old: mpOld("s-cap", [capture], entity: .source), base: nil)], world)
        #expect(present.writes.allSatisfy { $0.changes["title"] == nil && $0.changes["type"] == nil }, "and never beats the real values the new world holds")
        let ready: SyncJSON = .object(["state": "ready", "ord": [0, 4]])
        let real = mpRecord(.source, "src-cap", ["title": "Real", "ingest": ready], .owns)
        #expect(mpPlan([MigrationOldRecordInput(old: mpOld("s-cap", [real], entity: .source), base: nil)], MigrationWorldSnapshot()).writes[0].stamps[StampedPath("title")]?.milliseconds == 5_000, "a ready source's title is stamped with the old date")
    }

    @Test("The base entry")
    func theBaseEntry() throws {
        let n = mpRecord(.notebook, "nb1", ["title": "N", "researchQuestions": ["q1": "x"]], .owns)
        let entry = MigrationBaseEntry(mapping: LegacyMapping(entity: .learningGoal, logicalKey: "lg", records: [n]), changeTag: "t", waiting: true)
        let round = MigrationBaseEntry(json: entry.json, changeTag: "t")
        #expect(round == entry, "a base entry survives its JSON form")
        #expect(entry.records["Notebook:nb1"]?.hashes["researchQuestions/q1"] != nil, "a map field is listed per element")
        #expect(MigrationRecordKey(baseKey: "Entry:en:nb1:source:s1", spaceID: nil) == mpKey(.entry, "en:nb1:source:s1"), "a base key splits at its first colon")
    }


    // MARK: A pass over this Mac's own view (WP16b2)

    @Test("Reach: a pass over this Mac's own view patches only the records the server does not hold")
    func reach() throws {
        let before = mpRecord(.notebook, "nb1", ["title": "Old", "instructions": "same"], .owns)
        let after = mpRecord(.notebook, "nb1", ["title": "New", "instructions": "same"], .owns)
        let input = MigrationOldRecordInput(old: mpOld("lg1", [after]), base: mpBase([before]))
        var onServer = MigrationWorldSnapshot()
        onServer.records[mpKey(.notebook, "nb1")] = mpHeld(.notebook, "nb1", ["title": "Old", "instructions": "same"])
        #expect(mpPlan([input], onServer, mpOptions(reach: .absentOnly, ownRows: true)).writes.isEmpty, "absentOnly: a record the server holds is not patched")
        #expect(mpPlan([input], onServer, mpOptions(reach: .everything, ownRows: true)).writes.count == 1, "everything: it is")
        #expect(mpPlan([input], onServer, mpOptions(reach: .absentOnly, ownRows: true)).olds[0].nextEntry?.records["Notebook:nb1"]?.hashes["title"] == mpHash("New"),
                "absentOnly: the snapshot still moves past it")

        var inRows = MigrationWorldSnapshot()
        inRows.records[mpKey(.notebook, "nb1")] = mpRows(.notebook, "nb1", ["title": "Old", "instructions": "same"])
        let patched = mpPlan([input], inRows, mpOptions(reach: .absentOnly, ownRows: true))
        #expect(patched.writes.count == 1 && !patched.writes[0].creates && patched.writes[0].changes == ["title": .value("New")], "a record only the rows hold is patched, with the field that differs alone")

        // the deferred catch-up has no hashes: every field is applied, but a value the rows hold is dropped
        let noHashes = MigrationOldRecordInput(old: mpOld("lg1", [after]), base: MigrationBaseEntry(changeTag: "t", records: ["Notebook:nb1": MigrationBaseRecord(owned: true, hashes: [:])]))
        let all = mpPlan([noHashes], inRows, mpOptions(reach: .everything, ownRows: true))
        #expect(all.writes.count == 1 && all.writes[0].changes == ["title": .value("New")], "no hashes: every field is applied, a value the rows already hold is dropped")
        // no base on the root: the stamps decide over a record the server holds
        var older = MigrationWorldSnapshot()
        older.records[mpKey(.notebook, "nb1")] = mpHeld(.notebook, "nb1", ["title": "Mine", "instructions": "same"], ms: 2_000, device: mpDevice)
        #expect(mpPlan([noHashes], older, mpOptions(reach: .everything, ownRows: true)).writes.count == 1, "no base on the root: an older new-world stamp is overtaken")
        var newer = MigrationWorldSnapshot()
        newer.records[mpKey(.notebook, "nb1")] = mpHeld(.notebook, "nb1", ["title": "Mine", "instructions": "same"], ms: 9_000, device: mpDevice)
        #expect(mpPlan([noHashes], newer, mpOptions(reach: .everything, ownRows: true)).writes.isEmpty, "and a later one stands")
        // absent everywhere: created whole; listed in a manifest: deleted in the new world
        #expect(mpPlan([MigrationOldRecordInput(old: mpOld("lg1", [after]), base: nil)], MigrationWorldSnapshot(), mpOptions(reach: .absentOnly, ownRows: true)).creates == [mpKey(.notebook, "nb1")],
                "absent everywhere: created whole")
        var listed = MigrationWorldSnapshot()
        listed.listed.insert(mpKey(.notebook, "nb1"))
        #expect(mpPlan([MigrationOldRecordInput(old: mpOld("lg1", [after]), base: nil)], listed, mpOptions(reach: .absentOnly, ownRows: true)).writes.isEmpty, "listed: deleted in the new world")
    }

    @Test("Removal from this Mac's view: only rows the server does not hold and no unsent change names")
    func removalFromOwnView() throws {
        let notebook = mpRecord(.notebook, "nb1", ["title": "N"], .owns)
        let candidates = MigrationBaseEntry(changeTag: "t", records: [
            "Notebook:nb1": MigrationBaseRecord(owned: true, hashes: [:]), "Entry:en:nb1:source:s1": MigrationBaseRecord(owned: true, hashes: [:]),
        ])
        let input = MigrationOldRecordInput(old: mpOld("lg1", [notebook]), base: candidates)
        let own = mpOptions(reach: .absentOnly, ownRows: true)
        let noBase = mpOptions(reach: .everything, ownRows: true)
        let entryKey = mpKey(.entry, "en:nb1:source:s1")

        var inRows = MigrationWorldSnapshot()
        inRows.records[mpKey(.notebook, "nb1")] = mpRows(.notebook, "nb1", ["title": "N"])
        inRows.records[entryKey] = mpRows(.entry, "en:nb1:source:s1", ["state": "active"])
        let gone = mpPlan([input], inRows, own)
        #expect(gone.removals == 1 && gone.writes.contains { $0.key == entryKey && $0.removes && $0.changes["state"] == .value("removed") }, "a candidate only the rows hold is removed, flagged as a removal")
        #expect(mpPlan([input], inRows, noBase).removals == 1, "also with no base on the root")

        var server = inRows
        server.records[entryKey] = mpHeld(.entry, "en:nb1:source:s1", ["state": "active"])
        #expect(mpPlan([input], server, own).removals == 0 && mpPlan([input], server, own).writes.isEmpty, "held by the server: not removed (with a base)")
        let withoutBase = mpPlan([input], server, noBase)
        #expect(withoutBase.removals == 0 && withoutBase.deletions.isEmpty && withoutBase.writes.isEmpty && withoutBase.kept.isEmpty, "held by the server: not removed and not listed (no base)")

        var local = inRows
        local.localChanges.insert(entryKey)
        let kept = mpPlan([input], local, own)
        #expect(kept.removals == 0 && kept.kept.map(\.reason) == [.editedInNewWorld], "a record with an unsent change of this Mac's own is kept and logged")

        let deletedInput = MigrationOldRecordInput(old: mpOld("lg1", [], deleted: true), base: candidates)
        var dworld = MigrationWorldSnapshot()
        dworld.records[mpKey(.notebook, "nb1")] = mpRows(.notebook, "nb1", ["title": "N"])
        dworld.records[entryKey] = mpRows(.entry, "en:nb1:source:s1", ["state": "active"])
        let deleted = mpPlan([deletedInput], dworld, noBase)
        #expect(deleted.deletions.map(\.key) == [mpKey(.notebook, "nb1")] && deleted.writes.contains { $0.key == entryKey && $0.removes }, "a deleted old record's owned rows go: the notebook deleted, its Entry flipped")
        #expect(deleted.olds[0].nextEntry == nil, "and it leaves the snapshot")

        let reading = MigrationBaseEntry(changeTag: "t", records: ["ReadingState:rs:s1": MigrationBaseRecord(owned: true, hashes: [:])])
        var rworld = MigrationWorldSnapshot()
        rworld.records[mpKey(.readingState, "rs:s1")] = mpRows(.readingState, "rs:s1", ["targetKind": "source"])
        let neverRemoved = mpPlan([MigrationOldRecordInput(old: mpOld("s1", [], deleted: true), base: reading)], rworld, noBase)
        #expect(neverRemoved.removals == 0 && neverRemoved.kept.map(\.reason) == [.neverRemoved], "per-member state is never removed")
        #expect(mpPlan([MigrationOldRecordInput(old: mpOld("lg1", [], deleted: true), base: nil)], dworld, noBase).removals == 0, "with no history nothing local is removed")
        let fed = MigrationBaseEntry(changeTag: "t", records: ["Notebook:nb1": MigrationBaseRecord(owned: false, hashes: [:])])
        #expect(mpPlan([MigrationOldRecordInput(old: mpOld("lg1", [], deleted: true), base: fed)], dworld, noBase).kept.map(\.reason) == [.notOwned], "a record the old record only fed is kept")
    }

    @Test("Bodies from this Mac's own rows: no edit takes the old body, an edit of its own stays beside one Recovered Doc")
    func bodiesFromOwnRows() throws {
        let oldPackage = FileRef(owner: "doc1", role: "body", hash: "oldhash", size: 10, mime: "application/x-forever-doc", encoding: "identity", storedParts: [Data(count: 10)])
        let doc = mpRecord(.artifact, "doc1", ["title": "D", "body": oldPackage.value], .owns, overrides: ["body": "oldhash"])
        let input = MigrationOldRecordInput(old: mpOld("a1", [doc], entity: .artifact), base: MigrationBaseEntry(changeTag: "t", records: ["Artifact:doc1": MigrationBaseRecord(owned: true, hashes: [:])]))
        let options = mpOptions(reach: .everything, ownRows: true)
        var clean = MigrationWorldSnapshot()
        clean.records[mpKey(.artifact, "doc1")] = mpRows(.artifact, "doc1", ["title": "D"], body: "lasthash")
        let applied = mpPlan([input], clean, options)
        #expect(applied.writes.count == 1 && !applied.writes[0].creates && !applied.writes[0].isRecoveredDoc && applied.writes[0].changes["body"] != nil
                && applied.writes[0].bodySource == .docPackage(oldRecord: "Knowledge/a1"), "no edit of its own: the old body is applied")
        var same = MigrationWorldSnapshot()
        same.records[mpKey(.artifact, "doc1")] = mpRows(.artifact, "doc1", ["title": "D"], body: "oldhash")
        #expect(mpPlan([input], same, options).writes.isEmpty, "rows that hold the old body take nothing")
        var edited = clean
        edited.ownEdits.insert(mpKey(.artifact, "doc1"))
        let recovered = mpPlan([input], edited, options)
        #expect(recovered.writes.count == 1 && recovered.writes[0].isRecoveredDoc && recovered.writes[0].creates, "an edit of its own stays beside one Recovered Doc")
        #expect(recovered.writes[0].key == mpKey(.artifact, MigrationBodyRule.recoveredID(artifactID: "doc1", hash: "oldhash")), "under the deterministic id")

        // a record this Mac's local change wins is planned for its body alone: the title is given to a creation only
        var bodyRecord = doc
        bodyRecord.createOnlyFields = ["title"]
        let bodyOnly = MigrationOldRecordInput(old: mpOld("a1", [bodyRecord], entity: .artifact), base: nil)
        var withOther = MigrationWorldSnapshot()
        withOther.records[mpKey(.artifact, "doc1")] = mpRows(.artifact, "doc1", ["title": "Mine"], body: "lasthash")
        let onlyBody = mpPlan([bodyOnly], withOther, options)
        #expect(onlyBody.writes.count == 1 && onlyBody.writes[0].changes.keys.sorted() == ["body"], "a kept record is planned for its body alone")
        withOther.ownEdits.insert(mpKey(.artifact, "doc1"))
        let beside = mpPlan([bodyOnly], withOther, options)
        #expect(beside.writes.count == 1 && beside.writes[0].isRecoveredDoc && beside.writes[0].changes["title"] == .value("Recovered: D"), "and a Recovered Doc copies its title")
    }

    @Test("The refresh's body: the body its snapshot names is the one this Mac last synced")
    func refreshBody() throws {
        let newPackage = FileRef(owner: "doc1", role: "body", hash: "newhash", size: 10, mime: "application/x-forever-doc", encoding: "identity", storedParts: [Data(count: 10)])
        let doc = mpRecord(.artifact, "doc1", ["title": "D", "body": newPackage.value], .owns, overrides: ["body": "newhash"])
        let snapshot = MigrationBaseEntry(changeTag: "t", records: ["Artifact:doc1": MigrationBaseRecord(owned: true, hashes: ["body": "snaphash", "title": mpHash("D")])])
        let input = MigrationOldRecordInput(old: mpOld("a1", [doc], entity: .artifact), base: snapshot)
        let own = mpOptions(reach: .absentOnly, ownRows: true)
        var clean = MigrationWorldSnapshot()
        clean.records[mpKey(.artifact, "doc1")] = mpRows(.artifact, "doc1", ["title": "D"], body: "snaphash")
        #expect(mpPlan([input], clean, own).writes.first.map { !$0.creates && $0.changes["body"] != nil } == true, "the refresh applies a body its snapshot does not know when this Mac has no edit")
        var edited = clean
        edited.ownEdits.insert(mpKey(.artifact, "doc1"))
        #expect(mpPlan([input], edited, own).writes.first?.isRecoveredDoc == true, "and recovers it beside this Mac's edit")
    }
}

// MARK: Helpers, file-private and prefixed so no other suite sees them

fileprivate let mpSalt = "abcd2345"
fileprivate let mpDevice = "k3f7ab2q"
fileprivate func mpStamp(_ policy: SyncPolicy, _ ms: Int64, _ device: String = SyncIdentity.legacyDeviceID) -> SyncStamp {
    SyncStamp(policy: policy, milliseconds: ms, counter: 0, deviceID: device)
}

/// A record as the replica holds it, every field stamped at `ms` by `device`.
fileprivate func mpHeld(_ type: SyncRecordType, _ id: String, _ fields: [String: SyncJSON], ms: Int64 = 1_000, device: String = SyncIdentity.legacyDeviceID,
          replicaBody: String? = nil, pendingBody: String? = nil, stampOverrides: [String: SyncFieldStamp] = [:]) -> MigrationHeldRecord {
    var envelope = SyncEnvelope(type: type.rawValue, id: id, saltID: mpSalt, fields: fields)
    for (field, value) in fields {
        let spec = type.spec.field(field)!
        if spec.kind == .scalar {
            envelope.stamps[field] = .value(mpStamp(spec.policy, ms, device))
        } else {
            envelope.stamps[field] = .elements((value.objectValue ?? [:]).mapValues { _ in mpStamp(spec.policy, ms, device) })
        }
    }
    for (field, stamp) in stampOverrides { envelope.stamps[field] = stamp }
    return MigrationHeldRecord(merged: envelope, inReplica: true, replicaBodyHash: replicaBody, pendingBodyHash: pendingBody)
}

fileprivate func mpHash(_ value: SyncJSON) -> String { LegacyFieldHashes.hash(value) }

fileprivate func mpRecord(_ type: SyncRecordType, _ id: String, _ fields: [String: SyncJSON], _ giving: LegacyGiving, space: String? = nil,
            whole: Set<String> = [], overrides: [String: String] = [:], createOnly: Set<String> = []) -> LegacyV2Record {
    var rec = LegacyV2Record(type: type, id: id, fields: fields, giving: giving)
    rec.wholeFields = whole
    rec.hashOverrides = overrides
    rec.createOnlyFields = createOnly
    rec.spaceID = space
    return rec
}

fileprivate func mpOld(_ name: String, _ records: [LegacyV2Record], ms: Int64 = 5_000, silent: Set<LegacyChildScope> = [], zone: String = "Knowledge",
         space: String? = nil, entity: CloudKitSyncEntity = .learningGoal, deleted: Bool = false) -> MigrationOldRecord {
    var mapping = LegacyMapping(entity: entity, logicalKey: name, records: records, silentChildren: silent)
    mapping.records = records
    return MigrationOldRecord(zone: zone, name: name, changeTag: "tag-\(ms)", modifiedAt: SyncTime.date(milliseconds: ms),
                              mapping: deleted ? nil : mapping, spaceID: space)
}

fileprivate func mpBase(_ records: [LegacyV2Record], waiting: Bool = false) -> MigrationBaseEntry {
    MigrationBaseEntry(mapping: LegacyMapping(entity: .learningGoal, logicalKey: "b", records: records), changeTag: "old", waiting: waiting)
}

fileprivate let mpNow = SyncTime.date(milliseconds: 100_000_000_000)
fileprivate func mpOptions(
    keep: Bool = false, since: Int64? = nil, waiting: [String: Date] = [:], reach: MigrationImportPlanner.Reach = .everything, ownRows: Bool = false
) -> MigrationImportPlanner.Options {
    MigrationImportPlanner.Options(now: mpNow, keepRemovals: keep, newWorldSince: since.map(SyncTime.date), waitingSince: waiting, reach: reach, ownRows: ownRows)
}

/// A record only this Mac's rows hold: encoded from the rows, with no stamps and no server copy.
fileprivate func mpRows(_ type: SyncRecordType, _ id: String, _ fields: [String: SyncJSON], body: String? = nil) -> MigrationHeldRecord {
    MigrationHeldRecord(merged: SyncEnvelope(type: type.rawValue, id: id, saltID: "", fields: fields), inReplica: false, replicaBodyHash: body, pendingBodyHash: nil)
}

fileprivate func mpPlan(_ inputs: [MigrationOldRecordInput], _ world: MigrationWorldSnapshot, _ opts: MigrationImportPlanner.Options? = nil) -> MigrationPassPlan {
    MigrationImportPlanner.plan(inputs, world: world, options: opts ?? mpOptions())
}

fileprivate func mpKey(_ type: SyncRecordType, _ id: String, space: String? = nil) -> MigrationRecordKey { MigrationRecordKey(type, id, spaceID: space) }
