import Foundation
import Testing
@testable import ForeverLM

/// Clocks and stamps (§6.3, D9): server-corrected time per column, a stamp minted once and pinned,
/// the clamp on what an edit has seen, no stamp issued twice, and no stamp before the device knows
/// its server offset.
@Suite("Stamp clock")
struct StampClockTests {
    static let device = "k3f7ab2q"
    static let now: Int64 = 1_759_400_000_000

    static func clock(offset: Int64 = 250) -> StampClock {
        StampClock(deviceID: device, offsetSamples: [offset])
    }

    @Test("The stamp-clock vectors hold")
    func vectors() {
        SyncVectorRunner.expectCases("stamp-clock")
    }

    @Test("No stamp is minted before the device has seen a server time, and one is as soon as it has")
    func noStampBeforeAnOffset() {
        var clock = StampClock(deviceID: Self.device)
        #expect(clock.serverOffset == nil)
        #expect(clock.mint(.lastWriter, eventTime: Self.now, seen: nil, now: Self.now) == nil)
        clock.recordServerTime(Self.now + 1_500, sentAt: Self.now)
        #expect(clock.serverOffset == 1_500)
        #expect(clock.mint(.lastWriter, eventTime: Self.now, seen: nil, now: Self.now)?.milliseconds == Self.now + 1_500)
    }

    @Test("The offset is the median of the last 20 acknowledged saves, so one stray response moves nothing")
    func medianOffset() {
        var clock = StampClock(deviceID: Self.device)
        for _ in 0..<19 { clock.recordServerTime(Self.now + 300, sentAt: Self.now) }
        clock.recordServerTime(Self.now + 3_600_000, sentAt: Self.now)
        #expect(clock.serverOffset == 300)
        #expect(!clock.offsetIsLarge)
        #expect(StampClock(deviceID: Self.device, offsetSamples: [200_000]).offsetIsLarge)
    }

    @Test("Each column keeps its own event time: an older change is never re-dated past a later one")
    func perColumnEventTime() throws {
        var clock = Self.clock()
        let t0 = Self.now - 60_000
        let t2 = Self.now
        let minted = (clock.mint(.lastWriter, eventTime: t2, seen: nil, now: Self.now), clock.mint(.lastWriter, eventTime: t0, seen: nil, now: Self.now))
        let late = try #require(minted.0)
        let early = try #require(minted.1)
        #expect(early.milliseconds == t0 + 250)
        #expect(late.milliseconds == t2 + 250)
        #expect(late.isLater(than: early))
        // A remote edit made between the two (t1) still beats the older column and loses to the newer.
        let remote = SyncStamp(policy: .lastWriter, milliseconds: t0 + 30_000 + 250, counter: 0, deviceID: "bbbbbbbb")
        #expect(remote.isLater(than: early))
        #expect(late.isLater(than: remote))
    }

    @Test("A pinned stamp is reused on every encode, and a further change mints a later one")
    func pinning() throws {
        var clock = Self.clock()
        var envelope = SyncEnvelope.new(.notebook, id: "nb1", saltID: "3fa9c2d1")
        var pinned: [StampedPath: SyncStamp] = [:]
        func encode(_ title: String, at eventTime: Int64) throws {
            try envelope.apply(RecordPatch(.notebook, id: "nb1", changes: ["title": .value(.string(title))])) { path, policy, seen in
                if let stamp = pinned[path] { return stamp }
                let minted = clock.mint(policy, eventTime: eventTime, seen: seen, now: Self.now)
                let stamp = try #require(minted)
                pinned[path] = stamp
                return stamp
            }
        }
        try encode("First", at: Self.now - 5_000)
        let first = try #require(pinned[StampedPath("title")])
        // Re-encoding the same change before it is sent reuses the pinned stamp.
        var reencoded = SyncEnvelope.new(.notebook, id: "nb1", saltID: "3fa9c2d1")
        try reencoded.apply(RecordPatch(.notebook, id: "nb1", changes: ["title": .value("First")])) { path, _, _ in try #require(pinned[path]) }
        #expect(reencoded.stamps["title"] == .value(first))
        // A further change to the column discards the pinned stamp; the new one is later than what it saw.
        pinned.removeAll()
        try encode("Second", at: Self.now - 9_000)
        let second = try #require(pinned[StampedPath("title")])
        #expect(second.isLater(than: first))
        #expect(second.milliseconds == first.milliseconds + 1)
    }

    @Test("An edit after seeing a far-future stamp is stamped one millisecond past now + 1 day, never past the bad clock")
    func clampsWhatItSaw() throws {
        var clock = Self.clock(offset: 0)
        let farFuture = SyncStamp(policy: .lastWriter, milliseconds: Self.now + 40 * 86_400_000, counter: 0, deviceID: "ffffffff")
        let minted = clock.mint(.lastWriter, eventTime: Self.now, seen: farFuture, now: Self.now)
        let stamp = try #require(minted)
        #expect(stamp.milliseconds == Self.now + 86_400_000 + 1)
        #expect(farFuture.isLater(than: stamp))
        // The merge still lets it win: it was minted against the stamp the server still holds, and
        // the caller pinned that provenance beside it.
        let held = SyncEnvelope(type: "Notebook", id: "nb1", saltID: "00000000", fields: ["title": "Bad clock"], stamps: ["title": .value(farFuture)])
        var edited = held
        edited.fields["title"] = "Fixed"
        edited.stamps["title"] = .value(stamp)
        #expect(FieldMerge.merge(server: held, local: edited, base: held, mintedAgainst: [StampedPath("title"): farFuture])
            .merged.fields["title"] == "Fixed")
    }

    @Test("Clamping both sides with the tie broken by the stamp itself is the plain order, whatever now is", arguments: 1...3)
    func clampedOrderIsThePlainOrder(seed: UInt64) {
        var generator = FieldMergeTests.SeededGenerator(state: seed)
        let ceiling = Int64(SyncSchema.Limits.receivedStampFutureClampMs)
        func clampedCompare(_ a: SyncStamp, _ b: SyncStamp, now: Int64) -> Int {
            let ca = min(a.milliseconds, now + ceiling)
            let cb = min(b.milliseconds, now + ceiling)
            if ca != cb { return ca < cb ? -1 : 1 }
            return SyncStamp.compare(a, b)
        }
        for _ in 0..<2_000 {
            let now = Self.now + Int64.random(in: -5 * ceiling...5 * ceiling, using: &generator)
            let a = SyncStamp(policy: .lastWriter, milliseconds: Self.now + Int64.random(in: -10 * ceiling...10 * ceiling, using: &generator),
                              counter: Int.random(in: 0...2, using: &generator), deviceID: ["aaaaaaaa", "bbbbbbbb"].randomElement(using: &generator)!)
            let b = SyncStamp(policy: .lastWriter, milliseconds: Self.now + Int64.random(in: -10 * ceiling...10 * ceiling, using: &generator),
                              counter: Int.random(in: 0...2, using: &generator), deviceID: ["aaaaaaaa", "bbbbbbbb"].randomElement(using: &generator)!)
            #expect(clampedCompare(a, b, now: now) == SyncStamp.compare(a, b))
        }
    }

    @Test("Stamps within one millisecond take the next counter; a provisional stamp loses to any real one")
    func counterAndProvisional() throws {
        var clock = Self.clock()
        let first = clock.mint(.lastWriter, eventTime: Self.now, seen: nil, now: Self.now)
        let second = clock.mint(.lastWriter, eventTime: Self.now, seen: nil, now: Self.now)
        let a = try #require(first)
        let b = try #require(second)
        #expect(a.counter == 0 && b.counter == 1 && b.isLater(than: a))
        let provisional = SyncStamp.provisional(.lastWriter, deviceID: "bbbbbbbb")
        #expect(provisional.rawValue == "L0000000000001.0000.bbbbbbbb")
        #expect(a.isLater(than: provisional))
    }

    @Test("Two changes in one millisecond below the last stamp never get one stamp, nor does a millisecond the clock moved past")
    func noStampTwice() throws {
        var clock = Self.clock(offset: 0)
        let older = Self.now - 10_000
        let minted = [
            clock.mint(.lastWriter, eventTime: Self.now, seen: nil, now: Self.now),
            clock.mint(.lastWriter, eventTime: older, seen: nil, now: Self.now),
            clock.mint(.lastWriter, eventTime: older, seen: nil, now: Self.now),
            clock.mint(.lastWriter, eventTime: Self.now + 5_000, seen: nil, now: Self.now),
            clock.mint(.lastWriter, eventTime: Self.now, seen: nil, now: Self.now),
        ].compactMap { $0 }
        #expect(minted.count == 5)
        #expect(Set(minted.map(\.rawValue)).count == 5)
        #expect(minted[2].isLater(than: minted[1]) && minted[2].milliseconds == older)
        #expect(minted[4].milliseconds == Self.now && minted[4].counter == 1)
        #expect(clock.earlierCounters == [older: 1, Self.now: 1])
    }

    @Test("A clock survives being saved and read back (ck_clock), and a corrupt one is refused instead of trapping at its first mint")
    func codable() throws {
        var clock = Self.clock()
        _ = clock.mint(.lastWriter, eventTime: Self.now, seen: nil, now: Self.now)
        _ = clock.mint(.lastWriter, eventTime: Self.now - 60_000, seen: nil, now: Self.now)
        let restored = try JSONDecoder().decode(StampClock.self, from: JSONEncoder().encode(clock))
        #expect(restored == clock)
        #expect(restored.earlierCounters.count == 1)
        for corrupt in [
            #"{"deviceID":"K3F7AB2Q","offsetSamples":[250],"lastMilliseconds":1759400000250,"lastCounter":0}"#,
            #"{"deviceID":"k3f7ab2q","offsetSamples":[250],"lastMilliseconds":1759400000250,"lastCounter":10000}"#,
            #"{"deviceID":"k3f7ab2q","offsetSamples":[250],"lastMilliseconds":99999999999999,"lastCounter":0}"#,
            #"{"deviceID":"k3f7ab2q","offsetSamples":[250],"lastMilliseconds":1759400000250,"lastCounter":0,"earlierCounters":{"1759400000250":1}}"#,
            #"{"deviceID":"k3f7ab2q","offsetSamples":[250],"lastMilliseconds":1759400000250,"lastCounter":0,"earlierCounters":{"x":1}}"#,
        ] {
            #expect(throws: DecodingError.self, Comment(rawValue: corrupt)) {
                try JSONDecoder().decode(StampClock.self, from: Data(corrupt.utf8))
            }
        }
    }
}
