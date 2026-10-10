import Foundation
import Testing
@testable import ForeverLM

/// The shared late-import base and its watermark (docs/cloudkit-schema-design.md §3.5.1, §13.6, WP16b):
/// 64 shards named by the first byte of sha256 of the old record name divided by 4, written as
/// deterministic bytes, and a watermark that knows when the old zones have been quiet for seven days.
@Suite("Migration base")
struct MigrationBaseTests {
    private static let day: TimeInterval = 86_400
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static let entry = MigrationBaseEntry(changeTag: "tag", waiting: true, records: [
        "Notebook:nb1": MigrationBaseRecord(owned: true, hashes: ["title": "aa", "researchQuestions/q": "bb"]),
        "Entry:en:nb1:source:s1": MigrationBaseRecord(owned: false, hashes: ["state": "cc"]),
    ])

    @Test("An old record's shard is the first byte of sha256 of its name divided by 4, in hex, 00 to 3f")
    func shardNames() {
        let names = (0..<2000).map { MigrationBaseShards.name(forRecordName: "rec-\($0)") }
        #expect(names.allSatisfy { MigrationBaseShards.allNames.contains($0) })
        #expect(Set(names).count == 64, "2000 names spread over every shard")
        #expect(MigrationBaseShards.allNames.count == 64 && MigrationBaseShards.allNames.first == "00" && MigrationBaseShards.allNames.last == "3f")
        // sha256("abc") starts 0xba = 186; 186 / 4 = 46 = 0x2e
        #expect(MigrationBaseShards.name(forRecordName: "abc") == "2e")
    }

    @Test("A partition names all 64 shards, an entry lands in its record's shard, and a shard survives its bytes")
    func shardBytes() throws {
        let entries = ["Knowledge/rec-1": Self.entry, "Team-t@owner/rec-2": MigrationBaseEntry(changeTag: nil, waiting: false, records: [:])]
        let partition = MigrationBaseShards.partition(entries)
        #expect(partition.count == 64)
        let shard = try #require(partition[MigrationBaseShards.name(forRecordName: "rec-1")])
        #expect(shard["Knowledge/rec-1"] == Self.entry)
        let bytes = MigrationBaseShards.encode(shard)
        #expect(try MigrationBaseShards.decode(bytes) == shard, "the change tag and the waiting flag survive")
        #expect(MigrationBaseShards.encode(shard) == bytes, "the bytes are deterministic, so two Macs agree")
        #expect(MigrationBaseShards.recordName(ofEntryKey: "Team-t@owner/rec-2") == "rec-2")
        #expect(MigrationBaseShards.zone(ofEntryKey: "Team-t@owner/rec-2") == "Team-t@owner")
        #expect(try MigrationBaseShards.decode(Data("{\"v\":1}".utf8)).isEmpty)
    }

    @Test("Seven quiet days finish the import, an old-zone write clears it, and polling is hourly, daily, then weekly")
    func watermark() {
        var mark = MigrationImportWatermark(container: "iCloud.com.foreverlm", zones: ["Knowledge"], tokens: ["Knowledge": "AAA="])
        #expect(MigrationImportWatermark(json: mark.json) == mark)
        #expect(mark.pollInterval == MigrationImportWatermark.hour)

        mark.recordPass(at: Self.t0, sawOldWrite: false)
        #expect(mark.quietSince == SyncTime.milliseconds(Self.t0) && mark.finishedAt == nil, "the first quiet pass starts the quiet period")
        mark.recordPass(at: Self.t0.addingTimeInterval(6 * Self.day), sawOldWrite: false)
        #expect(mark.finishedAt == nil, "six quiet days are not enough")
        mark.recordPass(at: Self.t0.addingTimeInterval(7 * Self.day), sawOldWrite: false)
        #expect(mark.finishedAt == SyncTime.milliseconds(Self.t0.addingTimeInterval(7 * Self.day)) && mark.isQuiet)
        #expect(mark.pollInterval == Self.day)

        mark.recordPass(at: Self.t0.addingTimeInterval(8 * Self.day), sawOldWrite: true)
        let written = SyncTime.milliseconds(Self.t0.addingTimeInterval(8 * Self.day))
        #expect(mark.finishedAt == nil && mark.quietSince == written && mark.lastOldWriteAt == written, "a write clears finishedAt and restarts the quiet period")
        #expect(mark.pollInterval == MigrationImportWatermark.hour)
        mark.recordPass(at: Self.t0.addingTimeInterval(14 * Self.day), sawOldWrite: false)
        #expect(mark.finishedAt == nil, "a week counts from the last write")

        mark.removedAt = 1
        #expect(mark.pollInterval == 7 * Self.day, "after the removal the check for a re-created zone is weekly")
    }

    @Test("A watermark with a key it does not know still reads")
    func unknownKeys() throws {
        let mark = try #require(MigrationImportWatermark(json: .object(["zones": ["Knowledge"], "future": "x"])))
        #expect(mark.zones == ["Knowledge"] && mark.tokens.isEmpty)
    }

    @Test("A base entry survives its JSON form, lists a map field per element, and splits its keys at the first colon")
    func baseEntry() throws {
        let notebook = LegacyV2Record(type: .notebook, id: "nb1", fields: ["title": "N", "researchQuestions": ["q1": "x"]], giving: .owns)
        let entry = MigrationBaseEntry(mapping: LegacyMapping(entity: .learningGoal, logicalKey: "lg", records: [notebook]), changeTag: "t", waiting: true)
        #expect(MigrationBaseEntry(json: entry.jsonWithTag) == entry)
        #expect(entry.records["Notebook:nb1"]?.hashes["researchQuestions/q1"] != nil)
        #expect(MigrationRecordKey(baseKey: "Entry:en:nb1:source:s1", spaceID: nil) == MigrationRecordKey(.entry, "en:nb1:source:s1"))
    }
}
