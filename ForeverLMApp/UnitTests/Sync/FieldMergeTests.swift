import Foundation
import Testing
@testable import ForeverLM

/// The merge (§6.2): the vectors pin its cases; these pin its properties over seeded random
/// records, and the parts the vectors cannot show (the outbox's view of what won, and the
/// `onServerFirstLoss` call that turns a lost Keep into a card of its own).
@Suite("Field merge")
struct FieldMergeTests {
    /// SplitMix64, so a failing seed can be replayed.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func stamp(_ letter: SyncPolicy, _ offset: Int64, _ device: String = "aaaaaaaa", counter: Int = 0) -> SyncStamp {
        SyncStamp(policy: letter, milliseconds: 1_759_400_000_000 + offset, counter: counter, deviceID: device)
    }

    static func record(type: String = "VectorRecord", _ fields: [String: SyncJSON], _ stamps: [String: SyncFieldStamp],
                       extra: [String: SyncJSON] = [:]) -> SyncEnvelope {
        SyncEnvelope(type: type, id: "r1", saltID: "00000000", fields: fields, stamps: stamps, extra: extra)
    }

    /// A value that follows from its stamp, so two equal stamps always carry one value, as they do
    /// on the wire (a stamp names one write).
    static func value(for stamp: SyncStamp, numeric: Bool) -> SyncJSON {
        if numeric { return .number(Double(stamp.milliseconds % 997) + Double(stamp.counter) / 10) }
        return .string("\(stamp.deviceID)-\(stamp.milliseconds % 1000)")
    }

    /// A random record whose fields use only the letters given: scalars, a map and a set, each
    /// element derived from the base so the sides share history the way devices do.
    static func randomSides(_ generator: inout SeededGenerator, letters: [SyncPolicy]) -> (server: SyncEnvelope, local: SyncEnvelope, base: SyncEnvelope?) {
        var clock: Int64 = 0
        func next(_ letter: SyncPolicy, _ device: String) -> SyncStamp {
            clock += Int64.random(in: 1...40, using: &generator)
            return stamp(letter, clock, device, counter: Int.random(in: 0...2, using: &generator))
        }
        var baseFields: [String: SyncJSON] = [:]
        var baseStamps: [String: SyncFieldStamp] = [:]
        for (index, letter) in letters.enumerated() {
            let name = "f\(index)"
            let s = next(letter, "aaaaaaaa")
            baseFields[name] = value(for: s, numeric: letter != .lastWriter)
            baseStamps[name] = .value(s)
        }
        var mapValues: [String: SyncJSON] = [:]
        var mapStamps: [String: SyncStamp] = [:]
        for key in ["k1", "k2", "k3"] where Bool.random(using: &generator) {
            let s = next(.lastWriter, "aaaaaaaa")
            mapStamps[key] = s
            mapValues[key] = value(for: s, numeric: false)
        }
        baseFields["m"] = .object(mapValues)
        baseStamps["m"] = .elements(mapStamps)
        let base = record(baseFields, baseStamps)
        func edit(_ device: String) -> SyncEnvelope {
            var side = base
            for (index, letter) in letters.enumerated() where Bool.random(using: &generator) {
                let s = next(letter, device)
                let held = base.fields["f\(index)"]?.numberValue ?? 0
                // Writers only raise an X value and only lower an N value (editedAt, furthest with its
                // epoch, addedAt); the step follows from the stamp, so one stamp names one value.
                let step = Double(s.milliseconds % 97 + 1)
                switch letter {
                case .maximum: side.fields["f\(index)"] = .number(held + step)
                case .minimum: side.fields["f\(index)"] = .number(held - step)
                default: side.fields["f\(index)"] = value(for: s, numeric: false)
                }
                side.stamps["f\(index)"] = .value(s)
            }
            var values = side.fields["m"]?.objectValue ?? [:]
            guard case .elements(var stamps)? = side.stamps["m"] else { return side }
            for key in ["k1", "k2", "k3", "k4"] where Bool.random(using: &generator) {
                let s = next(.lastWriter, device)
                stamps[key] = s
                values[key] = Bool.random(using: &generator) ? .null : value(for: s, numeric: false)
            }
            side.fields["m"] = .object(values)
            side.stamps["m"] = .elements(stamps)
            return side
        }
        let server = edit("cccccccc")
        let local = edit("bbbbbbbb")
        return (server, local, Bool.random(using: &generator) ? base : nil)
    }

    @Test("The merge vectors hold")
    func vectors() {
        SyncVectorRunner.expectCases("merge")
    }

    @Test("Idempotent: merging the server record into itself is the server record, whatever the base", arguments: 1...4)
    func idempotent(seed: UInt64) {
        var generator = SeededGenerator(state: seed)
        for _ in 0..<200 {
            let (server, _, base) = Self.randomSides(&generator, letters: [.lastWriter, .serverFirst, .maximum, .minimum, .textBody])
            let outcome = FieldMerge.merge(server: server, local: server, base: base)
            #expect(outcome.merged == server)
            #expect(outcome.isServerRecord)
            #expect(outcome.needsTextMerge.isEmpty)
            #expect(outcome.serverFirstLosses.isEmpty)
        }
    }

    /// Commutative for every history writers make: L by stamp, X values that only grow and N values
    /// that only shrink (the merge skips a field a side did not change, as §6.2 says).
    @Test("Commutative in S and L for L, X and N fields and for map elements", arguments: 1...4)
    func commutative(seed: UInt64) {
        var generator = SeededGenerator(state: seed &* 7_919)
        for _ in 0..<200 {
            let (server, local, base) = Self.randomSides(&generator, letters: [.lastWriter, .lastWriter, .maximum, .minimum])
            let forward = FieldMerge.merge(server: server, local: local, base: base).merged
            let backward = FieldMerge.merge(server: local, local: server, base: base).merged
            #expect(forward.fields == backward.fields)
            #expect(forward.stamps == backward.stamps)
        }
    }

    @Test("Every field and key of the server the local side did not stamp survives, and so do its unknown top-level keys", arguments: 1...3)
    func unknownKeysSurvive(seed: UInt64) {
        var generator = SeededGenerator(state: seed &+ 99)
        for _ in 0..<200 {
            var (server, local, base) = Self.randomSides(&generator, letters: [.lastWriter, .serverFirst, .maximum])
            server.fields["future"] = ["kept": true]
            server.stamps["future"] = .value(Self.stamp(.lastWriter, 5))
            server.extra["futureTopLevel"] = [1, 2]
            local.extra["localOnly"] = true
            let merged = FieldMerge.merge(server: server, local: local, base: base).merged
            #expect(merged.fields["future"] == ["kept": true])
            #expect(merged.extra == ["futureTopLevel": [1, 2]])
            for (field, stamp) in server.stamps where local.stamps[field] == nil {
                #expect(merged.stamps[field] == stamp)
                #expect(merged.fields[field] == server.fields[field])
            }
        }
    }

    @Test("An L field's result carries the server's or the local stamp, never an older one", arguments: 1...3)
    func lastWriterStampsComeFromTheInputs(seed: UInt64) {
        var generator = SeededGenerator(state: seed &+ 7)
        for _ in 0..<200 {
            let (server, local, base) = Self.randomSides(&generator, letters: [.lastWriter, .lastWriter])
            let merged = FieldMerge.merge(server: server, local: local, base: base).merged
            for field in ["f0", "f1"] {
                guard let result = merged.stamps[field] else { continue }
                #expect(result == server.stamps[field] || result == local.stamps[field])
            }
        }
    }

    @Test("S is compare-and-set: the local value is next only while the server field is the base's, and a lost write is reported")
    func serverFirst() {
        let base = Self.record(["claim": ["device": "a"]], ["claim": .value(Self.stamp(.serverFirst, 0))])
        let local = Self.record(["claim": ["device": "b"]], ["claim": .value(Self.stamp(.serverFirst, 900, "bbbbbbbb"))])
        let unmoved = FieldMerge.merge(server: base, local: local, base: base)
        #expect(unmoved.merged.fields["claim"] == ["device": "b"])
        #expect(unmoved.takenFromLocal == [StampedPath("claim")])

        let moved = Self.record(["claim": ["device": "c"]], ["claim": .value(Self.stamp(.serverFirst, 100, "cccccccc"))])
        let lost = FieldMerge.merge(server: moved, local: local, base: base)
        #expect(lost.merged == moved)
        #expect(lost.serverFirstLosses.map(\.path) == [StampedPath("claim")])
        #expect(lost.serverFirstLosses.first?.local == ["device": "b"])
    }

    @Test("T: both sides changed the body since the base, so the server's stays and a three-way merge is asked for")
    func textBody() {
        let base = Self.record(["body": ["hash": "a"]], ["body": .value(Self.stamp(.textBody, 0))])
        let server = Self.record(["body": ["hash": "s"]], ["body": .value(Self.stamp(.textBody, 100, "cccccccc"))])
        let local = Self.record(["body": ["hash": "l"]], ["body": .value(Self.stamp(.textBody, 900))])
        let outcome = FieldMerge.merge(server: server, local: local, base: base)
        #expect(outcome.merged == server)
        #expect(outcome.needsTextMerge == ["body"])
        // The local body is still pending its three-way merge, so the outbox row must stay (§6.2 step 4).
        #expect(!outcome.isServerRecord)
        #expect(FieldMerge.merge(server: base, local: local, base: base).merged.fields["body"] == ["hash": "l"])
    }

    @Test("X takes the larger value under the later stamp, an ord object whole")
    func maximumByOrd() {
        let ready: SyncJSON = ["ord": [0, 4], "state": "ready", "at": 1]
        let queued: SyncJSON = ["ord": [0, 1], "state": "queued", "at": 2]
        let server = Self.record(["ingest": ready], ["ingest": .value(Self.stamp(.maximum, 0))])
        let local = Self.record(["ingest": queued], ["ingest": .value(Self.stamp(.maximum, 500, "bbbbbbbb"))])
        let merged = FieldMerge.merge(server: server, local: local, base: nil).merged
        #expect(merged.fields["ingest"] == ready)
        #expect(merged.stamps["ingest"] == .value(Self.stamp(.maximum, 500, "bbbbbbbb")))
        #expect(FieldMerge.compareOrdered([1, 2], [1, 2, 0]) == -1)
        #expect(FieldMerge.compareOrdered("a", 1) == nil)
    }

    @Test("An edit minted against the far-future stamp the server still holds wins; without that exact provenance, stamps decide")
    func farFutureProvenance() {
        let farFuture = Self.stamp(.lastWriter, 40 * 86_400_000, "ffffffff")
        let base = Self.record(["title": "Bad clock"], ["title": .value(farFuture)])
        let edit = Self.record(["title": "Fixed"], ["title": .value(Self.stamp(.lastWriter, 86_400_001))])
        let minted = FieldMerge.merge(server: base, local: edit, base: base, mintedAgainst: [StampedPath("title"): farFuture])
        #expect(minted.merged.fields["title"] == "Fixed")
        #expect(minted.takenFromLocal == [StampedPath("title")])
        // The same stamp copied without provenance (a forwarded stub edit, a late-import patch) loses.
        #expect(FieldMerge.merge(server: base, local: edit, base: base).merged.fields["title"] == "Bad clock")

        // A pinned edit whose server version moved goes by stamp order, whatever it was minted against.
        let seen = Self.stamp(.lastWriter, 1_000)
        let server = Self.record(["title": "Newer"], ["title": .value(Self.stamp(.lastWriter, 9_000, "cccccccc"))])
        let older = Self.record(["title": "Mine"], ["title": .value(Self.stamp(.lastWriter, 5_000, "bbbbbbbb"))])
        let moved = FieldMerge.merge(server: server, local: older, base: Self.record(["title": "Seen"], ["title": .value(seen)]),
                                     mintedAgainst: [StampedPath("title"): seen])
        #expect(moved.merged.fields["title"] == "Newer")
        #expect(moved.isServerRecord)
        // After a fetch made the base the server's record (a reconciling Mac), an older pending edit
        // naming the version it saw before the fetch still loses.
        #expect(FieldMerge.merge(server: server, local: older, base: server, mintedAgainst: [StampedPath("title"): seen])
            .merged.fields["title"] == "Newer")

        // Provenance is per stamped path: a whole map field's entry gives its elements none.
        let mapBase = Self.record(["m": ["k": "Bad clock"]], ["m": .elements(["k": farFuture])])
        let mapEdit = Self.record(["m": ["k": "Fixed"]], ["m": .elements(["k": Self.stamp(.lastWriter, 86_400_001)])])
        #expect(FieldMerge.merge(server: mapBase, local: mapEdit, base: mapBase, mintedAgainst: [StampedPath("m"): farFuture])
            .merged.fields["m"] == ["k": "Bad clock"])
        #expect(FieldMerge.merge(server: mapBase, local: mapEdit, base: mapBase, mintedAgainst: [StampedPath("m", element: "k"): farFuture])
            .merged.fields["m"] == ["k": "Fixed"])
    }

    @Test("A terminal value is never left: a retired card stays retired whichever side retired it, and the result commutes")
    func terminalValues() {
        let base = Self.record(type: "Card", ["deckSourceID": "src_1", "status": "draft"],
                               ["deckSourceID": .value(Self.stamp(.serverFirst, 0)), "status": .value(Self.stamp(.lastWriter, 0))])
        var retired = base
        retired.fields["status"] = "retired"
        retired.stamps["status"] = .value(Self.stamp(.lastWriter, 5_000, "bbbbbbbb"))
        var skippedLater = base
        skippedLater.fields["status"] = "skipped"
        skippedLater.stamps["status"] = .value(Self.stamp(.lastWriter, 6_000, "cccccccc"))
        let localRetired = FieldMerge.merge(server: skippedLater, local: retired, base: base)
        let serverRetired = FieldMerge.merge(server: retired, local: skippedLater, base: base)
        #expect(localRetired.merged.fields["status"] == "retired")
        #expect(serverRetired.merged.fields["status"] == "retired")
        #expect(localRetired.merged.stamps["status"] == serverRetired.merged.stamps["status"])
        #expect(localRetired.takenFromLocal == [StampedPath("status")])
        #expect(serverRetired.isServerRecord)
    }

    @Test("A Keep that lost is reported with its hook even when another local field won, and the hook mints the split card")
    func onServerFirstLoss() throws {
        let theirs: SyncJSON = ["front": "Q", "back": "Theirs", "anchors": [], "fingerprint": "fp-theirs", "at": 1]
        let mine: SyncJSON = ["front": "Q", "back": "Mine", "anchors": [], "fingerprint": "fp-mine", "at": 2]
        let base = Self.record(type: "Card", ["deckSourceID": "src_1", "status": "draft", "alwaysAsk": false],
                               ["deckSourceID": .value(Self.stamp(.serverFirst, 0)), "status": .value(Self.stamp(.lastWriter, 0)),
                                "alwaysAsk": .value(Self.stamp(.lastWriter, 0))])
        var server = base
        server.fields["kept"] = theirs
        server.stamps["kept"] = .value(Self.stamp(.serverFirst, 400, "cccccccc"))
        var local = base
        local.fields["kept"] = mine
        local.stamps["kept"] = .value(Self.stamp(.serverFirst, 500, "bbbbbbbb"))
        local.fields["alwaysAsk"] = true
        local.stamps["alwaysAsk"] = .value(Self.stamp(.lastWriter, 600, "bbbbbbbb"))

        let outcome = FieldMerge.merge(server: server, local: local, base: base)
        #expect(!outcome.isServerRecord, "alwaysAsk won, so M is not the server record")
        let loss = try #require(outcome.serverFirstLosses.first)
        #expect(loss.path == StampedPath("kept"))
        #expect(loss.hook == "splitKeptCard")
        #expect(SyncRecordType.card.spec.serverFirstLossHooks["kept"] == loss.hook)

        let lostKept = try #require(loss.local)
        let split = try #require(ServerFirstLossHooks.splitKeptCard(cardID: "card-1", server: outcome.merged, lostKept: lostKept))
        #expect(split.type == .card)
        #expect(split.id.hasPrefix("card:src_1:split:card-1:"))
        #expect(split.changes["kept"] == .value(mine))
        #expect(split.changes["splitFrom"] == .value("card-1"))
        #expect(ServerFirstLossHooks.splitKeptCard(cardID: "card-1", server: outcome.merged, lostKept: theirs) == nil)
    }

    @Test("Compaction drops removal markers past 90 days by the schema's kinds, and nothing else")
    func compaction() {
        let now: Int64 = 1_759_500_000_000
        let old = SyncStamp(policy: .lastWriter, milliseconds: now - 90 * 86_400_000 - 1, counter: 0, deviceID: "aaaaaaaa")
        let edge = SyncStamp(policy: .lastWriter, milliseconds: now - 90 * 86_400_000, counter: 0, deviceID: "aaaaaaaa")
        let source = Self.record(type: "Source", ["files": ["pdf": .null, "epub": .null, "text": ["hash": "t"]], "meta": ["protected": false]],
                                 ["files": .elements(["pdf": old, "epub": edge, "text": old]), "meta": .elements(["protected": old])])
        let compacted = FieldMerge.compact(source, now: now)
        #expect(compacted.fields["files"] == ["epub": .null, "text": ["hash": "t"]])
        #expect(compacted.fields["meta"] == ["protected": false])
        #expect(FieldMerge.compact(Self.record(["files": ["pdf": .null]], ["files": .elements(["pdf": old])]), now: now).fields["files"] == ["pdf": .null])
    }
}
