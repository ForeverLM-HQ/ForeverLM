import Foundation

/// A field's stamp (§3.2 rule 3): `L1759400000123.0001.k3f7ab2q` is the policy letter, 13-digit
/// epoch milliseconds (server-corrected, §6.3), a 4-digit counter and the 8-character device id.
///
/// Two stamps are ordered by the 27 characters after the letter as plain strings, which is
/// (milliseconds, counter, device id); the letter never takes part. Equality is of the whole
/// stamp, letter included, so a stamp equals only the one it was copied from. Comparisons use
/// this order unclamped: see `isLater(than:)`.
struct SyncStamp: Hashable, Sendable, CustomStringConvertible {
    static let maxMilliseconds: Int64 = 9_999_999_999_999
    static let maxCounter = 9_999

    let policy: SyncPolicy
    let milliseconds: Int64
    let counter: Int
    let deviceID: String

    init(policy: SyncPolicy, milliseconds: Int64, counter: Int, deviceID: String) {
        precondition((0...Self.maxMilliseconds).contains(milliseconds), "stamp milliseconds out of range")
        precondition((0...Self.maxCounter).contains(counter), "stamp counter out of range")
        precondition(Self.isValidDeviceID(deviceID), "stamp device id is not 8 base32 characters")
        self.policy = policy
        self.milliseconds = milliseconds
        self.counter = counter
        self.deviceID = deviceID
    }

    /// Parses `^[LSXNT][0-9]{13}\.[0-9]{4}\.[a-z2-7]{8}$`; nil for anything else.
    init?(_ text: String) {
        let bytes = Array(text.utf8)
        guard bytes.count == 28, bytes[14] == UInt8(ascii: "."), bytes[19] == UInt8(ascii: "."),
              let policy = SyncPolicy(rawValue: String(UnicodeScalar(bytes[0])))
        else { return nil }
        var milliseconds: Int64 = 0
        for byte in bytes[1...13] {
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
            milliseconds = milliseconds * 10 + Int64(byte - UInt8(ascii: "0"))
        }
        var counter = 0
        for byte in bytes[15...18] {
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
            counter = counter * 10 + Int(byte - UInt8(ascii: "0"))
        }
        let deviceID = String(decoding: bytes[20...27], as: UTF8.self)
        guard Self.isValidDeviceID(deviceID) else { return nil }
        self.policy = policy
        self.milliseconds = milliseconds
        self.counter = counter
        self.deviceID = deviceID
    }

    /// A skeletal import's stamp (§3.5.4): millisecond 1, so any real write beats it.
    static func provisional(_ policy: SyncPolicy, deviceID: String) -> SyncStamp {
        SyncStamp(policy: policy, milliseconds: Int64(SyncSchema.Limits.provisionalStampMs), counter: 0, deviceID: deviceID)
    }

    /// 8 characters of RFC 4648 lowercase base32 (`a-z`, `2-7`).
    static func isValidDeviceID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 8 && bytes.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "2")...UInt8(ascii: "7")).contains(byte)
        }
    }

    var rawValue: String {
        policy.rawValue + Self.digits(milliseconds, count: 13) + "." + Self.digits(Int64(counter), count: 4) + "." + deviceID
    }

    var description: String { rawValue }

    /// -1, 0 or 1 by the 27 characters after the letter.
    static func compare(_ lhs: SyncStamp, _ rhs: SyncStamp) -> Int {
        if lhs.milliseconds != rhs.milliseconds { return lhs.milliseconds < rhs.milliseconds ? -1 : 1 }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter ? -1 : 1 }
        if lhs.deviceID == rhs.deviceID { return 0 }
        return lhs.deviceID.utf8.lexicographicallyPrecedes(rhs.deviceID.utf8) ? -1 : 1
    }

    /// The later of two stamps in the order of rule 3.
    ///
    /// §6.3 asks for both sides of a comparison to be clamped to now + 1 day. A clamp never
    /// reverses two stamps' order; it only makes stamps past the ceiling equal, and that tie is
    /// broken by the 27 characters themselves (the rule defined for the clamp), so the clamped
    /// comparison is this unclamped one, on every device whatever its clock. What keeps a wrong
    /// clock from owning a field is the mint (`StampClock`: an edit after a far-future stamp is
    /// stamped `clamp(seen) + 1 ms`, never past it) and the merge, which lets that edit win because
    /// it was minted against the stamp the server still holds (`FieldMerge`, `mintedAgainst`).
    func isLater(than other: SyncStamp) -> Bool { Self.compare(self, other) > 0 }

    private static func digits(_ value: Int64, count: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, count - text.count)) + text
    }
}
