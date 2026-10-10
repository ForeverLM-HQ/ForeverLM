import Foundation
import Testing
@testable import ForeverLM

/// The chat-tick rule (§5.6, bug b5): an untick holds only while the Entry's stamps are the ones it
/// recorded, so a re-add or a re-approval from any device ticks the source again. A notebook's
/// context (D52): the Studio reads only the notebook's own sources, a chat also those of the listed
/// notebooks the member ticked, each list resolved before they are intersected (R6-m1).
@Suite("Sync notebook chat context")
struct SyncNotebookChatContextTests {
    static let deviceA = "aaaaaaaa"
    static let device = "k3f7ab2q"

    static func entry(_ item: String, in container: String = "nb1", state: String = "active", approval: String? = nil,
                      stateStamp: SyncStamp, approvalStamp: SyncStamp? = nil) -> SyncNotebookChatContext.Entry {
        SyncNotebookChatContext.Entry(containerID: container, itemKind: "source", itemID: item, state: state, approval: approval,
                                      stateStamp: stateStamp, approvalStamp: approvalStamp)
    }

    static func stamp(_ offset: Int64, _ device: String = deviceA) -> SyncStamp {
        SyncStamp(policy: .lastWriter, milliseconds: 1_759_400_000_000 + offset, counter: 0, deviceID: device)
    }

    /// A set field as a record holds it: every element `true`.
    static func set(_ ids: String...) -> [String: SyncJSON] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, SyncJSON.bool(true)) })
    }

    @Test("The chat-ticks vectors hold")
    func vectors() {
        SyncVectorRunner.expectCases("chat-ticks")
    }

    @Test("Untick, then a re-add elsewhere: the source is ticked again with no write to the member's record")
    func reAddTicksAgain() throws {
        let added = Self.entry("src_a", stateStamp: Self.stamp(0))
        var excluded: [String: SyncJSON] = [:]
        guard case .elements(let untick) = SyncNotebookChatContext.untick(added) else { Issue.record("an untick is an element change"); return }
        excluded.merge(untick) { $1 }
        #expect(SyncNotebookChatContext.studioSourceIDs(notebookID: "nb1", entries: [added], excluded: excluded).isEmpty)
        // Another device removes and re-adds it: a new state stamp.
        let reAdded = Self.entry("src_a", stateStamp: Self.stamp(5_000, "bbbbbbbb"))
        #expect(SyncNotebookChatContext.studioSourceIDs(notebookID: "nb1", entries: [reAdded], excluded: excluded) == ["src_a"])
    }

    @Test("Untick right after an offline add names the add's pinned stamp, so it still matches once the add is sent")
    func offlineAddThenUntick() throws {
        var clock = StampClock(deviceID: Self.device, offsetSamples: [0])
        var entry = SyncEnvelope.new(.entry, id: "en:nb1:source:src_a", saltID: "00000000")
        var pinned: [StampedPath: SyncStamp] = [:]
        let add = RecordPatch(.entry, id: "en:nb1:source:src_a", changes: [
            "containerKind": .value("notebook"), "containerID": .value("nb1"), "itemKind": .value("source"),
            "itemID": .value("src_a"), "state": .value("active"),
        ])
        try entry.apply(add) { path, policy, seen in
            let minted = clock.mint(policy, eventTime: 1_759_400_000_000, seen: seen, now: 1_759_400_000_000)
            let stamp = try #require(minted)
            pinned[path] = stamp
            return stamp
        }
        let pending = try #require(SyncNotebookChatContext.Entry(entry))
        #expect(pending.stateStamp == pinned[StampedPath("state")])
        let untick = SyncNotebookChatContext.untick(pending)
        // The add goes out later with exactly its pinned stamps; the exclusion still holds.
        var sent = SyncEnvelope.new(.entry, id: "en:nb1:source:src_a", saltID: "00000000")
        try sent.apply(add) { path, _, _ in try #require(pinned[path]) }
        guard case .elements(let excluded) = untick else { Issue.record("an untick is an element change"); return }
        #expect(SyncNotebookChatContext.studioSourceIDs(notebookID: "nb1", entries: [try #require(SyncNotebookChatContext.Entry(sent))],
                                                        excluded: excluded).isEmpty)
    }

    @Test("Pending and rejected suggestions are out of context; absent approval is approved; a tick puts a source back")
    func approvals() {
        let entries = [
            Self.entry("src_a", approval: "pending", stateStamp: Self.stamp(0), approvalStamp: Self.stamp(1)),
            Self.entry("src_b", approval: "rejected", stateStamp: Self.stamp(0), approvalStamp: Self.stamp(1)),
            Self.entry("src_c", approval: "approved", stateStamp: Self.stamp(0), approvalStamp: Self.stamp(1)),
            Self.entry("src_d", stateStamp: Self.stamp(0)),
            Self.entry("src_e", state: "removed", stateStamp: Self.stamp(0)),
        ]
        #expect(SyncNotebookChatContext.studioSourceIDs(notebookID: "nb1", entries: entries, excluded: [:]) == ["src_c", "src_d"])
        let excluded: [String: SyncJSON] = ["src_d": .string(SyncNotebookChatContext.stampPair(entries[3]))]
        #expect(SyncNotebookChatContext.studioSourceIDs(notebookID: "nb1", entries: entries, excluded: excluded) == ["src_c"])
        #expect(SyncNotebookChatContext.tick("src_d") == .elements(["src_d": .null]))
        #expect(SyncNotebookChatContext.stampPair(entries[3]).hasSuffix("|-"))
    }

    @Test("An Entry record reads as the rule's entry; a record without a state stamp does not")
    func fromEnvelope() {
        let record = SyncEnvelope(type: "Entry", id: "en:nb1:source:src_a", saltID: "00000000",
                                  fields: ["containerID": "nb1", "itemKind": "source", "itemID": "src_a", "state": "active", "approval": "approved"],
                                  stamps: ["state": .value(Self.stamp(0)), "approval": .value(Self.stamp(1))])
        #expect(SyncNotebookChatContext.Entry(record)?.approvalStamp == Self.stamp(1))
        var unstamped = record
        unstamped.stamps["state"] = nil
        #expect(SyncNotebookChatContext.Entry(unstamped) == nil)
    }

    // MARK: - Context notebooks (D52)

    @Test("A listed notebook adds nothing until the member ticks it; a ticked one adds its sources to the chat, never to the Studio, one level deep and never the notebook itself")
    func contextNotebooks() {
        let entries = [
            Self.entry("src_own", stateStamp: Self.stamp(0)),
            Self.entry("src_a", in: "nbA", stateStamp: Self.stamp(0)),
            Self.entry("src_pending", in: "nbA", approval: "pending", stateStamp: Self.stamp(0), approvalStamp: Self.stamp(1)),
            // nbB is nbA's own context notebook: one level deep, so it never joins nb1's chat.
            Self.entry("src_b", in: "nbB", stateStamp: Self.stamp(0)),
        ]
        let resolve: (String) -> String = { $0 }
        func chat(ticked: [String: SyncJSON], listed: [String: SyncJSON]) -> [String] {
            let context = SyncNotebookChatContext.contextNotebookIDs(notebookID: "nb1", contextNotebooks: ticked,
                                                                     relatedNotebookIDs: listed, resolve: resolve)
            return SyncNotebookChatContext.chatSourceIDs(notebookID: "nb1", contextNotebookIDs: context, entries: entries, excluded: [:])
        }
        #expect(chat(ticked: [:], listed: Self.set("nbA")) == ["src_own"], "listed but not ticked")
        #expect(chat(ticked: Self.set("nbA"), listed: [:]) == ["src_own"], "ticked but no longer listed")
        #expect(chat(ticked: ["nbA": .bool(false)], listed: Self.set("nbA")) == ["src_own"], "taken out of context")
        #expect(chat(ticked: Self.set("nbA"), listed: Self.set("nbA")) == ["src_a", "src_own"])
        #expect(SyncNotebookChatContext.contextNotebookIDs(notebookID: "nb1", contextNotebooks: Self.set("nb1", "nbA"),
                                                           relatedNotebookIDs: Self.set("nb1", "nbA"), resolve: resolve) == ["nbA"],
                "the notebook itself is dropped")
        #expect(SyncNotebookChatContext.studioSourceIDs(notebookID: "nb1", entries: entries, excluded: [:]) == ["src_own"],
                "the Studio reads only the notebook's own sources")
    }

    @Test("An exclusion of a source the notebook and a context notebook both hold compares with the notebook's own Entry")
    func sharedSourceComparesWithOwnEntry() throws {
        let own = Self.entry("src_s", stateStamp: Self.stamp(0))
        // nb0 sorts before nb1, so only the own-Entry-first rule picks `own`.
        let drawn = Self.entry("src_s", in: "nb0", stateStamp: Self.stamp(7_000, "bbbbbbbb"))
        let elsewhere = Self.entry("src_t", in: "nbB", stateStamp: Self.stamp(0))
        let smaller = Self.entry("src_t", in: "nbA", stateStamp: Self.stamp(3_000))
        let entries = [own, drawn, elsewhere, smaller]
        let context = ["nb0", "nbA", "nbB"]
        #expect(SyncNotebookChatContext.comparedEntry(for: "src_s", notebookID: "nb1", contextNotebookIDs: context, entries: entries) == own)
        #expect(SyncNotebookChatContext.comparedEntry(for: "src_t", notebookID: "nb1", contextNotebookIDs: context, entries: entries) == smaller,
                "a source only context notebooks hold compares with its Entry in the smallest one")
        func chat(_ excluded: [String: SyncJSON]) -> [String] {
            SyncNotebookChatContext.chatSourceIDs(notebookID: "nb1", contextNotebookIDs: context, entries: entries, excluded: excluded)
        }
        // The member unticks src_s: the untick names the notebook's own Entry and holds.
        let untick = try #require(SyncNotebookChatContext.comparedEntry(for: "src_s", notebookID: "nb1", contextNotebookIDs: context,
                                                                        entries: entries))
        guard case .elements(let excluded) = SyncNotebookChatContext.untick(untick) else { Issue.record("an untick is an element change"); return }
        #expect(chat(excluded) == ["src_t"])
        // An untick made while only nb0 held src_s names nb0's Entry; once src_s is the notebook's own, it is ticked again.
        #expect(chat(["src_s": .string(SyncNotebookChatContext.stampPair(drawn))]) == ["src_s", "src_t"])
        #expect(chat(["src_t": .string(SyncNotebookChatContext.stampPair(elsewhere))]) == ["src_s", "src_t"],
                "an untick naming the larger context notebook's Entry does not hold")
    }

    @Test("R6-m1: a context notebook merged into another keeps feeding the chat through the survivor, whether the tick or the link still names the stub")
    func mergedContextNotebook() {
        // nbA was merged into nbB; nbA's sources are nbB's now (twinned by the merge job).
        let held: [String: NotebookRedirects] = ["nb1": NotebookRedirects(), "nbA": NotebookRedirects(mergedInto: "nbB"), "nbB": NotebookRedirects()]
        let resolve: (String) -> String = { id in
            NotebookResolution.resolve(SyncRecordLocation(zone: .library, id: id)) { location in
                location.zone == .library ? held[location.id] : nil
            }.id
        }
        let entries = [Self.entry("src_own", stateStamp: Self.stamp(0)), Self.entry("src_m", in: "nbB", stateStamp: Self.stamp(0))]
        for (ticked, listed) in [("nbA", "nbB"), ("nbB", "nbA"), ("nbA", "nbA")] {
            let context = SyncNotebookChatContext.contextNotebookIDs(notebookID: "nb1", contextNotebooks: Self.set(ticked),
                                                                     relatedNotebookIDs: Self.set(listed), resolve: resolve)
            #expect(context == ["nbB"], "tick \(ticked), link \(listed)")
            #expect(SyncNotebookChatContext.chatSourceIDs(notebookID: "nb1", contextNotebookIDs: context, entries: entries, excluded: [:])
                    == ["src_m", "src_own"], "tick \(ticked), link \(listed)")
        }
        // A context notebook merged into the notebook itself adds nothing twice.
        let intoItself: [String: NotebookRedirects] = ["nb1": NotebookRedirects(), "nbA": NotebookRedirects(mergedInto: "nb1")]
        let context = SyncNotebookChatContext.contextNotebookIDs(notebookID: "nb1", contextNotebooks: Self.set("nbA"),
                                                                 relatedNotebookIDs: Self.set("nbA")) { id in
            NotebookResolution.resolve(SyncRecordLocation(zone: .library, id: id)) { intoItself[$0.id] }.id
        }
        #expect(context.isEmpty)
    }
}
