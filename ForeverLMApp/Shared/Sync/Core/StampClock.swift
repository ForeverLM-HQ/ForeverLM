/// The device's stamp source (§6.3, D9). It keeps the server offset (the median of the last 20
/// `server time − local send time` deltas from acknowledged saves, or from a response's own
/// timestamps on the web and in the hosted MCP) and the last stamp it issued. The Mac persists it
/// in `ck_clock`; the iPhone in its replica.
///
/// A stamp's milliseconds are `max(eventTime + serverOffset, clamp(seen) + 1)`, where `eventTime` is
/// the local time the field changed (per column on the Mac, so an edit is never re-dated past a
/// later remote edit) and `seen` is the replica's stamp for the field, clamped to now + 1 day: an
/// edit made after seeing a value is later than it, and an edit made after seeing a far-future
/// stamp is stamped one millisecond past the ceiling instead of inheriting the bad clock. The
/// counter tells apart stamps this device issues within one millisecond, including a millisecond
/// below the last stamp (an older column's event time): the clock remembers the last counter of the
/// 64 latest such milliseconds, so it never issues one (milliseconds, counter) pair twice while it
/// remembers that millisecond.
///
/// The stamp the caller pins is minted against `seen`, and the caller keeps `seen` beside it: the
/// merge lets the change win against that exact server version (`FieldMerge.merge(mintedAgainst:)`).
/// A further change to a column whose pinned stamp may already be on its way passes that stamp as
/// `seen` when it is later than the replica's, so the new stamp is later than the one it replaces.
struct StampClock: Codable, Equatable, Sendable {
    static let offsetSampleCount = 20
    /// How many milliseconds below the last stamp the clock remembers a counter for.
    static let earlierMillisecondCount = 64
    /// Above this the device logs that its clock is off; it stamps in server time either way.
    static let largeOffsetMilliseconds: Int64 = 120_000

    let deviceID: String
    /// `server − local` in milliseconds, oldest first.
    private(set) var offsetSamples: [Int64] = []
    private(set) var lastMilliseconds: Int64 = -1
    private(set) var lastCounter = 0
    /// The last counter issued in each millisecond below `lastMilliseconds` the clock has minted in,
    /// for the latest `earlierMillisecondCount` of them.
    private(set) var earlierCounters: [Int64: Int] = [:]

    /// A clock as it was saved: its offset samples (only the last 20 are kept), its last issued
    /// stamp (`lastMilliseconds` −1 before the first) and the counters below it.
    init(deviceID: String, offsetSamples: [Int64] = [], lastMilliseconds: Int64 = -1, lastCounter: Int = 0,
         earlierCounters: [Int64: Int] = [:]) {
        precondition(SyncStamp.isValidDeviceID(deviceID), "a stamp clock needs an 8-character base32 device id")
        self.deviceID = deviceID
        self.offsetSamples = Array(offsetSamples.suffix(Self.offsetSampleCount))
        self.lastMilliseconds = lastMilliseconds
        self.lastCounter = lastCounter
        self.earlierCounters = earlierCounters
        forgetOldestEarlierCounters()
    }

    /// The median offset: the lower middle sample for an even count. Nil until the device has seen
    /// a server time, and a device without one sends nothing (§2.4 step 4).
    var serverOffset: Int64? {
        guard !offsetSamples.isEmpty else { return nil }
        return offsetSamples.sorted()[(offsetSamples.count - 1) / 2]
    }

    var offsetIsLarge: Bool { serverOffset.map { abs($0) > Self.largeOffsetMilliseconds } ?? false }

    /// Records one acknowledged save or response: the server's time and the local time it was sent.
    mutating func recordServerTime(_ serverMilliseconds: Int64, sentAt localMilliseconds: Int64) {
        offsetSamples.append(serverMilliseconds - localMilliseconds)
        if offsetSamples.count > Self.offsetSampleCount {
            offsetSamples.removeFirst(offsetSamples.count - Self.offsetSampleCount)
        }
    }

    func serverTime(atLocal localMilliseconds: Int64) -> Int64? {
        serverOffset.map { localMilliseconds + $0 }
    }

    /// The stamp of a change made at local time `eventTime` to a field whose replica stamp is
    /// `seen`, minted at local time `now`. Nil before the first server time; the caller keeps the
    /// change unstamped (and anything that would name its stamp waits) until then.
    mutating func mint(_ policy: SyncPolicy, eventTime: Int64, seen: SyncStamp?, now: Int64) -> SyncStamp? {
        guard let offset = serverOffset else { return nil }
        var milliseconds = eventTime + offset
        if let seen {
            let ceiling = now + offset + Int64(SyncSchema.Limits.receivedStampFutureClampMs)
            milliseconds = max(milliseconds, min(seen.milliseconds, ceiling) + 1)
        }
        milliseconds = min(max(milliseconds, 0), SyncStamp.maxMilliseconds)
        var counter = nextCounter(at: milliseconds)
        // A full millisecond moves to the next one, which may itself have counters already.
        while counter > SyncStamp.maxCounter, milliseconds < SyncStamp.maxMilliseconds {
            milliseconds += 1
            counter = nextCounter(at: milliseconds)
        }
        counter = min(counter, SyncStamp.maxCounter)
        // An older event time (a column changed before the last stamp was issued) keeps its own
        // milliseconds and does not move the clock's high-water mark; its counter is remembered.
        if milliseconds > lastMilliseconds {
            if lastMilliseconds >= 0 { earlierCounters[lastMilliseconds] = lastCounter }
            lastMilliseconds = milliseconds
            lastCounter = counter
        } else if milliseconds == lastMilliseconds {
            lastCounter = counter
        } else {
            earlierCounters[milliseconds] = counter
        }
        forgetOldestEarlierCounters()
        return SyncStamp(policy: policy, milliseconds: milliseconds, counter: counter, deviceID: deviceID)
    }

    /// One past the last counter issued at `milliseconds`, or 0 when the clock remembers none.
    private func nextCounter(at milliseconds: Int64) -> Int {
        if milliseconds == lastMilliseconds { return lastCounter + 1 }
        return earlierCounters[milliseconds].map { $0 + 1 } ?? 0
    }

    private mutating func forgetOldestEarlierCounters() {
        earlierCounters = earlierCounters.filter { $0.key < lastMilliseconds && $0.key >= 0 }
        guard earlierCounters.count > Self.earlierMillisecondCount else { return }
        for milliseconds in earlierCounters.keys.sorted().prefix(earlierCounters.count - Self.earlierMillisecondCount) {
            earlierCounters.removeValue(forKey: milliseconds)
        }
    }

    // MARK: - Codable (`ck_clock`)

    private enum CodingKeys: String, CodingKey {
        case deviceID, offsetSamples, lastMilliseconds, lastCounter, earlierCounters
    }

    /// Reads a saved clock and refuses one that could not mint a valid stamp (a corrupt `ck_clock`
    /// row), instead of trapping at the first mint.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let deviceID = try container.decode(String.self, forKey: .deviceID)
        let offsetSamples = try container.decodeIfPresent([Int64].self, forKey: .offsetSamples) ?? []
        let lastMilliseconds = try container.decodeIfPresent(Int64.self, forKey: .lastMilliseconds) ?? -1
        let lastCounter = try container.decodeIfPresent(Int.self, forKey: .lastCounter) ?? 0
        let earlier = try container.decodeIfPresent([String: Int].self, forKey: .earlierCounters) ?? [:]
        guard SyncStamp.isValidDeviceID(deviceID) else {
            throw DecodingError.dataCorruptedError(forKey: .deviceID, in: container, debugDescription: "not 8 base32 characters")
        }
        guard (-1...SyncStamp.maxMilliseconds).contains(lastMilliseconds) else {
            throw DecodingError.dataCorruptedError(forKey: .lastMilliseconds, in: container, debugDescription: "outside the stamp range")
        }
        guard (0...SyncStamp.maxCounter).contains(lastCounter) else {
            throw DecodingError.dataCorruptedError(forKey: .lastCounter, in: container, debugDescription: "outside the counter range")
        }
        var earlierCounters: [Int64: Int] = [:]
        for (key, counter) in earlier {
            guard let milliseconds = Int64(key), (0..<max(lastMilliseconds, 0)).contains(milliseconds),
                  (0...SyncStamp.maxCounter).contains(counter)
            else {
                throw DecodingError.dataCorruptedError(forKey: .earlierCounters, in: container, debugDescription: "\(key): \(counter)")
            }
            earlierCounters[milliseconds] = counter
        }
        self.init(deviceID: deviceID, offsetSamples: offsetSamples, lastMilliseconds: lastMilliseconds,
                  lastCounter: lastCounter, earlierCounters: earlierCounters)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(offsetSamples, forKey: .offsetSamples)
        try container.encode(lastMilliseconds, forKey: .lastMilliseconds)
        try container.encode(lastCounter, forKey: .lastCounter)
        try container.encode(Dictionary(uniqueKeysWithValues: earlierCounters.map { (String($0.key), $0.value) }),
                             forKey: .earlierCounters)
    }
}
