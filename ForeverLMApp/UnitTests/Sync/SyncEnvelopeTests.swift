import Foundation
import Testing
@testable import ForeverLM

/// The payload envelope (§3.2): bytes, gzip and its inflate bound, the 256 KiB cap, spilled
/// strings, the salt's id, unchanged values never re-stamped, terminal values never left, and
/// dates in integer milliseconds.
@Suite("Sync envelope")
struct SyncEnvelopeTests {
    private static let stamp = SyncStamp("L1759400000000.0000.k3f7ab2q")!

    private static func notebook(_ fields: [String: SyncJSON] = ["title": "Cells"]) -> SyncEnvelope {
        SyncEnvelope(type: "Notebook", id: "nb1", saltID: "3fa9c2d1", fields: fields,
                     stamps: fields.mapValues { _ in .value(stamp) })
    }

    @Test("The envelope vectors hold")
    func vectors() {
        SyncVectorRunner.expectCases("envelope")
    }

    @Test("A small payload is stored as JSON and a large one gzip, and both read back")
    func storageForms() throws {
        let small = Self.notebook()
        let smallBytes = try small.storedPayload()
        #expect(smallBytes.first == UInt8(ascii: "{"))
        #expect(try SyncEnvelope(storedPayload: smallBytes) == small)

        let large = Self.notebook(["title": "Cells", "summary": .string(String(repeating: "mitochondria ", count: 2_000))])
        let largeBytes = try large.storedPayload()
        #expect(SyncGzip.isGzip(largeBytes))
        #expect(largeBytes.count < large.json.serialized().count)
        #expect(try SyncEnvelope(storedPayload: largeBytes) == large)
    }

    @Test("A payload over 256 KiB after gzip is refused")
    func cap() {
        // Random-looking text gzip cannot shrink below the cap.
        var generator = SystemRandomNumberGenerator()
        let noise = String((0..<600_000).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement(using: &generator)! })
        #expect(throws: SyncEnvelopeError.self) { try Self.notebook(["title": .string(noise)]).storedPayload() }
    }

    @Test("A string field spills above 32 KiB, never a key, an enum or a non-string field")
    func spillDecision() {
        #expect(!SyncEnvelope.spills(type: .exchange, field: "question", utf8Count: 32_768))
        #expect(SyncEnvelope.spills(type: .exchange, field: "question", utf8Count: 32_769))
        #expect(SyncEnvelope.spills(type: .notebook, field: "instructions", utf8Count: 100_000))
        #expect(!SyncEnvelope.spills(type: .setting, field: "key", utf8Count: 100_000))
        #expect(!SyncEnvelope.spills(type: .chat, field: "kind", utf8Count: 100_000))
        #expect(!SyncEnvelope.spills(type: .notebook, field: "relatedNotebookIDs", utf8Count: 100_000))
    }

    @Test("A spilled field holds its satellite's FileRef under its own stamp, and the same text is not re-sent")
    func spilledField() throws {
        let text = String(repeating: "Read the methods first. ", count: 2_000)
        let stored = try SyncGzip.compress(Data(text.utf8))
        let file = FileRef(owner: "nb1", role: "field.instructions", hash: SyncIdentity.sha256Hex(Data(text.utf8)),
                           size: Int64(text.utf8.count), mime: "text/plain; charset=utf-8", encoding: "gzip", storedParts: [stored])
        var envelope = Self.notebook(["instructions": SyncEnvelope.spillMarker(file)])
        #expect(envelope.spilledFields == ["instructions"])
        #expect(SyncEnvelope.spilledFile(envelope.fields["instructions"]!) == file)
        #expect(file.isInline)
        #expect(file.satelliteIDs == ["ct:nb1:field.instructions:\(FileRef.partHash32(stored))"])
        let stamped = try envelope.apply(RecordPatch(.notebook, id: "nb1", changes: ["instructions": .value(.string(text))])) { _, _, _ in
            Issue.record("the unchanged text was stamped")
            return Self.stamp
        }
        #expect(stamped.isEmpty)
    }

    @Test("The salt's id is the first 8 hex characters of sha256 of the 32 decoded bytes")
    func saltID() throws {
        let salt = try #require(RecordNaming.salt(base64: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="))
        #expect(RecordNaming.saltID(salt) == "630dcd29")
        #expect(RecordNaming.salt(base64: "AAEC") == nil)
        let fresh = RecordNaming.newSalt()
        #expect(fresh.count == 32)
        #expect(RecordNaming.saltID(fresh).count == 8)
    }

    @Test("An unchanged value is dropped and keeps its stamp; a changed one is stamped against the stamp it saw")
    func unchangedValuesAreNotResent() throws {
        var envelope = Self.notebook(["title": "Cells", "status": "active"])
        var seen: [StampedPath: SyncStamp?] = [:]
        let later = try #require(SyncStamp("L1759400009000.0000.k3f7ab2q"))
        let stamped = try envelope.apply(RecordPatch(.notebook, id: "nb1", changes: ["title": .value("Cells"), "status": .value("archived")])) { path, policy, held in
            #expect(policy == .lastWriter)
            seen[path] = held
            return later
        }
        #expect(stamped == [StampedPath("status")])
        #expect(seen[StampedPath("status")] == .some(Self.stamp))
        #expect(envelope.stamps["title"] == .value(Self.stamp))
        #expect(envelope.stamps["status"] == .value(later))
    }

    @Test("A change out of a terminal value is refused, and a refused patch leaves the envelope as held")
    func terminalValues() throws {
        let held = SyncEnvelope(type: "Card", id: "card-1", saltID: "3fa9c2d1",
                                fields: ["deckSourceID": "src_1", "status": "retired", "alwaysAsk": false],
                                stamps: ["deckSourceID": .value(Self.stamp), "status": .value(Self.stamp), "alwaysAsk": .value(Self.stamp)])
        var envelope = held
        // alwaysAsk sorts first, so it would be stamped before status is refused; nothing is kept.
        #expect(throws: RecordPatchError.leavesTerminalValue("status")) {
            try envelope.apply(RecordPatch(.card, id: "card-1", changes: ["alwaysAsk": .value(true), "status": .value("kept")])) { _, _, _ in
                Self.stamp
            }
        }
        #expect(envelope == held)
        let unchanged = try envelope.apply(RecordPatch(.card, id: "card-1", changes: ["status": .value("retired")])) { _, _, _ in
            Issue.record("the same terminal value was stamped")
            return Self.stamp
        }
        #expect(unchanged.isEmpty)
        #expect(SyncRecordType.card.spec.field("status")?.terminalValues == ["retired"])
    }

    @Test("Cocoa seconds and milliseconds round-trip without drift")
    func milliseconds() {
        let date = Date(timeIntervalSinceReferenceDate: 781_092_800.123)
        let ms = SyncTime.milliseconds(date)
        #expect(ms == 1_759_400_000_123)
        #expect(SyncTime.milliseconds(SyncTime.date(milliseconds: ms)) == ms)
        for ms: Int64 in [978_307_200_000, 1_759_400_000_999, 1_790_652_879_000, 1] {
            #expect(SyncTime.milliseconds(cocoaSeconds: SyncTime.cocoaSeconds(milliseconds: ms)) == ms)
        }
    }

    @Test("gzip output is RFC 1952: the magic bytes, and it inflates to the input")
    func gzip() throws {
        let text = Data(String(repeating: "Fission and fusion. ", count: 500).utf8)
        let compressed = try SyncGzip.compress(text)
        #expect(Array(compressed.prefix(3)) == [0x1F, 0x8B, 0x08])
        #expect(try SyncGzip.decompress(compressed, maxBytes: text.count) == text)
        var corrupt = compressed
        corrupt[corrupt.count - 6] ^= 0xFF
        #expect(throws: SyncGzip.Failure.self) { try SyncGzip.decompress(corrupt, maxBytes: text.count) }
        #expect(try SyncGzip.decompress(SyncGzip.compress(Data()), maxBytes: 0) == Data())
    }

    @Test("Inflating stops at the bound: a member over it is refused, and so is one whose trailer understates its size")
    func gzipBound() throws {
        let text = Data(String(repeating: "Fission and fusion. ", count: 500).utf8)
        let compressed = try SyncGzip.compress(text)
        #expect(throws: SyncGzip.Failure.self) { try SyncGzip.decompress(compressed, maxBytes: text.count - 1) }
        var understated = compressed
        let claim = UInt32(100)
        for shift in 0..<4 { understated[understated.count - 4 + shift] = UInt8(truncatingIfNeeded: claim >> UInt32(8 * shift)) }
        #expect(throws: SyncGzip.Failure.self) { try SyncGzip.decompress(understated, maxBytes: text.count) }
        // An envelope's payload is bounded by the schema's limit (16 MiB); envelope.json pins both refusals.
        #expect(SyncSchema.Limits.payloadMaxInflatedBytes == 16 * 1024 * 1024)
    }
}
