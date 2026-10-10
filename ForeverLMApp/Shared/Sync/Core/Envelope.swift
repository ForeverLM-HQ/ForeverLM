import Compression
import CryptoKit
import Foundation

/// A field's stamp in an envelope: one stamp for a scalar, one per key for a map or a set.
enum SyncFieldStamp: Equatable, Sendable {
    case value(SyncStamp)
    case elements([String: SyncStamp])
}

enum SyncEnvelopeError: Error, Equatable {
    /// Not JSON, not an object, missing one of the envelope keys, or gzip that does not inflate within
    /// `Limits.payloadMaxInflatedBytes`.
    case notAnEnvelope
    /// An envelope version this build cannot read; the raw payload is kept untouched.
    case unsupportedEnvelope(Int)
    /// A stamp outside the grammar of §3.2 rule 3.
    case invalidStamp(field: String)
    /// Stored bytes over 256 KiB: the record is parked in `ck_quarantine`.
    case payloadTooLarge(storedBytes: Int)
}

/// The payload of every record (§3.2): one JSON object of `env`, `type`, `id`, `rev`, `saltID`,
/// `fields` and `stamps`. Unknown top-level keys, fields, map keys and set elements are kept, and a
/// client writes by patching the envelope it holds (`apply(_:stamp:)`), never by encoding a record
/// from a struct, so nothing a newer client wrote is lost (§6.5). Vectors:
/// `schema/vectors/envelope.json`.
struct SyncEnvelope: Equatable, Sendable {
    enum StorageForm: Equatable, Sendable {
        case plain
        case gzip
    }

    /// The record type's name, kept raw: a type this build does not know is stored, not projected.
    var type: String
    var id: String
    /// The writer's schema revision (§12.5).
    var rev: Int
    /// The zone salt's id (§2.4 step 6); a record of another salt is ignored on apply.
    var saltID: String
    var fields: [String: SyncJSON]
    var stamps: [String: SyncFieldStamp]
    /// Top-level keys this build does not know.
    var extra: [String: SyncJSON]

    init(type: String, id: String, rev: Int = SyncSchema.schemaRevision, saltID: String,
         fields: [String: SyncJSON] = [:], stamps: [String: SyncFieldStamp] = [:], extra: [String: SyncJSON] = [:]) {
        self.type = type
        self.id = id
        self.rev = rev
        self.saltID = saltID
        self.fields = fields
        self.stamps = stamps
        self.extra = extra
    }

    var recordType: SyncRecordType? { SyncRecordType(rawValue: type) }

    /// Reads stored payload bytes: gzip when they start `1F 8B`, else UTF-8 JSON. Gzip that would
    /// inflate past `Limits.payloadMaxInflatedBytes` is refused before it is inflated, so a small
    /// record written into a space cannot make every member's device hold hundreds of megabytes.
    init(storedPayload bytes: Data) throws {
        let text: Data
        if SyncGzip.isGzip(bytes) {
            guard let inflated = try? SyncGzip.decompress(bytes, maxBytes: SyncSchema.Limits.payloadMaxInflatedBytes) else {
                throw SyncEnvelopeError.notAnEnvelope
            }
            text = inflated
        } else {
            text = bytes
        }
        guard let json = try? SyncJSON(parsing: text) else { throw SyncEnvelopeError.notAnEnvelope }
        try self.init(json: json)
    }

    init(json: SyncJSON) throws {
        guard var object = json.objectValue else { throw SyncEnvelopeError.notAnEnvelope }
        guard let env = object["env"]?.intValue else { throw SyncEnvelopeError.notAnEnvelope }
        guard env == SyncSchema.envelopeVersion else { throw SyncEnvelopeError.unsupportedEnvelope(env) }
        guard let type = object["type"]?.stringValue, let id = object["id"]?.stringValue,
              let rev = object["rev"]?.intValue, let saltID = object["saltID"]?.stringValue,
              let fields = object["fields"]?.objectValue, let rawStamps = object["stamps"]?.objectValue
        else { throw SyncEnvelopeError.notAnEnvelope }
        var stamps: [String: SyncFieldStamp] = [:]
        for (field, raw) in rawStamps {
            switch raw {
            case .string(let text):
                guard let stamp = SyncStamp(text) else { throw SyncEnvelopeError.invalidStamp(field: field) }
                stamps[field] = .value(stamp)
            case .object(let elements):
                var parsed: [String: SyncStamp] = [:]
                for (key, element) in elements {
                    guard let text = element.stringValue, let stamp = SyncStamp(text) else {
                        throw SyncEnvelopeError.invalidStamp(field: field)
                    }
                    parsed[key] = stamp
                }
                stamps[field] = .elements(parsed)
            default:
                throw SyncEnvelopeError.invalidStamp(field: field)
            }
        }
        for key in SyncSchema.envelopeKeys { object.removeValue(forKey: key) }
        self.init(type: type, id: id, rev: rev, saltID: saltID, fields: fields, stamps: stamps, extra: object)
    }

    var json: SyncJSON {
        var object = extra
        object["env"] = SyncJSON(SyncSchema.envelopeVersion)
        object["type"] = .string(type)
        object["id"] = .string(id)
        object["rev"] = SyncJSON(rev)
        object["saltID"] = .string(saltID)
        object["fields"] = .object(fields)
        object["stamps"] = .object(stamps.mapValues { stamp in
            switch stamp {
            case .value(let stamp): return .string(stamp.rawValue)
            case .elements(let elements): return .object(elements.mapValues { .string($0.rawValue) })
            }
        })
        return .object(object)
    }

    /// The bytes stored in `payload`: JSON, gzip above 16 KiB, refused above 256 KiB.
    func storedPayload() throws -> Data {
        let text = json.serialized()
        let stored = Self.storageForm(jsonByteCount: text.count) == .gzip ? try SyncGzip.compress(text) : text
        try Self.checkStoredSize(stored.count)
        return stored
    }

    static func storageForm(jsonByteCount: Int) -> StorageForm {
        jsonByteCount > SyncSchema.Limits.payloadGzipThresholdBytes ? .gzip : .plain
    }

    static func checkStoredSize(_ storedBytes: Int) throws {
        if storedBytes > SyncSchema.Limits.payloadMaxBytes { throw SyncEnvelopeError.payloadTooLarge(storedBytes: storedBytes) }
    }
}

// MARK: - Spilled strings (§3.2 rule 8)

extension SyncEnvelope {
    /// Whether a string of `utf8Count` bytes in `field` is stored as a `field.<name>` satellite:
    /// above 32 KiB, and only for a plain string field (never an enum or a field marked `spill: false`).
    static func spills(type: SyncRecordType, field: String, utf8Count: Int) -> Bool {
        guard let spec = type.spec.field(field), spec.spills else { return false }
        return utf8Count > SyncSchema.Limits.spillStringBytes
    }

    /// `{"$file": FileRef}`, the value a spilled field holds under its own stamp.
    static func spillMarker(_ file: FileRef) -> SyncJSON {
        .object([SyncSchema.spillMarkerKey: file.value])
    }

    /// The satellite a spilled field's value points at.
    static func spilledFile(_ value: SyncJSON) -> FileRef? {
        guard let object = value.objectValue, object.count == 1, let file = object[SyncSchema.spillMarkerKey] else { return nil }
        return FileRef(json: file)
    }

    /// The fields whose value is a spilled string, sorted.
    var spilledFields: [String] {
        fields.filter { Self.spilledFile($0.value) != nil }.map(\.key).sorted()
    }
}

// MARK: - Writing (§6.5 rule 1)

/// The only write API: the changed values of one record, patched onto the envelope a client holds.
struct RecordPatch: Equatable, Sendable {
    enum Change: Equatable, Sendable {
        /// A scalar field's whole new value; `.null` clears it.
        case value(SyncJSON)
        /// A map's changed keys (`.null` removes one) or a set's changed elements (`true`, `false`).
        case elements([String: SyncJSON])
    }

    let type: SyncRecordType
    let id: String
    var changes: [String: Change]

    init(_ type: SyncRecordType, id: String, changes: [String: Change] = [:]) {
        self.type = type
        self.id = id
        self.changes = changes
    }
}

enum RecordPatchError: Error, Equatable {
    case wrongRecord
    /// A field the schema does not list: this build writes only fields it knows.
    case unknownField(String)
    /// A whole value for a map or set, or elements for a scalar.
    case wrongKind(String)
    /// A set element that is not `true` or `false`.
    case notASetElement(field: String, element: String)
    /// A change out of a value the field never leaves (`Card.status` `retired`, §6.1).
    case leavesTerminalValue(String)
}

/// One stamped place in an envelope: a scalar field, or one key of a map or set.
struct StampedPath: Hashable, Sendable, CustomStringConvertible {
    let field: String
    let element: String?

    init(_ field: String, element: String? = nil) {
        self.field = field
        self.element = element
    }

    var description: String { element.map { "\(field)[\($0)]" } ?? field }
}

extension SyncEnvelope {
    /// An empty envelope for a record this client creates.
    static func new(_ type: SyncRecordType, id: String, saltID: String) -> SyncEnvelope {
        SyncEnvelope(type: type.rawValue, id: id, saltID: saltID)
    }

    /// Patches `patch` onto this envelope and returns the paths it stamped, sorted.
    ///
    /// A value equal to the one held (compared in the wire domain, rule 9) is dropped and keeps its
    /// stamp, so re-saving a form or restoring a position stamps nothing; so is a long string whose
    /// sha256 is the hash of the satellite the field already spilled into. Every other value gets
    /// `stamp(path, policy, seen)`, where `seen` is the stamp held for that path: the caller's pinned
    /// stamp for the change, or one `StampClock` mints against `seen`. A caller that pins a minted
    /// stamp keeps the `seen` it was minted against beside it and gives it back to the merge
    /// (`FieldMerge.merge(mintedAgainst:)`). Keys of a map or set the patch does not name, and every
    /// field it does not name, are left exactly as held. The patch is applied whole or not at all:
    /// a refusal, or a stamp that cannot be minted, leaves the envelope as held. Fields are stamped
    /// in name order, elements in key order.
    @discardableResult
    mutating func apply(
        _ patch: RecordPatch,
        stamp: (StampedPath, SyncPolicy, SyncStamp?) throws -> SyncStamp
    ) throws -> [StampedPath] {
        guard patch.type.rawValue == type, patch.id == id else { throw RecordPatchError.wrongRecord }
        var patched = self
        var stamped: [StampedPath] = []
        for (field, change) in patch.changes.sorted(by: { $0.key < $1.key }) {
            guard let spec = patch.type.spec.field(field) else { throw RecordPatchError.unknownField(field) }
            switch (spec.kind, change) {
            case (.scalar, .value(let value)):
                if let held = patched.fields[field], Self.sameWireValue(held, value) { continue }
                if let held = patched.fields[field]?.stringValue, spec.terminalValues.contains(held) {
                    throw RecordPatchError.leavesTerminalValue(field)
                }
                let path = StampedPath(field)
                let seen: SyncStamp? = if case .value(let held)? = patched.stamps[field] { held } else { nil }
                patched.stamps[field] = .value(try stamp(path, spec.policy, seen))
                patched.fields[field] = value
                stamped.append(path)
            case (.map, .elements(let changes)), (.set, .elements(let changes)):
                var heldValues = patched.fields[field]?.objectValue ?? [:]
                var heldStamps: [String: SyncStamp] = if case .elements(let held)? = patched.stamps[field] { held } else { [:] }
                if patched.fields[field]?.objectValue == nil { heldStamps = [:] }
                var changed = false
                for (element, value) in changes.sorted(by: { $0.key < $1.key }) {
                    if spec.kind == .set, value.boolValue == nil {
                        throw RecordPatchError.notASetElement(field: field, element: element)
                    }
                    if let held = heldValues[element], heldStamps[element] != nil, Self.sameWireValue(held, value) { continue }
                    let path = StampedPath(field, element: element)
                    heldStamps[element] = try stamp(path, spec.policy, heldStamps[element])
                    heldValues[element] = value
                    stamped.append(path)
                    changed = true
                }
                if changed {
                    patched.fields[field] = .object(heldValues)
                    patched.stamps[field] = .elements(heldStamps)
                }
            default:
                throw RecordPatchError.wrongKind(field)
            }
        }
        if !stamped.isEmpty { patched.rev = SyncSchema.schemaRevision }
        self = patched
        return stamped.sorted { $0.description < $1.description }
    }

    /// Equal in the wire domain, where a long string equals the spilled satellite of the same text.
    static func sameWireValue(_ held: SyncJSON, _ new: SyncJSON) -> Bool {
        if held == new { return true }
        if let file = spilledFile(held), case .string(let text) = new {
            return SyncIdentity.sha256Hex(Data(text.utf8)) == file.hash
        }
        return false
    }
}

// MARK: - Milliseconds

/// The wire's dates are integer epoch milliseconds (§3.2 rule 6). The Mac stores Cocoa seconds
/// (`Date.timeIntervalSinceReferenceDate`, REAL); converting rounds half away from zero in IEEE
/// double, pinned by the `cocoaToMs` and `msRoundTrip` vectors, so an unchanged date compares equal.
enum SyncTime {
    static let cocoaEpochOffsetSeconds = 978_307_200.0

    static func milliseconds(cocoaSeconds: Double) -> Int64 {
        Int64(((cocoaSeconds + cocoaEpochOffsetSeconds) * 1000).rounded(.toNearestOrAwayFromZero))
    }

    static func cocoaSeconds(milliseconds: Int64) -> Double {
        Double(milliseconds) / 1000 - cocoaEpochOffsetSeconds
    }

    static func milliseconds(_ date: Date) -> Int64 {
        milliseconds(cocoaSeconds: date.timeIntervalSinceReferenceDate)
    }

    static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSinceReferenceDate: cocoaSeconds(milliseconds: milliseconds))
    }
}

// MARK: - gzip

/// RFC 1952 gzip around raw DEFLATE (RFC 1951 streams with no zlib header: Foundation's
/// `NSData.compressed(using: .zlib)` writes them, and the Compression framework's bounded
/// `compression_decode_buffer` reads them, since Foundation cannot stop an inflate at a size).
/// Payloads above 16 KiB, text satellites and spilled strings are gzip, and browsers and Workers
/// read them with `DecompressionStream("gzip")`.
enum SyncGzip {
    struct Failure: Error, Equatable {}

    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    static func compress(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        // Magic, deflate, no flags, no modification time, no extra flags, unknown OS.
        var output = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        output.append(deflated)
        appendLittleEndian(crc32(data), to: &output)
        appendLittleEndian(UInt32(truncatingIfNeeded: data.count), to: &output)
        return output
    }

    /// The bytes a gzip member holds, refused (`Failure`) when they would be more than `maxBytes`.
    /// The trailer's size is only a claim: one more byte than it is ever held, so a stream that
    /// inflates past its claim fills that byte and is refused, and nothing past `maxBytes` is inflated.
    /// The DEFLATE stream must reach the end of its final block: `compression_decode_buffer` hands
    /// back what a stream cut short decoded so far, which the JS core refuses, so the stream API
    /// runs to `COMPRESSION_STATUS_END` instead.
    static func decompress(_ data: Data, maxBytes: Int) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 0x08 else { throw Failure() }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else { throw Failure() }
            index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 }
        guard index < bytes.count - 8 else { throw Failure() }
        let trailer = Array(bytes[(bytes.count - 8)...])
        let expectedCRC = UInt32(trailer[0]) | UInt32(trailer[1]) << 8 | UInt32(trailer[2]) << 16 | UInt32(trailer[3]) << 24
        let expectedSize = Int(UInt32(trailer[4]) | UInt32(trailer[5]) << 8 | UInt32(trailer[6]) << 16 | UInt32(trailer[7]) << 24)
        guard expectedSize <= maxBytes else { throw Failure() }
        guard let inflated = inflateWhole(Array(bytes[index..<(bytes.count - 8)]), capacity: expectedSize + 1),
              inflated.count == expectedSize
        else { throw Failure() }
        guard crc32(inflated) == expectedCRC else { throw Failure() }
        return inflated
    }

    /// Raw DEFLATE inflated to the end of its final block, into at most `capacity` bytes; nil for a
    /// stream that is corrupt, ends before its final block does, or would pass `capacity`.
    private static func inflateWhole(_ input: [UInt8], capacity: Int) -> Data? {
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(streamPointer) }
        guard !input.isEmpty, capacity > 0 else { return nil }
        var output = [UInt8](repeating: 0, count: capacity)
        let status: compression_status = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                streamPointer.pointee.src_ptr = source.baseAddress!
                streamPointer.pointee.src_size = source.count
                streamPointer.pointee.dst_ptr = destination.baseAddress!
                streamPointer.pointee.dst_size = destination.count
                var status = COMPRESSION_STATUS_OK
                // Every byte is offered at once; a stream that wants more input, or more room, has none.
                while status == COMPRESSION_STATUS_OK {
                    let before = (streamPointer.pointee.src_size, streamPointer.pointee.dst_size)
                    status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    if status == COMPRESSION_STATUS_OK, before == (streamPointer.pointee.src_size, streamPointer.pointee.dst_size) { break }
                }
                return status
            }
        }
        guard status == COMPRESSION_STATUS_END else { return nil }
        let written = output.count - streamPointer.pointee.dst_size
        guard written < capacity else { return nil }
        return Data(output[0..<written])
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
    }
}
