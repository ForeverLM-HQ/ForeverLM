import CryptoKit
import Foundation

/// Record names (§3.4): `prefix + "_" + base32lower(HMAC-SHA256(zoneSalt, type + "\n" + id))[0..<26]`,
/// and `root` for a zone's `ZoneRoot`. Names carry no title, URL or user text, since CloudKit shows
/// them in clear; the prefix only repeats the record type. Vectors: `schema/vectors/naming.json`.
enum RecordNaming {
    static let saltByteCount = 32

    static func recordName(type: SyncRecordType, id: String, salt: Data) -> String {
        let spec = type.spec
        if let fixed = spec.fixedRecordName { return fixed }
        let message = Data((type.rawValue + "\n" + id).utf8)
        let code = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: salt))
        return spec.prefix! + "_" + String(base32(Data(code)).prefix(SyncSchema.recordNameHashLength))
    }

    /// The record type a name belongs to, from its prefix, so a bare deletion is routed without a lookup.
    static func recordType(ofRecordName name: String) -> SyncRecordType? {
        if name == SyncSchema.rootRecordName { return .zoneRoot }
        guard let separator = name.firstIndex(of: "_") else { return nil }
        return SyncRecordType(prefix: String(name[..<separator]))
    }

    /// A zone's salt from `ZoneRoot.salt`: base64 of exactly 32 bytes.
    static func salt(base64: String) -> Data? {
        guard let bytes = Data(base64Encoded: base64), bytes.count == saltByteCount else { return nil }
        return bytes
    }

    static func newSalt() -> Data {
        Data((0..<saltByteCount).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// The first 8 hex characters of sha256 of the 32 salt bytes (§2.4 step 6), repeated in every payload.
    static func saltID(_ salt: Data) -> String {
        String(SyncIdentity.sha256Hex(salt).prefix(8))
    }

    /// RFC 4648 base32, lowercase, no padding.
    static func base32(_ data: Data) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
        var output: [UInt8] = []
        output.reserveCapacity((data.count * 8 + 4) / 5)
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                output.append(alphabet[Int((buffer >> UInt32(bits - 5)) & 31)])
                bits -= 5
            }
        }
        if bits > 0 { output.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }
        return String(decoding: output, as: UTF8.self)
    }
}

/// The deterministic logical ids of §4.1. Identity is code: every client derives the same id from
/// the same facts, so two devices that make the same thing make one record.
enum SyncIdentity {
    /// The device id migrated history is written under (`al:<day>:legacy22`); never drawn.
    static let migratedHistoryDeviceID = "legacy22"

    /// A new installation's device id: 5 random bytes as 8 base32 characters, never `legacy22`.
    static func newDeviceID() -> String {
        while true {
            let id = RecordNaming.base32(Data((0..<5).map { _ in UInt8.random(in: .min ... .max) }))
            if id != migratedHistoryDeviceID { return id }
        }
    }

    /// A web source: `src_` + hex(sha256("source:v1:" + URLNormalizer v1 of its URL)), as
    /// `SourceIdentity.stableID` mints it on the Mac.
    static func sourceID(normalizedURL: String) -> String {
        "src_" + sha256Hex(Data("source:v1:\(normalizedURL)".utf8))
    }

    /// A file captured on the iPhone or the web (D47), from the lowercase hex sha256 of its bytes,
    /// so the same bytes captured twice land on one source.
    static func sourceFileID(sha256Hex fileHash: String) -> String {
        "src_" + sha256Hex(Data("source:v1:file:\(fileHash)".utf8))
    }

    /// A show or channel: `col_` + hex(sha256("collection:v1:<kind>:<externalKey>")).
    static func collectionID(kind: String, externalKey: String) -> String {
        "col_" + sha256Hex(Data("collection:v1:\(kind):\(externalKey)".utf8))
    }

    /// Migrated attempts: `sit:legacy:` + the first 24 hex characters of sha256 of
    /// `session:<session_id>`, or of `day:<YYYY-MM-DD>` for an attempt with no session.
    static func migratedSittingID(_ input: String) -> String {
        "sit:legacy:" + sha256Hex(Data(input.utf8)).prefix(24)
    }

    /// `en:<containerID>:<itemKind>:<itemID>`; a second span of one item in a lesson adds `#2`, `#3`…
    static func entryID(containerID: String, itemKind: String, itemID: String, span: Int = 1) -> String {
        "en:\(containerID):\(itemKind):\(itemID)" + (span > 1 ? "#\(span)" : "")
    }

    static func deviceRecordID(_ deviceID: String) -> String { "dev:\(deviceID)" }
    static func enrollmentID(courseID: String) -> String { "enr:\(courseID)" }
    static func readingStateID(targetID: String) -> String { "rs:\(targetID)" }
    static func markID(kind: String, target: String) -> String { "mk:\(kind):\(target)" }
    static func notebookStateID(notebookID: String) -> String { "ns:\(notebookID)" }
    static func placementID(sourceID: String) -> String { "pl:\(sourceID)" }
    static func activityLogID(day: String, deviceID: String) -> String { "al:\(day):\(deviceID)" }
    static func cardDraftID(deckSourceID: String, seedKey: String) -> String { "card:\(deckSourceID):\(seedKey)" }
    static func practiceID(ruleID: String, scope: String, period: String) -> String { "pr:\(ruleID):\(scope):\(period)" }
    static func jobID(kind: String, target: String) -> String { "job:\(kind):\(target)" }

    static func contentID(owner: String, role: String, partHash32: String) -> String {
        "ct:\(owner):\(role):\(partHash32)"
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).hexString
    }
}
